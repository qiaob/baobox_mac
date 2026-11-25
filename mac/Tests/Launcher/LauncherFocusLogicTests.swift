import Foundation
import XCTest

/// 快速入口收起后等焦点回到原来的 App、粘贴目标的取法（docs/launcher/TECH_DESIGN.md §4「焦点」）。
final class LauncherFocusLogicTests: XCTestCase {
    private let target: pid_t = 100
    private let own: pid_t = 200
    private let raycast: pid_t = 300

    /// 拿键盘的是 Raycast 时它不是普通 Dock App（菜单栏 App）；别的默认当普通 App。
    private func snapshot(front: pid_t?, ownKey: Bool = false, keyboard: pid_t? = nil,
                          holderIsRegular: Bool? = nil) -> LauncherFocusSnapshot {
        LauncherFocusSnapshot(frontmostPID: front, targetPID: target, ownPID: own, ownWindowIsKey: ownKey,
                              keyboardPID: keyboard,
                              keyboardHolderIsRegular: holderIsRegular ?? (keyboard == raycast ? false : true))
    }

    // MARK: - 某一刻回去了没有

    func testReadyWhenTargetIsFrontAndPanelLetGo() {
        XCTAssertEqual(LauncherFocusVerdict.of(snapshot(front: target)), .ready, "没有辅助功能权限：只看前台和 key 窗口")
        XCTAssertEqual(LauncherFocusVerdict.of(snapshot(front: target, keyboard: target)), .ready)
    }

    func testWaitingWhileOurPanelIsStillKey() {
        XCTAssertEqual(LauncherFocusVerdict.of(snapshot(front: target, ownKey: true, keyboard: target)), .waiting)
    }

    func testWaitingWhileSomethingElseIsFront() {
        XCTAssertEqual(LauncherFocusVerdict.of(snapshot(front: own)), .waiting, "Baobox 自己在前台：等它让出去")
        XCTAssertEqual(LauncherFocusVerdict.of(snapshot(front: raycast)), .waiting)
        XCTAssertEqual(LauncherFocusVerdict.of(snapshot(front: nil)), .waiting)
    }

    func testWaitingWhileKeyboardIsStillOurs() {
        XCTAssertEqual(LauncherFocusVerdict.of(snapshot(front: target, keyboard: own)), .waiting,
                       "面板刚收起，系统还没把键盘还回去")
    }

    func testHeldElsewhereWhenAThirdAppHasTheKeyboard() {
        XCTAssertEqual(LauncherFocusVerdict.of(snapshot(front: target, keyboard: raycast)), .heldElsewhere(raycast))
    }

    func testARegularThirdAppWithTheKeyboardIsNotHeldElsewhere() {
        XCTAssertEqual(LauncherFocusVerdict.of(snapshot(front: target, keyboard: 400, holderIsRegular: true)), .ready,
                       "前台 App 和拿键盘的进程不是同一个 pid 的正常情况（壳 App）")
    }

    // MARK: - 等的过程

    func testFinishesAsSoonAsFocusIsBack() {
        var wait = LauncherFocusWait(start: 10)
        XCTAssertEqual(wait.step(snapshot(front: target, ownKey: true), now: 10.015), .keepWaiting)
        XCTAssertEqual(wait.step(snapshot(front: target), now: 10.030), .finish(.returned))
    }

    func testTimesOutAfter300Milliseconds() {
        var wait = LauncherFocusWait(start: 10)
        XCTAssertEqual(wait.step(snapshot(front: own), now: 10.29), .keepWaiting)
        XCTAssertEqual(wait.step(snapshot(front: own), now: 10.31), .finish(.timedOut))
    }

    func testStopsWaitingAfterTwoSightingsOfAThirdApp() {
        var wait = LauncherFocusWait(start: 10)
        XCTAssertEqual(wait.step(snapshot(front: target, keyboard: raycast), now: 10.015), .keepWaiting, "一次可能是系统还没处理完")
        XCTAssertEqual(wait.step(snapshot(front: target, keyboard: raycast), now: 10.030), .finish(.heldElsewhere),
                       "它不会自己还回来：不等了，粘贴那一步挡下")
    }

    func testSightingsOfAThirdAppMustBeConsecutive() {
        var wait = LauncherFocusWait(start: 10)
        XCTAssertEqual(wait.step(snapshot(front: target, keyboard: raycast), now: 10.015), .keepWaiting)
        XCTAssertEqual(wait.step(snapshot(front: target, keyboard: own), now: 10.030), .keepWaiting)
        XCTAssertEqual(wait.step(snapshot(front: target, keyboard: raycast), now: 10.045), .keepWaiting)
        XCTAssertEqual(wait.heldElsewhereCount, 1)
    }

    func testThirdAppAtTheDeadlineTimesOut() {
        var wait = LauncherFocusWait(start: 10)
        XCTAssertEqual(wait.step(snapshot(front: own), now: 10.2), .keepWaiting)
        XCTAssertEqual(wait.step(snapshot(front: target, keyboard: raycast), now: 10.31), .finish(.timedOut))
    }

    // MARK: - 发 ⌘V 前

    func testGatePastesWhenKeyboardIsWithTheTargetOrUnknown() {
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: target, holderIsRegular: true, targetPID: target, ownPID: own), .paste)
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: nil, holderIsRegular: nil, targetPID: target, ownPID: own), .paste,
                       "没有辅助功能权限 / 读不到：照常粘贴")
    }

    func testGateWaitsWhileKeyboardIsStillOurs() {
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: own, holderIsRegular: false, targetPID: target, ownPID: own),
                       .waitForSelf)
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: own, holderIsRegular: false, targetPID: nil, ownPID: own),
                       .waitForSelf)
    }

    func testGateBlocksOnlyANonRegularThirdApp() {
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: raycast, holderIsRegular: false, targetPID: target, ownPID: own),
                       .blocked(raycast), "Raycast 这类菜单栏 App 拿着键盘：⌘V 会粘进它，不发")
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: 400, holderIsRegular: true, targetPID: target, ownPID: own),
                       .paste, "是普通 Dock App：照常粘贴（不能挡壳 App 这类正常情况）")
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: 400, holderIsRegular: nil, targetPID: target, ownPID: own),
                       .paste, "找不到这个 App：照常粘贴")
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: raycast, holderIsRegular: false, targetPID: nil, ownPID: own),
                       .paste, "没有目标（粘给前台）时不知道该在哪儿，只防我们自己")
    }

    // MARK: - 动作的上下文只在闭包里

    func testActionContextOnlyInsideTheClosure() {
        let scope = LauncherActionScope<String>()
        XCTAssertNil(scope.current)
        var seenInside: String?
        var later: (() -> String?)?
        scope.run("otty") {
            seenInside = scope.current
            // 闭包里留到之后再跑的一步（异步粘贴、紧接着按的全局快捷键）：执行时已经读不到。
            later = { scope.current }
        }
        XCTAssertEqual(seenInside, "otty")
        XCTAssertNil(scope.current, "闭包一返回就清掉，没有时间窗口")
        XCTAssertNil(later?(), "之后的异步步骤读不到：要用就在闭包里先读走")
    }

    func testStepsQueuedOnTheMainQueueInsideTheClosureCannotSeeTheContext() {
        let box = AsyncStepBox()
        let ran = expectation(description: "排到主队列的那一步跑了")
        box.scope.run("otty") {
            // `PasteService` 的写法：进门同步读走，后面的步骤用读走的值。
            let context = box.scope.current
            DispatchQueue.main.async {
                box.seenLater = box.scope.current
                box.carried = context
                ran.fulfill()
            }
        }
        wait(for: [ran], timeout: 2)
        XCTAssertNil(box.seenLater, "排到主队列的一步（同 `PasteService` 等 0.12 s 再发 ⌘V）回头读全局状态：读不到")
        XCTAssertEqual(box.carried, "otty", "闭包里读走的值带得过去")
    }

    func testStepsInATaskStartedInsideTheClosureCannotSeeTheContext() {
        let box = AsyncStepBox()
        let ran = expectation(description: "Task 跑了")
        box.scope.run("otty") {
            // ⌘⏎ 插入的写法：闭包里读走目标，再开 Task 交给 `TextInserter`。
            let target = box.scope.current
            Task { @MainActor in
                box.seenLater = box.scope.current
                box.carried = target
                ran.fulfill()
            }
        }
        wait(for: [ran], timeout: 2)
        XCTAssertNil(box.seenLater, "Task 里的异步步骤读不到")
        XCTAssertEqual(box.carried, "otty")
    }

    func testContinuingAnActionLaterRestoresTheContextOnlyForThatStep() {
        // 「翻译图里的文字」：闭包里读走上下文，取字完了再在它里面执行那一步（`LauncherFocus.continueAction`）。
        let scope = LauncherActionScope<String>()
        var context: String?
        scope.run("otty") { context = scope.current }
        XCTAssertNil(scope.current)
        var seen: String?
        if let context { scope.run(context) { seen = scope.current } }
        XCTAssertEqual(seen, "otty")
        XCTAssertNil(scope.current, "那一步跑完又清掉")
    }

    /// `PasteService.paste` 进门的那一步：读 `actionContext`，交给 `LauncherPasteTarget.choose`。
    /// 动作的上下文 = 目标（呼出前的前台 App，已经退出时为 nil）。
    private func enterPaste(_ scope: LauncherActionScope<String?>, explicit: String? = nil,
                            clipboardPanel: String? = nil) -> LauncherPasteTarget.Choice<String> {
        let action = scope.current
        return LauncherPasteTarget.choose(explicit: explicit, clipboardPanel: clipboardPanel,
                                          inLauncherAction: action != nil, launcher: action ?? nil)
    }

    func testPasteInsideALauncherActionUsesItsTarget() {
        let scope = LauncherActionScope<String?>()
        var choice: LauncherPasteTarget.Choice<String>?
        scope.run("otty") { choice = enterPaste(scope) }
        XCTAssertEqual(choice, LauncherPasteTarget.Choice(app: "otty", source: .launcher, fromLauncher: true),
                       "剪贴板条目、「纯文本粘贴上一条」从快速入口执行：目标来自动作，算快速入口来的")
    }

    func testPasteRightAfterALauncherActionDoesNotSeeItsTarget() {
        let scope = LauncherActionScope<String?>()
        scope.run("otty") { _ = enterPaste(scope) }
        XCTAssertEqual(enterPaste(scope), LauncherPasteTarget.Choice<String>(app: nil, source: .missing, fromLauncher: false),
                       "紧接着按全局快捷键 ⌘⌥V：没有目标（粘给此刻的前台），不看键盘、不回执，和改动前一样")
        XCTAssertEqual(enterPaste(scope, clipboardPanel: "notes"),
                       LauncherPasteTarget.Choice(app: "notes", source: .clipboardPanel, fromLauncher: false),
                       "剪贴板面板：用它自己记下的")
    }

    func testPasteInsideALauncherActionWhoseAppQuit() {
        let scope = LauncherActionScope<String?>()
        var choice: LauncherPasteTarget.Choice<String>?
        scope.run(nil) { choice = enterPaste(scope) }
        XCTAssertEqual(choice, LauncherPasteTarget.Choice<String>(app: nil, source: .missing, fromLauncher: true),
                       "呼出前的 App 已经退出：没有目标，但还是快速入口来的（粘不出去要回执）")
    }

    func testChooseIgnoresALauncherTargetOutsideALauncherAction() {
        XCTAssertEqual(LauncherPasteTarget.choose(explicit: nil, clipboardPanel: nil, inLauncherAction: false, launcher: "otty"),
                       LauncherPasteTarget.Choice<String>(app: nil, source: .missing, fromLauncher: false),
                       "不在快速入口的动作里：就算传进来也不用")
        XCTAssertEqual(LauncherPasteTarget.choose(explicit: "a", clipboardPanel: "b", inLauncherAction: true, launcher: "c"),
                       LauncherPasteTarget.Choice(app: "a", source: .explicit, fromLauncher: true))
        XCTAssertEqual(LauncherPasteTarget.choose(explicit: nil, clipboardPanel: "b", inLauncherAction: true, launcher: "c"),
                       LauncherPasteTarget.Choice(app: "b", source: .clipboardPanel, fromLauncher: false),
                       "剪贴板面板开着时是它自己的粘贴")
    }

    func testNestedActionContextRestoresTheOuterOne() {
        let scope = LauncherActionScope<String>()
        scope.run("outer") {
            scope.run("inner") { XCTAssertEqual(scope.current, "inner") }
            XCTAssertEqual(scope.current, "outer")
        }
        XCTAssertNil(scope.current)
    }

    func testFromLauncherOnlyInsideALauncherAction() {
        XCTAssertTrue(LauncherPasteTarget.isFromLauncher(inLauncherAction: true, source: .launcher))
        XCTAssertTrue(LauncherPasteTarget.isFromLauncher(inLauncherAction: true, source: .explicit))
        XCTAssertTrue(LauncherPasteTarget.isFromLauncher(inLauncherAction: true, source: .missing),
                      "呼出时前台是 Baobox 自己：没有目标，但还是快速入口来的（粘不出去要回执）")
        XCTAssertFalse(LauncherPasteTarget.isFromLauncher(inLauncherAction: true, source: .clipboardPanel))
        XCTAssertFalse(LauncherPasteTarget.isFromLauncher(inLauncherAction: false, source: .missing), "全局快捷键 ⌘⌥V")
        XCTAssertFalse(LauncherPasteTarget.isFromLauncher(inLauncherAction: false, source: .clipboardPanel), "剪贴板面板")
        XCTAssertFalse(LauncherPasteTarget.isFromLauncher(inLauncherAction: false, source: .explicit))
    }

    // MARK: - 粘贴目标

    func testPasteTargetOrder() {
        let all = LauncherPasteTarget.resolve(explicit: "a", clipboardPanel: "b", launcher: "c")
        XCTAssertEqual(all.app, "a")
        XCTAssertEqual(all.source, .explicit)
        let noExplicit = LauncherPasteTarget.resolve(explicit: nil, clipboardPanel: "b", launcher: "c")
        XCTAssertEqual(noExplicit.app, "b")
        XCTAssertEqual(noExplicit.source, .clipboardPanel)
        let launcherOnly = LauncherPasteTarget.resolve(explicit: nil, clipboardPanel: nil, launcher: "c")
        XCTAssertEqual(launcherOnly.app, "c")
        XCTAssertEqual(launcherOnly.source, .launcher,
                       "「纯文本粘贴上一条」、剪贴板条目从快速入口执行：没传目标，用快速入口动作里的")
        let none = LauncherPasteTarget.resolve(explicit: String?.none, clipboardPanel: nil, launcher: nil)
        XCTAssertNil(none.app)
        XCTAssertEqual(none.source, .missing,
                       "全局快捷键触发，或快速入口的剪贴板条目、而呼出前的 App 已经退出：没有目标，粘给前台（不拿退出的 App 当目标）")
    }
}

/// 异步步骤里看到的东西（只在主线程读写）。
private final class AsyncStepBox: @unchecked Sendable {
    let scope = LauncherActionScope<String>()
    var seenLater: String? = "unset"
    var carried: String?
}
