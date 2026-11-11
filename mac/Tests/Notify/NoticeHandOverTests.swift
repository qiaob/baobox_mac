import Foundation
import XCTest

/// 关掉宠物时，气泡里还挂着 / 还在排队的哪些转成系统通知（#144，`Notice.handsOver(shown:)`）。
/// 规则：回执从不转；常驻、带按钮的总是转；其余只转还没露过面的，轻提示除外。
final class NoticeHandOverTests: XCTestCase {

    private let button = Notice.Action(id: "later", label: "Later")

    private func notice(level: Notice.Level, style: Notice.Style? = nil, actions: [Notice.Action] = [],
                        feedback: Bool = false) -> Notice {
        Notice(source: "meeting", level: level, title: "t", actions: actions, style: style, isUserFeedback: feedback)
    }

    func testStickyIsHandedOverWhetherShownOrNot() {
        // alert 不指定样式 = 常驻；bubble 指定成常驻也一样。
        for n in [notice(level: .alert), notice(level: .bubble, style: .sticky), notice(level: .ambient, style: .sticky)] {
            XCTAssertTrue(n.handsOver(shown: true))
            XCTAssertTrue(n.handsOver(shown: false))
        }
    }

    func testCardsWithButtonsAreHandedOverWhetherShownOrNot() {
        for n in [notice(level: .bubble, actions: [button]), notice(level: .ambient, actions: [button])] {
            XCTAssertTrue(n.handsOver(shown: true))
            XCTAssertTrue(n.handsOver(shown: false))
        }
    }

    func testShownCardWithoutButtonsIsNotRepeated() {
        XCTAssertFalse(notice(level: .bubble).handsOver(shown: true))
    }

    func testCardNotShownYetIsHandedOver() {
        XCTAssertTrue(notice(level: .bubble).handsOver(shown: false))
    }

    func testAmbientToastWithoutButtonsIsNeverHandedOver() {
        XCTAssertFalse(notice(level: .ambient).handsOver(shown: true))
        XCTAssertFalse(notice(level: .ambient).handsOver(shown: false))
    }

    func testReceiptsAreNeverHandedOverEvenStickyOrWithButtons() {
        let receipts = [notice(level: .bubble, actions: [button], feedback: true),
                        notice(level: .alert, feedback: true),
                        notice(level: .bubble, feedback: true)]
        for n in receipts {
            XCTAssertFalse(n.handsOver(shown: true))
            XCTAssertFalse(n.handsOver(shown: false))
        }
    }
}
