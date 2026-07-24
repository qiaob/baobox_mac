import Foundation

// MARK: - 模型

/// 一个 HTTP 头字段（保留原始大小写；查询用大小写不敏感辅助方法）。
/// 用具名 struct 而非 `(String,String)` 元组，便于 Sendable / 迭代 / 导出。
struct HTTPHeader: Sendable, Hashable {
    let name: String
    let value: String
}

extension Array where Element == HTTPHeader {
    /// 大小写不敏感取首个匹配头的值。
    func value(for name: String) -> String? {
        let lower = name.lowercased()
        return first { $0.name.lowercased() == lower }?.value
    }
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
    /// false = 透传未解密（仅记录 CONNECT 元数据，无明文）。
    var decrypted: Bool
    /// 附注：如「brotli 未解压」「h2 透传」「TLS 握手失败透传」「已截断」。
    var note: String?

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

    /// 追加一条 flow；超上限从头淘汰。回主线程调用（Network 回调里用 `DispatchQueue.main.async`）。
    func append(_ flow: Flow) {
        flows.append(flow)
        if flows.count > maxFlows {
            flows.removeFirst(flows.count - maxFlows)
        }
        recomputeDevices()
        FlowSnapshotStore.shared.set(flows)
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

    /// 估算内存占用（仅 body 字节，粗略）。
    var estimatedBytes: Int {
        flows.reduce(0) { $0 + ($1.requestBody?.count ?? 0) + ($1.responseBody?.count ?? 0) }
    }

    // MARK: - 过滤 / 搜索

    /// 过滤：设备（clientIP，nil=全部）、关键字（URL / body 文本）、方法集合、状态码分类集合。空条件即全通过。
    func filtered(query: String, methods: Set<String>, statusClasses: Set<Int>,
                  device: String? = nil) -> [Flow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        return flows.filter { flow in
            if let device, (flow.clientIP ?? NetCaptureEnv.unknownDeviceKey) != device { return false }
            if !methods.isEmpty && !methods.contains(flow.method.uppercased()) { return false }
            if !statusClasses.isEmpty && !statusClasses.contains(flow.statusClass) { return false }
            guard !trimmed.isEmpty else { return true }
            if flow.url.lowercased().contains(trimmed) { return true }
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
                "httpVersion": "HTTP/1.1",
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
                "httpVersion": "HTTP/1.1",
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
        if let body = flow.responseBody {
            let display = HTTPBodyCodec.decodedForDisplay(body: body, headers: flow.responseHeaders)
            if let text = String(data: display.data, encoding: .utf8), !text.isEmpty {
                lines.append("**Response body**\(display.note.map { " (\($0))" } ?? "")")
                lines.append("```")
                lines.append(String(text.prefix(8000)))
                lines.append("```")
            }
        }
        return lines.joined(separator: "\n")
    }
}
