import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：本地 MCP 的几处输出与输入整理。

/// 给 AI 的请求头脱敏后写回来的处理（`set_mock_rule`）。`list_mock_rules` 把 Authorization 等的值显示成 `<redacted>`；
/// AI 把读到的头原样写回时，不能让真实值被字面的 `<redacted>` 盖掉。
enum MCPHeaderRestore {
    static let placeholder = "<redacted>"

    /// 值恰好是 `<redacted>` 的头，换回这条规则里同名头（不分大小写）原来的值，同名的按出现顺序一一对应。
    /// 原来没有对应的头：这个头不写入，名字放进 `unresolved`（调用方报错）。
    static func restore(_ incoming: [HTTPHeader], from existing: [HTTPHeader]) -> (headers: [HTTPHeader], unresolved: [String]) {
        var pools: [String: [String]] = [:]
        for header in existing {
            pools[header.name.lowercased(), default: []].append(header.value)
        }
        var used: [String: Int] = [:]
        var headers: [HTTPHeader] = []
        var unresolved: [String] = []
        for header in incoming {
            guard header.value == placeholder else {
                headers.append(header)
                continue
            }
            let key = header.name.lowercased()
            let index = used[key, default: 0]
            if let values = pools[key], index < values.count {
                headers.append(HTTPHeader(name: header.name, value: values[index]))
                used[key] = index + 1
            } else {
                unresolved.append(header.name)
            }
        }
        return (headers, unresolved)
    }
}

/// `get_tcp_connection` 一块数据怎么写成文字（AI 的上下文有限）。
enum MCPBlockText {
    /// `format: auto` 下不像文本的块只给这么多字节的十六进制。
    static let binaryPreview = 256

    /// - `text`：当文本给；`hex`：十六进制（调用方先按每块上限截好）；
    /// - `auto`：像文本的给文本；不像的只给前 `binaryPreview` 字节的十六进制，后面一行说还有多少；块开头是 TLS 记录的标一句。
    static func render(_ data: Data, offset: Int, format: String) -> String {
        switch format {
        case "text": return TCPPayload.text(data)
        case "hex": return TCPPayload.hexDump(data, startOffset: offset)
        default: return TCPPayload.looksLikeText(data) ? TCPPayload.text(data) : binary(data, offset: offset)
        }
    }

    /// 不像文本的一块（`format: auto`）：TLS 记录标一句，前 `binaryPreview` 字节的十六进制，后面一行说还有多少。
    static func binary(_ data: Data, offset: Int) -> String {
        var lines: [String] = []
        if let kind = tlsRecord(data) { lines.append("(TLS record: \(kind))") }
        lines.append(TCPPayload.hexDump(data.prefix(binaryPreview), startOffset: offset))
        if data.count > binaryPreview {
            lines.append("[… \(data.count - binaryPreview) more bytes (binary; use format: hex to get all of it)]")
        }
        return lines.joined(separator: "\n")
    }

    /// 开头是不是一条 TLS 记录（`0x16` 握手 / `0x17` 应用数据，后面 `0x03 0x00–0x04`）；是的话给一个说明。
    static func tlsRecord(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        guard bytes.count == 3, bytes[1] == 0x03, bytes[2] <= 0x04 else { return nil }
        switch bytes[0] {
        case 0x16: return "handshake"
        case 0x17: return "application data, encrypted"
        default: return nil
        }
    }
}

/// `list_devices` 的一行：设备键、类型（This Mac / LAN / WireGuard）、名字（有才写，不重复 IP）、条数、最近一次。
enum MCPDeviceLine {
    enum Kind: String {
        case thisMac = "This Mac"
        case lan = "LAN"
        case wireguard = "WireGuard"
        case unknown = "unknown"
    }

    static func format(key: String, kind: Kind, name: String?, count: Int, last: String) -> String {
        var parts = [key, kind.rawValue]
        if let name, !name.isEmpty, name != key, name != kind.rawValue { parts.append(name) }
        parts.append(count == 1 ? "1 flow" : "\(count) flows")
        parts.append(last)
        return parts.joined(separator: " · ")
    }
}

/// 本地 MCP 只给本机的 AI 工具用，不给网页用（审查 #1）。网页可以用 `fetch(..., {mode: "no-cors"})` 发一个不触发预检的
/// POST 来调写工具，配合 DNS 重绑定还能读到回复（WireGuard 配置里有私钥）。Claude Code / Codex 不带 `Origin`、
/// `Host` 是 `127.0.0.1:<端口>`、POST 的是 JSON；浏览器发的不满足其中至少一条。
enum MCPRequestGate {
    struct Rejection: Equatable {
        /// `403 Forbidden` 这样的状态行。
        let status: String
        let reason: String
    }

    /// `headers` 的键是小写的。nil = 放行。
    static func check(method: String, headers: [String: String], port: UInt16) -> Rejection? {
        if headers["origin"] != nil {
            return Rejection(status: "403 Forbidden", reason: "requests from web pages are not accepted")
        }
        let host = (headers["host"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return Rejection(status: "403 Forbidden", reason: "Host must be 127.0.0.1:\(port) or localhost:\(port)")
        }
        // 预检（OPTIONS）不应答 CORS，浏览器就发不出带 JSON 的跨域请求；GET（SSE 流）这里不提供。
        guard method.uppercased() == "POST" else {
            return Rejection(status: "405 Method Not Allowed", reason: "only POST is accepted")
        }
        let type = (headers["content-type"] ?? "").split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard type == "application/json" else {
            return Rejection(status: "415 Unsupported Media Type", reason: "Content-Type must be application/json")
        }
        return nil
    }
}
