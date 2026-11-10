import CryptoKit
import Foundation
import Network
import UniformTypeIdentifiers

/// 局域网服务发给会话的事件（已切回主线程）。
enum LANServerEvent {
    case ready(port: UInt16)
    case failed(String)
    /// `code`：审批框上显示的 4 位设备码，手机网页显示同一个（#98）。
    case deviceRequest(clientID: String, name: String, code: String)
    /// 批准了一台设备，二维码换了新令牌（#98）。
    case tokenRotated(String)
    /// 已批准的设备太久没动静，作废了（#98）。
    case deviceExpired(clientID: String, name: String)
    case uploadBegan(uploadID: String, name: String, size: Int64)
    case uploadProgress(uploadID: String, received: Int64)
    case uploadFinished(uploadID: String, url: URL)
    case uploadFailed(uploadID: String)
    /// 超过上限，没收（#99）。
    case uploadRefused(name: String, size: Int64, refusal: PhoneTransferRefusal)
    case text(String)
    /// 手机下载完一次 Mac 共享的文件（同一个文件可以被下载多次）。
    case downloadFinished(fileID: String, started: Date, finished: Date)
}

/// 局域网模式：`NWListener` 上的极简 HTTP/1.1 服务，给手机提供网页与上传 / 下载接口。
/// 每个连接只处理一个请求（`Connection: close`）。接口见 docs/phone-transfer/TECH_DESIGN.md §3。
///
/// 网络回调都在 `queue` 上；设备表、共享文件表、文字表用 `lock` 保护，主线程也会读写。
final class LANTransferServer: @unchecked Sendable {
    struct SharedFile {
        let id: String
        let url: URL
        let name: String
        let size: Int64
        /// 共享的时刻：手机网页显示「什么时候发来的」。
        var added = Date()
    }

    enum DeviceState: String {
        case pending, approved, denied
    }

    /// 一台登记过的手机（#98）。
    private struct Device {
        var state: DeviceState
        let name: String
        /// 来源 IP（限制审批框数量）。
        let ip: String
        /// 登记时用的令牌：批准前的请求、领设备密钥都用它签名。
        let regKey: SymmetricKey
        /// 批准后发给它的密钥：之后的请求只认它。
        var deviceKey: SymmetricKey?
        var lastSeen: Date
    }

    /// 签名校验的结果。
    private enum AuthResult {
        /// 通过；`key` 是验证用的那把（hello 登记时记成这台设备的 regKey）。
        case ok(key: SymmetricKey)
        /// 时间戳和本机差太多（手机按回复里的 now 校准后重试）。
        case clock
        case denied
        case notApproved
    }

    /// 二维码里现在的令牌（URL 的 # 后面，不上网）。批准一台设备后就换（#98）。
    private var currentToken: String
    var token: String {
        lock.lock()
        defer { lock.unlock() }
        return currentToken
    }
    /// 只在这个地址上监听（用户在窗口里选的网卡），别的网卡 / IPv6 上连不进来；nil = 所有网卡。
    let bindIP: String?
    private let receiveDir: URL
    private let webRoot: URL?
    private let macName: String
    private let onEvent: @MainActor (LANServerEvent) -> Void

    private let queue = DispatchQueue(label: "com.baobox.phonetransfer.lan")
    private var listener: NWListener?

    private let lock = NSLock()
    private var devices: [String: Device] = [:]
    /// 用过的随机数（"设备|随机数" → 收到的时刻），防重放（#98）。
    private var nonces: [String: Date] = [:]
    private var sweepTimer: DispatchSourceTimer?
    private var shared: [SharedFile] = []
    private var texts: [(seq: Int, text: String, date: Date)] = []
    private var textSeq = 0
    private var connections: [ObjectIdentifier: LANConnection] = [:]
    private var stopped = false
    /// 这次会话已经收下（含正在收）的字节：上传按 Content-Length 先占上，失败了再还回去（#99）。
    private var receivedBytes: Int64 = 0
    private var activeUploads = 0

    /// 同时最多几个连接：手机网页平时 1～3 个（轮询 + 上传 + 下载）。
    static let maxConnections = 24
    /// 同时最多几个上传：手机网页是一个一个传的。
    static let maxActiveUploads = 3
    /// 没答复的设备请求：每个 IP 一个、总共几个，免得乱发的 hello 刷出一串审批框（#99）。
    static let maxPendingPerIP = 1
    static let maxPending = 4

    static let staticFiles: [String: String] = [
        "index.html": "text/html; charset=utf-8",
        "phone.js": "text/javascript; charset=utf-8",
        "rtc.js": "text/javascript; charset=utf-8"
    ]

    init(token: String, bindIP: String?, receiveDir: URL, webRoot: URL?, macName: String,
         onEvent: @escaping @MainActor (LANServerEvent) -> Void) {
        self.currentToken = token
        self.bindIP = bindIP
        self.receiveDir = receiveDir
        self.webRoot = webRoot
        self.macName = macName
        self.onEvent = onEvent
    }

    // MARK: - 启停（主线程调用）

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 选了网卡就只绑它的地址，端口由系统分配（docs/phone-transfer/TECH_DESIGN.md §3.1）。
        if let bindIP {
            params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindIP), port: .any)
        }
        guard let listener = try? NWListener(using: params) else {
            emit(.failed(L("phonetransfer.error.listen")))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener?.port?.rawValue { self.emit(.ready(port: port)) }
            case .failed(let error):
                self.emit(.failed(L("phonetransfer.error.listen") + " (\(error))"))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { nw.cancel(); return }
            let connection = LANConnection(nw: nw, queue: self.queue, server: self)
            self.lock.lock()
            // 连接太多（有人在刷）就直接断开新来的。
            let accept = !self.stopped && self.connections.count < Self.maxConnections
            if accept { self.connections[ObjectIdentifier(connection)] = connection }
            self.lock.unlock()
            if !accept { nw.cancel(); return }
            connection.start()
        }
        listener.start(queue: queue)
        // 每分钟扫一遍：太久没动静的设备作废（#98）。
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweepTimer = timer
    }

    func stop() {
        sweepTimer?.cancel()
        sweepTimer = nil
        listener?.cancel()
        listener = nil
        lock.lock()
        stopped = true
        let all = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for c in all { c.close() }
    }

    // MARK: - 会话操作（主线程调用）

    /// 允许：发给这台设备自己的密钥，二维码换新令牌（旧二维码拍走了也没用）。拒绝：记下，它再问也是拒绝。
    func setDecision(clientID: String, approved: Bool) {
        lock.lock()
        var rotated: String?
        if var device = devices[clientID] {
            device.state = approved ? .approved : .denied
            if approved {
                device.deviceKey = SymmetricKey(size: .bits256)
                device.lastSeen = Date()
                currentToken = PhoneTransferSettings.randomToken(bytes: 16)
                rotated = currentToken
            }
            devices[clientID] = device
        }
        lock.unlock()
        if let rotated { emit(.tokenRotated(rotated)) }
    }

    func share(_ file: SharedFile) {
        lock.lock()
        shared.append(file)
        lock.unlock()
    }

    func addMacText(_ text: String) {
        lock.lock()
        textSeq += 1
        texts.append((textSeq, text, Date()))
        lock.unlock()
    }

    // MARK: - 内部

    fileprivate func remove(_ connection: LANConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    fileprivate func emit(_ event: LANServerEvent) {
        let handler = onEvent
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(event) }
        }
    }

    /// 作废太久没动静的已批准设备，过期的随机数也清掉。持锁调用；返回作废的设备（解锁后再发事件）。
    private func pruneLocked(now: Date) -> [(String, String)] {
        var expired: [(String, String)] = []
        for (id, device) in devices where device.state == .approved
            && now.timeIntervalSince(device.lastSeen) > LANAuth.idleExpiry {
            expired.append((id, device.name))
        }
        for (id, _) in expired { devices[id] = nil }
        nonces = nonces.filter { now.timeIntervalSince($0.value) < LANAuth.nonceTTL }
        return expired
    }

    private func sweep() {
        lock.lock()
        let expired = pruneLocked(now: Date())
        lock.unlock()
        for (id, name) in expired { emit(.deviceExpired(clientID: id, name: name)) }
    }

    /// 校验签名与新鲜度（#98，docs/phone-transfer/TECH_DESIGN.md §3.4）。在 `queue` 上调用。
    private func authenticate(_ req: LANRequest, clientID: String) -> AuthResult {
        guard let (unsigned, sig) = LANAuth.splitSignature(req.rawQuery) else { return .denied }
        let canonical = LANAuth.canonical(method: req.method, path: req.path, unsignedQuery: unsigned)
        let now = Date()
        lock.lock()
        let expired = pruneLocked(now: now)
        let device = devices[clientID]
        let current = currentToken
        lock.unlock()
        for (id, name) in expired { emit(.deviceExpired(clientID: id, name: name)) }

        // 用哪把密钥：hello 认设备密钥或登记时的令牌（没登记过的用现在的令牌）；别的接口只认设备密钥。
        var keys: [SymmetricKey] = []
        if req.path == "/api/hello" {
            if let deviceKey = device?.deviceKey { keys.append(deviceKey) }
            keys.append(device?.regKey ?? LANAuth.key(token: current))
        } else {
            guard let device, device.state == .approved, let deviceKey = device.deviceKey else { return .notApproved }
            keys.append(deviceKey)
        }
        guard let key = keys.first(where: { LANAuth.verify(sig, canonical: canonical, key: $0) }) else {
            return .denied
        }

        if let exp = req.query["exp"] {
            // 下载链接：<img> / <a download> 加不了随机数，只看过期时刻。
            guard req.method == "GET", req.path == "/api/file", let ms = Double(exp) else { return .denied }
            let expiry = Date(timeIntervalSince1970: ms / 1000)
            guard expiry > now, expiry.timeIntervalSince(now) <= LANAuth.maxLinkLifetime else { return .denied }
        } else {
            guard let ms = Double(req.query["ts"] ?? ""), let nonce = req.query["n"],
                  (16...64).contains(nonce.count), nonce.allSatisfy(\.isHexDigit) else { return .denied }
            let sent = Date(timeIntervalSince1970: ms / 1000)
            guard abs(sent.timeIntervalSince(now)) <= LANAuth.clockWindow else { return .clock }
            lock.lock()
            let seen = nonces["\(clientID)|\(nonce)"] != nil
            if !seen { nonces["\(clientID)|\(nonce)"] = now }
            lock.unlock()
            guard !seen else { return .denied }
        }
        lock.lock()
        devices[clientID]?.lastSeen = now
        lock.unlock()
        return .ok(key: key)
    }

    /// 路由一个已解析的请求。在 `queue` 上调用。
    fileprivate func route(_ req: LANRequest, _ conn: LANConnection) {
        let path = req.path
        if req.method == "GET" {
            if path == "/" || path == "/index.html" { serveStatic("index.html", conn); return }
            let name = String(path.dropFirst())
            if Self.staticFiles[name] != nil { serveStatic(name, conn); return }
        }
        guard path.hasPrefix("/api/") else {
            conn.respond(status: 404, json: ["error": "not found"])
            return
        }
        let clientID = req.query["c"] ?? ""
        guard clientID.count == 16, clientID.allSatisfy({ $0.isHexDigit }) else {
            conn.respond(status: 400, json: ["error": "client"])
            return
        }
        let key: SymmetricKey
        switch authenticate(req, clientID: clientID) {
        case .ok(let matched):
            key = matched
        case .clock:
            conn.respond(status: 401, json: ["error": "clock", "now": Self.millis(Date())])
            return
        case .denied:
            conn.respond(status: 401, json: ["error": "auth"])
            return
        case .notApproved:
            conn.respond(status: 403, json: ["error": "approval"])
            return
        }

        switch (req.method, path) {
        case ("GET", "/api/hello"):
            handleHello(clientID: clientID, name: req.query["name"] ?? "", ip: conn.remoteIP, regKey: key, conn)
        case ("GET", "/api/poll"):
            handlePoll(clientID: clientID, since: Int(req.query["since"] ?? "") ?? 0, conn)
        case ("GET", "/api/file"):
            handleDownload(id: req.query["id"] ?? "", conn)
        case ("POST", "/api/upload"):
            handleUpload(req, conn)
        case ("POST", "/api/text"):
            handleText(req, conn)
        default:
            conn.respond(status: 404, json: ["error": "not found"])
        }
    }

    private func serveStatic(_ name: String, _ conn: LANConnection) {
        guard let root = webRoot, let type = Self.staticFiles[name],
              let data = try? Data(contentsOf: root.appendingPathComponent(name)) else {
            conn.respond(status: 404, json: ["error": "missing"])
            return
        }
        conn.respond(status: 200, contentType: type, body: data)
    }

    /// `regKey`：这次请求验证通过的那把密钥。没登记过的设备就用它登记（= 它扫的那张二维码的令牌）。
    private func handleHello(clientID: String, name: String, ip: String, regKey: SymmetricKey, _ conn: LANConnection) {
        let trimmed = String(name.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "Phone" : trimmed
        lock.lock()
        let isNew = devices[clientID] == nil
        var limited = false
        if isNew {
            let pending = devices.values.filter { $0.state == .pending }
            if pending.filter({ $0.ip == ip }).count >= Self.maxPendingPerIP || pending.count >= Self.maxPending {
                limited = true
            } else {
                devices[clientID] = Device(state: .pending, name: display, ip: ip, regKey: regKey, deviceKey: nil,
                                           lastSeen: Date())
            }
        }
        let device = devices[clientID]
        lock.unlock()
        guard !limited, let device else {
            // 不记这台设备、不弹审批框；网页收到 429 会隔一秒再问。
            conn.respond(status: 429, json: ["error": "busy"])
            return
        }
        if isNew {
            emit(.deviceRequest(clientID: clientID, name: display,
                                code: LANAuth.deviceCode(regKey: device.regKey, clientID: clientID)))
        }
        var reply: [String: Any] = ["state": device.state.rawValue, "mac": macName]
        if device.state == .approved, let deviceKey = device.deviceKey {
            reply["dk"] = LANAuth.wrap(deviceKey: deviceKey, regKey: device.regKey, clientID: clientID)
        }
        conn.respond(status: 200, json: reply)
    }

    private func handlePoll(clientID: String, since: Int, _ conn: LANConnection) {
        lock.lock()
        let state = devices[clientID]?.state
        let files = shared.map {
            ["id": $0.id, "name": $0.name, "size": NSNumber(value: $0.size), "ts": Self.millis($0.added)] as [String: Any]
        }
        let newTexts = texts.filter { $0.seq > since }.map {
            ["seq": $0.seq, "text": $0.text, "ts": Self.millis($0.date)] as [String: Any]
        }
        let seq = textSeq
        let received = receivedBytes
        lock.unlock()
        guard state == .approved else {
            conn.respond(status: 200, json: ["state": (state ?? .pending).rawValue])
            return
        }
        // 上限也告诉网页：发之前先比一下，超了直接在手机上说清楚，不必传一半被断开（#99）。
        let room = PhoneTransferLimits.room(received: received, freeSpace: PhoneTransferLimits.freeSpace(at: receiveDir))
        let limits: [String: Any] = ["file": NSNumber(value: PhoneTransferLimits.maxFileBytes),
                                     "room": NSNumber(value: room)]
        conn.respond(status: 200, json: ["state": "approved", "files": files, "texts": newTexts, "seq": seq,
                                         "limits": limits])
    }

    private func handleDownload(id: String, _ conn: LANConnection) {
        lock.lock()
        let file = shared.first { $0.id == id }
        lock.unlock()
        guard let file else {
            conn.respond(status: 404, json: ["error": "file"])
            return
        }
        let started = Date()
        conn.streamFile(file.url, name: file.name) { [weak self] ok in
            if ok { self?.emit(.downloadFinished(fileID: id, started: started, finished: Date())) }
        }
    }

    /// 给手机网页的时间戳（毫秒）。
    private static func millis(_ date: Date) -> NSNumber {
        NSNumber(value: Int64(date.timeIntervalSince1970 * 1000))
    }

    private func handleUpload(_ req: LANRequest, _ conn: LANConnection) {
        if req.headers["transfer-encoding"] != nil {
            conn.respond(status: 411, json: ["error": "length required"])
            return
        }
        guard let length = Int64(req.headers["content-length"] ?? ""), length >= 0 else {
            conn.respond(status: 411, json: ["error": "length required"])
            return
        }
        let name = PhoneTransferSettings.sanitize(req.query["name"] ?? "file")
        guard PhoneTransferSettings.ensureDirectory(receiveDir) else {
            conn.respond(status: 500, json: ["error": "folder"])
            return
        }
        // 上限（#99）：单个文件、这次会话合计、收完磁盘要剩的。先按 Content-Length 占上，失败再还。
        let freeSpace = PhoneTransferLimits.freeSpace(at: receiveDir)
        lock.lock()
        let refusal = PhoneTransferLimits.check(size: length, received: receivedBytes, freeSpace: freeSpace)
        let busy = refusal == nil && activeUploads >= Self.maxActiveUploads
        if refusal == nil, !busy {
            receivedBytes += length
            activeUploads += 1
        }
        lock.unlock()
        if busy {
            conn.respond(status: 429, json: ["error": "busy"])
            return
        }
        if let refusal {
            emit(.uploadRefused(name: name, size: length, refusal: refusal))
            let reason = refusal.phoneReason
            conn.respond(status: 413, json: ["error": reason.why, "limit": NSNumber(value: reason.limit)])
            return
        }
        let uploadID = UUID().uuidString
        let temp = receiveDir.appendingPathComponent(".\(uploadID).part")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp) else {
            endUpload(length: length, kept: false)
            conn.respond(status: 500, json: ["error": "write"])
            return
        }
        emit(.uploadBegan(uploadID: uploadID, name: name, size: length))

        var lastReport = Date.distantPast
        conn.receiveBody(length: length, into: handle, progress: { [weak self] received in
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.2 {
                lastReport = now
                self?.emit(.uploadProgress(uploadID: uploadID, received: received))
            }
        }, completion: { [weak self] ok in
            try? handle.close()
            guard let self else { return }
            guard ok else {
                try? FileManager.default.removeItem(at: temp)
                self.endUpload(length: length, kept: false)
                self.emit(.uploadFailed(uploadID: uploadID))
                return
            }
            let target = PhoneTransferSettings.uniqueURL(in: self.receiveDir, name: name)
            do {
                try FileManager.default.moveItem(at: temp, to: target)
                self.endUpload(length: length, kept: true)
                self.emit(.uploadFinished(uploadID: uploadID, url: target))
                conn.respond(status: 200, json: ["ok": true])
            } catch {
                try? FileManager.default.removeItem(at: temp)
                self.endUpload(length: length, kept: false)
                self.emit(.uploadFailed(uploadID: uploadID))
                conn.respond(status: 500, json: ["error": "rename"])
            }
        })
    }

    /// 一个上传结束：没收下的把占的额度还回去。
    private func endUpload(length: Int64, kept: Bool) {
        lock.lock()
        activeUploads = max(0, activeUploads - 1)
        if !kept { receivedBytes = max(0, receivedBytes - length) }
        lock.unlock()
    }

    private func handleText(_ req: LANRequest, _ conn: LANConnection) {
        guard let length = Int(req.headers["content-length"] ?? ""), length >= 0, length <= 1_048_576 else {
            conn.respond(status: 413, json: ["error": "too large"])
            return
        }
        // 文字也算进这次会话的合计（#99）。
        lock.lock()
        let fits = receivedBytes + Int64(length) <= PhoneTransferLimits.maxSessionBytes
        if fits { receivedBytes += Int64(length) }
        lock.unlock()
        guard fits else {
            conn.respond(status: 413, json: ["error": "room", "limit": NSNumber(value: 0)])
            return
        }
        conn.readBody(length: length) { [weak self] data in
            // 文字的哈希在签过名的查询串里（bh），内容被改了就对不上（#98）。
            guard let data, LANAuth.sha256Hex(data) == req.query["bh"]?.lowercased(),
                  let text = String(data: data, encoding: .utf8) else {
                conn.respond(status: 400, json: ["error": "body"])
                return
            }
            if !text.isEmpty { self?.emit(.text(text)) }
            conn.respond(status: 200, json: ["ok": true])
        }
    }
}

// MARK: - 请求

struct LANRequest {
    let method: String
    let path: String
    let query: [String: String]
    /// `?` 后面原样的查询串（签名按原始字节算，#98）。
    let rawQuery: String
    let headers: [String: String]

    /// 解析请求头（不含空行）。格式不对返回 nil。
    init?(head: Data) {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0]).uppercased()
        let target = String(parts[1])
        rawQuery = target.firstIndex(of: "?").map { String(target[target.index(after: $0)...]) } ?? ""
        guard let comps = URLComponents(string: "http://localhost" + target) else { return nil }
        path = comps.path.isEmpty ? "/" : comps.path
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] where q[item.name] == nil {
            q[item.name] = item.value ?? ""
        }
        query = q
        var h: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            h[key] = value
        }
        headers = h
    }
}

// MARK: - 单个连接

final class LANConnection: @unchecked Sendable {
    private let nw: NWConnection
    private let queue: DispatchQueue
    private weak var server: LANTransferServer?
    private var buffer = Data()
    private var closed = false

    private static let maxHead = 64 * 1024
    private static let chunk = 256 * 1024

    init(nw: NWConnection, queue: DispatchQueue, server: LANTransferServer) {
        self.nw = nw
        self.queue = queue
        self.server = server
    }

    /// 对方的 IP（限制审批框数量用）；取不到为空串。
    var remoteIP: String {
        guard case .hostPort(let host, _) = nw.endpoint else { return "" }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return ""
        }
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        nw.start(queue: queue)
        readHead()
    }

    func close() {
        guard !closed else { return }
        closed = true
        nw.cancel()
        server?.remove(self)
    }

    private func readHead() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHead) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            let separator = Data("\r\n\r\n".utf8)
            if let range = self.buffer.range(of: separator) {
                let head = self.buffer.subdata(in: self.buffer.startIndex..<range.lowerBound)
                self.buffer = self.buffer.subdata(in: range.upperBound..<self.buffer.endIndex)
                guard let req = LANRequest(head: head) else {
                    self.respond(status: 400, json: ["error": "bad request"])
                    return
                }
                self.server?.route(req, self)
                return
            }
            if error != nil || isComplete || self.buffer.count > Self.maxHead {
                self.close()
                return
            }
            self.readHead()
        }
    }

    // MARK: 请求体

    /// 读完整个请求体（小请求用）。
    func readBody(length: Int, completion: @escaping (Data?) -> Void) {
        if buffer.count >= length {
            completion(buffer.prefix(length))
            return
        }
        nw.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count >= length {
                completion(self.buffer.prefix(length))
            } else if error != nil || isComplete {
                completion(nil)
            } else {
                self.readBody(length: length, completion: completion)
            }
        }
    }

    /// 把请求体流式写进文件。
    func receiveBody(length: Int64, into handle: FileHandle,
                     progress: @escaping (Int64) -> Void, completion: @escaping (Bool) -> Void) {
        var received: Int64 = 0
        if !buffer.isEmpty {
            let take = buffer.prefix(Int(min(Int64(buffer.count), length)))
            do { try handle.write(contentsOf: take) } catch { completion(false); return }
            received = Int64(take.count)
            buffer = Data()
        }
        if received >= length {
            completion(true)
            return
        }
        func next() {
            nw.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, isComplete, error in
                guard let self, !self.closed else { completion(false); return }
                if let data, !data.isEmpty {
                    let take = data.prefix(Int(min(Int64(data.count), length - received)))
                    do { try handle.write(contentsOf: take) } catch { completion(false); self.close(); return }
                    received += Int64(take.count)
                    progress(received)
                }
                if received >= length {
                    completion(true)
                } else if error != nil || isComplete {
                    completion(false)
                    self.close()
                } else {
                    next()
                }
            }
        }
        next()
    }

    // MARK: 响应

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 411: return "Length Required"
        case 401: return "Unauthorized"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        default: return "Internal Server Error"
        }
    }

    private func header(status: Int, contentType: String, length: Int64, extra: [String: String] = [:]) -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reason(status))",
                     "Content-Type: \(contentType)",
                     "Content-Length: \(length)",
                     "Cache-Control: no-store",
                     "X-Content-Type-Options: nosniff",
                     "Referrer-Policy: no-referrer",
                     "Connection: close"]
        for (k, v) in extra { lines.append("\(k): \(v)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    func respond(status: Int, contentType: String, body: Data) {
        guard !closed else { return }
        var out = header(status: status, contentType: contentType, length: Int64(body.count))
        out.append(body)
        nw.send(content: out, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    func respond(status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        respond(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    /// 流式发送文件：读一块、发完再读下一块。
    func streamFile(_ url: URL, name: String, completion: @escaping (Bool) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = PhoneTransferSettings.fileSize(url) else {
            respond(status: 404, json: ["error": "file"])
            completion(false)
            return
        }
        // RFC 5987：只留 ASCII 非保留字符，其余（含中文）一律百分号编码。.alphanumerics 含非 ASCII 字母，不能用。
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "file"
        let ascii = String(name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" && $0.value >= 0x20 ? Character($0) : "_" })
        // 按扩展名给类型：响应带 nosniff，图片要有正确的类型，手机网页才能用 <img> 显示（长按存相册）。
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let head = header(status: 200, contentType: type, length: size,
                          extra: ["Content-Disposition": "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"])
        var sent: Int64 = 0

        func finish(_ ok: Bool) {
            try? handle.close()
            completion(ok)
            close()
        }

        func sendNext() {
            guard !closed else { finish(false); return }
            let data: Data
            do {
                data = try handle.read(upToCount: Self.chunk) ?? Data()
            } catch {
                finish(false)
                return
            }
            if data.isEmpty {
                finish(sent >= size)
                return
            }
            sent += Int64(data.count)
            nw.send(content: data, completion: .contentProcessed { error in
                if error != nil { finish(false) } else { sendNext() }
            })
        }

        nw.send(content: head, completion: .contentProcessed { error in
            if error != nil { finish(false) } else { sendNext() }
        })
    }
}
