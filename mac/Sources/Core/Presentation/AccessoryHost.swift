import AppKit

/// 能让别的模块把小浮窗挂上去的地方（目前是桌面宠物的头顶，docs/notify-core/DESIGN.md §3.4）。一次挂一个。
/// 模块用 `ToolModule.presentationRoles()` 交出来，框架在启动时装进 `PresentationHub`；浮窗经 `AccessoryDock` 找它，不认识提供者。
@MainActor
protocol AccessoryHost: AnyObject {
    /// 挂上：能挂就挂成子窗口并贴好位置，不能挂就先不挂。挂上、摘下都回调 `onChange(挂着没有)`：
    /// 登记时当场先回调一次，之后状态变了（宠物开关、借出归还、出场退场）再回调。没挂着时，位置由浮窗自己摆。
    func dock(_ window: NSWindow, onChange: @escaping (Bool) -> Void)
    /// 摘下来、不再跟着。不回调，调用方自己收起窗口。传进来的不是当前挂件就什么也不做。
    func undock(_ window: NSWindow)
    /// 浮窗换了大小（`size`），或者自己重新排过一次（orderOut 会把子窗口摘掉）：重新挂好、贴位。不是当前挂件就忽略。
    func refresh(_ window: NSWindow, size: CGSize?)
}

/// 浮窗找挂靠点的入口，本身没有状态。没有挂靠点（宠物模块没注册）时，`dock` 当场回调 false，其余什么也不做 ——
/// 浮窗照「宠物关着」的样子自己摆。
@MainActor
enum AccessoryDock {
    /// 挂到挂靠点上，挂靠点的回调原样转给 `onChange`。没有挂靠点就当场同步回调 false（同宠物关着时），不等下一拍。
    static func dock(_ window: NSWindow, onChange: @escaping (Bool) -> Void) {
        guard let host = PresentationHub.shared.accessories else {
            onChange(false)
            return
        }
        host.dock(window, onChange: onChange)
    }

    /// 摘下来，不回调。没有挂靠点时什么也不做。
    static func undock(_ window: NSWindow) {
        PresentationHub.shared.accessories?.undock(window)
    }

    /// 换了大小或重新排过窗口后重新挂好、贴位。没有挂靠点时什么也不做（那时浮窗从没挂上过）。
    static func refresh(_ window: NSWindow, size: CGSize? = nil) {
        PresentationHub.shared.accessories?.refresh(window, size: size)
    }
}
