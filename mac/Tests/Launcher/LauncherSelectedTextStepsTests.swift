import Foundation
import XCTest

/// 读选中文字的步骤（docs/launcher/TECH_DESIGN.md §8.4，第 9 步验证后改）：带时限（快速入口）时先读选区范围、有选区才读全文，
/// 不带时限（划词助手）保持下沉前的顺序。AX 调用换成记账的假函数。
final class LauncherSelectedTextStepsTests: XCTestCase {
    /// 一次读：各步返回什么，记下读了哪几步、按什么顺序。
    private final class FakeElement {
        var selectedText: String?
        var range: NSRange?
        var value: String?
        var stopAfterFirst = false
        private(set) var calls: [String] = []

        init(selectedText: String? = nil, range: NSRange? = nil, value: String? = nil) {
            self.selectedText = selectedText
            self.range = range
            self.value = value
        }

        func read(timed: Bool) -> String? {
            LauncherSelectedTextSteps.read(
                timed: timed,
                selectedText: { calls.append("selectedText"); return selectedText },
                selectedRange: { calls.append("range"); return range },
                value: { calls.append("value"); return value },
                stopped: { stopAfterFirst })
        }
    }

    private static let document = String(repeating: "整篇正文。", count: 2_000)

    func testTimedReadWithNothingSelectedNeverPullsTheWholeText() {
        // 光标停在大文件里、没选中：kAXSelectedText 回成功 + 空串，范围长度 0。
        let element = FakeElement(selectedText: "", range: NSRange(location: 120, length: 0), value: Self.document)
        XCTAssertNil(element.read(timed: true))
        XCTAssertEqual(element.calls, ["selectedText", "range"], "带时限：没有选区就不读全文")
    }

    func testTimedReadCutsTheSelectionOutOfTheText() {
        let element = FakeElement(selectedText: "", range: NSRange(location: 2, length: 3), value: "abcdefg")
        XCTAssertEqual(element.read(timed: true), "cde")
        XCTAssertEqual(element.calls, ["selectedText", "range", "value"], "先范围、后全文")
    }

    func testUntimedReadKeepsTheOriginalOrder() {
        let none = FakeElement(selectedText: "", range: NSRange(location: 0, length: 0), value: Self.document)
        XCTAssertNil(none.read(timed: false))
        XCTAssertEqual(none.calls, ["selectedText", "value", "range"], "划词助手：同下沉前，先全文、后范围")
        let some = FakeElement(selectedText: nil, range: NSRange(location: 2, length: 3), value: "abcdefg")
        XCTAssertEqual(some.read(timed: false), "cde")
        XCTAssertEqual(some.calls, ["selectedText", "value", "range"])
    }

    func testSelectedTextAttributeWinsWithoutFurtherReads() {
        for timed in [true, false] {
            let element = FakeElement(selectedText: "选中的", range: NSRange(location: 0, length: 3), value: "全文")
            XCTAssertEqual(element.read(timed: timed), "选中的")
            XCTAssertEqual(element.calls, ["selectedText"])
        }
    }

    func testStopsAfterTheFirstReadWhenTimeIsUp() {
        let element = FakeElement(selectedText: "", range: NSRange(location: 0, length: 3), value: "abc")
        element.stopAfterFirst = true
        XCTAssertNil(element.read(timed: true))
        XCTAssertEqual(element.calls, ["selectedText"])
    }

    func testMissingPiecesGiveNothing() {
        XCTAssertNil(FakeElement(selectedText: nil, range: nil, value: "abc").read(timed: true), "读不到范围")
        XCTAssertNil(FakeElement(selectedText: nil, range: NSRange(location: 0, length: 2), value: nil).read(timed: true),
                     "读不到全文")
        XCTAssertNil(FakeElement(selectedText: nil, range: NSRange(location: 5, length: 3), value: "abc").read(timed: true),
                     "范围越界")
    }

    func testRangesCountUTF16LikeAccessibility() {
        // 「😀」占两个 UTF-16 单位：AX 的范围按 UTF-16 计。
        XCTAssertEqual(LauncherSelectedTextSteps.substring(of: "a😀bc", range: NSRange(location: 1, length: 2)), "😀")
        XCTAssertEqual(LauncherSelectedTextSteps.substring(of: "a😀bc", range: NSRange(location: 3, length: 2)), "bc")
        XCTAssertNil(LauncherSelectedTextSteps.substring(of: "abc", range: NSRange(location: -1, length: 2)))
    }
}
