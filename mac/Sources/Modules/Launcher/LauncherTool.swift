import AppKit
import SwiftUI

/// 快速入口（docs/launcher/）：一个快捷键呼出输入框，搜 App 和 Baobox 的命令，回车执行。
/// 菜单只有一行「打开快速入口」；快捷键出厂不绑定，在设置页或快捷键页录。注册在第一个（它是总入口）。
@MainActor
final class LauncherTool: ToolModule {
    static let toggleHotkeyID = "launcher.toggle"

    let id = "launcher"
    let name = L("launcher.name")
    let symbolName = "magnifyingglass"

    private let controller: LauncherController

    /// 命令表从注册表里收（同设置的快捷键页：注册表由外面传进来）。
    init(registry: ToolRegistry) {
        controller = LauncherController(registry: registry)
    }

    func submenuItems() -> [NSMenuItem] {
        [ClosureMenuItem(title: L("launcher.menu.open"), hotkeyID: Self.toggleHotkeyID) { [weak self] in
            self?.controller.show()
        }]
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: Self.toggleHotkeyID,
                title: L("launcher.hotkey.toggle"),
                subtitle: L("launcher.hotkey.toggle.subtitle"),
                defaultCombo: nil,
                action: { [weak self] in self?.controller.toggle() }
            )
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(LauncherSettingsView())
    }

    func activate() {
        controller.activate()
    }

    func willTerminate() {
        controller.willTerminate()
    }
}
