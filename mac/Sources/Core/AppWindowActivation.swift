import AppKit

/// 普通窗口（设置等）开着时让 Baobox 临时当普通 App。
///
/// Baobox 是菜单栏 App（LSUIElement，`.accessory`）。这类 App 的窗口会被系统放进别的 App 的**全屏空间**当附属窗口：
/// 在全屏的终端里打开设置，设置窗口就叠在全屏窗口上；点回终端它也照样盖着 —— 全屏窗口在自己的空间里永远排最底下，
/// 切换桌面时系统甚至会把前台交给 Baobox。App 是 `.regular` 时系统改为切到桌面空间显示窗口（有 Dock 图标、能 ⌘Tab）。
///
/// 关键（2026-11-08 用 LSUIElement 探针实测）：窗口会不会叠进全屏空间，**按窗口创建那一刻 App 的身份定**。
/// `.accessory` 时建好的窗口，之后切成 `.regular` 再显示也照样叠上去。所以要先 `becomeRegular()` 再创建窗口，
/// 窗口关掉就释放、下次重建，不能复用 `.accessory` 时期建的窗口。
@MainActor
enum AppWindowActivation {
    private static var windows = Set<ObjectIdentifier>()

    /// 普通窗口显示前调用，**必须在创建窗口之前**（见上）。
    static func becomeRegular() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// 窗口显示了（计数用）。
    static func windowDidShow(_ window: NSWindow) {
        windows.insert(ObjectIdentifier(window))
    }

    /// 窗口关闭时调用（`windowWillClose`）。这类窗口全关了就切回 `.accessory`；
    /// 几个一起开着时，关掉其中一个不会提前切回去。
    static func windowWillClose(_ window: NSWindow) {
        windows.remove(ObjectIdentifier(window))
        guard windows.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
