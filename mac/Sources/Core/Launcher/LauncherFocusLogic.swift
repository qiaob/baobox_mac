import Foundation

// 快速入口把焦点还给原来的 App 的纯逻辑（docs/launcher/TECH_DESIGN.md §4「焦点」）：什么时候算焦点真的回去了、
// 发 ⌘V 前键盘在哪儿该不该粘、粘贴往哪个 App 粘。只依赖 Foundation，进 BaoboxTests；读系统状态在 `Core/LauncherFocus.swift`。
//
// 背景（2026-11-24 用户真机 + 探针，WindowServer 日志）：不激活 App 的面板（nonactivatingPanel）成为 key 时，
// WindowServer 把它记成 key thief，并记下「上一个 thief」；面板收起时键盘焦点还给的是那个「上一个 thief」，
// 不是前台 App。别的 App 和我们响应同一个快捷键（用户的 Raycast 也是 ⌘Space）时，它先抢了一下又藏起窗口，
// 我们收起后键盘就落到它那里，合成的 ⌘V 也送进了它。我们不为这种状态绕路（不去强切前台）：
// 读得出键盘在第三个 App 那里就不发 ⌘V、说清原因，让用户只留一个 App 用这个快捷键（§9）。

/// 等焦点时看一眼的系统状态。pid 用 `pid_t`（Foundation 里就有）。
struct LauncherFocusSnapshot: Equatable {
    /// `NSWorkspace.frontmostApplication` 的 pid。
    var frontmostPID: pid_t?
    /// 要把焦点还给的 App（呼出前的前台 App）。
    var targetPID: pid_t
    /// Baobox 自己。
    var ownPID: pid_t
    /// Baobox 此刻有没有 key 窗口（快速入口的面板收起后应当没有；不激活 App 的面板是 key 时这里是 true）。
    var ownWindowIsKey: Bool
    /// 辅助功能读到的系统键盘焦点所在 App（`AXFocusedApplication`）；没有权限、读不到时为 nil（= 不拿它判断）。
    var keyboardPID: pid_t?
    /// 拿着键盘的那个 App 是不是普通的 Dock App（`activationPolicy == .regular`）；找不到这个 App 时为 nil。
    /// 只有**不是**普通 App 的（Raycast、Alfred 这类菜单栏 / 后台 App）才算「键盘被占着」：
    /// 前台 App 和实际拿键盘的进程不是同一个 pid 的正常情况（某些壳 App）不能挡。
    var keyboardHolderIsRegular: Bool? = nil
}

/// 某一刻焦点回去了没有。
enum LauncherFocusVerdict: Equatable {
    /// 前台是目标、我们的面板不是 key、键盘（读得到的话）也在目标那里。
    case ready
    /// 还没回去（前台还不是目标、我们的面板还是 key、键盘还在我们这儿）。
    case waiting
    /// 前台是目标、我们也让开了，键盘却在第三个 App 那里（别的 App 留下的 key thief）。
    case heldElsewhere(pid_t)

    static func of(_ snapshot: LauncherFocusSnapshot) -> LauncherFocusVerdict {
        guard !snapshot.ownWindowIsKey, snapshot.frontmostPID == snapshot.targetPID else { return .waiting }
        switch LauncherKeyboardGate.decide(keyboardPID: snapshot.keyboardPID, holderIsRegular: snapshot.keyboardHolderIsRegular,
                                           targetPID: snapshot.targetPID, ownPID: snapshot.ownPID) {
        case .paste: return .ready
        case .waitForSelf: return .waiting
        case .blocked(let pid): return .heldElsewhere(pid)
        }
    }
}

/// 收起面板后等焦点回到原来的 App：每 15 ms 看一次（`LauncherFocus` 调 `step`），最多 300 ms。
/// 连着两次看到键盘在第三个 App 那里就不等了（它不会自己还回来）：照样执行动作，粘贴那一步会读到它、不发 ⌘V。
struct LauncherFocusWait {
    enum Outcome: String, Equatable {
        /// 焦点回去了。
        case returned
        /// 前台回去了，键盘却在第三个 App 那里。
        case heldElsewhere
        /// 等满了没回去。
        case timedOut
    }

    enum Step: Equatable {
        case keepWaiting
        case finish(Outcome)
    }

    static let timeout: TimeInterval = 0.3
    /// 连着几次看到「键盘在第三个 App 那里」才算数（一次可能只是系统还没处理完）。
    static let heldElsewhereConfirmations = 2

    let deadline: TimeInterval
    private(set) var heldElsewhereCount = 0

    init(start: TimeInterval) {
        deadline = start + Self.timeout
    }

    mutating func step(_ snapshot: LauncherFocusSnapshot, now: TimeInterval) -> Step {
        switch LauncherFocusVerdict.of(snapshot) {
        case .ready:
            return .finish(.returned)
        case .heldElsewhere:
            heldElsewhereCount += 1
            if heldElsewhereCount >= Self.heldElsewhereConfirmations { return .finish(.heldElsewhere) }
        case .waiting:
            heldElsewhereCount = 0
        }
        return now >= deadline ? .finish(.timedOut) : .keepWaiting
    }
}

/// 快速入口的动作要发 ⌘V（剪贴板粘贴、`TextInserter` 的粘贴那条路）之前，看系统键盘焦点在哪儿。
enum LauncherKeyboardGate: Equatable {
    /// 在目标那里（或读不到）：照常粘贴。
    case paste
    /// 还在 Baobox 自己这儿：再等一小会儿（并进等焦点的上限）。
    case waitForSelf
    /// 在第三个**不是普通 Dock App** 的 App（Raycast、Alfred 这类菜单栏 / 后台 App）那里：不发 ⌘V（否则内容粘进那个 App），
    /// 内容留在剪贴板，回执说清原因。
    case blocked(pid_t)

    /// - Parameters:
    ///   - holderIsRegular: 拿着键盘的 App 是不是普通 Dock App；nil = 找不到这个 App。是普通 App、或找不到时照常粘贴
    ///     （前台 App 和实际拿键盘的进程不是同一个 pid 的正常情况不能挡）。
    ///   - targetPID: 要粘进的 App；nil = 没有目标（粘给前台，此时只防「键盘在我们自己这儿」）。
    static func decide(keyboardPID: pid_t?, holderIsRegular: Bool?, targetPID: pid_t?, ownPID: pid_t) -> LauncherKeyboardGate {
        guard let keyboard = keyboardPID else { return .paste }
        if keyboard == ownPID { return .waitForSelf }
        if let targetPID, keyboard != targetPID, holderIsRegular == false { return .blocked(keyboard) }
        return .paste
    }
}

/// 「正在执行的快速入口动作」的上下文（目标 App 等）：只在 `run` 包着的那一段闭包**同步**执行时看得到，闭包一返回就清掉。
/// 闭包里排到之后的异步步骤读不到 —— 要用就在闭包里同步读走；全局快捷键、剪贴板面板、听写这些别的途径于是不可能读到它。
/// 嵌套时退出内层恢复外层。只在主线程用（`LauncherFocus` 持有一个）。
final class LauncherActionScope<Context> {
    private(set) var current: Context?

    func run(_ context: Context, _ body: () -> Void) {
        let outer = current
        current = context
        defer { current = outer }
        body()
    }
}

/// 粘贴往哪个 App 粘（`PasteService.paste`）：显式传入的 → 剪贴板面板呼出时记下的 → 快速入口正在执行的动作的目标。
/// 都没有 = 没有目标（前台是谁就粘给谁；前台是 Baobox 自己时只留复制结果）。
enum LauncherPasteTarget {
    enum Source: String, Equatable {
        case explicit
        case clipboardPanel
        case launcher
        case missing
    }

    static func resolve<App>(explicit: App?, clipboardPanel: App?, launcher: App?) -> (app: App?, source: Source) {
        if let explicit { return (explicit, .explicit) }
        if let clipboardPanel { return (clipboardPanel, .clipboardPanel) }
        if let launcher { return (launcher, .launcher) }
        return (nil, .missing)
    }

    /// 这次粘贴算不算「从快速入口来的」（要看键盘、粘不出去要回执）：进门那一刻正在快速入口动作的闭包里，
    /// 且目标不是剪贴板面板记下的（剪贴板面板开着时那是它自己的粘贴）。
    static func isFromLauncher(inLauncherAction: Bool, source: Source) -> Bool {
        inLauncherAction && source != .clipboardPanel
    }

    /// 一次粘贴往哪儿粘、目标从哪儿来、算不算快速入口来的。
    struct Choice<App> {
        let app: App?
        let source: Source
        let fromLauncher: Bool
    }

    /// `PasteService.paste` 进门同步调一次，后面的异步步骤只用它的结果。
    /// - Parameters:
    ///   - inLauncherAction: 进门那一刻是不是正在快速入口动作的闭包里（`LauncherFocus.actionContext != nil`）。
    ///     不在的话（全局快捷键、剪贴板面板、菜单）`launcher` 一律不用 —— 快速入口的目标在闭包外不起作用。
    ///   - launcher: 那个动作的目标（呼出前的前台 App；已经退出时为 nil）。
    static func choose<App>(explicit: App?, clipboardPanel: App?, inLauncherAction: Bool, launcher: App?) -> Choice<App> {
        let resolved = resolve(explicit: explicit, clipboardPanel: clipboardPanel, launcher: inLauncherAction ? launcher : nil)
        return Choice(app: resolved.app, source: resolved.source,
                      fromLauncher: isFromLauncher(inLauncherAction: inLauncherAction, source: resolved.source))
    }
}

extension LauncherPasteTarget.Choice: Equatable where App: Equatable {}
