import Foundation
import XCTest

/// Claude Code 会话导出成 Markdown（`ClaudeSessionMarkdown`，DEDUPE.md §5.1 B2）：
/// (a) 小标题跟界面语言；(b) 用户消息里的系统注入不导出；(c) 坏行只丢那一行；其余格式照旧。
final class ClaudeSessionMarkdownTests: XCTestCase {

    private func export(_ data: Data, _ headings: CLISessionMarkdown.Headings = .english) -> String {
        ClaudeSessionMarkdown.markdown(from: data, title: "修登录页", headings: headings)
    }

    private func user(_ content: Any) throws -> String {
        try jsonLine(["type": "user", "message": ["role": "user", "content": content]])
    }

    private func assistant(_ content: Any) throws -> String {
        try jsonLine(["type": "assistant", "message": ["role": "assistant", "content": content]])
    }

    private func text(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    /// 一段典型的会话：斜杠命令与它的输出、提问、带思考与工具调用的回复、工具结果、两个文字块的回复。
    private func session() throws -> Data {
        jsonlData(
            #"{"type":"summary","summary":"修登录页","leafUuid":"u1"}"#,
            try user("<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>"),
            try user("<local-command-stdout>Set model to opus</local-command-stdout>"),
            try user("登录页的按钮点了没反应"),
            try assistant([
                ["type": "thinking", "thinking": "先看 LoginView"],
                text("我看一下 LoginView。"),
                ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/app/LoginView.swift"]],
            ]),
            try user([["type": "tool_result", "tool_use_id": "t1", "content": "struct LoginView {}"]]),
            try assistant([text("按钮的 action 没接上。"), text("已经改好了。")])
        )
    }

    // MARK: - (a) 小标题

    func testChineseInterfaceGetsChineseHeadings() throws {
        XCTAssertEqual(export(try session(), .chinese), """
        # 修登录页

        ## 用户

        登录页的按钮点了没反应

        ## 助手

        我看一下 LoginView。

        ## 助手

        按钮的 action 没接上。

        已经改好了。

        """)
    }

    func testEnglishInterfaceKeepsUserAndAssistant() throws {
        XCTAssertEqual(export(try session(), .english), """
        # 修登录页

        ## User

        登录页的按钮点了没反应

        ## Assistant

        我看一下 LoginView。

        ## Assistant

        按钮的 action 没接上。

        已经改好了。

        """)
    }

    // MARK: - (b) 系统注入

    func testSkipsEachKindOfSystemInjection() throws {
        let expected = export(jsonlData(try user("前一句"), try assistant([text("后一句")])))
        XCTAssertEqual(expected, "# 修登录页\n\n## User\n\n前一句\n\n## Assistant\n\n后一句\n")

        let injections: [Any] = (systemInjectionSamples as [Any]) + [
            [text("<system-reminder>content 是数组时看第一个 text 块</system-reminder>"), text("第二个块不导出")],
        ]
        for injection in injections {
            let data = jsonlData(try user("前一句"), try user(injection), try assistant([text("后一句")]))
            XCTAssertEqual(export(data), expected, "\(injection)")
        }
    }

    func testKeepsTextThatOnlyContainsATagAndRepliesThatStartWithOne() throws {
        let data = jsonlData(
            try user("把 <div> 换成 <section>"),
            try assistant([text("<section> 已经换好了。")]),
            try assistant("<!DOCTYPE html>\n<html></html>")
        )
        XCTAssertEqual(export(data), """
        # 修登录页

        ## User

        把 <div> 换成 <section>

        ## Assistant

        <section> 已经换好了。

        ## Assistant

        <!DOCTYPE html>
        <html></html>

        """, "标签不在开头的用户消息照常导出；系统注入只在 user 行里，助手的回复以 < 开头是正文，照常导出")
    }

    // MARK: - (c) 坏行

    func testDropsOnlyTheLinesWithBadBytes() throws {
        var data = jsonlData(try user("第一句"))
        data.append(Data(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"坏"#.utf8))
        data.append(contentsOf: halfCharacter)
        data.append(Data(#""}]}}"#.utf8))
        data.append(0x0A)
        data.append(jsonlData(try assistant([text("第二句")])))
        data.append(Data(#"{"type":"user","message":{"role":"user","content":"正在写的一行"#.utf8))
        data.append(contentsOf: halfCharacter)

        XCTAssertEqual(export(data), "# 修登录页\n\n## User\n\n第一句\n\n## Assistant\n\n第二句\n",
                       "中间那行有坏字节、最后一行写了一半：各丢自己那一行")
    }

    // MARK: - 其余照旧

    func testTheRestOfTheFormatIsUnchanged() throws {
        let data = jsonlData(
            #"{"type":"file-history-snapshot","snapshot":{}}"#,
            #"{"type":"system","content":"Conversation compacted"}"#,
            #"{"type":"user"}"#,
            try user("  前后的空白原样保留  "),
            try user(" \n "),
            try assistant([["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]]),
            try assistant([text("只有"), ["type": "tool_use", "id": "t2", "name": "Bash", "input": [String: Any]()], text("文字块")]),
            try user([text("取第一个 text 块"), text("第二个不要")])
        )
        let expected = [
            "# 修登录页", "",
            "## 用户", "", "  前后的空白原样保留  ", "",
            "## 助手", "", "只有\n\n文字块", "",
            "## 用户", "", "取第一个 text 块", "",
        ].joined(separator: "\n")
        XCTAssertEqual(export(data, .chinese), expected,
                       "别的类型、没有 message、只有空白、只有工具调用的行不导出；正文不 trim；助手拼全部 text 块，用户只取第一个")
        XCTAssertEqual(export(Data(), .chinese), "# 修登录页\n", "空文件只有标题")
    }
}
