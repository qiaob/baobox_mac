import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：Mock 规则（docs/packet-capture/TOOLS.md §4）。
// 命中的请求不再发给服务器，引擎直接回规则里写的响应。匹配在桥脚本里做：方法（`*` = 任意）、域名精确、
// 路径不看 `?` 之后、可用 `*` 通配；多条都能命中时列表里靠上的生效。

/// 一条 Mock 规则。存盘（`mock-rules.json`）和发给引擎（`rules` 指令）用的都是它。
struct MockRule: Equatable, Identifiable, Sendable {
    /// 方法写这个 = 任意方法。
    static let anyMethod = "*"

    var id: String
    var enabled: Bool
    /// 大写的方法名，或 `anyMethod`。
    var method: String
    var host: String
    var path: String
    var status: Int
    var headers: [HTTPHeader]
    var body: Data

    init(id: String = UUID().uuidString.lowercased(),
         enabled: Bool = true,
         method: String = MockRule.anyMethod,
         host: String = "",
         path: String = "/",
         status: Int = 200,
         headers: [HTTPHeader] = [],
         body: Data = Data()) {
        self.id = id
        self.enabled = enabled
        self.method = method
        self.host = host
        self.path = path
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// 用一条抓到的请求预填：匹配 = 方法 + 域名 + 路径（去掉 `?` 之后），响应 = 抓到的状态码、响应头、正文；
    /// 还没有响应就 200、空。描述线上形态的头（长度、压缩、分块）去掉 —— 正文已经是解压后的，引擎会重算。
    static func draft(method: String, host: String, path: String,
                      status: Int?, headers: [HTTPHeader], body: Data?) -> MockRule {
        MockRule(method: method.uppercased(),
                 host: host,
                 path: path,
                 status: status ?? 200,
                 headers: headers.filter { !HeaderText.wireHeaders.contains($0.name.lowercased()) },
                 body: body ?? Data()).normalized()
    }

    /// 保存前整理：域名去空白、转小写；路径去空白、去掉 `?` 之后、保证以 `/` 开头；方法转大写，空着 = 任意。
    func normalized() -> MockRule {
        var rule = self
        rule.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let question = cleanPath.firstIndex(of: "?") { cleanPath = String(cleanPath[..<question]) }
        if !cleanPath.hasPrefix("/") && !cleanPath.hasPrefix("*") { cleanPath = "/" + cleanPath }
        rule.path = cleanPath
        let cleanMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        rule.method = cleanMethod.isEmpty ? Self.anyMethod : cleanMethod
        return rule
    }

    /// 能不能保存：有域名，状态码在 100–599。
    var isValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (100...599).contains(status)
    }

    /// `rules` 指令里的一项（docs/packet-capture/TOOLS.md §6）。
    var commandObject: [String: Any] {
        [
            "id": id,
            "enabled": enabled,
            "method": method,
            "host": host,
            "path": path,
            "status": status,
            "headers": headers.map { [$0.name, $0.value] },
            "body": body.base64EncodedString(),
        ]
    }
}

// MARK: - 存盘格式

extension MockRule: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, enabled, method, host, path, status, headers, body
    }

    /// 只有 `host` 是必需的；别的字段缺了或类型不对都按默认值（约定 5）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let host = try container.decode(String.self, forKey: .host)
        // `try?` 把「缺了」和「类型不对」都变成 nil（Swift 5 起不会套成双层可选）。
        let id = try? container.decodeIfPresent(String.self, forKey: .id)
        let pairs = try? container.decodeIfPresent([[String]].self, forKey: .headers)
        self.init(id: id.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased(),
                  enabled: (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true,
                  method: (try? container.decodeIfPresent(String.self, forKey: .method)) ?? Self.anyMethod,
                  host: host,
                  path: (try? container.decodeIfPresent(String.self, forKey: .path)) ?? "/",
                  status: (try? container.decodeIfPresent(Int.self, forKey: .status)) ?? 200,
                  headers: (pairs ?? []).compactMap { $0.count == 2 ? HTTPHeader(name: $0[0], value: $0[1]) : nil },
                  body: (try? container.decodeIfPresent(Data.self, forKey: .body)) ?? Data())
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(method, forKey: .method)
        try container.encode(host, forKey: .host)
        try container.encode(path, forKey: .path)
        try container.encode(status, forKey: .status)
        try container.encode(headers.map { [$0.name, $0.value] }, forKey: .headers)
        try container.encode(body, forKey: .body)   // JSONEncoder 默认把 Data 写成 base64
    }
}

/// `mock-rules.json` 的读写。
enum MockRuleFile {
    /// 不是一个 JSON 数组（文件坏了）返回 nil，调用方把坏文件改名留着；数组里坏掉的项跳过，其余照常用。
    static func decode(_ data: Data) -> [MockRule]? {
        guard let items = try? JSONDecoder().decode([LossyRule].self, from: data) else { return nil }
        return items.compactMap(\.rule)
    }

    static func encode(_ rules: [MockRule]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(rules)
    }

    /// 解一项，失败就是 nil（不让一条坏规则拖垮整个文件）。
    private struct LossyRule: Decodable {
        let rule: MockRule?
        init(from decoder: Decoder) throws {
            rule = try? MockRule(from: decoder)
        }
    }
}
