import Foundation

/// WireGuard 设备表（docs/packet-capture/WIREGUARD-DEVICES.md）：配置页的设备列表、引擎的 WireGuard 监听、
/// 设备栏和 TCP 包里的名字都从这里取。
///
/// 一台设备 = 一份密钥 + 一个 UDP 端口 + 一张二维码 + 一个名字。读写盘都在一条串行队列上做（`io`），做完回主线程发布；
/// 设备表「已经落盘的那一版」只在这条队列上读改写，两次操作（界面上点的、MCP 调的）不会互相盖掉。
/// 设备加了或删了，WireGuard 开着就让引擎换监听（`NetCaptureSession.wireguardDevicesChanged`）；改名不用。
@MainActor
final class WireGuardDeviceStore: ObservableObject {
    static let shared = WireGuardDeviceStore()

    @Published private(set) var devices: [WireGuardDevice] = []
    /// 启动时的读取（和迁移）做完了没有。
    @Published private(set) var loaded = false
    /// 密钥文件缺了或坏了的设备：不出二维码、不开监听，提示删掉重新添加。
    @Published private(set) var missingKeys: Set<String> = []
    /// 每台最后一个包的时间（HTTP 和 TCP 都算）。只在内存里：重启后是「还没连过」，直到它再来包。
    @Published private(set) var lastSeen: [String: Date] = [:]

    private var keys: [String: WireGuardKeys] = [:]
    /// 密钥不在 `<id>.json` 的设备（迁移时旧文件没搬成）：监听用这个文件。
    private var keyFiles: [String: URL] = [:]
    private var whenLoaded: [() -> Void] = []
    private var loading = false
    private let io = DispatchQueue(label: "com.baobox.netcapture.wireguard", qos: .userInitiated)
    /// 已经落盘的设备表。只在 `io` 上碰。
    private let committed = CommittedDevices()

    private init() {}

    // MARK: - 读

    /// 启动时（`activate()`）在后台读设备表，必要时先把多设备之前的那一份密钥迁成第一台设备。
    /// 迁移写设备表失败：报 `StorageWriteFailure`，保持「没读完」（不能添加设备，免得新设备占掉旧端口、旧钥匙作废），
    /// 下一次 `ensureLoaded`（打开 WireGuard、MCP 加设备）再试；等着的事留到读成功再做。
    func load() {
        guard !loaded, !loading else { return }
        loading = true
        let files = NetCaptureEnv.wireguardFiles
        // 迁出来的那台叫什么：用户给 10.0.0.1 起过别名就用它，否则「设备 1」。别名留着不删：
        // 家里的网段可能真有一台 10.0.0.1 的局域网设备，那个名字是给它起的。
        let migratedName = NetCaptureEnv.deviceAlias(for: WireGuardKeys.clientAddress)
            .flatMap(WireGuardDeviceTable.cleanName) ?? Self.formatName(1)
        let legacyPort = NetCaptureEnv.wireguardPort
        let committed = committed
        io.async {
            let outcome = Result { try files.load(migratedName: migratedName, legacyPort: legacyPort) }
            if case .success(let result) = outcome { committed.devices = result.devices }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading = false
                    switch outcome {
                    case .failure(let error):
                        StorageWriteFailure.report(L("netcapture.wireguard.storageName"), reason: error.localizedDescription)
                    case .success(let result):
                        for problem in result.problems {
                            StorageWriteFailure.report(L("netcapture.wireguard.storageName"), reason: problem)
                        }
                        self.keys = result.keys
                        self.keyFiles = result.keyFiles
                        self.publish(result.devices)
                        self.loaded = true
                        let actions = self.whenLoaded
                        self.whenLoaded = []
                        actions.forEach { $0() }
                    }
                }
            }
        }
    }

    /// 读完了再做（打开 WireGuard 开关时要知道有没有设备、密钥在哪）。
    func ensureLoaded(then: @escaping () -> Void) {
        if loaded {
            then()
            return
        }
        whenLoaded.append(then)
        load()
    }

    func device(id: String) -> WireGuardDevice? { devices.first { $0.id == id } }

    /// 引擎这次要开的监听：有钥匙的设备，每台一个，按列表顺序。
    var listeners: [WireGuardListener] {
        let files = NetCaptureEnv.wireguardFiles
        return devices.filter { keys[$0.id] != nil }
            .map { WireGuardListener(keyFile: (keyFiles[$0.id] ?? files.keyURL(id: $0.id)).path, port: $0.port) }
    }

    /// 二维码上的端点：Mac 现在的局域网 IP + 这台的端口。
    func endpoint(for device: WireGuardDevice) -> String {
        "\(NetworkInterfaces.primaryIP()):\(device.port)"
    }

    /// 二维码里的客户端配置（也是「复制配置」的内容）。钥匙丢了的设备没有。
    func clientConfig(for device: WireGuardDevice) -> String? {
        keys[device.id]?.clientConfig(endpoint: endpoint(for: device))
    }

    /// 添加时输入框里先填好的名字：「设备 N」。
    func defaultName() -> String {
        WireGuardDeviceTable.defaultName(existing: devices.map(\.name), format: Self.formatName)
    }

    nonisolated static func formatName(_ number: Int) -> String { L("netcapture.wg.defaultName \(number)") }

    // MARK: - 改

    enum StoreError: LocalizedError {
        case noFreePort
        case notFound
        case notLoaded
        var errorDescription: String? {
            switch self {
            case .noFreePort: return "no free UDP port"
            case .notFound: return "no such device"
            case .notLoaded: return "the device list could not be read yet"
            }
        }
    }

    /// 添加一台：建钥匙（权限 600）、分端口、写设备表，然后引擎换监听（WireGuard 开着时）。
    /// 先写密钥再写设备表：设备表写不下去只多一个没人用的密钥文件，不会出现一台没有钥匙的设备。
    func add(name: String, completion: @escaping (Result<WireGuardDevice, Error>) -> Void) {
        // 设备表没读成（迁移写盘失败）时不能加：新设备会占掉旧二维码的端口。
        guard loaded else {
            completion(.failure(StoreError.notLoaded))
            return
        }
        let cleaned = WireGuardDeviceTable.cleanName(name) ?? defaultName()
        let files = NetCaptureEnv.wireguardFiles
        let start = NetCaptureEnv.wireguardPort
        let reserved = NetCaptureEnv.reservedPorts
        let committed = committed
        io.async {
            let result = Result { () throws -> (WireGuardDevice, WireGuardKeys, [WireGuardDevice]) in
                // 旧的单份密钥还没迁走（上次搬文件失败）：它的端口（旧设置里的那个）也算占着。
                let legacy: Set<UInt16> = files.legacyKeysExist ? [start] : []
                guard let port = WireGuardDeviceTable.nextPort(start: start, used: committed.devices.map(\.port),
                                                               reserved: reserved.union(legacy)) else { throw StoreError.noFreePort }
                let device = WireGuardDevice(id: WireGuardDeviceTable.newID(), name: cleaned, port: port)
                let keys = try files.createKeys(id: device.id)
                let next = committed.devices + [device]
                do {
                    try files.writeTable(next)
                } catch {
                    try? files.removeKeys(id: device.id)
                    throw error
                }
                committed.devices = next
                return (device, keys, next)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let (device, keys, next)):
                        self.keys[device.id] = keys
                        self.publish(next)
                        NetCaptureSession.shared.wireguardDevicesChanged()
                        completion(.success(device))
                    case .failure(let error):
                        StorageWriteFailure.report(L("netcapture.wireguard.storageName"), reason: error.localizedDescription)
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// 改名：只改设备表，引擎不用重启（设备栏、TCP 包、配置页一起变）。
    func rename(id: String, to name: String, completion: ((Bool) -> Void)? = nil) {
        guard let cleaned = WireGuardDeviceTable.cleanName(name) else {
            completion?(false)
            return
        }
        mutate({ list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
            list[index].name = cleaned
        }, then: { ok in
            if ok { FlowStore.shared.refreshDeviceLabels() }
            completion?(ok)
        })
    }

    /// 删除：从设备表里去掉、删掉它的密钥，引擎换监听。已经抓到的包还在列表里（名字显示「已删除的设备」）。
    func remove(id: String, completion: ((Bool) -> Void)? = nil) {
        let files = NetCaptureEnv.wireguardFiles
        let legacy = keyFiles[id]
        mutate({ list in
            guard list.contains(where: { $0.id == id }) else { throw StoreError.notFound }
            list.removeAll { $0.id == id }
        }, afterWrite: {
            do {
                try files.removeKeys(id: id)
                // 这台用的还是旧的单份密钥（没搬成）：删设备就是不要这把钥匙了。
                if let legacy { try FileManager.default.removeItem(at: legacy) }
            } catch {
                StorageWriteFailure.report(L("netcapture.wireguard.storageName"), reason: error.localizedDescription)
            }
        }, then: { ok in
            guard ok else {
                completion?(false)
                return
            }
            self.keys[id] = nil
            self.keyFiles[id] = nil
            FlowStore.shared.refreshDeviceLabels()
            NetCaptureSession.shared.wireguardDevicesChanged()
            completion?(true)
        })
    }

    /// 在 `io` 上改设备表、写盘，回主线程发布。写不下去报 `StorageWriteFailure`，列表不变。
    private func mutate(_ change: @escaping @Sendable (inout [WireGuardDevice]) throws -> Void,
                        afterWrite: (@Sendable () -> Void)? = nil,
                        then: @escaping (Bool) -> Void) {
        let files = NetCaptureEnv.wireguardFiles
        let committed = committed
        io.async {
            var next = committed.devices
            var failure: Error?
            do {
                try change(&next)
                try files.writeTable(next)
                committed.devices = next
                afterWrite?()
            } catch {
                failure = error
            }
            let published = committed.devices
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failure, !(failure is StoreError) {
                        StorageWriteFailure.report(L("netcapture.wireguard.storageName"), reason: failure.localizedDescription)
                    }
                    self.publish(published)
                    then(failure == nil)
                }
            }
        }
    }

    private func publish(_ list: [WireGuardDevice]) {
        devices = list
        missingKeys = Set(list.map(\.id).filter { keys[$0] == nil })
        WireGuardNameSnapshot.shared.set(list)
    }

    // MARK: - 最近活动

    /// 引擎推来的一批事件里，哪些设备来了包（HTTP 请求 / 响应 / WebSocket 消息、没解密的 TLS、TCP 连接与数据）。
    /// 在 `FlowStore` / `TCPStore` 落完这批之后调：响应、TCP 数据要靠它们找回是哪台设备。
    func noteActivity(_ events: [CaptureEvent]) {
        var flowIDs = Set<UUID>()
        var tcpIDs = Set<UUID>()
        var touched = Set<String>()
        for event in events {
            switch event {
            case .request(let request): if let id = request.wireguard { touched.insert(id) }
            case .tls(_, let id?, _, _): touched.insert(id)
            case .tcpOpen(let open): if let id = open.wireguard { touched.insert(id) }
            case .response(let response): flowIDs.insert(response.id)
            case .webSocket(let message): flowIDs.insert(message.flowID)
            case .tcpData(let data): tcpIDs.insert(data.connectionID)
            default: continue
            }
        }
        if !flowIDs.isEmpty {
            for flow in FlowStore.shared.flows.reversed() where flowIDs.contains(flow.id) {
                if let id = flow.wireguardID { touched.insert(id) }
            }
        }
        if !tcpIDs.isEmpty {
            for connection in TCPStore.shared.connections.reversed() where tcpIDs.contains(connection.id) {
                if let id = connection.wireguardID { touched.insert(id) }
            }
        }
        guard !touched.isEmpty else { return }
        let now = Date()
        for id in touched { lastSeen[id] = now }
    }
}

/// 设备表已经落盘的那一版。只在 WireGuardDeviceStore 的 `io` 队列上读写。
private final class CommittedDevices: @unchecked Sendable {
    var devices: [WireGuardDevice] = []
}

/// 设备名的线程安全快照：MCP 在自己的队列上要把 `wg:<id>` 变成名字。
final class WireGuardNameSnapshot: @unchecked Sendable {
    static let shared = WireGuardNameSnapshot()
    private let lock = NSLock()
    private var devices: [WireGuardDevice] = []
    private init() {}

    func set(_ list: [WireGuardDevice]) { lock.lock(); devices = list; lock.unlock() }
    func get() -> [WireGuardDevice] { lock.lock(); defer { lock.unlock() }; return devices }
    func name(id: String) -> String? { get().first { $0.id == id }?.name }
}
