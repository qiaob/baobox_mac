import Foundation
import Network

/// 局域网传输 —— 会话登记表：既**持有**会话（否则会话在 `newConnectionHandler` 返回后即被释放），
/// 也让服务停止时能一次性掐断所有在途连接。
///
/// 与 NetCapture 的 `ConnectionRegistry` 同形，但那个类型绑死在 `ProxyConnection` 上，故独立一份。
final class LanDropSessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: LanDropSession] = [:]

    func add(_ session: LanDropSession) {
        lock.lock()
        sessions[ObjectIdentifier(session)] = session
        lock.unlock()
    }

    func remove(_ session: LanDropSession) {
        lock.lock()
        sessions.removeValue(forKey: ObjectIdentifier(session))
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll(keepingCapacity: false)
        lock.unlock()
        for session in all { session.cancel() }
    }
}

/// 局域网传输 —— 单连接 HTTP 会话。
///
/// 在自己的串行队列上运行，不读任何 `@MainActor` 状态（token / 保存目录 / 大小上限在构造时注入），
/// 向主线程的上报一律 `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`。
///
/// 上传走**原始字节流**而非 multipart（见 TECH_DESIGN §3）：收到的每个 chunk 立即 append 到
/// `<目标>.baobox-part`，内存占用与文件大小无关；收满 Content-Length 才改名为最终文件，
/// 中断则删除 part 文件，不留半截垃圾。
final class LanDropSession: @unchecked Sendable {

    /// 构造时注入的不可变配置，避免会话反向读主线程状态。
    struct Config: Sendable {
        let token: String
        let saveDir: URL
        let maxFileSize: Int
    }

    /// 请求头最大字节数：超过即断开，防恶意客户端只发头不发空行把内存撑爆。
    private static let maxHeaderBytes = 32 * 1024

    /// 单次 receive 上限。
    private static let chunkSize = 256 * 1024

    /// 进度上报节流间隔（秒）。
    private static let reportInterval: TimeInterval = 0.2

    /// 落盘中的上传状态。
    private struct Upload {
        let id: UUID
        let name: String
        let total: Int
        let partURL: URL
        var finalURL: URL
        let handle: FileHandle
        var received: Int
        var lastReport: Date
    }

    /// 下发中的下载状态（Mac → 手机方向）。
    private struct Download {
        let handle: FileHandle
        var remaining: Int
        var lastActivityPing: Date
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let config: Config
    private let registry: LanDropSessionRegistry

    private var buffer = Data()
    private var upload: Upload?
    private var download: Download?
    private var finished = false

    init(connection: NWConnection, config: Config, registry: LanDropSessionRegistry) {
        self.connection = connection
        self.config = config
        self.registry = registry
        self.queue = DispatchQueue(label: "com.baobox.landrop.session")
    }

    func start() {
        registry.add(self)   // 登记 = 持有；cleanup 时注销
        connection.start(queue: queue)
        Self.onMain { LanDropServer.shared.noteActivity() }
        receiveMore()
    }

    /// 外部（服务停止）掐断。
    func cancel() {
        queue.async { [weak self] in
            self?.abortUpload(reason: L("landrop.error.interrupted"))
            self?.cleanup()
        }
    }

    // MARK: - 读取

    private func receiveMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if self.upload != nil {
                    self.feed(data)
                } else {
                    self.buffer.append(data)
                    self.consumeHeaderIfReady()
                }
            }
            if error != nil {
                self.abortUpload(reason: L("landrop.error.interrupted"))
                self.endDownload()
                self.cleanup()
                return
            }
            if isComplete {
                // 对端关闭了写端。下发中的话只停止读、继续发完——有的客户端发完请求就半关闭，
                // 这时 cleanup 会把还没发完的文件截断。
                if self.download != nil { return }
                // 上传未收满即为中断。
                self.abortUpload(reason: L("landrop.error.interrupted"))
                self.cleanup()
                return
            }
            guard !self.finished else { return }
            self.receiveMore()
        }
    }

    /// 头部齐了就解析并路由；不齐则继续等（超过上限直接断）。
    private func consumeHeaderIfReady() {
        guard upload == nil, !finished else { return }
        guard let range = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            if buffer.count > Self.maxHeaderBytes { cleanup() }
            return
        }
        let headText = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound),
                              encoding: .isoLatin1) ?? ""
        let rest = buffer.subdata(in: range.upperBound..<buffer.endIndex)
        buffer = Data()

        let lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let method = parts.count > 0 ? String(parts[0]).uppercased() : ""
        let target = parts.count > 1 ? String(parts[1]) : "/"
        route(method: method, target: target, headers: headers, pendingBody: rest)
    }

    // MARK: - 路由

    private func route(method: String, target: String, headers: [String: String], pendingBody: Data) {
        let components = URLComponents(string: "http://localhost" + target)
        let path = components?.path ?? "/"
        let query = components?.queryItems ?? []
        let token = query.first(where: { $0.name == "k" })?.value ?? ""

        // 访问码不对 → 一律 404（不是 401）：不向扫到端口的人暴露这里跑着什么。
        guard Self.constantTimeEqual(token, config.token) else {
            respond(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data())
            return
        }

        // 只有「真的在传东西」才算活动。`/ping` 与 `/list` 是网页的被动轮询，
        // 若也算活动，页面一直开着就永远不会空闲超时，自动关闭形同虚设。
        if path == "/" || path == "/upload" || path == "/file" {
            Self.onMain { LanDropServer.shared.noteActivity() }
        }

        switch (method, path) {
        case ("GET", "/"):
            let html = LanDropPage.html(token: config.token,
                                        folderName: config.saveDir.lastPathComponent,
                                        maxFileSize: config.maxFileSize,
                                        shared: LanDropShareSnapshot.shared.get(),
                                        acceptLanguage: headers["accept-language"])
            respond(status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))

        case ("GET", "/ping"):
            respond(status: "200 OK", contentType: "application/json", body: Data(#"{"ok":true}"#.utf8))

        case ("GET", "/list"):
            // 只回句柄 / 文件名 / 大小 —— 路径一个字都不出去。
            let items = LanDropShareSnapshot.shared.get().map {
                ["id": $0.id, "name": $0.name, "size": $0.size] as [String: Any]
            }
            let json = (try? JSONSerialization.data(withJSONObject: ["items": items]))
                ?? Data(#"{"items":[]}"#.utf8)
            respond(status: "200 OK", contentType: "application/json", body: json)

        case ("GET", "/file"):
            let id = query.first(where: { $0.name == "id" })?.value ?? ""
            sendSharedFile(id: id, headers: headers)

        case ("POST", "/upload"):
            let rawName = query.first(where: { $0.name == "name" })?.value ?? ""
            beginUpload(rawName: rawName, headers: headers, pendingBody: pendingBody)

        default:
            respond(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data())
        }
    }

    // MARK: - 下发（Mac → 手机）

    /// 按句柄下发一个被显式分享的文件。
    ///
    /// **只认句柄，不认路径**：手机传来的 id 在内存分享表里查，查不到就 404。服务端没有任何
    /// 接受路径输入的入口，所以这个方向上不存在目录穿越或越权读取——能拿到的只有用户拖进面板的东西。
    private func sendSharedFile(id: String, headers: [String: String]) {
        guard let item = LanDropShareSnapshot.shared.item(id: id),
              let handle = try? FileHandle(forReadingFrom: item.url) else {
            // 句柄失效、或文件在分享期间被删除 / 移走。
            respond(status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data())
            return
        }

        let total = (try? handle.seekToEnd()).map { Int($0) } ?? item.size
        var start = 0
        var end = max(0, total - 1)
        var partial = false
        if let raw = headers["range"], let parsed = Self.parseRange(raw, total: total) {
            start = parsed.lower
            end = parsed.upper
            partial = true
        }
        // 越界或畸形的 Range 在 `parseRange` 里已经被判成 nil，此处退化为整文件 200，
        // 故不需要 416 分支（多回一个状态码不如少一条永不执行的路径）。
        let length = total == 0 ? 0 : end - start + 1
        if start > 0 {
            do { try handle.seek(toOffset: UInt64(start)) } catch {
                try? handle.close()
                respond(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data())
                return
            }
        }

        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(Self.mimeType(for: item.name))\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
        head += "Content-Disposition: \(Self.contentDisposition(for: item.name))\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"

        download = Download(handle: handle, remaining: length, lastActivityPing: Date())
        finished = true   // 不再读这条连接，剩下的事情是把文件发完

        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                self.endDownload()
                self.cleanup()
                return
            }
            self.pumpDownload()
        })
    }

    /// 逐块读文件并发出，**发完一块才读下一块**（背压）：4 GB 文件的内存占用等于一块的大小。
    private func pumpDownload() {
        guard var current = download else {
            cleanup()
            return
        }
        guard current.remaining > 0 else {
            endDownload()
            cleanup()
            return
        }
        let want = min(Self.chunkSize, current.remaining)
        guard let chunk = try? current.handle.read(upToCount: want), !chunk.isEmpty else {
            // 文件在下发途中被截断 / 出错：直接断开，手机侧因 Content-Length 不满而报失败。
            endDownload()
            cleanup()
            return
        }
        current.remaining -= chunk.count

        // 下发期间也要刷空闲计时，否则传一个大文件传到一半服务被自动关掉。节流 2 秒。
        if Date().timeIntervalSince(current.lastActivityPing) >= 2 {
            current.lastActivityPing = Date()
            Self.onMain { LanDropServer.shared.noteActivity() }
        }
        download = current

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                self.endDownload()
                self.cleanup()
                return
            }
            self.pumpDownload()
        })
    }

    private func endDownload() {
        guard let current = download else { return }
        download = nil
        try? current.handle.close()
        Self.onMain { LanDropServer.shared.noteActivity() }
    }

    /// 解析单段 `Range: bytes=…`。支持 `a-b`、`a-`、`-suffix` 三种写法；多段与非法值返回 nil（退化为整文件 200）。
    static func parseRange(_ raw: String, total: Int) -> (lower: Int, upper: Int)? {
        guard total > 0 else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("bytes=") else { return nil }
        let spec = String(trimmed.dropFirst("bytes=".count))
        guard !spec.contains(",") else { return nil }   // 多段不支持
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let first = String(parts[0]), second = String(parts[1])

        if first.isEmpty {
            // `-500`：末尾 500 字节
            guard let suffix = Int(second), suffix > 0 else { return nil }
            let lower = max(0, total - suffix)
            return (lower, total - 1)
        }
        guard let lower = Int(first), lower >= 0, lower < total else { return nil }
        if second.isEmpty { return (lower, total - 1) }
        guard let upper = Int(second), upper >= lower else { return nil }
        return (lower, min(upper, total - 1))
    }

    /// 常见类型给准确 MIME，其余一律 octet-stream（浏览器会走下载而不是乱渲染）。
    static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "txt", "log", "md": return "text/plain; charset=utf-8"
        case "json": return "application/json"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    /// 图片 / 音视频用 `inline`：iOS Safari 会直接打开，长按即可存进相册——比下载到「文件」App 顺手。
    /// 其余用 `attachment` 触发下载。文件名同时给 ASCII 回退与 RFC 5987 的 UTF-8 形式。
    static func contentDisposition(for name: String) -> String {
        let mime = mimeType(for: name)
        let kind = mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/")
            ? "inline" : "attachment"
        let ascii = String(name.unicodeScalars.map { $0.isASCII && $0 != "\"" && $0 != "\\" ? Character($0) : "_" })
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ascii
        return "\(kind); filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)"
    }

    // MARK: - 上传

    private func beginUpload(rawName: String, headers: [String: String], pendingBody: Data) {
        let total = Int(headers["content-length"] ?? "") ?? -1
        guard total >= 0 else {
            respond(status: "411 Length Required", contentType: "text/plain; charset=utf-8", body: Data())
            return
        }
        if config.maxFileSize > 0, total > config.maxFileSize {
            respond(status: "413 Payload Too Large", contentType: "text/plain; charset=utf-8", body: Data())
            return
        }

        let name = LanDropEnv.sanitize(filename: rawName)
        // 用构造时注入的目录，不读当前设置：上传途中用户改了设置也不会让同一批文件散落两处。
        guard let dir = LanDropEnv.ensureDirectory(config.saveDir) else {
            reportFailure(name: name, reason: L("landrop.error.saveDirUnwritable"))
            respond(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data())
            return
        }

        let finalURL = LanDropEnv.uniqueURL(in: dir, filename: name)
        let partURL = URL(fileURLWithPath: finalURL.path + ".baobox-part")
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partURL) else {
            try? FileManager.default.removeItem(at: partURL)
            reportFailure(name: name, reason: L("landrop.error.saveDirUnwritable"))
            respond(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data())
            return
        }

        let id = UUID()
        upload = Upload(id: id, name: finalURL.lastPathComponent, total: total,
                        partURL: partURL, finalURL: finalURL, handle: handle,
                        received: 0, lastReport: Date())

        let displayName = finalURL.lastPathComponent
        Self.onMain {
            LanDropTransfers.shared.begin(id: id, name: displayName, total: total)
            LanDropNotify.postStart(name: displayName)
            LanDropServer.shared.noteActivity()
        }

        // 空文件没有 body 可等，先判；否则 feed 的「剩余字节为 0」会直接 return，传输永远收不了尾。
        if total == 0 {
            finishUpload()
        } else if !pendingBody.isEmpty {
            // 头之后已经跟着来的那部分 body 先落盘。
            feed(pendingBody)
        }
    }

    private func feed(_ data: Data) {
        guard var current = upload else { return }

        // 多收的字节（客户端多发 / 粘包）直接丢弃，只认 Content-Length 声明的长度。
        // `prefix` 在不足时返回全部，故无需再比较长度。
        let remaining = current.total - current.received
        guard remaining > 0 else { return }
        let slice = data.prefix(remaining)

        do {
            try current.handle.write(contentsOf: slice)
        } catch {
            abortUpload(reason: L("landrop.error.writeFailed"))
            respond(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data())
            return
        }
        current.received += slice.count
        upload = current

        if current.received >= current.total {
            finishUpload()
            return
        }

        // 节流上报：大文件下 progress 回调极密，不节流会把主线程刷爆。
        if Date().timeIntervalSince(current.lastReport) >= Self.reportInterval {
            current.lastReport = Date()
            upload = current
            let id = current.id
            let received = current.received
            Self.onMain {
                LanDropTransfers.shared.update(id: id, received: received)
                LanDropServer.shared.noteActivity()
            }
        }
    }

    private func finishUpload() {
        guard let current = upload else { return }
        upload = nil
        try? current.handle.close()

        // 落盘期间同名文件可能已被别的传输占用，改名前再取一次唯一名。
        var target = current.finalURL
        if FileManager.default.fileExists(atPath: target.path) {
            target = LanDropEnv.uniqueURL(in: target.deletingLastPathComponent(),
                                          filename: target.lastPathComponent)
        }
        do {
            try FileManager.default.moveItem(at: current.partURL, to: target)
        } catch {
            try? FileManager.default.removeItem(at: current.partURL)
            let id = current.id
            let name = current.name
            Self.onMain {
                LanDropTransfers.shared.fail(id: id, reason: L("landrop.error.writeFailed"))
                LanDropNotify.postFailed(name: name, reason: L("landrop.error.writeFailed"))
            }
            respond(status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data())
            return
        }

        let id = current.id
        let name = target.lastPathComponent
        let path = target.path
        let bytes = current.received
        Self.onMain {
            LanDropTransfers.shared.finish(id: id, path: path, received: bytes)
            LanDropNotify.postDone(name: name, bytes: bytes)
            LanDropServer.shared.noteActivity()
            LanDropServer.shared.stopIfDoneAndConfigured()
        }

        let payload: [String: Any] = ["ok": true, "name": name, "bytes": bytes]
        let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(#"{"ok":true}"#.utf8)
        respond(status: "200 OK", contentType: "application/json", body: json)
    }

    /// 中断收尾：关句柄、删 part 文件、标记失败。已完成或本就没在传则什么都不做。
    private func abortUpload(reason: String) {
        guard let current = upload else { return }
        upload = nil
        try? current.handle.close()
        try? FileManager.default.removeItem(at: current.partURL)
        let id = current.id
        let name = current.name
        Self.onMain {
            LanDropTransfers.shared.fail(id: id, reason: reason)
            LanDropNotify.postFailed(name: name, reason: reason)
        }
    }

    /// 尚未建立上传条目时的失败上报（如保存目录不可写）。
    private func reportFailure(name: String, reason: String) {
        Self.onMain { LanDropNotify.postFailed(name: name, reason: reason) }
    }

    // MARK: - 响应

    private func respond(status: String, contentType: String, body: Data) {
        guard !finished else { return }
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var packet = Data(head.utf8)
        packet.append(body)
        finished = true
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
            self?.cleanup()
        })
    }

    private func cleanup() {
        connection.cancel()
        registry.remove(self)   // 注销 = 释放持有
    }

    // MARK: - 工具

    /// 全量比较（不短路），避免按前缀逐字节试探 token 的时序侧信道。
    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }

    private static func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                work()
            }
        }
    }
}
