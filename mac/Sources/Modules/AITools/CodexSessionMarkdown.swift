import Foundation

/// Codex 会话 rollout jsonl 的纯解析：逐行字段提取与导出 Markdown。
///
/// 纯 Foundation（不碰 `CodexEnv`、不调 `L()`），和 `Core/CLISession/` 一起编进 `BaoboxTests`。
/// 读文件、取小标题文案在 `CodexSessionFormat.markdown(fileURL:title:)`（`CodexSessionIndex.swift`）。

// MARK: - 解析辅助

/// rollout 行里 Codex 独有的解析辅助。逐行解析与时间戳用共用的 `CLIJSONL`。
enum CodexJSONLParsing {

    /// 从内容值提取首个可读文本。内容可能是纯字符串，或
    /// `[{type:text|input_text, text:...}]` 数组（Codex 与 Claude 的 content 略有差异）。
    nonisolated static func extractText(from content: Any?) -> String? {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                let type = block["type"] as? String
                if type == nil || type == "text" || type == "input_text" || type == "output_text" {
                    if let text = block["text"] as? String, !text.isEmpty { return text }
                }
            }
        }
        return nil
    }

    /// 从一个 rollout 行对象里尽力取出 (id, cwd)。兼容顶层与 `payload` 嵌套两种写法。
    nonisolated static func extractMeta(from object: [String: Any]) -> (id: String?, cwd: String?) {
        var id = object["id"] as? String
        var cwd = object["cwd"] as? String
        if let payload = object["payload"] as? [String: Any] {
            id = id ?? (payload["id"] as? String)
            cwd = cwd ?? (payload["cwd"] as? String)
        }
        return (id, cwd)
    }

    /// 从一个 rollout 行对象里尽力取出用户输入文本；非用户消息返回 nil。
    nonisolated static func extractUserText(from object: [String: Any]) -> String? {
        if let payload = object["payload"] as? [String: Any] {
            // 形态 A：event_msg / user_message，message 为字符串。
            if (payload["type"] as? String) == "user_message", let m = payload["message"] as? String {
                return m
            }
            // 形态 B：response_item，role == user，content 为块数组。
            if (payload["role"] as? String) == "user",
               let text = extractText(from: payload["content"]) {
                return text
            }
        }
        // 形态 C：顶层直接带 role / content。
        if (object["role"] as? String) == "user",
           let text = extractText(from: object["content"]) {
            return text
        }
        return nil
    }
}

// MARK: - 导出 Markdown

/// 整份 rollout 导出成 Markdown：`# 标题`，然后按出现顺序每条消息一段 `## 用户` / `## 助手` + 正文（去掉首尾空白）。
///
/// - 逐行读（`CLIJSONL.forEachObject`）：一行坏了（比如正在写的会话末尾半个汉字）只丢那一行，其余照常导出。
/// - 只取 `payload.type == "message"` 的 `response_item`（`event_msg` 的 user_message / agent_message 是镜像，取之会重复）；
///   跳过 developer / system 角色与系统注入块（`<environment_context>`、`<permissions instructions>`…，`CLISessionMarkdown.isSystemInjection`）。
enum CodexSessionMarkdown {

    static func markdown(from data: Data, title: String, headings: CLISessionMarkdown.Headings) -> String {
        var out = "# \(title)\n"
        CLIJSONL.forEachObject(in: data) { object in
            guard let payload = object["payload"] as? [String: Any],
                  (payload["type"] as? String) == "message",
                  let role = payload["role"] as? String,
                  role == "user" || role == "assistant",
                  let text = CodexJSONLParsing.extractText(from: payload["content"]) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !CLISessionMarkdown.isSystemInjection(trimmed) else { return }
            let heading = role == "user" ? headings.user : headings.assistant
            out += "\n## \(heading)\n\n\(trimmed)\n"
        }
        return out
    }
}
