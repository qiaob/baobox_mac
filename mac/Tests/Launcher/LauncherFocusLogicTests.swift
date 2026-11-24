import Foundation
import XCTest

/// 快速入口收起后等焦点回到原来的 App、粘贴目标的取法（docs/launcher/TECH_DESIGN.md §4「焦点」）。
final class LauncherFocusLogicTests: XCTestCase {
    private let target: pid_t = 100
    private let own: pid_t = 200
    private let raycast: pid_t = 300

    private func snapshot(front: pid_t?, ownKey: Bool = false, keyboard: pid_t? = nil) -> LauncherFocusSnapshot {
        LauncherFocusSnapshot(frontmostPID: front, targetPID: target, ownPID: own, ownWindowIsKey: ownKey,
                              keyboardPID: keyboard)
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
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: target, targetPID: target, ownPID: own), .paste)
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: nil, targetPID: target, ownPID: own), .paste,
                       "没有辅助功能权限 / 读不到：照常粘贴")
    }

    func testGateWaitsWhileKeyboardIsStillOurs() {
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: own, targetPID: target, ownPID: own), .waitForSelf)
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: own, targetPID: nil, ownPID: own), .waitForSelf)
    }

    func testGateBlocksWhenAThirdAppHasTheKeyboard() {
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: raycast, targetPID: target, ownPID: own), .blocked(raycast),
                       "⌘V 会粘进 Raycast：不发")
        XCTAssertEqual(LauncherKeyboardGate.decide(keyboardPID: raycast, targetPID: nil, ownPID: own), .paste,
                       "没有目标（粘给前台）时不知道该在哪儿，只防我们自己")
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
        XCTAssertEqual(launcherOnly.source, .launcher, "「纯文本粘贴上一条」从快速入口执行：没传目标，用快速入口的")
        let none = LauncherPasteTarget.resolve(explicit: String?.none, clipboardPanel: nil, launcher: nil)
        XCTAssertNil(none.app)
        XCTAssertEqual(none.source, .missing, "全局快捷键触发：没有目标，粘给前台")
    }
}
