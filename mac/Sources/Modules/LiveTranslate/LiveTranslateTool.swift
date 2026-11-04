import AppKit
import SwiftUI

/// 实时翻译模块壳：麦克风 / 系统声音 → 语音识别 → 英中互译 → 屏幕字幕条。
/// 见 docs/live-translate/DESIGN.md。
@MainActor
final class LiveTranslateTool: ToolModule {
    let id = "livetranslate"
    let name = L("livetranslate.name")
    let symbolName = "captions.bubble"

    private var controller: LiveTranslateController { LiveTranslateController.shared }

    func willTerminate() {
        controller.stop()
    }

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let toggleTitle = controller.isRunning ? L("livetranslate.menu.stop") : L("livetranslate.menu.start")
        items.append(ClosureMenuItem(title: toggleTitle, hotkeyID: "livetranslate.toggle") { [weak self] in
            self?.controller.toggle()
        })
        items.append(.separator())

        // 音源（单选）。
        items.append(NSMenuItem(title: L("livetranslate.menu.sourceHeader"), action: nil, keyEquivalent: ""))
        let currentSource = LiveTranslateSettings.source
        for source in LiveTranslateSource.allCases {
            let item = ClosureMenuItem(title: source.title) { [weak self] in
                guard LiveTranslateSettings.source != source else { return }
                LiveTranslateSettings.source = source
                self?.controller.restartIfRunning()
            }
            item.state = source == currentSource ? .on : .off
            items.append(item)
        }
        items.append(.separator())

        // 语言方向（单选）。
        items.append(NSMenuItem(title: L("livetranslate.menu.languageHeader"), action: nil, keyEquivalent: ""))
        let currentLanguage = LiveTranslateSettings.language
        let translates = LiveTranslateSettings.translateEnabled
        for language in LiveTranslateLanguage.allCases {
            let title = translates
                ? "\(language.displayName) → \(language.other.displayName)"
                : language.displayName
            let item = ClosureMenuItem(title: title) { [weak self] in
                guard LiveTranslateSettings.language != language else { return }
                LiveTranslateSettings.language = language
                self?.controller.restartIfRunning()
            }
            item.state = language == currentLanguage ? .on : .off
            items.append(item)
        }
        items.append(.separator())

        let translateItem = ClosureMenuItem(title: L("livetranslate.menu.translate")) { [weak self] in
            LiveTranslateSettings.translateEnabled.toggle()
            self?.controller.restartIfRunning()
        }
        translateItem.state = translates ? .on : .off
        items.append(translateItem)

        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "livetranslate.toggle",
                title: L("livetranslate.hotkey.toggle"),
                subtitle: L("livetranslate.hotkey.toggle.subtitle"),
                // 易冲突组合出厂不绑定（仓库惯例），在快捷键页自设。
                defaultCombo: nil
            ) {
                LiveTranslateController.shared.toggle()
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(LiveTranslateSettingsView())
    }

    func activate() {
        // 无后台服务：音源与识别只在用户开启后才启动。
    }
}
