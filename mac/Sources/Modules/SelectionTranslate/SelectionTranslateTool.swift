import AppKit
import SwiftUI

extension AIFeature {
    /// 划词翻译用哪个引擎 / 模型（docs/ai-service/DESIGN.md §3.3）。新键没值时读旧的共用键 `translation.engine`。
    static let selectionTranslate = AIFeature(id: "selectiontranslate.translate", kind: .translation,
                                              legacyKey: TranslationSettings.legacyEngineKey)
}

extension AIFeatureDefinition {
    static var selectionTranslate: AIFeatureDefinition {
        AIFeatureDefinition(feature: .selectionTranslate, title: L("selectiontranslate.ai.translate"),
                            sends: L("selectiontranslate.ai.translateSends"))
    }
}

/// 划词翻译模块壳：全系统选中文字 → 就地浮层翻译 + 朗读。
/// 设计见 docs/selection-translate/DESIGN.md。
@MainActor
final class SelectionTranslateTool: ToolModule {
    let id = "selectiontranslate"
    let name = L("selectiontranslate.name")
    let symbolName = "character.bubble"

    private var controller: SelectionTranslateController { .shared }

    func submenuItems() -> [NSMenuItem] {
        let translate = ClosureMenuItem(title: L("selectiontranslate.menu.translate"),
                                        hotkeyID: "selectiontranslate.translateSelection") { [weak self] in
            self?.controller.translateSelection(manual: true)
        }
        let region = ClosureMenuItem(title: L("selectiontranslate.menu.regionOCR"),
                                     hotkeyID: "selectiontranslate.regionOCR") { [weak self] in
            self?.controller.translateRegion()
        }
        let autoPopup = ClosureMenuItem(title: L("selectiontranslate.menu.autoPopup")) { [weak self] in
            SelectionTranslateSettings.autoPopup.toggle()
            self?.controller.refreshEventTap()
        }
        autoPopup.state = SelectionTranslateSettings.autoPopup ? .on : .off
        return [translate, region, .separator(), autoPopup]
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "selectiontranslate.translateSelection",
                title: L("selectiontranslate.hotkey.translate"),
                subtitle: L("selectiontranslate.hotkey.translate.subtitle"),
                defaultCombo: nil // 易与各 App 内快捷键冲突，出厂不绑定（仓库惯例）
            ) { [weak self] in
                self?.controller.translateSelection(manual: true)
            },
            HotkeyDefinition(
                id: "selectiontranslate.regionOCR",
                title: L("selectiontranslate.hotkey.regionOCR"),
                subtitle: L("selectiontranslate.hotkey.regionOCR.subtitle"),
                defaultCombo: nil
            ) { [weak self] in
                self?.controller.translateRegion()
            }
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(SelectionTranslateSettingsView())
    }

    func aiFeatures() -> [AIFeatureDefinition] {
        [.selectionTranslate]
    }

    func activate() {
        controller.activate()
    }

    func willTerminate() {
        controller.stopAll()
    }
}
