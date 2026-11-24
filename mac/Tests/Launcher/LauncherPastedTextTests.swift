import Foundation
import XCTest

/// 粘贴进来的原文：带换行才记、输入框里的文字还是它才用（docs/launcher/TECH_DESIGN.md §5.4）。
final class LauncherPastedTextTests: XCTestCase {

    func testOnlyMultilineTextIsWorthKeeping() {
        XCTAssertTrue(LauncherPastedText.isWorthKeeping("第一行\n第二行"))
        XCTAssertTrue(LauncherPastedText.isWorthKeeping("a\r\nb"))
        XCTAssertTrue(LauncherPastedText.isWorthKeeping("a\u{2028}b"), "Unicode 行分隔符也算")
        XCTAssertFalse(LauncherPastedText.isWorthKeeping("one line"))
        XCTAssertFalse(LauncherPastedText.isWorthKeeping("tab\tonly"))
        XCTAssertFalse(LauncherPastedText.isWorthKeeping(""))
    }

    func testNormalized() {
        XCTAssertEqual(LauncherPastedText.normalized("  a \n\n b\t\tc  "), "a b c")
        XCTAssertEqual(LauncherPastedText.normalized("line one\r\nline two"), "line one line two")
        XCTAssertEqual(LauncherPastedText.normalized("   "), "")
        XCTAssertEqual(LauncherPastedText.normalized("中文　全角空格"), "中文 全角空格")
    }

    func testFieldTextAfterThePasteMatches() {
        // 单行输入框把 \n 换成一个空格、\r\n 换成两个空格（探针实测），制表符留着。
        let original = "第一段：快速入口\n\n第二段：放进任何东西\r\n第三段\twith tab"
        let field = "第一段：快速入口  第二段：放进任何东西  第三段\twith tab"
        XCTAssertTrue(LauncherPastedText.matches(original: original, fieldText: field))
        XCTAssertEqual(LauncherPastedText.original(original, matching: field), original)
        XCTAssertEqual(LauncherPastedText.original("\n  a\nb  \n", matching: "a b"), "a\nb", "首尾空白去掉，中间的换行留着")
    }

    func testAnyEditDropsTheOriginal() {
        let original = "Dear team,\nthe release is on Friday.\nThanks"
        XCTAssertNil(LauncherPastedText.original(original, matching: "Dear team, the release is on Friday. Thank"))
        XCTAssertNil(LauncherPastedText.original(original, matching: "Dear team, the release is on Monday. Thanks"))
        XCTAssertNil(LauncherPastedText.original(original, matching: "x Dear team, the release is on Friday. Thanks"),
                     "粘在已有文字后面的也不算")
        XCTAssertNil(LauncherPastedText.original(original, matching: ""))
    }

    func testNothingToUse() {
        XCTAssertNil(LauncherPastedText.original(nil, matching: "abc"))
        XCTAssertNil(LauncherPastedText.original("single line", matching: "single line"), "单行的不用记")
        XCTAssertNil(LauncherPastedText.original("\n\n", matching: ""), "全是空白")
    }

    func testWhitespaceOnlyDifferencesStillMatch() {
        XCTAssertTrue(LauncherPastedText.matches(original: "a\nb", fieldText: "  a   b "))
        XCTAssertFalse(LauncherPastedText.matches(original: "a\nb", fieldText: "ab"), "空白没了不算一样")
    }
}
