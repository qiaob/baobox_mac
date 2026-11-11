import Foundation

/// Claude Code 会话 JSONL 的纯解析：逐行字段提取与导出 Markdown。
///
/// 纯 Foundation（不碰 `ClaudeEnv`、不调 `L()`），和 `Core/CLISession/` 一起编进 `BaoboxTests`。
/// 读文件、取小标题文案在 `ClaudeSessionFormat.markdown(fileURL:title:)`（`ClaudeSessionIndex.swift`）。

// MARK: - 逐行 JSON 解析工具（本模块共享）

/// 会话 / 事件 JSONL 里 Claude Code 独有的解析辅助。逐行解析与时间戳用共用的 `CLIJSONL`。
enum ClaudeJSONLParsing {

    /// 从 message.content 提取首个可读文本。
    /// content 可能是纯字符串，或 `[{type:text,text:...}, {type:tool_use,...}]` 数组。
    nonisolated static func extractText(fromContent content: Any) -> String? {
        if let text = content as? String {
            return text
        }
        if let blocks = content as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "text" {
                if let text = block["text"] as? String { return text }
            }
        }
        return nil
    }
}

// MARK: - 导出 Markdown

/// 整份会话导出成 Markdown：`# 标题`，然后按出现顺序每条消息一段 `## 用户` / `## 助手` + 正文。
///
/// - 逐行读（`CLIJSONL.forEachObject`）：一行坏了只丢那一行，其余照常导出。
/// - 用户消息取第一个 text 块，助手消息拼全部 text 块（空行隔开）；tool_use、tool_result、thinking 不导出；正文原样，不 trim。
/// - 用户消息里的系统注入（`<command-name>`、`<local-command-stdout>`…）不导出，规则同会话标题（`CLISessionMarkdown.isSystemInjection`）。
///   系统注入只出现在 user 行里；助手的回复以 `<` 开头是正文（比如一段 HTML），照常导出。
enum ClaudeSessionMarkdown {

    static func markdown(from data: Data, title: String, headings: CLISessionMarkdown.Headings) -> String {
        var lines: [String] = ["# \(title)", ""]
        CLIJSONL.forEachObject(in: data) { object in
            guard let type = object["type"] as? String,
                  type == "user" || type == "assistant",
                  let message = object["message"] as? [String: Any] else { return }

            let text: String?
            if type == "user" {
                text = message["content"].flatMap { ClaudeJSONLParsing.extractText(fromContent: $0) }
            } else {
                // assistant.content 是数组，拼接全部 text 块。
                if let blocks = message["content"] as? [[String: Any]] {
                    let joined = blocks.compactMap { block -> String? in
                        (block["type"] as? String) == "text" ? block["text"] as? String : nil
                    }.joined(separator: "\n\n")
                    text = joined.isEmpty ? nil : joined
                } else {
                    text = message["content"].flatMap { ClaudeJSONLParsing.extractText(fromContent: $0) }
                }
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if type == "user", CLISessionMarkdown.isSystemInjection(text) { return }
            lines.append("## \(type == "user" ? headings.user : headings.assistant)")
            lines.append("")
            lines.append(text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
