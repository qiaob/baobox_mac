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
        guard let keyboard = snapshot.keyboardPID, keyboard != snapshot.targetPID else { return .ready }
        return keyboard == snapshot.ownPID ? .waiting : .heldElsewhere(keyboard)
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
    /// 在第三个 App 那里：不发 ⌘V（否则内容粘进那个 App），内容留在剪贴板，回执说清原因。
    case blocked(pid_t)

    /// - Parameter targetPID: 要粘进的 App；nil = 没有目标（粘给前台，此时只防「键盘在我们自己这儿」）。
    static func decide(keyboardPID: pid_t?, targetPID: pid_t?, ownPID: pid_t) -> LauncherKeyboardGate {
        guard let keyboard = keyboardPID else { return .paste }
        if keyboard == ownPID { return .waitForSelf }
        if let targetPID, keyboard != targetPID { return .blocked(keyboard) }
        return .paste
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
}
