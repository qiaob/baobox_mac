import AppKit
import SwiftUI

/// 语音听写模块壳（issue #45，docs/dictation/）：菜单、快捷键、设置 Tab；逻辑都在 DictationController。
@MainActor
final class DictationTool: ToolModule {
    let id = "dictation"
    let name = L("dictation.name")
    let symbolName = "waveform.and.mic"

    static let holdHotkeyID = "dictation.hold"
    static let toggleHotkeyID = "dictation.toggle"
    static let longHotkeyID = "dictation.long"

    private var controller: DictationController { .shared }

    /// 只读内存状态，零磁盘 IO。
    func submenuItems() -> [NSMenuItem] {
        let controller = self.controller
        let listening = controller.phase != .idle
        let toggleTitle = listening && controller.mode == .toggle ? L("dictation.menu.stop") : L("dictation.menu.start")
        let toggle = ClosureMenuItem(title: toggleTitle, hotkeyID: Self.toggleHotkeyID) {
            controller.toggle()
        }
        let longTitle: String
        if controller.mode == .long, controller.phase == .listening {
            longTitle = L("dictation.menu.longStop")
        } else if controller.collecting {
            longTitle = L("dictation.menu.longResume")
        } else {
            longTitle = L("dictation.menu.long")
        }
        let long = ClosureMenuItem(title: longTitle, hotkeyID: Self.longHotkeyID) {
            controller.toggleLong()
        }
        var items: [NSMenuItem] = [toggle, long, .separator()]
        if controller.hasLastText {
            items.append(ClosureMenuItem(title: L("dictation.menu.copyLast")) {
                controller.copyLast()
            })
        } else {
            // 没有 action 的项自动置灰。
            items.append(NSMenuItem(title: L("dictation.menu.copyLast"), action: nil, keyEquivalent: ""))
        }
        items.append(ClosureMenuItem(title: L("dictation.menu.history")) {
            controller.openHistory()
        })
        return items
    }

    /// 「开始 / 结束听写」出厂绑定 ⌥Space（2026-11-08 用户定：连续听写是主力用法，⌥Space 也是语音输入工具的惯用键；
    /// 被别的 App 的启动器占着时用户在快捷键页改）。另外两个出厂不绑定（仓库惯例：易冲突的组合由用户自设）。
    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: Self.holdHotkeyID,
                title: L("dictation.hotkey.hold"),
                subtitle: L("dictation.hotkey.holdHelp"),
                defaultCombo: nil,
                action: { DictationController.shared.holdPressed() },
                onRelease: { DictationController.shared.holdReleased() }
            ),
            HotkeyDefinition(
                id: Self.toggleHotkeyID,
                title: L("dictation.hotkey.toggle"),
                subtitle: L("dictation.hotkey.toggleHelp"),
                defaultCombo: KeyCombo(keyCode: 0x31, carbonModifiers: KeyCombo.option) // ⌥Space
            ) {
                DictationController.shared.toggle()
            },
            HotkeyDefinition(
                id: Self.longHotkeyID,
                title: L("dictation.hotkey.long"),
                subtitle: L("dictation.hotkey.longHelp"),
                defaultCombo: nil
            ) {
                DictationController.shared.toggleLong()
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(DictationSettingsView())
    }

    func activate() {
        controller.activate()
    }

    func willTerminate() {
        controller.terminate()
    }
}
