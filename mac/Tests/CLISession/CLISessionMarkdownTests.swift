import Foundation
import XCTest

/// 导出 Markdown 两边共用的三样（DEDUPE.md §5.1 B2）：逐行读、系统注入的判定、小标题文案。
final class CLISessionMarkdownTests: XCTestCase {

    private func titles(in data: Data) -> [String] {
        var titles: [String] = []
        CLIJSONL.forEachObject(in: data) { titles.append(($0["t"] as? String) ?? "?") }
        return titles
    }

    // MARK: - 逐行读

    func testForEachObjectDropsOnlyTheBadLines() {
        var data = jsonlData(
            #"{"t":"一"}"#,
            #"{"t":"坏 JSON""#,
            #"[1,2]"#,
            "",
            #"{"t":"二"}"# + "\r"
        )
        data.append(Data(#"{"t":"坏"#.utf8))
        data.append(contentsOf: halfCharacter)
        data.append(Data(#""}"#.utf8))
        data.append(0x0A)
        data.append(Data(#"{"t":"三"}"#.utf8))   // 最后一行没有换行

        XCTAssertNil(String(data: data, encoding: .utf8), "整份按 UTF-8 解会失败（Codex 以前的读法）")
        XCTAssertEqual(titles(in: data), ["一", "二", "三"],
                       "坏 JSON、非对象、空行、坏 UTF-8 各丢自己那一行；CRLF 照样认；没有换行的最后一行照样解析")
    }

    func testForEachObjectDropsAHalfWrittenLastLine() {
        var data = jsonlData(#"{"t":"一"}"#, #"{"t":"二"}"#)
        data.append(Data(#"{"t":"正在写"#.utf8))
        data.append(contentsOf: halfCharacter)

        XCTAssertEqual(titles(in: data), ["一", "二"], "写了一半、切在汉字中间的最后一行丢掉，前面的照常")
        XCTAssertEqual(titles(in: Data()), [])
    }

    // MARK: - 系统注入

    func testTextThatStartsWithATagIsASystemInjection() {
        for text in systemInjectionSamples {
            XCTAssertTrue(CLISessionMarkdown.isSystemInjection(text), text)
        }
    }

    func testOrdinaryTextIsNotASystemInjection() {
        let ordinary = [
            "登录页的按钮点了没反应",
            "把 <div> 换成 <section>",
            "a < b 的时候走这一支",
            "  前后有空格  ",
            "",
            " \n ",
        ]
        for text in ordinary {
            XCTAssertFalse(CLISessionMarkdown.isSystemInjection(text), text)
        }
    }

    // MARK: - 小标题文案

    /// 两个模块的 key 不同、文案相同；格式的测试用的 `.english` / `.chinese` 就是这几条。
    func testExportHeadingsInTheCatalog() {
        for (user, assistant) in [("claudecode.export.user", "claudecode.export.assistant"),
                                  ("aitools.export.user", "aitools.export.assistant")] {
            XCTAssertEqual(catalogValue(user, language: "en"), CLISessionMarkdown.Headings.english.user, user)
            XCTAssertEqual(catalogValue(assistant, language: "en"), CLISessionMarkdown.Headings.english.assistant, assistant)
            XCTAssertEqual(catalogValue(user, language: "zh-Hans"), CLISessionMarkdown.Headings.chinese.user, user)
            XCTAssertEqual(catalogValue(assistant, language: "zh-Hans"), CLISessionMarkdown.Headings.chinese.assistant, assistant)
        }
    }
}
