import AppKit
import SwiftUI

/// AI 编程助手组合模块壳：将「Claude Code 助手」与「Codex 助手」收拢为一个一级菜单与设置 Tab。
/// 两个都已安装时二级菜单分成两个干净子菜单；仅装了一个时直接平铺已安装项（零额外层级）；所有快捷键、设置键与快速入口命令不变。
@MainActor
final class CodingAssistantsTool: ToolModule {
    let id = "codingassistants"
    let name = L("codingassistants.name")
    let symbolName = "terminal"

    private let claude = ClaudeCodeTool()
    private let codex = AIToolsTool()

    func submenuItems() -> [NSMenuItem] {
        let hasClaude = ClaudeEnv.isInstalled
        let hasCodex = CodexEnv.isInstalled

        if hasClaude && hasCodex {
            return [
                submenuEntry(title: claude.name, symbolName: claude.symbolName, items: claude.submenuItems()),
                submenuEntry(title: codex.name, symbolName: codex.symbolName, items: codex.submenuItems()),
            ]
        }
        if hasClaude {
            var items = claude.submenuItems()
            items.append(.separator())
            items.append(disabled(L("aitools.menu.notInstalled")))
            return items
        }
        if hasCodex {
            var items = codex.submenuItems()
            items.append(.separator())
            items.append(disabled(L("claudecode.menu.notInstalled")))
            return items
        }
        return [
            disabled(L("claudecode.menu.notInstalled")),
            disabled(L("aitools.menu.notInstalled")),
        ]
    }

    func hotkeys() -> [HotkeyDefinition] {
        claude.hotkeys() + codex.hotkeys()
    }

    func settingsTab() -> AnyView {
        AnyView(CodingAssistantsSettingsView())
    }

    func activate() {
        claude.activate()
        codex.activate()
    }

    func willTerminate() {
        claude.willTerminate()
        codex.willTerminate()
    }

    func statusMenuHeaderItems() -> [NSMenuItem] {
        claude.statusMenuHeaderItems() + codex.statusMenuHeaderItems()
    }

    func aiFeatures() -> [AIFeatureDefinition] {
        claude.aiFeatures() + codex.aiFeatures()
    }

    func launcherCommands() -> [LauncherCommand] {
        claude.launcherCommands() + codex.launcherCommands()
    }

    func launcherSources() -> [any LauncherSearchable] {
        claude.launcherSources() + codex.launcherSources()
    }

    func launcherFileRoots() -> [String] {
        claude.launcherFileRoots() + codex.launcherFileRoots()
    }

    func launcherKnownFiles() -> [LauncherKnownFile] {
        claude.launcherKnownFiles() + codex.launcherKnownFiles()
    }

    func launcherContextSuggestions() -> [LauncherCommand] {
        claude.launcherContextSuggestions() + codex.launcherContextSuggestions()
    }

    // MARK: 辅助

    private func submenuEntry(title: String, symbolName: String, items: [NSMenuItem]) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            entry.image = image
        }
        let submenu = NSMenu()
        submenu.autoenablesItems = true
        for child in items {
            StatusItemController.showHotkeyIfTagged(child)
            submenu.addItem(child)
        }
        entry.submenu = submenu
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// AI 编程助手设置页：顶部分段切换「Claude Code」与「Codex」，默认优先选已安装的那个。
struct CodingAssistantsSettingsView: View {
    private enum Pane: Hashable {
        case claude, codex
    }

    @State private var pane: Pane = (!ClaudeEnv.isInstalled && CodexEnv.isInstalled) ? .codex : .claude

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $pane) {
                Text("claudecode.name").tag(Pane.claude)
                Text("aitools.name").tag(Pane.codex)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider()

            switch pane {
            case .claude:
                ClaudeCodeSettingsView()
            case .codex:
                AIToolsSettingsView()
            }
        }
    }
}
