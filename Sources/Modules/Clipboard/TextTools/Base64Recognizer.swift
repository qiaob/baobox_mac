import Foundation

/// Base64 识别。
///
/// Base64 的字符集太宽松，**误报率是所有格式里最高的** —— 任何足够长的字母数字串
/// 看起来都像 base64。所以门槛设得很严（五道，缺一不可），且优先级排最后。
/// 误报的代价只是徽章行多一个 chip，不影响任何正常操作。
struct Base64Recognizer: TextFormatRecognizer {
    let id = "base64"
    let priority = 90

    private static let minLength = 16
    private static let printableThreshold = 0.9

    func detect(_ text: String) -> FormatMatch? {
        guard let decoded = Self.decodedText(text) else { return nil }
        // 原文是不可读的编码，所以这里给 rendered —— 展示解码后的才有意义。
        let rendered = JSONFormatter.isValid(decoded)
            ? (JSONFormatter.rewrite(decoded, pretty: true))
            : decoded

        return FormatMatch(
            id: id,
            badge: "Base64",
            rendered: rendered,
            rows: [],
            actions: [
                FormatAction(id: "base64.decode", title: L("clipboard.tools.action.decode"),
                             kind: .transform { Self.decodedText($0) }),
                FormatAction(id: "base64.encode", title: L("clipboard.tools.action.encode"),
                             kind: .transform { Data($0.utf8).base64EncodedString() })
            ]
        )
    }

    // MARK: - 判据

    /// 标准 base64 与 base64url 都吃：`-`→`+`、`_`→`/`，按需补 `=`。
    static func decodeFlexible(_ text: String) -> Data? {
        var normalized = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 { return nil } // 长度 %4 == 1 不可能是合法 base64
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }

    /// 五道门槛：长度、字符集、长度对齐、UTF-8 有效、可打印占比。
    static func decodedText(_ text: String) -> String? {
        guard text.count >= minLength,
              text.unicodeScalars.allSatisfy({ allowedScalars.contains($0) }),
              let data = decodeFlexible(text),
              !data.isEmpty,
              let decoded = String(data: data, encoding: .utf8),
              printableRatio(decoded) >= printableThreshold else { return nil }
        return decoded
    }

    private static let allowedScalars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/-_="
    )

    /// 排除「解出来是随机二进制、恰好又是合法 UTF-8」的情况。
    private static func printableRatio(_ text: String) -> Double {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return 0 }
        let printable = scalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar == "\r" || scalar.value >= 0x20
        }.count
        return Double(printable) / Double(scalars.count)
    }
}
