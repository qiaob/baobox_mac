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
        controller.terminate()
        OfflineTranslator.shared.shutdown()
        OfflineTranslator.corrector.shutdown()
    }

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let toggleTitle = controller.isRunning ? L("livetranslate.menu.stop") : L("livetranslate.menu.start")
        items.append(ClosureMenuItem(title: toggleTitle, hotkeyID: "livetranslate.toggle") { [weak self] in
            self?.controller.toggle()
        })
        // 最近一次的本地记录（只看内存里的状态，菜单构建不碰磁盘）。
        if let transcript = controller.lastTranscript, transcript.hasContent {
            let url = transcript.fileURL
            items.append(ClosureMenuItem(title: L("livetranslate.record.openLatest")) {
                NSWorkspace.shared.open(url)
            })
        }
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

        // 说话语言（单选）：自动（两种之间逐句判别）+ 常用几种 + 当前选中的（完整列表在设置页）。
        items.append(NSMenuItem(title: L("livetranslate.menu.languageHeader"), action: nil, keyEquivalent: ""))
        let currentSpeech = LiveTranslateSettings.speech
        let autoSpeech = LiveTranslateSpeech.auto(LiveTranslateSettings.autoA, LiveTranslateSettings.autoB)
        let autoItem = ClosureMenuItem(title: autoSpeech.title) { [weak self] in
            guard LiveTranslateSettings.speech != autoSpeech else { return }
            LiveTranslateSettings.setAutoSpeech()
            self?.controller.restartIfRunning()
        }
        autoItem.state = currentSpeech == autoSpeech ? .on : .off
        items.append(autoItem)
        var spoken = TranslationLanguage.common
        if case .fixed(let current) = currentSpeech, !spoken.contains(current) {
            spoken.append(current)
        }
        for language in spoken {
            let item = ClosureMenuItem(title: language.endonym) { [weak self] in
                guard LiveTranslateSettings.speech != .fixed(language) else { return }
                LiveTranslateSettings.setSpeech(language)
                self?.controller.restartIfRunning()
            }
            item.state = currentSpeech == .fixed(language) ? .on : .off
            items.append(item)
        }
        items.append(.separator())

        // 译成（单选，开着翻译时才有）。
        let translates = LiveTranslateSettings.translateEnabled
        if translates {
            items.append(NSMenuItem(title: L("livetranslate.menu.targetHeader"), action: nil, keyEquivalent: ""))
            let currentTarget = LiveTranslateSettings.target
            var targets = TranslationLanguage.common
            if !targets.contains(currentTarget) {
                targets.append(currentTarget)
            }
            for language in targets {
                let item = ClosureMenuItem(title: language.endonym) { [weak self] in
                    guard LiveTranslateSettings.target != language else { return }
                    LiveTranslateSettings.target = language
                    self?.controller.restartIfRunning()
                }
                item.state = language == currentTarget ? .on : .off
                items.append(item)
            }
            items.append(.separator())
        }

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
