import CoreGraphics
import Foundation
import XCTest

/// 快速入口交来文字时划词助手结果面板的位置：水平居中、顶边在可见区域从上往下 1/5 处（docs/launcher/TECH_DESIGN.md §5.4）。
final class SelectionCenteredSlotTests: XCTestCase {
    /// 用户的内置屏：可见区域 (0, 79, 1512, 870)（菜单栏在上、程序坞在下）。
    private let builtIn = CGRect(x: 0, y: 79, width: 1512, height: 870)
    /// 用户的外接屏：在内置屏上方、往左错开 210。
    private let external = CGRect(x: -210, y: 982, width: 1920, height: 1080)

    func testTopIsOneFifthDownTheVisibleArea() {
        XCTAssertEqual(SelectionCenteredSlot(visible: builtIn).top, 949 - 174, accuracy: 0.001)
        XCTAssertEqual(SelectionCenteredSlot(visible: external).top, 2062 - 216, accuracy: 0.001)
    }

    func testCenteredHorizontallyWithTopEdgeOnTheLine() {
        let slot = SelectionCenteredSlot(visible: builtIn)
        let origin = slot.origin(for: CGSize(width: 400, height: 120))
        XCTAssertEqual(origin.x, 556, "(1512 − 400) / 2")
        XCTAssertEqual(origin.y + 120, 775, "顶边在 1/5 那条线上")
    }

    func testStaysCenteredAndKeepsTopWhenHeightChanges() {
        let slot = SelectionCenteredSlot(visible: external)
        let short = slot.origin(for: CGSize(width: 400, height: 60))
        let tall = slot.origin(for: CGSize(width: 400, height: 300))
        XCTAssertEqual(short.x, tall.x)
        XCTAssertEqual(short.x, 550, "外接屏中线 750 − 200")
        XCTAssertEqual(short.y + 60, tall.y + 300, "顶边不动、往下长")
    }

    func testClampedIntoTheVisibleAreaWhenTooTall() {
        let slot = SelectionCenteredSlot(visible: builtIn)
        let origin = slot.origin(for: CGSize(width: 400, height: 760))
        XCTAssertEqual(origin.y, 79 + 8, "底边放不下：夹回可见区（顶边跟着往上挪）")
    }

    func testOriginIsIntegral() {
        // 可见区高度的 1/5 不是整数时也给整数原点（系统会把窗口原点取整）。
        let slot = SelectionCenteredSlot(visible: CGRect(x: 0, y: 25, width: 1441, height: 873))
        let origin = slot.origin(for: CGSize(width: 400, height: 101))
        XCTAssertEqual(origin.x, origin.x.rounded())
        XCTAssertEqual(origin.y, origin.y.rounded())
    }

    func testRoundingIsNotADrag() {
        XCTAssertFalse(SelectionCenteredSlot.wasMoved(placed: CGPoint(x: 556, y: 655), actual: CGPoint(x: 556, y: 654.5)))
        XCTAssertFalse(SelectionCenteredSlot.wasMoved(placed: CGPoint(x: 556, y: 655), actual: CGPoint(x: 557, y: 655)))
        XCTAssertTrue(SelectionCenteredSlot.wasMoved(placed: CGPoint(x: 556, y: 655), actual: CGPoint(x: 600, y: 655)))
        XCTAssertTrue(SelectionCenteredSlot.wasMoved(placed: CGPoint(x: 556, y: 655), actual: CGPoint(x: 556, y: 640)))
    }

    func testZeroSizeReportIsNotMeasured() {
        XCTAssertFalse(SelectionCenteredSlot.isMeasured(.zero), "SwiftUI 第一次排版前报的 0 × 0")
        XCTAssertFalse(SelectionCenteredSlot.isMeasured(CGSize(width: 400, height: 0)))
        XCTAssertTrue(SelectionCenteredSlot.isMeasured(CGSize(width: 400, height: 88)))
    }
}
