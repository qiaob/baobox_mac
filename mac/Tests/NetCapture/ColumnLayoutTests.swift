import Foundation
import XCTest

/// 抓包窗口三栏的宽度（docs/packet-capture/TOOLS.md §7）：详情最宽，窗口拉宽时多出来的给详情。
final class ColumnLayoutTests: XCTestCase {
    private let layout = ColumnLayout.standard

    private func resolve(_ total: Double, _ sidebar: Double? = nil, _ list: Double? = nil) -> [Double] {
        let widths = layout.resolve(total: total, sidebar: sidebar ?? layout.sidebarDefault, list: list ?? layout.listDefault)
        return [widths.sidebar, widths.list, widths.detail]
    }

    func testDefaultWindowGivesTheRestToTheDetail() {
        XCTAssertEqual(resolve(1080), [200, 360, 518])
        XCTAssertEqual(resolve(980 + 2), [200, 360, 420], "200 + 360 + 420 刚好放下")
    }

    func testWiderWindowOnlyGrowsTheDetail() {
        XCTAssertEqual(resolve(1600), [200, 360, 1038])
        XCTAssertEqual(resolve(2400, 260, 500), [260, 500, 1638])
    }

    func testNarrowWindowShrinksListThenSidebar() {
        XCTAssertEqual(resolve(900), [198, 280, 420], "先把列表缩到 280，再缩左栏")
        XCTAssertEqual(resolve(layout.minimumTotal), [160, 280, 420])
        XCTAssertEqual(layout.minimumTotal, 862)
        // 比三栏最小值还窄（窗口最小宽度 900，正常到不了）：两栏停在最小，详情被挤。
        XCTAssertEqual(resolve(800), [160, 280, 358])
    }

    func testWantedWidthsAreClampedToTheirRanges() {
        XCTAssertEqual(resolve(1600, 50, 50), [160, 280, 1158])
        XCTAssertEqual(resolve(1600, 999, 999), [280, 560, 758])
    }

    func testDraggingStaysInRangeAndKeepsTheDetailWide() {
        // 左栏：160–280。
        XCTAssertEqual(layout.draggingSidebar(from: 200, by: 50, total: 1600, list: 360), 250)
        XCTAssertEqual(layout.draggingSidebar(from: 200, by: 500, total: 1600, list: 360), 280)
        XCTAssertEqual(layout.draggingSidebar(from: 200, by: -500, total: 1600, list: 360), 160)
        // 窗口窄：再拉宽就挤到详情了，停在详情 420 的位置。
        XCTAssertEqual(layout.draggingSidebar(from: 200, by: 50, total: 1000, list: 360), 218)
        // 列表：280–560，同样不挤详情。
        XCTAssertEqual(layout.draggingList(from: 360, by: 120, total: 1600, sidebar: 200), 480)
        XCTAssertEqual(layout.draggingList(from: 360, by: 999, total: 1600, sidebar: 200), 560)
        XCTAssertEqual(layout.draggingList(from: 360, by: -999, total: 1600, sidebar: 200), 280)
        XCTAssertEqual(layout.draggingList(from: 360, by: 200, total: 1080, sidebar: 200), 458)
        // 窗口已经窄到放不下：只能停在最小。
        XCTAssertEqual(layout.draggingList(from: 280, by: 50, total: 900, sidebar: 198), 280)
    }
}
