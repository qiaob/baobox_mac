import Foundation

// MARK: - 模型

// `HTTPHeader` 在 Logic/CaptureEvent.swift（纯逻辑，进单元测试）。

/// 一条 WebSocket 消息（挂在握手那条 Flow 上）。
struct FlowMessage: Identifiable, Sendable {
    let id: Int
    let fromClient: Bool
    /// 文本消息的内容；二进制消息为 nil。
    let text: String?
    let size: Int
    let at: Date
}

/// 一条被捕获的 HTTP 事务（请求 + 响应 + 元数据）。仅内存驻留。
struct Flow: Identifiable, Sendable {
    let id: UUID
    var method: String
    var scheme: String            // "http" / "https"
    var host: String
    var port: Int
    var path: String

    var requestHeaders: [HTTPHeader]
    var requestBody: Data?
    var requestTruncated: Bool

    var statusCode: Int?
    var responseHeaders: [HTTPHeader]
    var responseBody: Data?
    var responseTruncated: Bool

    var startedAt: Date
    var endedAt: Date?

    var requestBytes: Int
    var responseBytes: Int

    var remoteIP: String?
    /// 源设备局域网 IP（客户端连到代理的 remote 端）。`127.0.0.1`/`::1` → 本机；nil 未知。
    /// 用于多设备区分（§17）：一处在 `ProxyConnection.appendFlow` 统一打标。
    var clientIP: String?
    /// false = 透传未解密（只知道域名，没有明文）。
    var decrypted: Bool
    /// 附注：目前只放请求失败时引擎给的错误信息。
    var note: String?
    /// `HTTP/1.1`、`HTTP/2.0`…（引擎给的原样）。
    var httpVersion: String = "HTTP/1.1"
    /// 响应原本的 Content-Encoding；正文已经由引擎解压，这里只用来展示。
    var responseEncoding: String?
    /// 没解密的原因（`decrypted == false` 时有值）。
    var undecryptedReason: CaptureEvent.UndecryptedReason?
    /// WebSocket 消息（只有 WebSocket 连接有）。
    var messages: [FlowMessage] = []

    init(id: UUID = UUID(),
         method: String = "",
         scheme: String = "https",
         host: String = "",
         port: Int = 443,
         path: String = "/",
         requestHeaders: [HTTPHeader] = [],
         requestBody: Data? = nil,
         requestTruncated: Bool = false,
         statusCode: Int? = nil,
         responseHeaders: [HTTPHeader] = [],
         responseBody: Data? = nil,
         responseTruncated: Bool = false,
         startedAt: Date = Date(),
         endedAt: Date? = nil,
         requestBytes: Int = 0,
         responseBytes: Int = 0,
         remoteIP: String? = nil,
         clientIP: String? = nil,
         decrypted: Bool = true,
         note: String? = nil) {
        self.id = id
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.requestTruncated = requestTruncated
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.responseTruncated = responseTruncated
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.remoteIP = remoteIP
        self.clientIP = clientIP
        self.decrypted = decrypted
        self.note = note
    }

    private var defaultPort: Int { scheme == "https" ? 443 : 80 }

    var url: String {
        let portPart = (port == defaultPort) ? "" : ":\(port)"
        return "\(scheme)://\(host)\(portPart)\(path)"
    }

    var durationMs: Int? {
        endedAt.map { Int($0.timeIntervalSince(startedAt) * 1000) }
    }

    /// 状态码分类（用于配色 / 过滤）：2/3/4/5，nil→0。
    var statusClass: Int {
        guard let code = statusCode else { return 0 }
        return code / 100
    }

    /// 请求发出去了、响应还没回来。
    var isPending: Bool { decrypted && statusCode == nil && endedAt == nil }

    var isWebSocket: Bool {
        !messages.isEmpty
            || (statusCode == 101 && responseHeaders.value(for: "Upgrade")?.lowercased() == "websocket")
    }

    /// 列表里协议那一格：只有不是 HTTP/1.x 的才标。
    var protocolBadge: String? {
        if isWebSocket { return "WS" }
        if httpVersion.hasPrefix("HTTP/2") { return "h2" }
        if httpVersion.hasPrefix("HTTP/3") { return "h3" }
        return nil
    }

    /// 响应 Content-Type（小写主类型），用于 body 渲染选择。
    var responseContentType: String? {
        responseHeaders.value(for: "Content-Type")
    }
}

// MARK: - 设备（多设备区分，§17）

/// 一个抓包来源设备。身份 = 客户端源 LAN IP（手机 / 本机）。
struct DeviceInfo: Identifiable, Sendable {
    let id: String            // = ip（未知源用 NetCaptureEnv.unknownDeviceKey）
    let ip: String
    let label: String         // 别名 ?? 本机 ?? IP
    let flowCount: Int
    let lastActivity: Date
}

// MARK: - 跨线程快照

/// flow 的线程安全快照（`Flow` 为 Sendable）。独立于 @MainActor 的 `FlowStore`，供 MCP 连接队列
/// 等非主线程只读，避免从 nonisolated 上下文触碰 MainActor 隔离状态。
final class FlowSnapshotStore: @unchecked Sendable {
    static let shared = FlowSnapshotStore()
    private let lock = NSLock()
    private var flows: [Flow] = []
    private init() {}

    func set(_ newFlows: [Flow]) { lock.lock(); flows = newFlows; lock.unlock() }
    func get() -> [Flow] { lock.lock(); defer { lock.unlock() }; return flows }
}

// MARK: - 环形存储

/// flow 环形缓冲：追加序，超上限淘汰最旧；`@Published` 供 UI，并同步维护 `FlowSnapshotStore` 供 MCP。
@MainActor
final class FlowStore: ObservableObject {
    static let shared = FlowStore()

    /// 追加序（旧 → 新）；UI 倒序展示。
    @Published private(set) var flows: [Flow] = []

    /// 当前所有来源设备（按末次活动降序，本机固定最前）；`append`/`clear` 后重算。
    @Published private(set) var devices: [DeviceInfo] = []

    private init() {}

    var maxFlows: Int { NetCaptureEnv.maxFlows }

    /// 单条连接最多留多少条 WebSocket 消息（超了丢最旧的）。
    static let maxMessagesPerFlow = 500

    /// 把引擎推来的一批事件落到列表里：请求先到就先占一行，响应到了补全。一批只重算一次设备与快照。
    /// 与流量无关的事件（就绪、新设备）由 `NetCaptureEngine` 自己处理，这里忽略。
    func apply(_ events: [CaptureEvent]) {
        var changed = false
        for event in events {
            switch event {
            case .request(let request):
                var flow = Flow(id: request.id,
                                method: request.method,
                                scheme: request.scheme,
                                host: request.host,
                                port: request.port,
                                path: request.path,
                                requestHeaders: request.headers,
                                requestBody: request.body,
                                requestTruncated: request.truncated,
                                startedAt: request.startedAt,
                                requestBytes: request.bytes,
                                clientIP: request.client)
                flow.httpVersion = request.httpVersion
                if let index = index(of: request.id) { flows[index] = flow } else { flows.append(flow) }
                changed = true
            case .response(let response):
                guard let index = index(of: response.id) else { continue }
                flows[index].statusCode = response.status
                flows[index].responseHeaders = response.headers
                flows[index].responseBody = response.body
                flows[index].responseTruncated = response.truncated
                flows[index].responseEncoding = response.encoding
                flows[index].responseBytes = response.bytes
                flows[index].remoteIP = response.remote
                flows[index].endedAt = response.endedAt ?? Date()
                if let version = response.httpVersion { flows[index].httpVersion = version }
                changed = true
            case .failure(let id, let message, let at):
                guard let index = index(of: id) else { continue }
                flows[index].note = message
                if flows[index].endedAt == nil { flows[index].endedAt = at ?? Date() }
                changed = true
            case .webSocket(let message):
                guard let index = index(of: message.flowID) else { continue }
                let next = (flows[index].messages.last?.id ?? 0) + 1
                flows[index].messages.append(FlowMessage(id: next, fromClient: message.fromClient,
                                                         text: message.text, size: message.size, at: message.at))
                let overflow = flows[index].messages.count - Self.maxMessagesPerFlow
                if overflow > 0 { flows[index].messages.removeFirst(overflow) }
                changed = true
            case .tls(let client, let host, let reason):
                // 没解密的连接引擎不会给请求事件，这里补一行，让用户知道这个域名有流量、为什么看不到内容。
                let now = Date()
                var flow = Flow(method: "CONNECT", scheme: "https", host: host, port: 443, path: "",
                                startedAt: now, endedAt: now, clientIP: client, decrypted: false)
                flow.undecryptedReason = reason
                flows.append(flow)
                changed = true
            case .running, .device:
                continue
            }
        }
        guard changed else { return }
        if flows.count > maxFlows {
            flows.removeFirst(flows.count - maxFlows)
        }
        recomputeDevices()
        FlowSnapshotStore.shared.set(flows)
    }

    /// 响应、消息几乎总是落在最近的几条上，从尾部找。
    private func index(of id: UUID) -> Int? {
        flows.lastIndex { $0.id == id }
    }

    /// 清空并释放所有 body Data。
    func clear() {
        flows.removeAll(keepingCapacity: false)
        recomputeDevices()
        FlowSnapshotStore.shared.set(flows)
    }

    /// 移除某设备（clientIP）的全部 flow；用于设备 Tab 右键「清空此设备的包」。
    func clearDevice(ip: String) {
        flows.removeAll { ($0.clientIP ?? NetCaptureEnv.unknownDeviceKey) == ip }
        recomputeDevices()
        FlowSnapshotStore.shared.set(flows)
    }

    // MARK: - 设备聚合与别名（§17）

    /// 判定回环（本机）源 IP。
    static func isLoopback(_ ip: String) -> Bool {
        ip == "127.0.0.1" || ip == "::1" || ip.lowercased() == "localhost"
    }

    /// 设备显示名：别名优先 → 本机 → 原始 IP（反查主机名从简省略，见 §17.6 取舍）。
    static func label(for ip: String) -> String {
        if ip == NetCaptureEnv.unknownDeviceKey { return L("netcapture.device.unknown") }
        if let alias = NetCaptureEnv.deviceAlias(for: ip) { return alias }
        if isLoopback(ip) { return L("netcapture.device.thisMac") }
        return ip
    }

    /// 读取某设备别名（无则 nil）。
    func alias(ip: String) -> String? { NetCaptureEnv.deviceAlias(for: ip) }

    /// 设置/清除某设备别名，并刷新设备标签。空串清除。
    func setAlias(ip: String, _ alias: String?) {
        NetCaptureEnv.setDeviceAlias(alias, for: ip)
        recomputeDevices()
    }

    /// 从 `flows` 重算设备列表：按 clientIP 分桶计数 + 末次时间；本机排最前，其余按末次活动降序。
    private func recomputeDevices() {
        var buckets: [String: (count: Int, last: Date)] = [:]
        for flow in flows {
            let key = flow.clientIP ?? NetCaptureEnv.unknownDeviceKey
            var bucket = buckets[key] ?? (0, Date.distantPast)
            bucket.count += 1
            if flow.startedAt > bucket.last { bucket.last = flow.startedAt }
            buckets[key] = bucket
        }
        var result = buckets.map { key, bucket in
            DeviceInfo(id: key, ip: key, label: Self.label(for: key),
                       flowCount: bucket.count, lastActivity: bucket.last)
        }
        result.sort { lhs, rhs in
            let lLoop = Self.isLoopback(lhs.ip), rLoop = Self.isLoopback(rhs.ip)
            if lLoop != rLoop { return lLoop }         // 本机固定最前
            return lhs.lastActivity > rhs.lastActivity  // 其余按末次活动降序
        }
        devices = result
    }

    /// 某个来源（nil = 全部）下各域名的请求数，多的在前；左栏的域名列表用。
    func hosts(device: String?) -> [(host: String, count: Int)] {
        var counts: [String: Int] = [:]
        for flow in flows {
            if let device, (flow.clientIP ?? NetCaptureEnv.unknownDeviceKey) != device { continue }
            counts[flow.host, default: 0] += 1
        }
        return counts.map { (host: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.host < $1.host }
    }

    /// 估算内存占用（仅 body 字节，粗略）。
    var estimatedBytes: Int {
        flows.reduce(0) { $0 + ($1.requestBody?.count ?? 0) + ($1.responseBody?.count ?? 0) }
    }

    // MARK: - 过滤 / 搜索

    /// 过滤：设备（clientIP，nil=全部）、关键字（URL / body 文本）、方法集合、状态码分类集合。空条件即全通过。
    func filtered(query: String, methods: Set<String>, statusClasses: Set<Int>,
                  device: String? = nil, host: String? = nil) -> [Flow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        return flows.filter { flow in
            if let device, (flow.clientIP ?? NetCaptureEnv.unknownDeviceKey) != device { return false }
            if let host, flow.host != host { return false }
            if !methods.isEmpty && !methods.contains(flow.method.uppercased()) { return false }
            if !statusClasses.isEmpty && !statusClasses.contains(flow.statusClass) { return false }
            guard !trimmed.isEmpty else { return true }
            if flow.url.lowercased().contains(trimmed) { return true }
            if flow.messages.contains(where: { $0.text?.lowercased().contains(trimmed) == true }) { return true }
            if let body = flow.responseBody, let text = String(data: body, encoding: .utf8),
               text.lowercased().contains(trimmed) { return true }
            if let body = flow.requestBody, let text = String(data: body, encoding: .utf8),
               text.lowercased().contains(trimmed) { return true }
            return false
        }
    }

    // MARK: - 导出

    /// 标准 HAR 1.2 JSON。供导入 Charles / Proxyman 等工具。
    nonisolated func harData(_ source: [Flow]) -> Data {
        var entries: [[String: Any]] = []
        let iso = ISO8601DateFormatter()
        for flow in source {
            let reqHeaders = flow.requestHeaders.map { ["name": $0.name, "value": $0.value] }
            let respHeaders = flow.responseHeaders.map { ["name": $0.name, "value": $0.value] }
            let reqBodyText = flow.requestBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let respBodyText = flow.responseBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let request: [String: Any] = [
                "method": flow.method,
                "url": flow.url,
                "httpVersion": flow.httpVersion,
                "headers": reqHeaders,
                "queryString": [],
                "cookies": [],
                "headersSize": -1,
                "bodySize": flow.requestBytes,
                "postData": ["mimeType": flow.requestHeaders.value(for: "Content-Type") ?? "",
                             "text": reqBodyText],
            ]
            let response: [String: Any] = [
                "status": flow.statusCode ?? 0,
                "statusText": "",
                "httpVersion": flow.httpVersion,
                "headers": respHeaders,
                "cookies": [],
                "content": ["size": flow.responseBytes,
                            "mimeType": flow.responseContentType ?? "",
                            "text": respBodyText],
                "redirectURL": "",
                "headersSize": -1,
                "bodySize": flow.responseBytes,
            ]
            let entry: [String: Any] = [
                "startedDateTime": iso.string(from: flow.startedAt),
                "time": flow.durationMs ?? 0,
                "request": request,
                "response": response,
                "cache": [:],
                "timings": ["send": 0, "wait": flow.durationMs ?? 0, "receive": 0],
                "serverIPAddress": flow.remoteIP ?? "",
            ]
            entries.append(entry)
        }
        let log: [String: Any] = [
            "log": [
                "version": "1.2",
                "creator": ["name": "Baobox NetCapture", "version": "1.0"],
                "entries": entries,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: log,
                                            options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data()
    }

    /// 生成 cURL 命令（单引号转义）。
    nonisolated func curl(for flow: Flow) -> String {
        var parts = ["curl -X \(flow.method) \(NetCaptureEnv.shellSingleQuote(flow.url))"]
        for header in flow.requestHeaders {
            // 跳过会被 curl 自动管理的头。
            let lower = header.name.lowercased()
            if lower == "content-length" || lower == "host" { continue }
            parts.append("-H \(NetCaptureEnv.shellSingleQuote("\(header.name): \(header.value)"))")
        }
        if let body = flow.requestBody, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            parts.append("--data-binary \(NetCaptureEnv.shellSingleQuote(text))")
        }
        return parts.joined(separator: " \\\n  ")
    }

    /// 生成 Markdown 摘要（请求行 + 关键头 + body 摘要 + 响应），供「复制」与「发送到 Claude Code」。
    nonisolated func markdown(for flow: Flow) -> String {
        var lines: [String] = []
        lines.append("### \(flow.method) \(flow.url)")
        if let status = flow.statusCode {
            lines.append("Status: \(status)  ·  \(flow.durationMs.map { "\($0)ms" } ?? "-")  ·  \(flow.responseBytes) bytes")
        }
        lines.append("")
        lines.append("**Request headers**")
        lines.append("```")
        for h in flow.requestHeaders.prefix(30) { lines.append("\(h.name): \(h.value)") }
        lines.append("```")
        if let body = flow.requestBody, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            lines.append("**Request body**")
            lines.append("```")
            lines.append(String(text.prefix(4000)))
            lines.append("```")
        }
        lines.append("**Response headers**")
        lines.append("```")
        for h in flow.responseHeaders.prefix(30) { lines.append("\(h.name): \(h.value)") }
        lines.append("```")
        if let body = flow.responseBody, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            lines.append("**Response body**")
            lines.append("```")
            lines.append(String(text.prefix(8000)))
            lines.append("```")
        }
        return lines.joined(separator: "\n")
    }
}
