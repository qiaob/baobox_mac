import AppKit
import SwiftUI

/// 键盘点击（对标 Homerow Click Mode）—— ToolModule 壳。
@MainActor
final class KeyboardNavTool: ToolModule {
    let id = "keyboardnav"
    let name = L("keyboardnav.name")
    let symbolName = "cursorarrow.click.2"

    func activate() {}
    func willTerminate() {}

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if !Permissions.hasAccessibility {
            // 未授权：一条置灰引导（action = nil 自动置灰）。
            items.append(NSMenuItem(title: L("keyboardnav.menu.needAccessibility"),
                                    action: nil, keyEquivalent: ""))
        }
        items.append(ClosureMenuItem(title: L("keyboardnav.menu.click"), hotkeyID: "keyboardnav.click") {
            KeyboardNavController.shared.activate()
        })
        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "keyboardnav.click",
                title: L("keyboardnav.hotkey.click"),
                subtitle: L("keyboardnav.hotkey.click.subtitle"),
                // Homerow 官方默认 ⌘⇧Space（Command-Shift-Space）；keyCode 0x31 = Space。
                defaultCombo: KeyCombo(keyCode: 0x31, carbonModifiers: KeyCombo.cmd | KeyCombo.shift)
            ) {
                KeyboardNavController.shared.activate()
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(KeyboardNavSettingsView())
    }
}

/// 最简设置页：说明 + 快捷键提示（字符集/忽略应用等 P1 再加）。
private struct KeyboardNavSettingsView: View {
    @AppStorage(KeyboardNavEnv.labelScopeKey) private var labelScope = "current"

    var body: some View {
        Form {
            SwiftUI.Section("keyboardnav.settings.section") {
                Picker("keyboardnav.settings.labelScope", selection: $labelScope) {
                    Text("keyboardnav.settings.scopeCurrent").tag("current")
                    Text("keyboardnav.settings.scopeAll").tag("all")
                }
                Text("keyboardnav.settings.hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
