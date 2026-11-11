import Foundation
import XCTest

/// Codex 会话导出成 Markdown（`CodexSessionMarkdown`，DEDUPE.md §5.1 B2）：(c) 坏字节只丢那一行（以前整份导出失败）；
/// 小标题、跳过系统注入与镜像事件照旧。
final class CodexSessionMarkdownTests: XCTestCase {

    private func export(_ data: Data, _ headings: CLISessionMarkdown.Headings = .english) -> String {
        CodexSessionMarkdown.markdown(from: data, title: "修登录页", headings: headings)
    }

    /// 一条 `response_item` 消息。
    private func message(_ role: String, _ text: String) throws -> String {
        let type = role == "assistant" ? "output_text" : "input_text"
        return try jsonLine([
            "timestamp": "2026-11-10T08:00:00.000Z",
            "type": "response_item",
            "payload": ["type": "message", "role": role, "content": [["type": type, "text": text]]],
        ])
    }

    private func user(_ text: String) throws -> String { try message("user", text) }
    private func assistant(_ text: String) throws -> String { try message("assistant", text) }

    /// `event_msg`：user_message / agent_message 是上面消息的镜像。
    private func event(_ type: String, _ message: String) throws -> String {
        try jsonLine(["timestamp": "2026-11-10T08:00:00.000Z", "type": "event_msg",
                      "payload": ["type": type, "message": message]])
    }

    /// 一段典型的 rollout：SessionMeta、developer 指令、环境注入、提问（带首尾空白）与镜像、推理、回复与镜像。
    private func session() throws -> Data {
        jsonlData(
            #"{"timestamp":"2026-11-10T08:00:00.000Z","type":"session_meta","payload":{"id":"0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b","cwd":"/Users/me/app"}}"#,
            try message("developer", "<permissions instructions>Approval policy is on-request.</permissions instructions>"),
            try user("<environment_context>\n  <cwd>/Users/me/app</cwd>\n</environment_context>"),
            try user("  修一下登录页  \n"),
            try event("user_message", "修一下登录页"),
            #"{"timestamp":"2026-11-10T08:00:01.000Z","type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
            try assistant("好的，我先看看。"),
            try event("agent_message", "好的，我先看看。")
        )
    }

    // MARK: - (c) 坏字节

    func testABadByteDropsOnlyItsLine() throws {
        var data = jsonlData(try user("第一句"))
        data.append(Data(#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"坏"#.utf8))
        data.append(contentsOf: halfCharacter)
        data.append(Data(#""}]}}"#.utf8))
        data.append(0x0A)
        data.append(jsonlData(try assistant("第二句")))
        data.append(Data(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"正在写的一行"#.utf8))
        data.append(contentsOf: halfCharacter)

        XCTAssertNil(String(data: data, encoding: .utf8), "以前整份按 UTF-8 解：这份文件整份导出失败")
        XCTAssertEqual(export(data), "# 修登录页\n\n## User\n\n第一句\n\n## Assistant\n\n第二句\n",
                       "中间那行有坏字节、最后一行写了一半：各丢自己那一行，其余照常导出")
    }

    // MARK: - 照旧

    func testHeadingsFollowTheInterfaceLanguage() throws {
        XCTAssertEqual(export(try session(), .chinese), "# 修登录页\n\n## 用户\n\n修一下登录页\n\n## 助手\n\n好的，我先看看。\n")
        XCTAssertEqual(export(try session(), .english), "# 修登录页\n\n## User\n\n修一下登录页\n\n## Assistant\n\n好的，我先看看。\n",
                       "developer 指令、环境注入、镜像事件、推理不导出；正文去掉首尾空白")
    }

    func testSkipsEachKindOfSystemInjection() throws {
        let expected = export(jsonlData(try user("前一句"), try assistant("后一句")))
        XCTAssertEqual(expected, "# 修登录页\n\n## User\n\n前一句\n\n## Assistant\n\n后一句\n")
        for injection in systemInjectionSamples {
            let data = jsonlData(try user("前一句"), try user(injection), try assistant("后一句"))
            XCTAssertEqual(export(data), expected, injection)
        }
    }
}
