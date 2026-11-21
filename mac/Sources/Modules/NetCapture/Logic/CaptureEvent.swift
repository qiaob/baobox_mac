import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：引擎那一侧的桥脚本
// （Resources/NetCapture/baobox_bridge.py）推过来的事件怎么解。见 docs/packet-capture/TECH_DESIGN.md §4.1。

/// 一个 HTTP 头字段（保留原始大小写；查询用大小写不敏感辅助方法）。
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

/// 桥脚本从标准输出推来的一条事件。字段缺失或类型不符的行解不出来，返回 nil，调用方跳过（约定 5：决不 crash）。
enum CaptureEvent: Equatable, Sendable {
    case running(version: String)
    case request(Request)
    case response(Response)
    case failure(id: UUID, message: String, at: Date?)
    case webSocket(WebSocketMessage)
    case tls(client: String?, host: String, reason: UndecryptedReason)
    case device(client: String)

    struct Request: Equatable, Sendable {
        var id: UUID
        var client: String?
        var method: String
        var scheme: String
        var host: String
        var port: Int
        var path: String
        var httpVersion: String
        var headers: [HTTPHeader]
        var body: Data?
        var truncated: Bool
        /// 正文是压缩的但请求头没声明，桥脚本按内容特征认出来并解开了：这里是压缩方式的名字（gzip / zlib / zstd）。
        var sniffed: String?
        var bytes: Int
        var startedAt: Date
    }

    struct Response: Equatable, Sendable {
        var id: UUID
        var status: Int
        var httpVersion: String?
        var headers: [HTTPHeader]
        /// 已解压（gzip / brotli / zstd 都由引擎解开）。
        var body: Data?
        var truncated: Bool
        /// 原始的 Content-Encoding，只用于展示。
        var encoding: String?
        /// 同 `Request.sniffed`：头里没声明、按内容认出来的压缩方式。
        var sniffed: String?
        var bytes: Int
        var remote: String?
        var endedAt: Date?
    }

    struct WebSocketMessage: Equatable, Sendable {
        var flowID: UUID
        var fromClient: Bool
        /// 文本消息的内容；二进制消息为 nil。
        var text: String?
        var size: Int
        var at: Date
    }

    /// 一个域名为什么没被解密。
    enum UndecryptedReason: String, Sendable {
        /// 客户端拒绝了我们的证书（没装 / 没信任 CA，或 App 做了证书固定）。
        case handshakeFailed = "handshake_failed"
        /// 用户设的解密范围不包含它。
        case outOfScope = "out_of_scope"
    }

    /// 每行事件的前缀；引擎自己偶尔打到标准输出的别的东西没有这个前缀，一律丢弃。
    static let linePrefix = "BAOBOX "

    /// 解一行（不含换行符）。不是事件行、JSON 坏了、缺必需字段都返回 nil。
    static func parse(line: Data) -> CaptureEvent? {
        let prefix = Data(linePrefix.utf8)
        guard line.count > prefix.count, line.prefix(prefix.count) == prefix else { return nil }
        let payload = line.dropFirst(prefix.count)
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload)),
              let json = object as? [String: Any],
              let name = json["event"] as? String else { return nil }

        switch name {
        case "running":
            return .running(version: json["version"] as? String ?? "")
        case "request":
            guard let id = uuid(json["id"]),
                  let method = json["method"] as? String,
                  let host = json["host"] as? String else { return nil }
            let scheme = json["scheme"] as? String ?? "https"
            return .request(Request(
                id: id,
                client: json["client"] as? String,
                method: method,
                scheme: scheme,
                host: host,
                port: int(json["port"]) ?? (scheme == "https" ? 443 : 80),
                path: json["path"] as? String ?? "/",
                httpVersion: json["http"] as? String ?? "HTTP/1.1",
                headers: headers(json["headers"]),
                body: body(json["body"]),
                truncated: json["truncated"] as? Bool ?? false,
                sniffed: json["sniffed"] as? String,
                bytes: int(json["bytes"]) ?? 0,
                startedAt: date(json["ts"]) ?? Date()))
        case "response":
            guard let id = uuid(json["id"]), let status = int(json["status"]) else { return nil }
            return .response(Response(
                id: id,
                status: status,
                httpVersion: json["http"] as? String,
                headers: headers(json["headers"]),
                body: body(json["body"]),
                truncated: json["truncated"] as? Bool ?? false,
                encoding: json["encoding"] as? String,
                sniffed: json["sniffed"] as? String,
                bytes: int(json["bytes"]) ?? 0,
                remote: json["remote"] as? String,
                endedAt: date(json["ts"])))
        case "error":
            guard let id = uuid(json["id"]) else { return nil }
            return .failure(id: id, message: json["message"] as? String ?? "", at: date(json["ts"]))
        case "ws":
            guard let id = uuid(json["id"]), let fromClient = json["from_client"] as? Bool else { return nil }
            return .webSocket(WebSocketMessage(
                flowID: id,
                fromClient: fromClient,
                text: json["text"] as? String,
                size: int(json["size"]) ?? 0,
                at: date(json["ts"]) ?? Date()))
        case "tls":
            guard let host = json["host"] as? String,
                  let raw = json["reason"] as? String,
                  let reason = UndecryptedReason(rawValue: raw) else { return nil }
            return .tls(client: json["client"] as? String, host: host, reason: reason)
        case "device":
            guard let client = json["client"] as? String, !client.isEmpty else { return nil }
            return .device(client: client)
        default:
            return nil
        }
    }

    // MARK: - 字段读取

    private static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    /// JSON 数字可能解成 Int 或 Double，两种都认；Bool 不算数字。
    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    private static func body(_ value: Any?) -> Data? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return Data(base64Encoded: text)
    }

    /// `[[name, value], …]`；形状不对的项跳过。
    private static func headers(_ value: Any?) -> [HTTPHeader] {
        guard let pairs = value as? [Any] else { return [] }
        return pairs.compactMap { item in
            guard let pair = item as? [Any], pair.count == 2,
                  let name = pair[0] as? String, let value = pair[1] as? String else { return nil }
            return HTTPHeader(name: name, value: value)
        }
    }
}

/// 把管道里一段一段到的字节切成行。一行可以很大（正文是 base64 放在行里的），所以不能假设一次读到整行。
struct CaptureLineBuffer {
    private var pending = Data()

    /// 追加一段字节，返回这次凑齐的完整行（不含换行符）。
    mutating func append(_ chunk: Data) -> [Data] {
        guard !chunk.isEmpty else { return [] }
        pending.append(chunk)
        var lines: [Data] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: 0x0A) {
            lines.append(Data(pending[start..<newline]))
            start = pending.index(after: newline)
        }
        if start > pending.startIndex {
            pending = Data(pending[start...])
        }
        return lines
    }
}

/// 引擎自己的日志里能认出来的东西。
enum CaptureEngineLog {
    /// 「端口被占」的报错里是哪个端口。引擎的原话形如
    /// `HTTP(S) proxy failed to listen on 127.0.0.1:9090 with [Errno 48] …`；认不出来返回 nil。
    static func busyPort(in text: String) -> UInt16? {
        guard let marker = text.range(of: "failed to listen on ") else { return nil }
        let address = text[marker.upperBound...].prefix { !$0.isWhitespace }
        guard let colon = address.lastIndex(of: ":") else { return nil }
        return UInt16(address[address.index(after: colon)...])
    }
}
