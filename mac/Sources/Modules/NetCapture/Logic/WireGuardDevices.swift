import Foundation

// 网络抓包的纯逻辑（Foundation + CryptoKit，进 BaoboxTests）：WireGuard 多台设备。
// 见 docs/packet-capture/WIREGUARD-DEVICES.md。
//
// 一台设备 = 一份密钥 + 一个 UDP 端口 + 一张二维码 + 一个名字。引擎给每台开一个 `--mode wireguard:<密钥文件>@<端口>`，
// 桥按「连接是从哪个监听进来的」认设备：密钥文件名（去掉 `.json`）就是设备 id。
// 数据在 `<supportDir>/wireguard/`：设备表 `devices.json`（数组顺序 = 列表顺序），每台的密钥 `<id>.json`。

/// 一台经 WireGuard 接进来的设备。
struct WireGuardDevice: Equatable, Identifiable, Sendable {
    /// 小写 UUID。也是密钥文件名（`<id>.json`）和设备键（`wg:<id>`）里的那一段。
    let id: String
    var name: String
    /// 添加时分配，之后不变（二维码里写死了）。
    let port: UInt16
}

/// 设备表的编解码与几条规则（端口、默认名、设备键）。
enum WireGuardDeviceTable {
    /// 设备键：事件里带 `wg` 的连接记在 `wg:<id>` 名下，其余仍按来源 IP。
    static let keyPrefix = "wg:"

    static func deviceKey(id: String) -> String { keyPrefix + id }

    /// `wg:<id>` → id；不是隧道设备的键返回 nil。
    static func deviceID(fromKey key: String) -> String? {
        guard key.hasPrefix(keyPrefix) else { return nil }
        let id = String(key.dropFirst(keyPrefix.count))
        return id.isEmpty ? nil : id
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    /// id 只认小写 UUID：它要拼进文件路径，别的写法一概不认。
    static func isValidID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && id == id.lowercased()
    }

    /// 名字去掉首尾空白；空的不算名字。
    static func cleanName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 解设备表。整个文件不是数组 → 空表；坏的条目（id 不是小写 UUID、没有名字、端口不对）跳过；
    /// 重复的 id、重复的端口只留第一条（两个监听抢一个端口，引擎会起不来）。
    static func decode(_ data: Data) -> [WireGuardDevice] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        var seenIDs = Set<String>()
        var seenPorts = Set<UInt16>()
        var devices: [WireGuardDevice] = []
        for item in items {
            guard let object = item as? [String: Any],
                  let id = object["id"] as? String, isValidID(id),
                  let name = (object["name"] as? String).flatMap(cleanName),
                  let number = object["port"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let port = UInt16(exactly: number.doubleValue), port > 0,
                  !seenIDs.contains(id), !seenPorts.contains(port) else { continue }
            seenIDs.insert(id)
            seenPorts.insert(port)
            devices.append(WireGuardDevice(id: id, name: name, port: port))
        }
        return devices
    }

    static func encode(_ devices: [WireGuardDevice]) -> Data {
        let objects = devices.map { ["id": $0.id, "name": $0.name, "port": Int($0.port)] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
    }

    /// 新设备的端口：从设置里的起始端口往后排 —— 取「起始端口」和「起始端口以上已用的最大端口 + 1」里大的那个，
    /// 再跳过已用的和 `reserved`（代理、SOCKS、配置页、MCP 的端口）。往上排到 65535 还没有，就从起始端口、再从 1024 起找空的。
    /// 全满（实际不会）返回 nil。
    static func nextPort(start: UInt16, used: [UInt16], reserved: Set<UInt16>) -> UInt16? {
        let taken = Set(used).union(reserved)
        let start = max(start, 1024)
        func scan(from low: UInt16, to high: UInt16) -> UInt16? {
            guard low <= high else { return nil }
            return (low...high).first { !taken.contains($0) }
        }
        var first: UInt16? = start
        if let highest = used.filter({ $0 >= start }).max() {
            first = highest == .max ? nil : highest + 1
        }
        if let first, let port = scan(from: first, to: .max) { return port }
        return scan(from: start, to: .max) ?? scan(from: 1024, to: start)
    }

    /// 「设备 N」：N 从「已有几台 + 1」起，跟已有的名字重了就往上加。`format` 把数字变成本地化的名字。
    static func defaultName(existing: [String], format: (Int) -> String) -> String {
        let names = Set(existing)
        var number = existing.count + 1
        while names.contains(format(number)) { number += 1 }
        return format(number)
    }
}

/// 多设备之前只有一份密钥（`<supportDir>/wireguard.json`）。首次启动新版本时把它变成第一台设备：
/// 钥匙和端口都不变，扫过旧码的手机照样能连。先写设备表、再搬密钥文件，中途失败下次重来不丢钥匙。
enum WireGuardMigration {
    enum Plan: Equatable {
        /// 不用迁（新装，或早就迁完了）。
        case nothing
        /// 有旧密钥、还没有设备表：建第一台设备，写设备表，再把旧文件搬成它的密钥。
        case migrate
        /// 上次迁到一半：设备表写了，旧文件还没搬。搬到这一台（第一台，迁出来的那台总在最前面）名下。
        case finishMove(deviceID: String)
    }

    /// `legacyValid`：旧密钥文件在、而且读得出来（读不出来的不迁，留着也不碍事）。
    static func plan(tableExists: Bool, devices: [WireGuardDevice], legacyValid: Bool,
                     keyFileExists: (String) -> Bool) -> Plan {
        guard legacyValid else { return .nothing }
        guard tableExists else { return .migrate }
        if let first = devices.first, !keyFileExists(first.id) { return .finishMove(deviceID: first.id) }
        return .nothing
    }
}

/// 设备表与各台密钥的读写（在后台线程调）。写设备表是「临时文件 + 原子改名」，密钥沿用 `WireGuardKeyFile`（权限 600）。
struct WireGuardDeviceFiles: Sendable {
    /// `<supportDir>/wireguard/`
    let folder: URL
    /// 多设备之前的那一份：`<supportDir>/wireguard.json`
    let legacyKeyURL: URL

    var tableURL: URL { folder.appendingPathComponent("devices.json") }

    func keyURL(id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    /// 读设备表；文件不存在返回 nil（和「空表」分开：迁移要看它）。
    func readTable() -> [WireGuardDevice]? {
        guard let data = try? Data(contentsOf: tableURL) else { return nil }
        return WireGuardDeviceTable.decode(data)
    }

    func writeTable(_ devices: [WireGuardDevice]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WireGuardDeviceTable.encode(devices).write(to: tableURL, options: .atomic)
    }

    func readKeys(id: String) -> WireGuardKeys? {
        WireGuardKeyFile.read(at: keyURL(id: id))
    }

    /// 给新设备生成一份密钥写下去。
    func createKeys(id: String) throws -> WireGuardKeys {
        try WireGuardKeyFile.replace(at: keyURL(id: id))
    }

    func removeKeys(id: String) {
        try? FileManager.default.removeItem(at: keyURL(id: id))
    }

    struct LoadResult: Equatable, Sendable {
        var devices: [WireGuardDevice]
        /// 读得出来的密钥；缺了或坏了的设备不在这里。
        var keys: [String: WireGuardKeys]
        /// 这一次（或补完上次）迁出来的设备：调用方据此删掉 `10.0.0.1` 的旧别名。
        var migrated: WireGuardDevice?
    }

    /// 读设备表和各台密钥，必要时先把旧的单份密钥迁成第一台设备。
    /// `migratedName`：迁出来的那台叫什么（`10.0.0.1` 的别名，没有就是「设备 1」）；`legacyPort`：旧设置里的端口。
    /// 写设备表失败就抛出去（旧文件原样留着，下次再迁）；搬文件失败只是这台暂时没有钥匙，下次启动再搬。
    func load(migratedName: String, legacyPort: UInt16) throws -> LoadResult {
        let table = readTable()
        let legacy = WireGuardKeyFile.read(at: legacyKeyURL)
        var devices = table ?? []
        var migrated: WireGuardDevice?
        let plan = WireGuardMigration.plan(tableExists: table != nil, devices: devices, legacyValid: legacy != nil,
                                           keyFileExists: { FileManager.default.fileExists(atPath: keyURL(id: $0).path) })
        switch plan {
        case .nothing:
            break
        case .migrate:
            let device = WireGuardDevice(id: WireGuardDeviceTable.newID(),
                                         name: WireGuardDeviceTable.cleanName(migratedName) ?? migratedName,
                                         port: legacyPort)
            devices = [device]
            try writeTable(devices)
            migrated = device
            moveLegacy(to: device.id)
        case .finishMove(let id):
            migrated = devices.first { $0.id == id }
            moveLegacy(to: id)
        }
        var keys: [String: WireGuardKeys] = [:]
        for device in devices {
            if let found = readKeys(id: device.id) { keys[device.id] = found }
        }
        return LoadResult(devices: devices, keys: keys, migrated: migrated)
    }

    /// 旧密钥文件改名成这台的密钥（同一个卷上，原子的；权限原样是 600）。
    private func moveLegacy(to id: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = rename(legacyKeyURL.path, keyURL(id: id).path)
    }
}

/// 设备列表里「最近活动」那一列：这台最后一个包是多久以前。
enum WireGuardActivity {
    enum Seen: Equatable {
        case never
        case justNow
        case minutes(Int)
        case hours(Int)
        case yesterday
        case days(Int)
    }

    /// 绿点：这么久之内有包。
    static let recentWindow: TimeInterval = 5 * 60

    static func seen(_ date: Date?, now: Date, calendar: Calendar = .current) -> Seen {
        guard let date else { return .never }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return .justNow }
        if seconds < 3600 { return .minutes(Int(seconds / 60)) }
        if seconds < 86_400 { return .hours(Int(seconds / 3600)) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 2
        return days <= 1 ? .yesterday : .days(days)
    }

    static func isRecent(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) < recentWindow
    }
}
