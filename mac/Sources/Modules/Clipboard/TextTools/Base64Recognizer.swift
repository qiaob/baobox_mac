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
    /// 以 `=` 结尾的显式补位是强信号 —— 普通单词几乎不会以 = 收尾，误报面大幅
    /// 缩小，所以门槛放宽（否则 `CjEyMzQ=` 这类短样本永远解不出来）。
    private static let minLengthPadded = 8
    private static let printableThreshold = 0.9

    func detect(_ text: String) -> FormatMatch? {
        guard Self.decodedText(text) != nil else { return nil }
        return FormatMatch(
            id: id,
            badge: "Base64",
            // 不给 rendered，预览保持原文 —— 自动换成解码结果会让「预览看到的」和
            // 「⏎ 粘出去的」不一致（⏎ 只认显式转换）。解码是显式动作：结果进预览
            // 缓冲、带「已转换 · 还原」标记；解出来是 JSON 就顺手格式化。
            rendered: nil,
            rows: [],
            actions: [
                FormatAction(id: "base64.decode", title: L("clipboard.tools.action.decode"),
                             kind: .transform { Self.explicitDecode($0) })
                // 编码在通用「编码/哈希」下拉里（任何文本都能编），这里不重复给。
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

    /// 显式解码（解码按钮 / 通用「编码/解码」菜单）：**不做长度门槛** —— 那是给
    /// 自动识别防误报用的，用户明确点了解码就不该拦。字符集/UTF-8/可打印仍要过，
    /// 避免对着随机文本吐乱码。解出来是 JSON 顺手格式化。
    static func explicitDecode(_ text: String) -> String? {
        guard !text.isEmpty,
              text.unicodeScalars.allSatisfy({ allowedScalars.contains($0) }),
              let data = decodeFlexible(text),
              !data.isEmpty,
              let decoded = String(data: data, encoding: .utf8),
              printableRatio(decoded) >= printableThreshold else { return nil }
        return JSONFormatter.isValid(decoded) ? JSONFormatter.rewrite(decoded, pretty: true) : decoded
    }

    /// 五道门槛：长度、字符集、长度对齐、UTF-8 有效、可打印占比。
    static func decodedText(_ text: String) -> String? {
        guard text.count >= (text.hasSuffix("=") ? minLengthPadded : minLength),
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
