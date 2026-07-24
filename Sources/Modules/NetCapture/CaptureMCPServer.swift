import Foundation
import Network

/// 本地 MCP 服务（Streamable HTTP，`127.0.0.1:<mcpPort>`）：暴露查询抓包结果的工具供 AI 调用。
///
/// 传输：极简 HTTP + JSON-RPC（`initialize` / `tools/list` / `tools/call`），仅监听 loopback、无鉴权。
/// 数据读 `FlowSnapshotStore.shared.get()`（线程安全快照）。开关独立于抓包代理；关 = 停服务、释放端口。
/// 注册进 Claude Code / Codex 是独立的显式动作（写配置文件），不随开关自动改，避免污染用户配置。
@MainActor
final class CaptureMCPServer: ObservableObject {
    static let shared = CaptureMCPServer()

    @Published private(set) var isRunning = false

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.baobox.netcapture.mcp")

    /// 注册进 AI 配置时用的服务器名。
    static let serverName = "baobox-netcapture"

    private init() {}

    var endpointURL: String { "http://127.0.0.1:\(NetCaptureEnv.mcpPort)/mcp" }

    // MARK: - 启停

    func start() {
        guard !isRunning else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 仅绑 loopback（127.0.0.1），不对外暴露。
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                           port: NWEndpoint.Port(rawValue: NetCaptureEnv.mcpPort)!)
        guard let listener = try? NWListener(using: params) else { return }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.isRunning = true
                    case .failed, .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
        }
        listener.newConnectionHandler = { connection in
            MCPHTTPSession(connection: connection, queue: DispatchQueue(label: "com.baobox.netcapture.mcpconn")).start()
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - 注册进 Claude Code / Codex（显式动作，后台线程调用）

    /// 是否已注册到 Claude Code。后台线程调用（读文件）。
    nonisolated static func isRegisteredInClaude() -> Bool {
        ClaudeEnv.mcpServers().contains { $0.name == serverName }
    }

    /// 注册进 Claude Code（写 `~/.claude.json` 顶层 mcpServers，复用 ClaudeEnv 的安全读改写）。
    nonisolated static func registerInClaude() throws {
        try ClaudeEnv.setMCPServer(name: serverName, config: [
            "type": "http",
            "url": "http://127.0.0.1:\(NetCaptureEnv.mcpPort)/mcp",
        ])
    }

    nonisolated static func unregisterFromClaude() throws {
        try ClaudeEnv.removeMCPServer(name: serverName)
    }

    /// 是否已注册到 Codex（扫描 config.toml 的 [mcp_servers.<name>] 段）。后台线程调用。
    nonisolated static func isRegisteredInCodex() -> Bool {
        CodexEnv.mcpServers().contains { $0.name == serverName }
    }

    /// 注册进 Codex：块级追加 `[mcp_servers.baobox-netcapture]`（http 型）。备份后写。后台线程调用。
    nonisolated static func registerInCodex() throws {
        let url = CodexEnv.configFile
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // 已存在则先移除旧块，避免重复。
        text = removeCodexBlock(text)
        let block = """

        [mcp_servers.\(serverName)]
        url = "http://127.0.0.1:\(NetCaptureEnv.mcpPort)/mcp"
        """
        if !text.hasSuffix("\n") && !text.isEmpty { text += "\n" }
        text += block + "\n"
        try writeCodex(text, to: url)
    }

    nonisolated static func unregisterFromCodex() throws {
        let url = CodexEnv.configFile
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try writeCodex(removeCodexBlock(text), to: url)
    }

    // MARK: - 注册进 Cursor（`~/.cursor/mcp.json` 顶层 mcpServers，JSON 安全读改写）

    /// Cursor 全局 MCP 配置文件。
    nonisolated static var cursorConfigFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/mcp.json")
    }

    /// 是否已注册到 Cursor。后台线程调用（读文件）。
    nonisolated static func isRegisteredInCursor() -> Bool {
        guard let data = try? Data(contentsOf: cursorConfigFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }

    /// 注册进 Cursor：写 `mcpServers.baobox-netcapture`（http 型 url）。保留其余键，写前备份。后台线程调用。
    nonisolated static func registerInCursor() throws {
        let url = cursorConfigFile
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers[serverName] = ["url": "http://127.0.0.1:\(NetCaptureEnv.mcpPort)/mcp"]
        root["mcpServers"] = servers
        try writeCursor(root, to: url)
    }

    nonisolated static func unregisterFromCursor() throws {
        let url = cursorConfigFile
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any] else { return }
        servers.removeValue(forKey: serverName)
        root["mcpServers"] = servers
        try writeCursor(root, to: url)
    }

    nonisolated private static func writeCursor(_ root: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("baobox.bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url)
    }

    /// 移除 `[mcp_servers.baobox-netcapture]` 段（从段头到下一段头/文件尾）。保全其余内容。
    nonisolated private static func removeCodexBlock(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var skipping = false
        let header = "[mcp_servers.\(serverName)]"
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == header {
                skipping = true
                continue
            }
            if skipping {
                // 遇到下一个段头即停止跳过（保留该行）。
                if trimmed.hasPrefix("[") {
                    skipping = false
                    out.append(line)
                }
                continue
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    nonisolated private static func writeCodex(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("baobox.bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)?.write(to: url)
    }
}

// MARK: - 单次 HTTP/JSON-RPC 会话

/// 读一个 HTTP 请求（headers + Content-Length body），处理 MCP JSON-RPC，回一个 JSON 响应后关闭。
/// 在自身连接队列上运行，读 `FlowSnapshotStore.shared.get()`（线程安全）。
private final class MCPHTTPSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.start(queue: queue)
        readMore()
    }

    private func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if error != nil { self.connection.cancel(); return }
            if let (headers, body) = self.tryParseRequest() {
                self.handle(headers: headers, body: body)
            } else if isComplete {
                self.connection.cancel()
            } else {
                self.readMore()
            }
        }
    }

    /// 尝试解析完整 HTTP 请求（headers 到 \r\n\r\n，body 满足 Content-Length）。不完整返回 nil。
    private func tryParseRequest() -> (headers: [String: String], body: Data)? {
        guard let range = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return nil }
        let headerText = String(data: buffer.subdata(in: buffer.startIndex..<range.lowerBound),
                                encoding: .isoLatin1) ?? ""
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return nil }
        let end = buffer.index(bodyStart, offsetBy: length)
        return (headers, buffer.subdata(in: bodyStart..<end))
    }

    private func handle(headers: [String: String], body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(status: "400 Bad Request", json: ["error": "invalid JSON"])
            return
        }
        let method = json["method"] as? String ?? ""
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        // JSON-RPC 通知（无 id，如 notifications/initialized）→ 202 无体。
        if id == nil {
            respond(status: "202 Accepted", json: nil)
            return
        }

        switch method {
        case "initialize":
            respondRPC(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "baobox-netcapture", "version": "1.0"],
            ])
        case "tools/list":
            respondRPC(id: id, result: ["tools": Self.toolSchemas])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let text = MCPTools.call(name: name, arguments: args)
            respondRPC(id: id, result: ["content": [["type": "text", "text": text]]])
        default:
            respondRPC(id: id, error: ["code": -32601, "message": "method not found"])
        }
    }

    // MARK: 响应

    private func respondRPC(id: Any?, result: [String: Any]) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        payload["id"] = id ?? NSNull()
        respond(status: "200 OK", json: payload)
    }

    private func respondRPC(id: Any?, error: [String: Any]) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "error": error]
        payload["id"] = id ?? NSNull()
        respond(status: "200 OK", json: payload)
    }

    private func respond(status: String, json: [String: Any]?) {
        let bodyData: Data
        if let json { bodyData = (try? JSONSerialization.data(withJSONObject: json)) ?? Data() }
        else { bodyData = Data() }
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let response = Data(head.utf8) + bodyData
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    // MARK: 工具 schema

    static let toolSchemas: [[String: Any]] = [
        [
            "name": "list_flows",
            "description": "List recent captured HTTP flows (summaries). Optional filters: limit, host, method, status, device. device = client LAN IP (source device), get it from list_devices. Each summary ends with @<clientIP>.",
            "inputSchema": ["type": "object", "properties": [
                "limit": ["type": "integer"],
                "host": ["type": "string"],
                "method": ["type": "string"],
                "status": ["type": "integer"],
                "device": ["type": "string"],
            ]],
        ],
        [
            "name": "get_flow",
            "description": "Get one flow's full detail (headers + body text) by id, including its source device.",
            "inputSchema": ["type": "object",
                            "properties": ["id": ["type": "string"]],
                            "required": ["id"]],
        ],
        [
            "name": "search_flows",
            "description": "Search flows whose URL or body contains the query. Optional device = client LAN IP (from list_devices) to restrict to one device.",
            "inputSchema": ["type": "object",
                            "properties": ["query": ["type": "string"], "limit": ["type": "integer"],
                                           "device": ["type": "string"]],
                            "required": ["query"]],
        ],
        [
            "name": "list_devices",
            "description": "List capturing source devices (each phone / this Mac) keyed by client LAN IP, with flow count and last activity. Use a device's ip as the `device` argument to list_flows / search_flows.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "latest_flows",
            "description": "Get the most recent N flow summaries.",
            "inputSchema": ["type": "object", "properties": ["n": ["type": "integer"]]],
        ],
        [
            "name": "clear_flows",
            "description": "Clear all captured flows. Returns how many were cleared.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "start_capture",
            "description": "Start capturing HTTP(S) traffic (equivalent to the UI start switch). Returns the listening and LAN proxy address.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "stop_capture",
            "description": "Stop capturing traffic and restore the system proxy.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "capture_status",
            "description": "Report whether capture is running, its proxy address, and the number of captured flows.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
    ]
}

// MARK: - MCP 工具实现（读 FlowStore 快照，输出脱敏文本）

private enum MCPTools {

    /// 分发工具调用，返回文本结果（供 MCP content）。在 MCP 连接队列调用（读线程安全快照）。
    static func call(name: String, arguments: [String: Any]) -> String {
        let flows = FlowSnapshotStore.shared.get()
        switch name {
        case "list_flows":
            var filtered = flows
            if let host = arguments["host"] as? String, !host.isEmpty {
                filtered = filtered.filter { $0.host.lowercased().contains(host.lowercased()) }
            }
            if let method = arguments["method"] as? String, !method.isEmpty {
                filtered = filtered.filter { $0.method.uppercased() == method.uppercased() }
            }
            if let status = arguments["status"] as? Int {
                filtered = filtered.filter { $0.statusCode == status || $0.statusClass == status }
            }
            if let device = arguments["device"] as? String, !device.isEmpty {
                filtered = filtered.filter { ($0.clientIP ?? NetCaptureEnv.unknownDeviceKey) == device }
            }
            let limit = arguments["limit"] as? Int ?? 50
            return summaries(Array(filtered.suffix(limit)))
        case "latest_flows":
            let n = arguments["n"] as? Int ?? 20
            return summaries(Array(flows.suffix(n)))
        case "search_flows":
            let query = (arguments["query"] as? String ?? "").lowercased()
            let limit = arguments["limit"] as? Int ?? 50
            let device = arguments["device"] as? String
            let matched = flows.filter { flow in
                if let device, !device.isEmpty,
                   (flow.clientIP ?? NetCaptureEnv.unknownDeviceKey) != device { return false }
                if flow.url.lowercased().contains(query) { return true }
                if let b = flow.responseBody, let t = String(data: b, encoding: .utf8),
                   t.lowercased().contains(query) { return true }
                return false
            }
            return summaries(Array(matched.suffix(limit)))
        case "get_flow":
            guard let idStr = arguments["id"] as? String,
                  let flow = flows.first(where: { $0.id.uuidString == idStr }) else {
                return "flow not found"
            }
            return detail(flow)
        case "clear_flows":
            let count = flows.count
            DispatchQueue.main.async { MainActor.assumeIsolated { FlowStore.shared.clear() } }
            return "cleared \(count) flows"
        case "list_devices":
            return devices(flows)

        // MARK: 抓包控制（§16.1）—— 与 UI 互相驱动
        //
        // `ProxyServer.shared` 是唯一事实源（@MainActor、@Published var state），UI 菜单/窗口都观察它。
        // 本处**不自持任何抓包状态**，只转发对该单例的调用/读取，故：
        //   MCP → UI：写操作 hop 到主线程改单例，UI 因观察同一 state 立即反映；
        //   UI → MCP：capture_status 每次实时读单例 state，UI 手动开关结果对 AI 立即可见。
        case "start_capture":
            let port = NetCaptureEnv.port
            // 写：hop 主线程调单例（MCP → UI 即时同步）。
            DispatchQueue.main.async { MainActor.assumeIsolated { ProxyServer.shared.start(port: port) } }
            let ip = NetworkInterfaces.primaryIP()
            return "starting on 0.0.0.0:\(port), LAN \(ip):\(port)"
        case "stop_capture":
            DispatchQueue.main.async { MainActor.assumeIsolated { ProxyServer.shared.stop() } }
            return "stopped"
        case "capture_status":
            // 读：实时取单例 state。用 main.sync 从 MCP 连接队列取一次快照——
            // 主线程从不反向同步等待该连接队列（只向它 async 派发），故 main.sync 不会死锁。
            let snapshot: (label: String, port: UInt16) = DispatchQueue.main.sync {
                MainActor.assumeIsolated { () -> (label: String, port: UInt16) in
                    switch ProxyServer.shared.state {
                    case .running(let p): return ("running", p)
                    case .starting: return ("starting", 0)
                    case .failed: return ("failed", 0)
                    case .stopped: return ("stopped", 0)
                    }
                }
            }
            if snapshot.label == "running" {
                let ip = NetworkInterfaces.primaryIP()
                return "running \(ip):\(snapshot.port) · \(flows.count) flows"
            }
            return snapshot.label
        default:
            return "unknown tool: \(name)"
        }
    }

    private static func summaries(_ flows: [Flow]) -> String {
        if flows.isEmpty { return "(no flows)" }
        return flows.map { flow in
            let status = flow.statusCode.map(String.init) ?? "-"
            let dur = flow.durationMs.map { "\($0)ms" } ?? "-"
            let dec = flow.decrypted ? "" : " [passthrough]"
            let dev = flow.clientIP ?? NetCaptureEnv.unknownDeviceKey
            return "\(flow.id.uuidString) \(flow.method) \(status) \(flow.url) · \(dur) · \(flow.responseBytes)B\(dec) @\(dev)"
        }.joined(separator: "\n")
    }

    /// 按 clientIP 聚合设备列表（读快照 + UserDefaults 别名），供 `list_devices`。
    private static func devices(_ flows: [Flow]) -> String {
        var buckets: [String: (count: Int, last: Date)] = [:]
        for flow in flows {
            let ip = flow.clientIP ?? NetCaptureEnv.unknownDeviceKey
            var bucket = buckets[ip] ?? (0, Date.distantPast)
            bucket.count += 1
            if flow.startedAt > bucket.last { bucket.last = flow.startedAt }
            buckets[ip] = bucket
        }
        if buckets.isEmpty { return "(no devices)" }
        let iso = ISO8601DateFormatter()
        let sorted = buckets.sorted { $0.value.last > $1.value.last }
        return sorted.map { ip, bucket in
            "\(ip) \(deviceLabel(ip)) · \(bucket.count) flows · \(iso.string(from: bucket.last))"
        }.joined(separator: "\n")
    }

    /// MCP 侧设备名（英文，AI 面向）：别名 → This Mac（回环）→ IP。
    private static func deviceLabel(_ ip: String) -> String {
        if ip == NetCaptureEnv.unknownDeviceKey { return "(unknown)" }
        if let alias = NetCaptureEnv.deviceAlias(for: ip) { return alias }
        if ip == "127.0.0.1" || ip == "::1" { return "This Mac" }
        return ip
    }

    private static func detail(_ flow: Flow) -> String {
        var lines: [String] = ["\(flow.method) \(flow.url)"]
        lines.append("Status: \(flow.statusCode.map(String.init) ?? "-") · \(flow.durationMs.map { "\($0)ms" } ?? "-")")
        lines.append("Device: \(flow.clientIP ?? NetCaptureEnv.unknownDeviceKey)")
        lines.append("-- Request headers --")
        for h in flow.requestHeaders { lines.append("\(h.name): \(redact(name: h.name, value: h.value))") }
        if let body = flow.requestBody, let text = String(data: body, encoding: .utf8) {
            lines.append("-- Request body --"); lines.append(String(text.prefix(8000)))
        }
        lines.append("-- Response headers --")
        for h in flow.responseHeaders { lines.append("\(h.name): \(redact(name: h.name, value: h.value))") }
        if let body = flow.responseBody {
            let decoded = HTTPBodyCodec.decodedForDisplay(body: body, headers: flow.responseHeaders)
            if let text = String(data: decoded.data, encoding: .utf8) {
                lines.append("-- Response body --"); lines.append(String(text.prefix(16000)))
            } else {
                lines.append("-- Response body -- (binary, \(body.count) bytes)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 「MCP 返回时脱敏鉴权头」（默认开）：对 Authorization / Cookie / Set-Cookie 打码。
    private static func redact(name: String, value: String) -> String {
        guard NetCaptureEnv.mcpRedactAuth else { return value }
        let lower = name.lowercased()
        if lower == "authorization" || lower == "cookie" || lower == "set-cookie"
            || lower == "proxy-authorization" {
            return "<redacted>"
        }
        return value
    }
}
