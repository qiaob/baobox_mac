import Foundation
import XCTest

/// 「输入即出」的结果行：什么时候算 / 识别，识别结果怎么换成行（docs/launcher/TECH_DESIGN.md §6.3、§7）。
final class LauncherInstantResultsTests: XCTestCase {

    // MARK: - 什么时候算、什么时候识别

    func testCalculatorRunsOnlyWithoutAPrefix() {
        XCTAssertTrue(LauncherInstantPolicy.runsCalculator(LauncherQuery.parse("12*(3+4)")))
        XCTAssertFalse(LauncherInstantPolicy.runsCalculator(LauncherQuery.parse("a 12*3")))
        XCTAssertFalse(LauncherInstantPolicy.runsCalculator(LauncherQuery.parse("c 1+2")))
        XCTAssertFalse(LauncherInstantPolicy.runsCalculator(LauncherQuery.parse("> 1+2")))
        XCTAssertFalse(LauncherInstantPolicy.runsCalculator(LauncherQuery.parse("   ")))
        XCTAssertFalse(LauncherInstantPolicy.runsCalculator(LauncherQuery.parse("")))
    }

    func testTextRecognitionNeedsFourCharactersAndNoPrefix() {
        XCTAssertFalse(LauncherInstantPolicy.runsTextRecognition(LauncherQuery.parse("abc"), hasCalculation: false))
        XCTAssertTrue(LauncherInstantPolicy.runsTextRecognition(LauncherQuery.parse("abcd"), hasCalculation: false))
        XCTAssertFalse(LauncherInstantPolicy.runsTextRecognition(LauncherQuery.parse("  abc  "), hasCalculation: false),
                       "按去掉首尾空白后的字数算")
        XCTAssertTrue(LauncherInstantPolicy.runsTextRecognition(LauncherQuery.parse("时间戳啊"), hasCalculation: false))
        XCTAssertFalse(LauncherInstantPolicy.runsTextRecognition(LauncherQuery.parse("c 1700000000"),
                                                                 hasCalculation: false))
    }

    func testCalculationWinsOverTextRecognition() {
        XCTAssertFalse(LauncherInstantPolicy.runsTextRecognition(LauncherQuery.parse("0xff to dec"), hasCalculation: true))
    }

    // MARK: - 表格行

    private func row(_ label: String, _ value: String, _ copy: String?) -> LauncherConversionTableRow {
        LauncherConversionTableRow(label: label, value: value, copyValue: copy)
    }

    func testTableRowsWithCopyValuesBecomeAtMostThreeRows() {
        let table = [
            row("本地时间", "2023-11-15 06:13:20 GMT+08:00", "2023-11-15 06:13:20"),
            row("UTC", "2023-11-14 22:13:20Z", "2023-11-14 22:13:20Z"),
            row("相对时间", "2 年前", nil),
            row("ISO 8601", "2023-11-14T22:13:20Z", "2023-11-14T22:13:20Z"),
            row("秒", "1700000000", "1700000000"),
        ]
        let rows = LauncherConversions.rows(input: "1700000000", badge: "Unix 时间戳（秒）", table: table, transforms: [])
        XCTAssertEqual(rows.map(\.title), ["2023-11-15 06:13:20 GMT+08:00", "2023-11-14 22:13:20Z", "2023-11-14T22:13:20Z"])
        XCTAssertEqual(rows.map(\.copyText), ["2023-11-15 06:13:20", "2023-11-14 22:13:20Z", "2023-11-14T22:13:20Z"],
                       "复制的是复制值，不是显示的值")
        XCTAssertEqual(rows.first?.detail, "Unix 时间戳（秒） · 本地时间")
    }

    func testTableRowsWinOverTransforms() {
        var ran = false
        let rows = LauncherConversions.rows(input: "x", badge: "URL", table: [row("q", "hello world", "hello world")],
                                            transforms: [LauncherConversionTransform(title: "解码") { _ in
                                                ran = true
                                                return "y"
                                            }])
        XCTAssertEqual(rows.map(\.copyText), ["hello world"])
        XCTAssertFalse(ran, "有表格行就不跑转换")
    }

    func testEmptyCopyValueOrEmptyValue() {
        let rows = LauncherConversions.rows(input: "x", badge: "B",
                                            table: [row("a", "shown", ""), row("b", "", "copied")], transforms: [])
        XCTAssertEqual(rows.map(\.title), ["copied"], "复制值为空的不出；显示值为空时显示复制值")
    }

    // MARK: - 转换

    func testFirstUsefulTransformBecomesOneRow() {
        let transforms = [
            LauncherConversionTransform(title: "不适用") { _ in nil },
            LauncherConversionTransform(title: "原样") { $0 },
            LauncherConversionTransform(title: "空") { _ in "" },
            LauncherConversionTransform(title: "解码") { _ in "hello\n  world" },
            LauncherConversionTransform(title: "第二个") { _ in "never" },
        ]
        let rows = LauncherConversions.rows(input: "aGVsbG8=", badge: "Base64", table: [], transforms: transforms)
        XCTAssertEqual(rows, [LauncherConversion(title: "hello world", detail: "Base64 · 解码", copyText: "hello\n  world")])
    }

    func testNothingUsefulGivesNoRows() {
        XCTAssertTrue(LauncherConversions.rows(input: "x", badge: "B", table: [row("a", "1", nil)],
                                               transforms: [LauncherConversionTransform(title: "t") { $0 }]).isEmpty)
        XCTAssertTrue(LauncherConversions.rows(input: "x", badge: "B", table: [], transforms: []).isEmpty)
    }

    func testDetailWithoutLabel() {
        XCTAssertEqual(LauncherConversions.detail(badge: "URL", label: ""), "URL")
        XCTAssertEqual(LauncherConversions.detail(badge: "URL", label: "  "), "URL")
        XCTAssertEqual(LauncherConversions.detail(badge: "JWT", label: "exp"), "JWT · exp")
    }

    // MARK: - 压成一行

    func testSingleLineCollapsesWhitespace() {
        XCTAssertEqual(LauncherConversions.singleLine("{\n  \"a\" : 1,\n\t\"b\" : 2\n}"), "{ \"a\" : 1, \"b\" : 2 }")
        XCTAssertEqual(LauncherConversions.singleLine("   lead and trail   "), "lead and trail")
        XCTAssertEqual(LauncherConversions.singleLine(""), "")
        XCTAssertEqual(LauncherConversions.singleLine(" \n\t "), "")
        XCTAssertEqual(LauncherConversions.singleLine("中文\r\n换行"), "中文 换行")
    }

    func testSingleLineTruncates() {
        XCTAssertEqual(LauncherConversions.singleLine("abcdef", maxLength: 3), "abc")
        XCTAssertEqual(LauncherConversions.singleLine("ab cdef", maxLength: 3), "ab ")
        XCTAssertEqual(LauncherConversions.singleLine("ab    cd", maxLength: 2), "ab")
        XCTAssertEqual(LauncherConversions.singleLine(String(repeating: "x", count: 10_000)).count,
                       LauncherConversions.maxTitleLength)
    }
}
