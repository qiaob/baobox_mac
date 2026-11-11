import Foundation

/// 会话导出成 Markdown 时 Claude Code 与 Codex 两种格式共用的规矩（#109，docs/codex-assistant/DEDUPE.md §5.1 B2）：
/// 小标题跟界面语言（文案由模块传进来）、跳过系统注入；逐行读用 `CLIJSONL.forEachObject`（坏行只丢那一行）。
/// 格式本身（取哪些行、怎么取文本、段落怎么排）是真差异，留在各模块：`ClaudeSessionMarkdown`、`CodexSessionMarkdown`。
enum CLISessionMarkdown {

    /// 「## 用户」「## 助手」这两种小标题的文案。模块用 `L()` 取好传进来 —— 这里不调 `L()`（测试 target 里没有本地化表）。
    struct Headings: Equatable, Sendable {
        let user: String
        let assistant: String
    }

    /// 系统注入：去掉首尾空白后以 `<` 开头 —— CLI 自己塞进对话里的标记块，不是谁说的话：
    /// Claude Code 的 `<command-name>`、`<command-message>`、`<local-command-stdout>`、`<system-reminder>`…，
    /// Codex 的 `<environment_context>`、`<user_instructions>`…。两边的会话标题也按这条规则跳过（各自格式的 `scan`）。
    static func isSystemInjection(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }
}
