import Foundation
import XCTest

/// 快速入口的前缀解析（docs/launcher/TECH_DESIGN.md §5，REQUIREMENTS.md §3.2「只搜一类」）。
final class LauncherQueryTests: XCTestCase {

    private func parse(_ input: String) -> LauncherQuery {
        LauncherQuery.parse(input)
    }

    private func query(_ sourceID: String?, _ text: String) -> LauncherQuery {
        LauncherQuery(sourceID: sourceID, text: text)
    }

    // MARK: - 没有前缀

    func testNoPrefixKeepsWholeInputTrimmed() {
        XCTAssertEqual(parse("Safari"), query(nil, "Safari"))
        XCTAssertEqual(parse("  防休眠 两小时  "), query(nil, "防休眠 两小时"), "只去首尾空白，中间的保留")
    }

    func testEmptyAndBlankInput() {
        XCTAssertEqual(parse(""), query(nil, ""))
        XCTAssertEqual(parse("   "), query(nil, ""))
    }

    // MARK: - 出厂前缀

    func testEachDefaultPrefix() {
        XCTAssertEqual(parse("a Safari"), query("apps", "Safari"))
        XCTAssertEqual(parse("c curl"), query("clipboard", "curl"))
        XCTAssertEqual(parse("f 周报.pdf"), query("files", "周报.pdf"))
        XCTAssertEqual(parse("s baobox"), query("sessions", "baobox"))
        XCTAssertEqual(parse("m 站会"), query("meetings", "站会"))
        XCTAssertEqual(parse("w Xcode"), query("windows", "Xcode"))
    }

    func testPrefixIgnoresCase() {
        XCTAssertEqual(parse("A Safari"), query("apps", "Safari"))
        XCTAssertEqual(parse("C curl"), query("clipboard", "curl"))
        XCTAssertEqual(parse("W xcode"), query("windows", "xcode"), "查询词的大小写原样保留")
    }

    func testPrefixAloneWithoutSpaceDoesNotCount() {
        XCTAssertEqual(parse("a"), query(nil, "a"))
        XCTAssertEqual(parse("C"), query(nil, "C"))
    }

    func testPrefixFollowedByOtherCharactersDoesNotCount() {
        XCTAssertEqual(parse("app"), query(nil, "app"))
        XCTAssertEqual(parse("chrome"), query(nil, "chrome"))
        XCTAssertEqual(parse("a微信"), query(nil, "a微信"))
        XCTAssertEqual(parse("a-b"), query(nil, "a-b"))
    }

    func testPrefixWithSpaceButNoQueryLeavesEmptyText() {
        XCTAssertEqual(parse("a "), query("apps", ""))
        XCTAssertEqual(parse("c    "), query("clipboard", ""))
    }

    func testQueryAfterPrefixIsTrimmed() {
        XCTAssertEqual(parse("a   Safari  "), query("apps", "Safari"))
        XCTAssertEqual(parse("c  docker run  -it "), query("clipboard", "docker run  -it"))
    }

    func testLeadingWhitespaceBeforePrefixDoesNotCount() {
        XCTAssertEqual(parse(" a Safari"), query(nil, "a Safari"))
    }

    func testOnlyTheFirstPrefixCounts() {
        XCTAssertEqual(parse("a c foo"), query("apps", "c foo"))
    }

    func testFullWidthSpaceAlsoSeparates() {
        XCTAssertEqual(parse("a\u{3000}微信"), query("apps", "微信"))
    }

    func testUnknownLetterIsNotAPrefix() {
        XCTAssertEqual(parse("x foo"), query(nil, "x foo"))
        XCTAssertEqual(parse("b foo"), query(nil, "b foo"))
    }

    // MARK: - 传入的前缀表

    func testCustomPrefixTable() {
        let table = ["apps": "ap", "clipboard": "剪"]
        XCTAssertEqual(LauncherQuery.parse("ap Safari", prefixBySource: table), query("apps", "Safari"))
        XCTAssertEqual(LauncherQuery.parse("AP Safari", prefixBySource: table), query("apps", "Safari"))
        XCTAssertEqual(LauncherQuery.parse("剪 curl", prefixBySource: table), query("clipboard", "curl"))
        XCTAssertEqual(LauncherQuery.parse("a Safari", prefixBySource: table), query(nil, "a Safari"),
                       "出厂前缀不在表里就不认")
    }

    func testMultiCharacterPrefixNeedsTheWholePrefixAndASpace() {
        let table = ["apps": "app"]
        XCTAssertEqual(LauncherQuery.parse("ap", prefixBySource: table), query(nil, "ap"))
        XCTAssertEqual(LauncherQuery.parse("app", prefixBySource: table), query(nil, "app"))
        XCTAssertEqual(LauncherQuery.parse("apps", prefixBySource: table), query(nil, "apps"))
        XCTAssertEqual(LauncherQuery.parse("app ", prefixBySource: table), query("apps", ""))
    }

    func testEmptyPrefixIsDisabled() {
        let table = ["apps": "", "clipboard": "c"]
        XCTAssertEqual(LauncherQuery.parse(" foo", prefixBySource: table), query(nil, "foo"),
                       "空前缀不能把开头的空格当成「前缀 + 空格」")
        XCTAssertEqual(LauncherQuery.parse("c foo", prefixBySource: table), query("clipboard", "foo"))
    }

    func testBlankPrefixIsDisabled() {
        XCTAssertEqual(LauncherQuery.parse("  foo", prefixBySource: ["apps": " "]), query(nil, "foo"))
    }

    func testEmptyTableMeansNoPrefixes() {
        XCTAssertEqual(LauncherQuery.parse("a foo", prefixBySource: [:]), query(nil, "a foo"))
    }

    func testDuplicatePrefixPicksTheSmallestSourceID() {
        let table = ["windows": "w", "apps": "W"]
        for _ in 0..<20 {
            XCTAssertEqual(LauncherQuery.parse("w Xcode", prefixBySource: table), query("apps", "Xcode"))
        }
    }
}
