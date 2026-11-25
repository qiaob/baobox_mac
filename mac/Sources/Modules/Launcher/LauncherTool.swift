import AppKit
import SwiftUI

/// 快速入口（docs/launcher/）：一个快捷键呼出输入框，搜 App 和 Baobox 的命令，回车执行。
/// 菜单只有一行「打开快速入口」；快捷键出厂是 ⌘Space（2026-11-24 用户定），在设置页或快捷键页可改。注册在第一个（它是总入口）。
/// ⌘Space 被系统的 Spotlight 占着时注册不上、快捷键页标冲突：在系统设置里关掉 Spotlight 的快捷键后恢复默认即可（docs/launcher/TECH_DESIGN.md §9）。
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
                defaultCombo: KeyCombo(keyCode: 0x31, carbonModifiers: KeyCombo.cmd), // ⌘Space
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
