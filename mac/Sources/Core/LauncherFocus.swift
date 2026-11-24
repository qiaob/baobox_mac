import AppKit

/// 快速入口呼出前的前台 App（docs/launcher/TECH_DESIGN.md §4）。
///
/// 面板拿着键盘焦点时原来的窗口不再是 key，收起后系统不保证把焦点还回去：粘贴用的 ⌘V、插入的文字就没送到原来的窗口
/// （2026-11-24 用户实测：从快速入口粘贴剪贴板条目，原窗口收不到）。做法同剪贴板面板的 `previousApp`：
/// 呼出前记下前台 App，执行动作 / 按 Esc 收起后显式切回它；要往「原来的 App」里粘贴、插入的动作拿它当目标。
/// 放在 Core 而不是快速入口模块里：别的模块交给快速入口的动作（剪贴板的粘贴）也要读它。
@MainActor
enum LauncherFocus {
    /// 呼出快速入口那一刻的前台 App；当时前台就是 Baobox 自己（比如从设置窗口里呼出）则为 nil。
    private(set) static var previousApp: NSRunningApplication?

    /// 必须在面板拿焦点之前调。
    static func capture() {
        let app = NSWorkspace.shared.frontmostApplication
        previousApp = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    }

    /// 把焦点还给呼出前的 App。它已经退出、或当时前台是 Baobox 自己时什么都不做。
    static func restore() {
        guard let app = previousApp, !app.isTerminated else { return }
        app.activate()
    }
}
