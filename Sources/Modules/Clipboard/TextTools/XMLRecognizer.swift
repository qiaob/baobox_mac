import Foundation

/// XML 识别与格式化。用 macOS 自带的 `XMLDocument`（Foundation，非第三方）。
struct XMLRecognizer: TextFormatRecognizer {
    let id = "xml"
    let priority = 30

    func detect(_ text: String) -> FormatMatch? {
        guard text.hasPrefix("<"), Self.parse(text) != nil else { return nil }
        let tooBig = text.utf8.count > TextToolLimits.maxTransform
        let hint = tooBig ? L("clipboard.tools.tooLong") : nil

        return FormatMatch(
            id: id,
            badge: "XML",
            rendered: nil,
            rows: [],
            actions: [
                FormatAction(id: "xml.pretty", title: L("clipboard.tools.action.format"),
                             kind: .transform { Self.rewrite($0, pretty: true) },
                             isEnabled: !tooBig, disabledHint: hint),
                FormatAction(id: "xml.minify", title: L("clipboard.tools.action.minify"),
                             kind: .transform { Self.rewrite($0, pretty: false) },
                             isEnabled: !tooBig, disabledHint: hint)
            ]
        )
    }

    /// ⚠️ 剪贴板内容来源不可信：**必须显式禁止加载外部实体**。不加这一项的话，
    /// 一段构造过的 XML 能让 App 去读本地文件或发起网络请求（XXE）。这不是可选项。
    static func parse(_ text: String) -> XMLDocument? {
        let options: XMLNode.Options = [.nodeLoadExternalEntitiesNever, .nodePreserveWhitespace]
        return try? XMLDocument(xmlString: text, options: options)
    }

    static func rewrite(_ text: String, pretty: Bool) -> String? {
        guard let document = parse(text) else { return nil }
        let options: XMLNode.Options = pretty
            ? [.nodePrettyPrint, .nodeCompactEmptyElement]
            : [.nodeCompactEmptyElement]
        return String(data: document.xmlData(options: options), encoding: .utf8)
    }
}
