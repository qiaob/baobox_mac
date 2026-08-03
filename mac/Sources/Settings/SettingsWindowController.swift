import AppKit
import SwiftUI

/// 设置窗口控制器。
///
/// macOS 14 起 Apple 移除了用 `NSApp.sendAction(Selector(("showSettingsWindow:")))`
/// 打开 SwiftUI `Settings` scene 的能力，官方替代品 `SettingsLink` 与
/// `@Environment(\.openSettings)` 都只能在 SwiftUI 视图层级里取得，
/// 拿不到 AppKit 菜单回调的上下文。菜单栏 App 因此自己持有窗口，行为完全可控。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    /// 打开设置窗口并切到指定 Tab；tab 为 nil 时保持当前选中项。
    func show(registry: ToolRegistry, tab: String?) {
        if let tab { SettingsTabSelection.shared.selectedTab = tab }

        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(registry: registry))
            let created = NSWindow(contentViewController: hosting)
            created.title = L("settings.window.title")
            created.styleMask = [.titled, .closable]
            // 关闭窗口后复用同一实例，避免默认的 close 即释放导致再次打开时崩溃。
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }

        // LSUIElement 应用默认不激活，不主动激活则窗口会出现在其他 App 之后。
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
