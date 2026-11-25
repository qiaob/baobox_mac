import Foundation
import XCTest

/// 二次确认（docs/launcher/TECH_DESIGN.md §4「按两次回车」，第 10 步）：哪一行在等第二次 ⏎、什么时候复位、标题里的对象怎么截断。
final class LauncherConfirmTests: XCTestCase {

    // MARK: - 按两次

    func testFirstPressArmsSecondPressRuns() {
        var state = LauncherConfirmState()
        XCTAssertNil(state.armedID)
        XCTAssertFalse(state.press("suggest/terminal"), "第一次只是等着")
        XCTAssertEqual(state.armedID, "suggest/terminal")
        XCTAssertTrue(state.press("suggest/terminal"), "第二次才执行")
        XCTAssertNil(state.armedID, "执行后复位")
        XCTAssertFalse(state.press("suggest/terminal"), "复位后又要按两次")
    }

    func testPressingAnotherRowMovesTheWait() {
        var state = LauncherConfirmState()
        _ = state.press("reminder/a")
        XCTAssertFalse(state.press("reminder/b"), "换了一行：只算那一行的第一次")
        XCTAssertEqual(state.armedID, "reminder/b")
        XCTAssertTrue(state.press("reminder/b"))
    }

    func testMovingTheSelectionAwayResets() {
        var state = LauncherConfirmState()
        _ = state.press("suggest/terminal")
        XCTAssertNil(state.selectionChanged(to: "suggest/terminal"), "还选着它：不复位")
        XCTAssertEqual(state.armedID, "suggest/terminal")
        XCTAssertEqual(state.selectionChanged(to: "textaction/translate"), "suggest/terminal", "移开了：复位")
        XCTAssertNil(state.armedID)
        XCTAssertNil(state.selectionChanged(to: nil), "没有在等的就没什么可复位")
        _ = state.press("suggest/terminal")
        XCTAssertEqual(state.selectionChanged(to: nil), "suggest/terminal", "列表空了也复位")
    }

    func testResetForNewInputOrHiding() {
        var state = LauncherConfirmState()
        XCTAssertNil(state.reset())
        _ = state.press("x")
        XCTAssertEqual(state.reset(), "x")
        XCTAssertNil(state.armedID)
        XCTAssertFalse(state.press("x"), "复位后第一次又只是等着")
    }

    // MARK: - 标题里的对象

    func testShortObjectsStayWhole() {
        XCTAssertEqual(LauncherConfirmText.object("git status"), "git status")
        XCTAssertEqual(LauncherConfirmText.object("  git   status \n"), "git status", "压成一行")
        XCTAssertEqual(LauncherConfirmText.object("14:35 取快递"), "14:35 取快递")
        let exactly = String(repeating: "a", count: LauncherConfirmText.maxObjectWidth)
        XCTAssertEqual(LauncherConfirmText.object(exactly), exactly, "正好放得下不截")
    }

    func testLongObjectsKeepTheStartAndTheEnd() {
        let command = "docker run --rm -it -v \"$PWD\":/work -w /work node:20 sh -c 'npm ci && npm run build && npm test'"
        let shown = LauncherConfirmText.object(command)
        XCTAssertTrue(shown.hasPrefix("docker run --rm"), shown)
        XCTAssertTrue(shown.hasSuffix("npm test'"), shown)
        XCTAssertTrue(shown.contains("…"), shown)
        XCTAssertLessThanOrEqual(shown.map(LauncherConfirmText.width).reduce(0, +), LauncherConfirmText.maxObjectWidth)
    }

    func testWideCharactersCountDouble() {
        XCTAssertEqual(LauncherConfirmText.width("a"), 1)
        XCTAssertEqual(LauncherConfirmText.width("取"), 2)
        XCTAssertEqual(LauncherConfirmText.width("："), 2)
        let chinese = String(repeating: "取快递", count: 20)
        let shown = LauncherConfirmText.object(chinese, maxWidth: 20)
        XCTAssertLessThanOrEqual(shown.map(LauncherConfirmText.width).reduce(0, +), 20, shown)
        XCTAssertTrue(shown.hasPrefix("取快递"), shown)
        XCTAssertTrue(shown.hasSuffix("快递"), shown)
    }

    func testTinyWidths() {
        XCTAssertEqual(LauncherConfirmText.object("abcdefgh", maxWidth: 0), "a…h", "最少按 3 算")
        XCTAssertEqual(LauncherConfirmText.object("abcdefgh", maxWidth: 6), "abc…gh", "开头多半、结尾少半")
        XCTAssertEqual(LauncherConfirmText.object(""), "")
    }

    // MARK: - 选中

    func testChoosingARowCountsAsManual() {
        var selection = LauncherSelectionState()
        selection.choose(0, rowCount: 3)
        XCTAssertEqual(selection.index, 0)
        XCTAssertTrue(selection.isManual, "点名了第 0 行也算手动选过")
        // 后台结果回来：留在它上面。
        XCTAssertFalse(selection.rowsChanged(from: ["a", "b", "c"], to: ["new", "a", "b", "c"], newInput: false))
        XCTAssertEqual(selection.index, 1)
        selection.choose(5, rowCount: 3)
        XCTAssertEqual(selection.index, 1, "越界的不理")
    }
}
