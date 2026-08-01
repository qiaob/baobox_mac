import Foundation

/// URL 识别：percent 编解码 + query 参数拆表。curl 命令归并在此（同一个开关与
/// 徽章组，2026-08-02 增补）：解析出方法/URL/Header/Body 分行展示，支持
/// 格式化/压缩/提取 URL；纯 URL 侧新增「转为 curl」。
struct URLRecognizer: TextFormatRecognizer {
    let id = "url"
    let priority = 50

    private static let maxInputLength = 8 * 1024
    /// 抓包导出的 curl 带着大 Cookie 很容易破 8KB，给它单独的上限。
    private static let maxCurlLength = 64 * 1024

    func detect(_ text: String) -> FormatMatch? {
        // curl 优先：命令带空格/换行，天然过不了下面的纯 URL 门槛，两条路互斥。
        if text.utf8.count <= Self.maxCurlLength, let command = CurlCommand.parse(text) {
            return Self.curlMatch(command)
        }
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
                // 菜单项标题必须自解释：光写「解码/编码」看不出是 percent 编码，
                // 和旁边通用的「编码/解码」下拉还会混。
                FormatAction(id: "url.menu", title: "URL", kind: .menu([
                    FormatAction(id: "url.decode", title: L("clipboard.tools.action.urlDecode"),
                                 kind: .transform { $0.removingPercentEncoding }),
                    FormatAction(id: "url.encode", title: L("clipboard.tools.action.urlEncode"),
                                 kind: .transform { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }),
                    FormatAction(id: "url.toCurl", title: L("clipboard.tools.action.toCurl"),
                                 kind: .transform { "curl \(CurlCommand.shellQuote($0))" })
                ]))
            ]
        )
    }

    // MARK: - curl

    private static func curlMatch(_ command: CurlCommand) -> FormatMatch {
        var rows: [FormatRow] = [
            FormatRow(label: L("clipboard.tools.curl.method"), value: command.effectiveMethod, copyValue: nil)
        ]
        if let url = command.url {
            rows.append(FormatRow(label: "URL", value: url, copyValue: url))
        }
        for header in command.headers {
            rows.append(FormatRow(label: header.name, value: header.value, copyValue: header.value))
        }
        if let cookie = command.cookie {
            rows.append(FormatRow(label: "Cookie", value: cookie, copyValue: cookie))
        }
        if let user = command.user {
            rows.append(FormatRow(label: L("clipboard.tools.curl.auth"), value: user, copyValue: user))
        }
        if !command.dataParts.isEmpty {
            // 多个 -d 在 curl 语义里拼 &；body 是 JSON 就格式化展示，复制仍给原文。
            let body = command.dataParts.joined(separator: "&")
            let display = JSONFormatter.isValid(body) ? JSONFormatter.rewrite(body, pretty: true) : body
            rows.append(FormatRow(label: L("clipboard.tools.curl.body"), value: display, copyValue: body))
        }
        for part in command.formParts {
            rows.append(FormatRow(label: L("clipboard.tools.curl.form"), value: part, copyValue: part))
        }
        if !command.otherArgs.isEmpty {
            rows.append(FormatRow(label: L("clipboard.tools.curl.other"),
                                  value: command.otherArgs.joined(separator: " "), copyValue: nil))
        }

        return FormatMatch(
            id: "url",
            badge: "cURL",
            rendered: nil,
            rows: rows,
            actions: [
                FormatAction(id: "url.curlMenu", title: "cURL", kind: .menu([
                    FormatAction(id: "curl.format", title: L("clipboard.tools.action.curlExpand"),
                                 kind: .transform { CurlCommand.parse($0)?.formatted() }),
                    FormatAction(id: "curl.minify", title: L("clipboard.tools.action.curlOneline"),
                                 kind: .transform { CurlCommand.parse($0)?.minified() }),
                    FormatAction(id: "curl.extractURL", title: L("clipboard.tools.action.extractURL"),
                                 kind: .transform { CurlCommand.parse($0)?.url })
                ]))
            ]
        )
    }
}
