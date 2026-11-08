import AppKit
import Foundation
import Network

/// 手机互传会话：一个窗口一个会话。负责模式切换、设备请求、传输列表与文字，
/// 协调局域网服务（`LANTransferServer`）与公网宿主（`RTCTransferHost`）。
/// 见 docs/phone-transfer/TECH_DESIGN.md §2。
@MainActor
final class PhoneTransferSession: ObservableObject {
    static let shared = PhoneTransferSession()

    enum Mode: String {
        case lan, internet
    }

    enum Phase: Equatable {
        case idle
        case starting
        case waiting
        case expired
        case connecting
        case connected
        case closed
        case failed(String)
    }

    struct Request: Identifiable {
        let id: String
        let name: String
    }

    enum TransferState: Equatable {
        case queued, active, finished, failed
        case shared(downloads: Int)
    }

    struct Transfer: Identifiable {
        let id: String
        let incoming: Bool
        let name: String
        let size: Int64
        var done: Int64
        var state: TransferState
        var url: URL?
        /// 加进列表 / 开始传 / 传完的时刻：显示「17:30:12 · 用时 1.2 秒」（REQUIREMENTS §3.4）。
        /// 局域网共享给手机的文件：start / finish 是最近一次被下载的起止。
        var createdAt = Date()
        var startedAt: Date?
        var finishedAt: Date?
        /// 图片的缩略图，后台生成。
        var thumbnail: NSImage?

        var isImage: Bool { PhoneTransferImage.isImage(URL(fileURLWithPath: name)) }
    }

    struct TextItem: Identifiable {
        let id = UUID()
        let incoming: Bool
        let text: String
        var date = Date()
    }

    @Published private(set) var mode: Mode = .lan
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var qrText: String?
    @Published private(set) var requests: [Request] = []
    @Published private(set) var devices: [String] = []
    @Published private(set) var route: String?
    @Published private(set) var signalReady = 0
    @Published private(set) var failureDetail: [String] = []
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var texts: [TextItem] = []
    /// 公网模式的宿主 WebView 由窗口挂进视图层级。
    @Published private(set) var rtcHost: RTCTransferHost?
    /// 局域网模式可选的网卡，窗口开着时随网络变化刷新。
    @Published private(set) var interfaces: [PhoneTransferInterface] = []
    /// 默认路由那块网卡的地址（「自动」用它）。
    @Published private(set) var primaryIP = "127.0.0.1"
    /// 网卡选择：`""` 自动、`"*"` 所有网卡、其他是 BSD 名（存在设置里，下次打开沿用）。
    @Published private(set) var lanInterfaceChoice = PhoneTransferSettings.lanInterface

    var isRunning: Bool { phase != .idle }

    private var lan: LANTransferServer?
    /// 当前二维码里的地址。
    private var lanIP: String?
    private var pathMonitor: NWPathMonitor?
    private var interfaceKinds: [String: PhoneTransferInterface.Kind] = [:]
    private var expiryTimer: Timer?
    private var signalTimer: Timer?
    private var generation = 0

    // 公网模式：发送队列与正在接收的文件。
    private var outQueue: [(id: String, url: URL, name: String, size: Int64)] = []
    private var pumping = false
    private var rxID: String?
    private var rxName = ""
    private var rxTemp: URL?
    private var rxHandle: FileHandle?

    private static let expiry: TimeInterval = 10 * 60

    private init() {}

    // MARK: - 生命周期

    func start(mode newMode: Mode? = nil) {
        stopBackends()
        if let newMode { mode = newMode }
        generation += 1
        requests = []
        devices = []
        route = nil
        signalReady = 0
        failureDetail = []
        qrText = nil
        lanIP = nil
        phase = .starting
        startInterfaceMonitor()
        switch mode {
        case .lan: startLAN()
        case .internet: startInternet()
        }
        armExpiry()
    }

    func switchMode(_ newMode: Mode) {
        guard newMode != mode || phase == .idle else { return }
        start(mode: newMode)
    }

    func refresh() {
        start()
    }

    /// 关窗时调用：停掉后端、清掉令牌，传输记录保留到下次打开窗口前。
    func stop() {
        stopBackends()
        pathMonitor?.cancel()
        pathMonitor = nil
        phase = .idle
        qrText = nil
        lanIP = nil
        requests = []
        devices = []
        route = nil
    }

    private func stopBackends() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        signalTimer?.invalidate()
        signalTimer = nil
        lan?.stop()
        lan = nil
        rtcHost?.stop()
        rtcHost = nil
        outQueue.removeAll()
        for i in transfers.indices where transfers[i].state == .queued || transfers[i].state == .active {
            transfers[i].state = .failed
            transfers[i].finishedAt = Date()
        }
        abortReceive()
    }

    // MARK: - 网卡

    /// 窗口开着期间监视网络变化，刷新可选网卡（插网线、连 VPN、开互联网共享都会多出一块）。
    private func startInterfaceMonitor() {
        guard pathMonitor == nil else { return }
        refreshInterfaces()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let kinds = PhoneTransferNetwork.kinds(of: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.pathMonitor != nil else { return }
                    self.interfaceKinds = kinds
                    self.refreshInterfaces()
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "com.baobox.phonetransfer.path"))
    }

    private func refreshInterfaces() {
        let list = PhoneTransferNetwork.interfaces(kinds: interfaceKinds)
        if list != interfaces { interfaces = list }
        let ip = NetworkInterfaces.primaryIP()
        if ip != primaryIP { primaryIP = ip }
    }

    /// 窗口里换网卡：记住选择；局域网模式正在跑就用新网卡重开（换新令牌、新二维码）。
    func setLANInterface(_ choice: String) {
        guard choice != lanInterfaceChoice else { return }
        lanInterfaceChoice = choice
        PhoneTransferSettings.lanInterface = choice
        if mode == .lan, phase != .idle { start() }
    }

    private func armExpiry() {
        expiryTimer?.invalidate()
        let gen = generation
        expiryTimer = Timer.scheduledTimer(withTimeInterval: Self.expiry, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                // 有设备连着就不过期。
                guard self.devices.isEmpty, self.requests.isEmpty,
                      self.phase == .waiting || self.phase == .starting else { return }
                self.stopBackends()
                self.phase = .expired
            }
        }
    }

    // MARK: - 局域网模式

    private func startLAN() {
        let gen = generation
        refreshInterfaces()
        // 先定地址再起服务：选了网卡就只在它的地址上监听（TECH_DESIGN §3.1）。
        let qrIP: String
        let bindIP: String?
        switch lanInterfaceChoice {
        case "":
            qrIP = primaryIP
            bindIP = qrIP
        case "*":
            qrIP = primaryIP
            bindIP = nil
        default:
            guard let iface = interfaces.first(where: { $0.name == lanInterfaceChoice }) else {
                phase = .failed(L("phonetransfer.error.noInterface \(lanInterfaceChoice)"))
                return
            }
            qrIP = iface.ip
            bindIP = iface.ip
        }
        guard qrIP != "127.0.0.1" else {
            phase = .failed(L("phonetransfer.error.noLAN"))
            return
        }
        lanIP = qrIP
        let server = LANTransferServer(
            token: PhoneTransferSettings.randomToken(bytes: 16),
            bindIP: bindIP,
            receiveDir: PhoneTransferSettings.receiveDir,
            webRoot: Bundle.main.url(forResource: "PhoneTransfer", withExtension: nil),
            macName: PhoneTransferSettings.macName
        ) { [weak self] event in
            guard let self, self.generation == gen else { return }
            self.handleLAN(event)
        }
        lan = server
        server.start()
    }

    private func handleLAN(_ event: LANServerEvent) {
        switch event {
        case .ready(let port):
            guard let server = lan, let ip = lanIP else { return }
            qrText = "http://\(ip):\(port)/?t=\(server.token)"
            if phase == .starting { phase = .waiting }
        case .failed(let message):
            phase = .failed(message)
        case .deviceRequest(let clientID, let name):
            requests.append(Request(id: clientID, name: name))
            PhoneTransferWindowController.shared.show()
        case .uploadBegan(let id, let name, let size):
            transfers.insert(Transfer(id: id, incoming: true, name: name, size: size, done: 0, state: .active,
                                      startedAt: Date()), at: 0)
        case .uploadProgress(let id, let received):
            update(id) { $0.done = received }
        case .uploadFinished(let id, let url):
            update(id) {
                $0.done = $0.size
                $0.state = .finished
                $0.url = url
                $0.finishedAt = Date()
            }
            loadThumbnail(id: id, url: url)
        case .uploadFailed(let id):
            update(id) {
                $0.state = .failed
                $0.finishedAt = Date()
            }
        case .text(let text):
            receivedText(text)
        case .downloadFinished(let fileID, let started, let finished):
            update(fileID) {
                if case .shared(let n) = $0.state { $0.state = .shared(downloads: n + 1) }
                $0.startedAt = started
                $0.finishedAt = finished
            }
        }
    }

    // MARK: - 公网模式

    private func startInternet() {
        let gen = generation
        let host = RTCTransferHost()
        let sid = PhoneTransferSettings.randomToken(bytes: 16)
        let key = PhoneTransferSettings.randomToken(bytes: 32)
        let since = Int(Date().timeIntervalSince1970)
        host.onMessage = { [weak self] msg in
            guard let self, self.generation == gen else { return }
            self.handleRTC(msg, sid: sid, key: key, since: since)
        }
        rtcHost = host
        guard host.load() else {
            phase = .failed(L("phonetransfer.error.resources"))
            return
        }
        qrText = PhoneTransferSettings.pageURL + "#s=\(sid)&k=\(key)"

        signalTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, self.phase == .starting else { return }
                self.phase = .failed(L("phonetransfer.error.signal"))
            }
        }
    }

    private func handleRTC(_ msg: [String: Any], sid: String, key: String, since: Int) {
        let type = msg["type"] as? String ?? ""
        switch type {
        case "loaded":
            if (msg["rtc"] as? Bool) != true {
                phase = .failed(L("phonetransfer.error.noWebRTC"))
            } else if (msg["crypto"] as? Bool) != true {
                phase = .failed(L("phonetransfer.error.noCrypto"))
            } else {
                rtcHost?.start(sid: sid, key: key, since: since, macName: PhoneTransferSettings.macName)
            }
        case "signal":
            let state = msg["state"] as? String ?? ""
            if state == "unsupported" {
                phase = .failed((msg["reason"] as? String) == "rtc"
                                ? L("phonetransfer.error.noWebRTC") : L("phonetransfer.error.noCrypto"))
            } else if state == "status" {
                signalReady = (msg["ready"] as? NSNumber)?.intValue ?? 0
                if signalReady > 0, phase == .starting { phase = .waiting }
            }
        case "offer":
            let name = (msg["name"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? "Phone"
            requests = [Request(id: "rtc", name: name)]
            PhoneTransferWindowController.shared.show()
        case "peer":
            if let name = msg["name"] as? String, !name.isEmpty { devices = [String(name.prefix(60))] }
        case "state":
            handleRTCState(msg)
        case "rx-begin":
            beginReceive(id: msg["id"] as? String ?? "", name: msg["name"] as? String ?? "file",
                         size: (msg["size"] as? NSNumber)?.int64Value ?? 0)
        case "rx-chunk":
            guard let id = msg["id"] as? String, id == rxID,
                  let b64 = msg["b64"] as? String, let data = Data(base64Encoded: b64) else { return }
            do {
                try rxHandle?.write(contentsOf: data)
                update(id) { $0.done += Int64(data.count) }
            } catch {
                abortReceive()
            }
        case "rx-end":
            if let id = msg["id"] as? String, id == rxID { finishReceive() }
        case "rx-cancel":
            if let id = msg["id"] as? String, id == rxID { abortReceive() }
        case "text":
            if let text = msg["text"] as? String, !text.isEmpty { receivedText(text) }
        case "log":
            NSLog("[PhoneTransfer] %@", (msg["msg"] as? String) ?? "")
        default:
            break
        }
    }

    private func handleRTCState(_ msg: [String: Any]) {
        switch msg["state"] as? String ?? "" {
        case "connecting":
            phase = .connecting
        case "connected":
            route = msg["route"] as? String
            phase = .connected
            pumpRTC()
        case "failed":
            failureDetail = [
                L("phonetransfer.nat.phone") + natText(msg["phoneNat"] as? String),
                L("phonetransfer.nat.mac") + natText(msg["macNat"] as? String)
            ]
            phase = .failed(L("phonetransfer.error.p2p"))
        case "closed":
            phase = .closed
            abortReceive()
            for i in transfers.indices where transfers[i].state == .queued || transfers[i].state == .active {
                transfers[i].state = .failed
            }
            outQueue.removeAll()
        default:
            break
        }
    }

    private func natText(_ value: String?) -> String {
        switch value {
        case "ok": return L("phonetransfer.nat.ok")
        case "symmetric": return L("phonetransfer.nat.symmetric")
        case "blocked": return L("phonetransfer.nat.blocked")
        default: return L("phonetransfer.nat.unknown")
        }
    }

    private func beginReceive(id: String, name: String, size: Int64) {
        abortReceive()
        let dir = PhoneTransferSettings.receiveDir
        guard !id.isEmpty, PhoneTransferSettings.ensureDirectory(dir) else { return }
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp) else { return }
        rxID = id
        rxName = PhoneTransferSettings.sanitize(name)
        rxTemp = temp
        rxHandle = handle
        transfers.insert(Transfer(id: id, incoming: true, name: rxName, size: size, done: 0, state: .active,
                                  startedAt: Date()), at: 0)
    }

    private func finishReceive() {
        guard let id = rxID, let temp = rxTemp else { return }
        try? rxHandle?.close()
        let target = PhoneTransferSettings.uniqueURL(in: PhoneTransferSettings.receiveDir, name: rxName)
        do {
            try FileManager.default.moveItem(at: temp, to: target)
            update(id) {
                $0.state = .finished
                $0.done = max($0.done, $0.size)
                $0.url = target
                $0.finishedAt = Date()
            }
            loadThumbnail(id: id, url: target)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            update(id) {
                $0.state = .failed
                $0.finishedAt = Date()
            }
        }
        rxID = nil
        rxTemp = nil
        rxHandle = nil
    }

    private func abortReceive() {
        try? rxHandle?.close()
        if let temp = rxTemp { try? FileManager.default.removeItem(at: temp) }
        if let id = rxID {
            update(id) {
                $0.state = .failed
                $0.finishedAt = Date()
            }
        }
        rxID = nil
        rxTemp = nil
        rxHandle = nil
    }

    private func pumpRTC() {
        guard !pumping, phase == .connected, let host = rtcHost else { return }
        pumping = true
        let gen = generation
        Task { @MainActor in
            defer { self.pumping = false }
            while self.generation == gen, self.phase == .connected, !self.outQueue.isEmpty {
                let job = self.outQueue.removeFirst()
                self.update(job.id) {
                    $0.state = .active
                    $0.startedAt = Date()
                }
                do {
                    try await host.sendFile(id: job.id, url: job.url, name: job.name, size: job.size) { sent in
                        self.update(job.id) { $0.done = sent }
                    }
                    self.update(job.id) {
                        $0.state = .finished
                        $0.done = $0.size
                        $0.finishedAt = Date()
                    }
                } catch {
                    self.update(job.id) {
                        $0.state = .failed
                        $0.finishedAt = Date()
                    }
                }
            }
        }
    }

    // MARK: - 用户操作

    func approve(_ request: Request) {
        requests.removeAll { $0.id == request.id }
        switch mode {
        case .lan:
            lan?.setDecision(clientID: request.id, approved: true)
            if !devices.contains(request.name) { devices.append(request.name) }
            phase = .connected
        case .internet:
            devices = [request.name]
            rtcHost?.approve(true)
        }
    }

    func deny(_ request: Request) {
        requests.removeAll { $0.id == request.id }
        switch mode {
        case .lan:
            lan?.setDecision(clientID: request.id, approved: false)
        case .internet:
            // 公网会话一次只接一部手机；拒绝后告诉对方，再换一个新二维码。
            rtcHost?.approve(false)
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.refresh()
                }
            }
        }
    }

    func send(files urls: [URL]) {
        for url in urls {
            guard let size = PhoneTransferSettings.fileSize(url) else { continue }
            let id = "m" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
            let name = url.lastPathComponent
            switch mode {
            case .lan:
                lan?.share(LANTransferServer.SharedFile(id: id, url: url, name: name, size: size))
                transfers.insert(Transfer(id: id, incoming: false, name: name, size: size, done: 0,
                                          state: .shared(downloads: 0), url: url), at: 0)
            case .internet:
                outQueue.append((id: id, url: url, name: name, size: size))
                transfers.insert(Transfer(id: id, incoming: false, name: name, size: size, done: 0,
                                          state: .queued, url: url), at: 0)
            }
            loadThumbnail(id: id, url: url)
        }
        if mode == .internet { pumpRTC() }
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch mode {
        case .lan:
            lan?.addMacText(text)
            texts.insert(TextItem(incoming: false, text: text), at: 0)
        case .internet:
            guard let host = rtcHost, phase == .connected else { return }
            texts.insert(TextItem(incoming: false, text: text), at: 0)
            Task { @MainActor in
                try? await host.sendText(text)
            }
        }
    }

    func clearHistory() {
        transfers.removeAll { $0.state != .active && $0.state != .queued }
        texts.removeAll()
    }

    var canSend: Bool {
        switch mode {
        case .lan: return lan != nil && !devices.isEmpty
        case .internet: return phase == .connected
        }
    }

    // MARK: - 工具

    private func receivedText(_ text: String) {
        texts.insert(TextItem(incoming: true, text: text), at: 0)
        if PhoneTransferSettings.autoCopyText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func update(_ id: String, _ change: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    /// 图片在后台生成缩略图（最长边 128 像素，按 EXIF 方向转正），好了再填回列表。
    private func loadThumbnail(id: String, url: URL) {
        guard PhoneTransferImage.isImage(url) else { return }
        PhoneTransferImage.load(url, maxPixel: 128) { [weak self] image in
            guard let image else { return }
            self?.update(id) { $0.thumbnail = image }
        }
    }
}
