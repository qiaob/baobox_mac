import Foundation
import XCTest

/// 导出 Markdown 两边共用的几样（DEDUPE.md §5.1 B2）：逐行读、系统注入的判定、小标题文案；以及存盘框预填的文件名（DEDUPE-P2.md §2.4 类 1）。
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

    // MARK: - 导出文件名（#164 PR3：两个中心窗口原来各写一份）

    func testExportFileNameReplacesSlashesAndColons() {
        XCTAssertEqual(CLISessionMarkdown.exportFileName(title: "fix: a/b//c", fallback: "session"), "fix- a-b--c")
        XCTAssertEqual(CLISessionMarkdown.exportFileName(title: #"别的不动 \ "引号" * ? | < >"#, fallback: "session"),
                       #"别的不动 \ "引号" * ? | < >"#, "只换 / 与 :")
    }

    func testExportFileNameTrimsWhitespaceAndNewlinesAfterReplacing() {
        XCTAssertEqual(CLISessionMarkdown.exportFileName(title: "  整理周报 \n\t", fallback: "session"), "整理周报")
        XCTAssertEqual(CLISessionMarkdown.exportFileName(title: " / ", fallback: "session"), "-", "先换再去首尾空白")
        XCTAssertEqual(CLISessionMarkdown.exportFileName(title: "a  \n  b", fallback: "session"), "a  \n  b", "中间的空白不动")
    }

    func testExportFileNameFallsBackWhenNothingIsLeft() {
        for title in ["", "   ", "\n\t \r\n"] {
            XCTAssertEqual(CLISessionMarkdown.exportFileName(title: title, fallback: "session"), "session")
            XCTAssertEqual(CLISessionMarkdown.exportFileName(title: title, fallback: "codex-session"), "codex-session")
        }
    }

    func testExportFileNameKeepsTheFirstSixtyCharacters() {
        let sixty = String(repeating: "字", count: 60)
        XCTAssertEqual(CLISessionMarkdown.exportFileName(title: sixty, fallback: "session"), sixty, "正好 60 个不截")
        XCTAssertEqual(CLISessionMarkdown.exportFileName(title: sixty + "多", fallback: "session"), sixty)
        XCTAssertEqual(CLISessionMarkdown.exportFileName(title: "   " + sixty + "多", fallback: "session"), sixty,
                       "先去首尾空白再截：开头的空格不占名额")

        let family = "👨‍👩‍👧‍👦"
        let emoji = String(repeating: family, count: 61)
        XCTAssertEqual(CLISessionMarkdown.exportFileName(title: emoji, fallback: "session"),
                       String(repeating: family, count: 60), "按字符（字素簇）数，不按 UTF-16 / 字节")
    }

    func testExportFileNameMayEndWithASpaceAfterCutting() {
        let title = String(repeating: "a", count: 59) + " bcd"
        XCTAssertEqual(CLISessionMarkdown.exportFileName(title: title, fallback: "session"),
                       String(repeating: "a", count: 59) + " ", "截完不再去空白（同原来）")
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
