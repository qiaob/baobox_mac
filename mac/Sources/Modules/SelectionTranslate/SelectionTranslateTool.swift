import AppKit
import SwiftUI

extension AIFeature {
    /// 划词翻译用哪个引擎 / 模型（docs/ai-service/DESIGN.md §3.3）。新键没值时读旧的共用键 `translation.engine`。
    static let selectionTranslate = AIFeature(id: "selectiontranslate.translate", kind: .translation,
                                              legacyKey: TranslationSettings.legacyEngineKey)
    /// 划词助手的 AI 动作（润色、改写、地道英文、解释、总结、自定义）用哪个模型；出厂本地
    /// （docs/selection-translate/ASSISTANT.md §1.6）。
    static let selectionActions = AIFeature(id: "selectiontranslate.actions", kind: .generation)
}

extension AIFeatureDefinition {
    static var selectionTranslate: AIFeatureDefinition {
        AIFeatureDefinition(feature: .selectionTranslate, title: L("selectiontranslate.ai.translate"),
                            sends: L("selectiontranslate.ai.translateSends"))
    }

    static var selectionActions: AIFeatureDefinition {
        // 有人等着结果：建议最快的。
        AIFeatureDefinition(feature: .selectionActions, title: L("selectiontranslate.ai.actions"),
                            sends: L("selectiontranslate.ai.actionsSends"), advice: .fastest)
    }
}

/// 划词助手模块壳：全系统选中文字 → 动作条（翻译 · 学习 · 润色 · 改写 · 地道英文 · 解释 · 总结 · 自定义）。
/// 设计见 docs/selection-translate/DESIGN.md（取词、翻译、浮层）与 ASSISTANT.md（动作条、AI 动作、学习）。
/// 模块 id、快捷键 id、设置键沿用 `selectiontranslate.*`（改名前的设置和快捷键不受影响）。
@MainActor
final class SelectionTranslateTool: ToolModule {
    let id = "selectiontranslate"
    let name = L("selectiontranslate.name")
    let symbolName = "character.bubble"

    private var controller: SelectionTranslateController { .shared }

    func submenuItems() -> [NSMenuItem] {
        let actions = ClosureMenuItem(title: L("selectiontranslate.menu.showActions"),
                                      hotkeyID: "selectiontranslate.showActions") { [weak self] in
            self?.controller.showActionsByKeyboard()
        }
        let translate = ClosureMenuItem(title: L("selectiontranslate.menu.translate"),
                                        hotkeyID: "selectiontranslate.translateSelection") { [weak self] in
            self?.controller.translateSelection(manual: true)
        }
        let learn = ClosureMenuItem(title: L("selectiontranslate.menu.learn"),
                                    hotkeyID: SelectionBuiltinAction.learn.hotkeyID) { [weak self] in
            self?.controller.runOnSelection(SelectionBuiltinAction.learn.rawValue)
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
        return [actions, translate, learn, region, .separator(), autoPopup]
    }

    func hotkeys() -> [HotkeyDefinition] {
        // 易与各 App 内快捷键冲突，全部出厂不绑定（仓库惯例）。
        var definitions = [
            HotkeyDefinition(
                id: "selectiontranslate.showActions",
                title: L("selectiontranslate.hotkey.showActions"),
                subtitle: L("selectiontranslate.hotkey.showActions.subtitle"),
                defaultCombo: nil
            ) { [weak self] in
                self?.controller.showActionsByKeyboard()
            },
            HotkeyDefinition(
                id: "selectiontranslate.translateSelection",
                title: L("selectiontranslate.hotkey.translate"),
                subtitle: L("selectiontranslate.hotkey.translate.subtitle"),
                defaultCombo: nil
            ) { [weak self] in
                self?.controller.translateSelection(manual: true)
            }
        ]
        for builtin in SelectionBuiltinAction.allCases where builtin != .translate {
            definitions.append(HotkeyDefinition(
                id: builtin.hotkeyID,
                title: L("selectiontranslate.hotkey.action \(builtin.title)"),
                subtitle: L("selectiontranslate.hotkey.action.subtitle"),
                defaultCombo: nil
            ) { [weak self] in
                self?.controller.runOnSelection(builtin.rawValue)
            })
        }
        definitions.append(HotkeyDefinition(
            id: "selectiontranslate.regionOCR",
            title: L("selectiontranslate.hotkey.regionOCR"),
            subtitle: L("selectiontranslate.hotkey.regionOCR.subtitle"),
            defaultCombo: nil
        ) { [weak self] in
            self?.controller.translateRegion()
        })
        return definitions
    }

    /// 设置页嵌录制控件用（与 `hotkeys()` 的 id 一致）。
    static var hotkeyIDs: [String] {
        ["selectiontranslate.showActions", "selectiontranslate.translateSelection"]
            + SelectionBuiltinAction.allCases.filter { $0 != .translate }.map(\.hotkeyID)
            + ["selectiontranslate.regionOCR"]
    }

    func settingsTab() -> AnyView {
        AnyView(SelectionTranslateSettingsView())
    }

    func aiFeatures() -> [AIFeatureDefinition] {
        [.selectionTranslate, .selectionActions]
    }

    func activate() {
        controller.activate()
    }

    func willTerminate() {
        controller.stopAll()
    }
}
