import Foundation

/// JWT 识别。**基本是拼装**：解三段 → 丢给 Base64 → 丢给 JSON → 时间声明丢给
/// TimestampRecognizer。这里几乎不写解析逻辑 —— 如果哪天发现要在这重写一堆东西，
/// 说明抽象设计错了，该回头改抽象而不是硬写。
///
/// **不做签名验证**：没有密钥，也不该在剪贴板工具里做。
struct JWTRecognizer: TextFormatRecognizer {
    let id = "jwt"
    let priority = 10

    func detect(_ text: String) -> FormatMatch? {
        guard let parsed = Self.parse(text) else { return nil }

        let rendered = """
        // header
        \(parsed.headerJSON)

        // payload
        \(parsed.payloadJSON)

        // signature
        \(parsed.signature)
        """

        return FormatMatch(
            id: id,
            badge: "JWT",
            // 原文是不可读的编码，展示解码后的三段才有意义。
            rendered: rendered,
            rows: Self.timeRows(parsed.payloadObject),
            actions: [
                FormatAction(id: "jwt.payload", title: L("clipboard.tools.action.jwtPayload"),
                             kind: .transform { _ in parsed.payloadJSON }),
                FormatAction(id: "jwt.header", title: L("clipboard.tools.action.jwtHeader"),
                             kind: .transform { _ in parsed.headerJSON })
            ]
        )
    }

    // MARK: - 解析

    struct Parsed {
        let headerJSON: String
        let payloadJSON: String
        let signature: String
        let payloadObject: [String: Any]
    }

    /// 门槛：三段以 `.` 分隔 + 每段是合法 base64url + **第一段解出来是含 `alg` 的 JSON**。
    /// 最后这条让误报接近于零，所以 JWT 的优先级排最前。
    static func parse(_ text: String) -> Parsed? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }

        guard let headerData = Base64Recognizer.decodeFlexible(String(parts[0])),
              let headerObject = (try? JSONSerialization.jsonObject(with: headerData, options: [])) as? [String: Any],
              headerObject["alg"] != nil,
              let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        guard let payloadData = Base64Recognizer.decodeFlexible(String(parts[1])),
              let payloadObject = (try? JSONSerialization.jsonObject(with: payloadData, options: [])) as? [String: Any],
              let payloadText = String(data: payloadData, encoding: .utf8) else { return nil }

        return Parsed(headerJSON: JSONFormatter.rewrite(headerText, pretty: true),
                      payloadJSON: JSONFormatter.rewrite(payloadText, pretty: true),
                      signature: String(parts[2]),
                      payloadObject: payloadObject)
    }

    /// payload 里的时间声明转成人类时间。声明名是 RFC 7519 的标准术语，不翻译。
    static func timeRows(_ payload: [String: Any]) -> [FormatRow] {
        var rows: [FormatRow] = []
        for claim in ["iat", "nbf", "exp", "auth_time"] {
            guard let number = payload[claim] as? NSNumber else { continue }
            let date = Date(timeIntervalSince1970: number.doubleValue)
            let plain = TimestampRecognizer.localTimeString(date)
            var value = plain
            var warning = false
            if claim == "exp" {
                warning = date < Date()
                let suffix = warning
                    ? "\(L("clipboard.tools.jwt.expired")) \(TimestampRecognizer.relative(date))"
                    : TimestampRecognizer.relative(date)
                value = "\(plain) · \(suffix)"
            }
            rows.append(FormatRow(label: claim, value: value, copyValue: plain, isWarning: warning))
        }
        return rows
    }
}
