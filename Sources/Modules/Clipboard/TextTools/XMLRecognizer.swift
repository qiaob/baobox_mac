import Foundation

/// XML 识别与格式化。用 macOS 自带的 `XMLDocument`（Foundation，非第三方）。
struct XMLRecognizer: TextFormatRecognizer {
    let id = "xml"
    let priority = 30

    func detect(_ text: String) -> FormatMatch? {
        guard text.hasPrefix("<"), Self.parse(text) != nil else { return nil }
        return FormatMatch(
            id: id,
            badge: "XML",
            rendered: nil,
            rows: [],
            actions: [
                // rewrite 自带解析校验，解不开返回 nil = 静默不动。
                FormatAction(id: "xml.pretty", title: L("clipboard.tools.action.format"),
                             kind: .transform { Self.rewrite($0, pretty: true) }),
                FormatAction(id: "xml.minify", title: L("clipboard.tools.action.minify"),
                             kind: .transform { Self.rewrite($0, pretty: false) })
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
