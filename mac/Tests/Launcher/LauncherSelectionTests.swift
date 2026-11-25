import Foundation
import XCTest

/// 选中行（docs/launcher/TECH_DESIGN.md §4「选中行」，PR 11 复查后定）：这次输入以来没手动选过 → 永远第一行；
/// 手动选过 → 按行 id 留在他选的那一行，那一行没了才回到第一行。所有后台刷新都用这一条。
final class LauncherSelectionTests: XCTestCase {

    /// 一批行换成另一批（同一个输入的后台刷新），返回选中的行 id。
    private func refresh(_ state: inout LauncherSelectionState, from old: [String], to new: [String]) -> String? {
        _ = state.rowsChanged(from: old, to: new, newInput: false)
        return new.indices.contains(state.index) ? new[state.index] : nil
    }

    func testNewInputSelectsTheFirstRowAndClearsManual() {
        var state = LauncherSelectionState()
        state.move(by: 2, rowCount: 5)
        XCTAssertTrue(state.isManual)
        XCTAssertTrue(state.rowsChanged(from: ["a", "b", "c", "d", "e"], to: ["x", "y"], newInput: true), "输入变了回到顶上")
        XCTAssertEqual(state.index, 0)
        XCTAssertFalse(state.isManual, "输入一变就清零")
    }

    func testNotManualAndARowInsertedAboveSelectsTheNewFirstRow() {
        // 验证者的 N1：输入 plan.txt，第 0 行是网页搜索建议；内存来源先交了普通文件行；Spotlight 带来固定行。
        var state = LauncherSelectionState()
        _ = state.rowsChanged(from: [], to: ["web", "find"], newInput: true)
        XCTAssertEqual(refresh(&state, from: ["web", "find"], to: ["clip", "plan.txt.bak", "web", "find"]), "clip",
                       "没手动选过：第一行")
        XCTAssertEqual(refresh(&state, from: ["clip", "plan.txt.bak", "web", "find"],
                               to: ["pinned/plan.txt", "clip", "plan.txt.bak", "web", "find"]), "pinned/plan.txt",
                       "固定行一来选中就在它上面，⏎ 打开文件")
    }

    func testNotManualAndTheFirstRowReplacedFollowsTheNewFirstRow() {
        // `main.swift`：内存来源先到、第一行是临时目录里的副本；Spotlight 到了，项目里的那份排到第一行。
        var state = LauncherSelectionState()
        _ = state.rowsChanged(from: [], to: ["tmp/main.swift", "web"], newInput: true)
        let scrolls = state.rowsChanged(from: ["tmp/main.swift", "web"], to: ["proj/main.swift", "tmp/main.swift", "web"],
                                        newInput: false)
        XCTAssertEqual(state.index, 0, "没手动选过：回车打开的永远是当下排第一的那个")
        XCTAssertTrue(scrolls, "第一行换了一个：回到顶上")
        XCTAssertFalse(state.rowsChanged(from: ["proj/main.swift", "tmp/main.swift", "web"],
                                         to: ["proj/main.swift", "tmp/main.swift", "web", "more"], newInput: false),
                       "第一行没变：不动滚动位置")
    }

    func testManualAndARowInsertedAboveStaysOnTheChosenRow() {
        var state = LauncherSelectionState()
        _ = state.rowsChanged(from: [], to: ["a", "b", "c"], newInput: true)
        state.move(by: 1, rowCount: 3)
        XCTAssertEqual(refresh(&state, from: ["a", "b", "c"], to: ["new", "a", "b", "c"]), "b", "按行 id 跟着他选的那一行")
        XCTAssertEqual(state.index, 2)
        XCTAssertTrue(state.isManual)
    }

    func testManualChoiceThatDisappearsFallsBackToTheFirstRow() {
        var state = LauncherSelectionState()
        _ = state.rowsChanged(from: [], to: ["a", "b", "c"], newInput: true)
        state.move(by: 2, rowCount: 3)
        XCTAssertEqual(refresh(&state, from: ["a", "b", "c"], to: ["a", "b"]), "a", "他选的那一行没了：回到第一行")
        XCTAssertFalse(state.isManual, "不再算手动选过")
        XCTAssertEqual(refresh(&state, from: ["a", "b"], to: ["pinned", "a", "b"]), "pinned", "之后又照「没选过」处理")
    }

    func testDownThenUpBackToTheFirstRowIsManual() {
        // ↓ ↑ 回到第 0 行是手动选的：固定行来了不许拉走。
        var state = LauncherSelectionState()
        _ = state.rowsChanged(from: [], to: ["clip", "web"], newInput: true)
        state.move(by: 1, rowCount: 2)
        state.move(by: -1, rowCount: 2)
        XCTAssertEqual(state.index, 0)
        XCTAssertTrue(state.isManual)
        XCTAssertEqual(refresh(&state, from: ["clip", "web"], to: ["pinned", "clip", "web"]), "clip")
    }

    func testMoveAtTheEdgeStillCountsAndClamps() {
        var state = LauncherSelectionState()
        _ = state.rowsChanged(from: [], to: ["a", "b"], newInput: true)
        state.move(by: -1, rowCount: 2)
        XCTAssertEqual(state.index, 0)
        XCTAssertTrue(state.isManual, "按了 ↑（到头没动）也算：他表示了要这一行")
        state.move(by: 5, rowCount: 2)
        XCTAssertEqual(state.index, 1)
        var empty = LauncherSelectionState()
        empty.move(by: 1, rowCount: 0)
        XCTAssertFalse(empty.isManual, "没有行时不算")
    }

    func testHoverOnlyCountsWhenItChangesTheRow() {
        var state = LauncherSelectionState()
        _ = state.rowsChanged(from: [], to: ["a", "b", "c"], newInput: true)
        state.hover(0, rowCount: 3)
        XCTAssertFalse(state.isManual, "停在已经选中的那一行上不算")
        state.hover(5, rowCount: 3)
        XCTAssertFalse(state.isManual, "行号不对不算")
        state.hover(2, rowCount: 3)
        XCTAssertEqual(state.index, 2)
        XCTAssertTrue(state.isManual)
    }
}
