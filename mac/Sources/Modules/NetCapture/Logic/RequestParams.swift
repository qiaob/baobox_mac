import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：把请求拆成表（docs/packet-capture/TOOLS.md §2）。
// Query 参数、Cookie、表单正文都是「名 / 值」两列；Set-Cookie 多一列「其余属性原样」。

/// 表里的一行。
struct NameValue: Equatable, Hashable, Sendable {
    let name: String
    let value: String
}

/// 一条 Set-Cookie：名、值，和第一个 `;` 之后的属性（`Path=/; HttpOnly`…）原样。
struct SetCookie: Equatable, Sendable {
    let name: String
    let value: String
    let attributes: String
}

enum RequestParams {
    /// path 里 `?` 之后的参数。`+` 当空格，再做百分号解码；解不开的保留原文。没有 `?` 或 `?` 后为空返回空数组。
    static func queryItems(path: String) -> [NameValue] {
        guard let question = path.firstIndex(of: "?") else { return [] }
        var query = path[path.index(after: question)...]
        if let hash = query.firstIndex(of: "#") { query = query[..<hash] }
        return formPairs(query)
    }

    /// 一个 `Cookie` 头的值 → 名 / 值（按 `;` 分，两头去空白；不做解码，Cookie 的值没有统一编码）。
    static func cookies(header: String) -> [NameValue] {
        header.split(separator: ";").compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard let equals = trimmed.firstIndex(of: "=") else { return NameValue(name: trimmed, value: "") }
            return NameValue(name: trimmed[..<equals].trimmingCharacters(in: .whitespaces),
                             value: trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// 所有 `Cookie` 头合起来拆。HTTP/2 允许把 Cookie 拆成好几个头发，引擎原样给过来。
    static func cookies(headers: [HTTPHeader]) -> [NameValue] {
        headers.filter { $0.name.lowercased() == "cookie" }.flatMap { cookies(header: $0.value) }
    }

    /// 每个 `Set-Cookie` 头一条。第一段是 `名=值`，其后的属性原样放进 `attributes`。
    static func setCookies(headers: [HTTPHeader]) -> [SetCookie] {
        headers.filter { $0.name.lowercased() == "set-cookie" }.compactMap { header in
            let value = header.value
            let pair: Substring
            let attributes: String
            if let semicolon = value.firstIndex(of: ";") {
                pair = value[..<semicolon]
                attributes = value[value.index(after: semicolon)...].trimmingCharacters(in: .whitespaces)
            } else {
                pair = value[...]
                attributes = ""
            }
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard let equals = trimmed.firstIndex(of: "=") else {
                return SetCookie(name: trimmed, value: "", attributes: attributes)
            }
            return SetCookie(name: trimmed[..<equals].trimmingCharacters(in: .whitespaces),
                             value: trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces),
                             attributes: attributes)
        }
    }

    /// `application/x-www-form-urlencoded` 的正文 → 名 / 值。不是这种类型、或正文不是 UTF-8 返回 nil（界面按别的方式显示）。
    static func formItems(body: Data?, contentType: String?) -> [NameValue]? {
        guard let contentType, contentType.lowercased().contains("application/x-www-form-urlencoded") else { return nil }
        guard let body, !body.isEmpty else { return [] }
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        return formPairs(text[...])
    }

    /// 复制一张表：多行 `名: 值`。
    static func copyText(_ items: [NameValue]) -> String {
        items.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    /// 复制 Set-Cookie：每条一行，`名=值; 属性`，和头里的写法一样。
    static func copyText(_ cookies: [SetCookie]) -> String {
        cookies.map { cookie in
            cookie.attributes.isEmpty ? "\(cookie.name)=\(cookie.value)"
                                      : "\(cookie.name)=\(cookie.value); \(cookie.attributes)"
        }.joined(separator: "\n")
    }

    // MARK: - 共用

    /// `a=1&b=%E4%B8%AD&c` 这种：按 `&` 分，空段跳过，按第一个 `=` 切名和值，没有 `=` 的值为空。
    private static func formPairs(_ text: Substring) -> [NameValue] {
        text.split(separator: "&").compactMap { piece in
            guard !piece.isEmpty else { return nil }
            if let equals = piece.firstIndex(of: "=") {
                return NameValue(name: decode(piece[..<equals]), value: decode(piece[piece.index(after: equals)...]))
            }
            return NameValue(name: decode(piece), value: "")
        }
    }

    /// `+` 当空格，再百分号解码；解不开（`%zz`、半个 UTF-8 字符）就给原文。
    private static func decode(_ raw: Substring) -> String {
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? String(raw)
    }
}
