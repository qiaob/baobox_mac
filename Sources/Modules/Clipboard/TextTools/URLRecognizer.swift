import Foundation

/// URL 识别：percent 编解码 + query 参数拆表。
struct URLRecognizer: TextFormatRecognizer {
    let id = "url"
    let priority = 50

    private static let maxInputLength = 8 * 1024

    func detect(_ text: String) -> FormatMatch? {
        guard text.utf8.count <= Self.maxInputLength,
              !text.contains(" "), !text.contains("\n"),
              let components = URLComponents(string: text),
              let scheme = components.scheme, !scheme.isEmpty,
              components.host != nil else { return nil }

        // query 的 value 展示成解码后的 —— 编码后的看不出内容，表格就没意义了。
        let rows = (components.queryItems ?? []).map { item -> FormatRow in
            let raw = item.value ?? ""
            let decoded = raw.removingPercentEncoding ?? raw
            return FormatRow(label: item.name, value: decoded, copyValue: decoded)
        }

        return FormatMatch(
            id: id,
            badge: "URL",
            rendered: nil,
            rows: rows,
            actions: [
                FormatAction(id: "url.decode", title: L("clipboard.tools.action.decode"),
                             kind: .transform { $0.removingPercentEncoding }),
                FormatAction(id: "url.encode", title: L("clipboard.tools.action.encode"),
                             kind: .transform { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) })
            ]
        )
    }
}
