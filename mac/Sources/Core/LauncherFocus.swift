import AppKit
import ApplicationServices
import os

/// 快速入口呼出前的前台 App，以及收起后把焦点还给它（docs/launcher/TECH_DESIGN.md §4「焦点」）。
///
/// 快速入口的面板是不激活 App 的 key 面板（nonactivatingPanel）：前台 App 一直没变，键盘焦点被面板「借走」。
/// 收起后键盘焦点还给谁由 WindowServer 决定 —— 它还给「面板拿焦点之前的那个借走焦点的窗口」，不一定是前台 App。
/// 别的 App 和我们响应同一个快捷键时（2026-11-24 用户的 Raycast 也是 ⌘Space），它先借了一下又把窗口藏起来，
/// 我们收起后键盘就落到它那里：合成的 ⌘V 进了 Raycast，终端里什么都没粘出来。这种状态不绕路（不强切前台）：
/// 读得出键盘在第三个 App 那里就不发 ⌘V，回执说清原因（`checkKeyboardBeforePaste`），提前的提示见 `LauncherHotkeyConflictCheck`。
///
/// 系统行为（2026-11-24 探针 + WindowServer 日志，macOS 27.2）：
/// - 面板 `orderOut` 的同一拍，本进程的 `NSApp.keyWindow` 就是 nil、`NSApp.isActive` 就是 false
///   （面板是 key 时本进程的 `NSApp.isActive` 是 true，但 `NSRunningApplication.current.isActive` 是 false）；
///   `NSWorkspace.frontmostApplication` 始终是原来的 App。
/// - 对本来就在前台的 App 调 `activate()`：返回 true，WindowServer 什么都不做，清不掉别人留下的借焦点。
/// - macOS 14 起的协作式激活：不是前台的 App 去激活别的 App，系统可以不理（文档如此，没在真机上测：会切走用户的前台）。
///   对我们的影响：目标一直在前台，只要等面板让出 key；Baobox 自己在前台（从设置窗口里呼出、或执行前被激活了）时
///   先 `yieldActivation(to:)` 再让目标 `activate()`。部署目标是 macOS 14，这两个 API 不用 `#available`。
/// - 公开 API 里只有辅助功能的 `AXFocusedApplication` 可能看得出「键盘在第三个 App 那里」（`NSRunningApplication.isActive`、
///   `menuBarOwningApplication` 都只看前台）。它跟不跟着借焦点走没测成（探针没有辅助功能权限）：每次都把它和前台 App 记进日志。
///
/// 放在 Core 而不是快速入口模块里：别的模块交给快速入口的动作（剪贴板的粘贴）也要读它。
@MainActor
enum LauncherFocus {
    /// 正在执行的快速入口动作的上下文。
    struct ActionContext {
        /// 呼出前的前台 App；当时前台是 Baobox 自己、或它已经退出时为 nil。
        let target: NSRunningApplication?
    }

    private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")
    /// 等焦点时多久看一次。
    static let pollInterval: TimeInterval = 0.015

    /// 呼出快速入口那一刻的前台 App；当时前台就是 Baobox 自己（比如从设置窗口里呼出）则为 nil。
    /// 不对外：它在面板收起后还留着，别的模块读它就成了时间窗口；要目标只能在动作闭包里读 `actionContext`。
    private static var previousApp: NSRunningApplication?
    private static let actionScope = LauncherActionScope<ActionContext>()
    /// 正在执行的快速入口动作：只在动作闭包同步执行的那一段有值，闭包一返回就是 nil（没有时间窗口）。
    /// 要在之后的异步步骤里用，就在闭包里同步读走（`PasteService.paste` 进门就读）。
    static var actionContext: ActionContext? { actionScope.current }

    private static var pending: PendingWait?
    /// 最近一次等焦点的截止时刻（uptime）：粘贴前「键盘还在我们这儿」时最多等到这里（并进同一个上限）。
    private static var focusDeadline: TimeInterval = 0

    /// 一次「收起后等焦点回去再执行」。
    private final class PendingWait {
        let target: NSRunningApplication
        let start: TimeInterval
        var wait: LauncherFocusWait
        var polls = 0
        /// 读辅助功能键盘焦点用了多久（毫秒）：总共、最长的一次（日志里看真机上要多久）。
        var keyboardReadTotal: Double = 0
        var keyboardReadMax: Double = 0
        let action: @MainActor () -> Void

        init(target: NSRunningApplication, start: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.target = target
            self.start = start
            wait = LauncherFocusWait(start: start)
            self.action = action
        }
    }

    /// 必须在面板拿焦点之前调。还在等上一次的焦点（收起后不到半秒又呼出）就作废那次，那个动作不再执行。
    static func capture() {
        cancel(reason: "launcher shown again")
        let app = NSWorkspace.shared.frontmostApplication
        previousApp = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
        log.notice("captured front app \(bundleID(previousApp), privacy: .public); NSApp.isActive \(NSApp.isActive, privacy: .public)")
    }

    /// Esc / 再按一次快捷键收起：把焦点还给呼出前的 App，不等。它已经退出、或当时前台是 Baobox 自己时什么都不做。
    static func restore() {
        cancel(reason: "dismissed")
        guard let app = previousApp, !app.isTerminated else { return }
        requestActivation(of: app)
    }

    /// 执行动作前（面板已经收起）：把焦点还给呼出前的 App，等它真的回去 —— 前台是它、Baobox 没有 key 窗口、
    /// 读得到系统键盘焦点时键盘也在它那里 —— 再回调；每 15 ms 看一次，最多等 300 ms，超时也回调。
    /// 连着两次读到键盘在第三个 App 那里就不等了（照样回调，粘贴那一步会挡下）。
    /// 呼出前的 App 为 nil 或已退出时立即回调。`action` 同步执行期间 `actionContext` 有值。
    static func restore(then action: @escaping @MainActor () -> Void) {
        cancel(reason: "superseded")
        let start = uptime()
        focusDeadline = start + LauncherFocusWait.timeout
        guard let target = previousApp, !target.isTerminated else {
            log.notice("restore: \(previousApp == nil ? "no app was captured" : "captured app has quit", privacy: .public), running now")
            run(action, target: nil)
            return
        }
        requestActivation(of: target)
        let wait = PendingWait(target: target, start: start, action: action)
        pending = wait
        // 同一拍里面板刚 orderOut：下一拍开始看。
        DispatchQueue.main.async {
            MainActor.assumeIsolated { tick(wait) }
        }
    }

    /// 作废还在等的那次（再次呼出、App 退出）。动作不执行。
    static func cancel(reason: String = "cancelled") {
        guard let wait = pending else { return }
        pending = nil
        log.notice("focus wait for \(bundleID(wait.target), privacy: .public) cancelled (\(reason, privacy: .public)) after \(milliseconds(since: wait.start), format: .fixed(precision: 0), privacy: .public) ms; action dropped")
    }

    // MARK: - 等焦点

    private static func tick(_ wait: PendingWait) {
        guard pending === wait else { return }
        if wait.target.isTerminated {
            pending = nil
            log.notice("focus wait: \(bundleID(wait.target), privacy: .public) quit while waiting, running now")
            run(wait.action, target: nil)
            return
        }
        wait.polls += 1
        let (snapshot, readMilliseconds) = snapshot(for: wait.target)
        wait.keyboardReadTotal += readMilliseconds
        wait.keyboardReadMax = max(wait.keyboardReadMax, readMilliseconds)
        switch wait.wait.step(snapshot, now: uptime()) {
        case .keepWaiting:
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                MainActor.assumeIsolated { tick(wait) }
            }
        case .finish(let outcome):
            pending = nil
            log.notice("focus wait \(outcome.rawValue, privacy: .public) after \(milliseconds(since: wait.start), format: .fixed(precision: 0), privacy: .public) ms (\(wait.polls, privacy: .public) checks): front \(bundleID(pid: snapshot.frontmostPID), privacy: .public), target \(bundleID(wait.target), privacy: .public), keyboard (AX) \(bundleID(pid: snapshot.keyboardPID), privacy: .public) [\(policyLabel(pid: snapshot.keyboardPID), privacy: .public)], NSApp.isActive \(NSApp.isActive, privacy: .public), Baobox key window \(snapshot.ownWindowIsKey, privacy: .public); AX reads \(wait.keyboardReadTotal, format: .fixed(precision: 1), privacy: .public) ms in total, longest \(wait.keyboardReadMax, format: .fixed(precision: 1), privacy: .public) ms")
            run(wait.action, target: wait.target)
        }
    }

    /// 执行动作：动作闭包同步执行的那一段，别的模块（`PasteService`）能看到「这是快速入口的动作、目标是谁」；闭包返回即清掉。
    private static func run(_ action: @MainActor () -> Void, target: NSRunningApplication?) {
        actionScope.run(ActionContext(target: target)) { action() }
    }

    /// 动作里有一步要等（「翻译图里的文字」等取字）：在动作闭包里读走的上下文，等到了再在它里面执行那一步。nil 时直接执行。
    static func continueAction(in context: ActionContext?, _ body: @MainActor () -> Void) {
        guard let context else {
            body()
            return
        }
        actionScope.run(context) { body() }
    }

    /// 请求把前台还给 `app`：Baobox 自己在前台时先让出（协作式激活），它不在前台时请它激活。
    private static func requestActivation(of app: NSRunningApplication) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if front == ProcessInfo.processInfo.processIdentifier {
            NSApp.yieldActivation(to: app)
        }
        if front != app.processIdentifier {
            app.activate()
        }
    }

    /// 此刻的状态，和读辅助功能键盘焦点用了多少毫秒。
    private static func snapshot(for target: NSRunningApplication) -> (LauncherFocusSnapshot, Double) {
        let keyboard = readKeyboardFocus()
        let snapshot = LauncherFocusSnapshot(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                             targetPID: target.processIdentifier,
                                             ownPID: ProcessInfo.processInfo.processIdentifier,
                                             ownWindowIsKey: NSApp.keyWindow != nil,
                                             keyboardPID: keyboard.pid,
                                             keyboardHolderIsRegular: isRegularApp(pid: keyboard.pid))
        return (snapshot, keyboard.milliseconds)
    }

    // MARK: - 粘贴前看一眼键盘

    /// 粘贴前看系统键盘焦点的结果。
    enum KeyboardCheck: Equatable {
        /// 在目标那里、或读不到：发 ⌘V。
        case clear
        /// 在第三个 App（pid）那里：不发。
        case heldBy(pid_t)
        /// 等到上限还在 Baobox 自己这儿：不发。
        case stillOurs
    }

    /// 快速入口的动作要发 ⌘V 之前调（只有从快速入口来的粘贴调；全局快捷键、剪贴板面板的粘贴不调）：
    /// 读一次辅助功能的系统键盘焦点，在目标那里（或读不到）→ `.clear`；在 Baobox 自己这儿 → 每 15 ms 再看，
    /// 最多等到这次等焦点的上限（至少再看一次）；在第三个 App 那里 → `.heldBy`。
    /// 不发回执：调用方确认内容在剪贴板上之后调 `postBlockedReceipt`。
    /// - Parameter target: 要粘进的 App；nil = 粘给前台。
    static func checkKeyboardBeforePaste(target: NSRunningApplication?,
                                         completion: @escaping @MainActor (KeyboardCheck) -> Void) {
        let deadline = max(focusDeadline, uptime() + pollInterval)
        let targetPID = (target ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier
        func check() {
            let read = readKeyboardFocus()
            let keyboard = read.pid
            let decision = LauncherKeyboardGate.decide(keyboardPID: keyboard, holderIsRegular: isRegularApp(pid: keyboard),
                                                       targetPID: targetPID,
                                                       ownPID: ProcessInfo.processInfo.processIdentifier)
            let result: KeyboardCheck
            switch decision {
            case .paste:
                result = .clear
            case .blocked(let pid):
                result = .heldBy(pid)
            case .waitForSelf:
                guard uptime() >= deadline else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                        MainActor.assumeIsolated { check() }
                    }
                    return
                }
                result = .stillOurs
            }
            log.notice("keyboard check before ⌘V: keyboard (AX) \(bundleID(pid: keyboard), privacy: .public) [\(policyLabel(pid: keyboard), privacy: .public)] (read in \(read.milliseconds, format: .fixed(precision: 1), privacy: .public) ms), front \(bundleID(NSWorkspace.shared.frontmostApplication), privacy: .public), target \(bundleID(pid: targetPID), privacy: .public) → \(String(describing: result), privacy: .public)")
            completion(result)
        }
        check()
    }

    static func checkKeyboardBeforePaste(target: NSRunningApplication?) async -> KeyboardCheck {
        await withCheckedContinuation { continuation in
            checkKeyboardBeforePaste(target: target) { continuation.resume(returning: $0) }
        }
    }

    /// 没粘贴的回执（同防休眠开关的回执：宠物开着是宠物气泡，否则系统通知；勿扰时照常显示）。内容已在剪贴板上时才调。
    static func postBlockedReceipt(_ check: KeyboardCheck) {
        let title: String
        var body = ""
        switch check {
        case .clear:
            return
        case .stillOurs:
            title = L("clipboard.paste.copiedNotPasted")
        case .heldBy(let pid):
            let holder = NSRunningApplication(processIdentifier: pid)
            switch LauncherHotkeyConflict.blockedReceipt(
                holderBundleID: holder?.bundleIdentifier,
                confirmedConflict: LauncherHotkeyConflictCheck.confirmedConflictName()) {
            case .hotkeyConflict(let name):
                title = L("launcher.paste.hotkeyConflict \(name)")
                body = L("launcher.paste.notPastedCopied")
            case .keyboardHeld:
                let name = holder?.localizedName ?? holder?.bundleIdentifier ?? "pid \(pid)"
                title = L("launcher.paste.keyboardHeld \(name)")
            }
        }
        NotifyCenter.shared.post(Notice(source: "launcher", level: .ambient, title: title, body: body,
                                        icon: "keyboard", isUserFeedback: true))
    }

    /// 辅助功能读到的系统键盘焦点所在 App 的 pid（没有权限、读不到时为 nil），和这一次读用了多少毫秒。
    /// 不设超时：对系统级元素设超时会改掉本进程**所有**辅助功能调用的默认超时（窗口管理、划词取词、键盘点击都受影响）；
    /// 这一步问的是系统，不是目标 App。到底要多久看日志里的毫秒数。
    static func readKeyboardFocus() -> (pid: pid_t?, milliseconds: Double) {
        guard AXIsProcessTrusted() else { return (nil, 0) }
        let start = uptime()
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value)
        let milliseconds = (uptime() - start) * 1000
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, milliseconds) }
        var pid: pid_t = 0
        guard AXUIElementGetPid(unsafeBitCast(value, to: AXUIElement.self), &pid) == .success else { return (nil, milliseconds) }
        return (pid, milliseconds)
    }

    /// 这个 pid 的 App 是不是普通的 Dock App；找不到这个 App（或 pid 为 nil）时为 nil。
    private static func isRegularApp(pid: pid_t?) -> Bool? {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.activationPolicy == .regular
    }

    // MARK: - 日志

    /// 日志里拿键盘的 App 是哪一类：regular / accessory / prohibited / unknown。
    private static func policyLabel(pid: pid_t?) -> String {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return "unknown" }
        switch app.activationPolicy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "other"
        }
    }

    /// 日志里的 App：bundle id（没有就写 pid），nil 写 "nil"。不记名字以外的东西。
    static func bundleID(_ app: NSRunningApplication?) -> String {
        guard let app else { return "nil" }
        return app.bundleIdentifier ?? "pid \(app.processIdentifier)"
    }

    static func bundleID(pid: pid_t?) -> String {
        guard let pid else { return "nil" }
        if pid == ProcessInfo.processInfo.processIdentifier { return "self" }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
    }

    private static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func milliseconds(since start: TimeInterval) -> Double {
        (uptime() - start) * 1000
    }
}
