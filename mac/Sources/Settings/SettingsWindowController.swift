import AppKit
import SwiftUI

/// 设置窗口控制器。
///
/// macOS 14 起 Apple 移除了用 `NSApp.sendAction(Selector(("showSettingsWindow:")))`
/// 打开 SwiftUI `Settings` scene 的能力，官方替代品 `SettingsLink` 与
/// `@Environment(\.openSettings)` 都只能在 SwiftUI 视图层级里取得，
/// 拿不到 AppKit 菜单回调的上下文。菜单栏 App 因此自己持有窗口，行为完全可控。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {}

    /// 打开设置窗口并切到指定 Tab；tab 为 nil 时保持当前选中项。
    func show(registry: ToolRegistry, tab: String?) {
        if let tab { SettingsTabSelection.shared.selectedTab = tab }

        // 从全屏 App 里打开时别叠在全屏窗口上、永远盖着它：开着期间当普通 App。
        // 必须在创建窗口之前切 —— 窗口按创建时 App 的身份决定会不会叠进全屏空间（见 AppWindowActivation）。
        AppWindowActivation.becomeRegular()

        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            let hosting = NSHostingController(rootView: SettingsView(registry: registry))
            let created = NSWindow(contentViewController: hosting)
            created.title = L("settings.window.title")
            created.styleMask = [.titled, .closable]
            // 释放由我们管（关窗后下一拍放掉）：默认的 close 即释放会在关闭过程中把窗口放掉。
            created.isReleasedWhenClosed = false
            created.center()
            created.delegate = self
            self.window = created
            window = created
        }
        AppWindowActivation.windowDidShow(window)
        // LSUIElement 应用默认不激活，不主动激活则窗口会出现在其他 App 之后。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 关窗：切回菜单栏 App，并放掉这个窗口 —— 下次打开时先切成普通 App 再重建（复用 `.accessory` 时期的窗口会叠进全屏空间）。
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        AppWindowActivation.windowWillClose(closing)
        // 还在这个窗口自己的关闭过程里：下一拍再放，别在关闭途中把它释放掉。
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if SettingsWindowController.shared.window === closing {
                    SettingsWindowController.shared.window = nil
                }
            }
        }
    }
}
