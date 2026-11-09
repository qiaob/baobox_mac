import SwiftUI

/// 划词助手设置页：选中后弹什么、动作（排序 / 开关 / 自定义）、快捷键、AI 动作引擎、翻译、学习、权限、试用。
/// 见 docs/selection-translate/ASSISTANT.md §2.7。
struct SelectionTranslateSettingsView: View {
    @AppStorage(SelectionTranslateSettings.autoPopupKey) private var autoPopup = true
    @AppStorage(SelectionTranslateSettings.copyFallbackKey) private var copyFallback = true
    @AppStorage(SelectionTranslateSettings.autoSpeakKey) private var autoSpeak = false
    @AppStorage(SelectionTranslateSettings.targetKey)
    private var target = SelectionTranslateSettings.target.code
    @AppStorage(SelectionTranslateSettings.secondaryTargetKey)
    private var secondaryTarget = SelectionTranslateSettings.secondaryTarget.code
    @AppStorage(SelectionAssistantSettings.popupActionKey)
    private var popupAction = SelectionAssistantSettings.PopupAction.bar.rawValue
    @AppStorage(SelectionAssistantSettings.optionDigitsKey) private var optionDigits = true
    @AppStorage(SelectionAssistantSettings.learnNativeKey)
    private var learnNative = SelectionAssistantSettings.learnNative.code
    @AppStorage(SelectionAssistantSettings.learnTargetKey)
    private var learnTarget = SelectionAssistantSettings.learnTarget.code
    @AppStorage(SelectionAssistantSettings.learnAccentKey) private var accent = "us"
    @AppStorage(SelectionAssistantSettings.learnAutoSpeakKey) private var learnAutoSpeak = false

    @State private var actions: [SelectionAction] = SelectionActionStore.all
    /// 正在展开编辑的自定义动作。
    @State private var editingID: String?

    var body: some View {
        Form {
            Section {
                Text("selectiontranslate.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            triggerSection
            actionsSection
            keyboardSection
            aiSection
            translateSection
            learnSection
            permissionSection

            Section {
                HStack(spacing: 10) {
                    Button("selectiontranslate.settings.tryActions") {
                        SelectionTranslateController.shared.showActionsByKeyboard()
                    }
                    Button("selectiontranslate.settings.tryTranslate") {
                        SelectionTranslateController.shared.translateSelection(manual: true)
                    }
                    Button("selectiontranslate.settings.tryRegion") {
                        SelectionTranslateController.shared.translateRegion()
                    }
                }
            } header: {
                Text("selectiontranslate.settings.trySection")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 选中后

    private var triggerSection: some View {
        Section {
            Toggle("selectiontranslate.settings.autoPopup", isOn: $autoPopup)
                .onChange(of: autoPopup) { _, _ in
                    SelectionTranslateController.shared.refreshEventTap()
                }
            Picker("selectiontranslate.settings.popupAction", selection: $popupAction) {
                ForEach(SelectionAssistantSettings.PopupAction.allCases) { action in
                    Text(action.title).tag(action.rawValue)
                }
            }
            .disabled(!autoPopup)
            Text("selectiontranslate.settings.autoPopupHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("selectiontranslate.settings.copyFallback", isOn: $copyFallback)
            Text("selectiontranslate.settings.copyFallbackHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("selectiontranslate.settings.triggerSection")
        }
    }

    // MARK: - 动作

    private var actionsSection: some View {
        Section {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                actionRow(action, index: index)
                if action.isCustom, editingID == action.id {
                    customEditor(index: index)
                }
            }
            HStack {
                Text("selectiontranslate.settings.actionsHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("selectiontranslate.settings.newAction") {
                    let action = SelectionAction.newCustom()
                    actions.append(action)
                    editingID = action.id
                    save()
                }
            }
        } header: {
            Text("selectiontranslate.settings.actionsSection")
        }
    }

    private func actionRow(_ action: SelectionAction, index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { actions[safe: index]?.enabled ?? false },
                set: { value in
                    guard actions.indices.contains(index) else { return }
                    actions[index].enabled = value
                    save()
                }))
                .labelsHidden()
                .disabled(action.builtin == .translate)
            Image(systemName: action.symbolName)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                if let builtin = action.builtin {
                    Text(builtin.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(action.isRewrite ? L("selectiontranslate.settings.kindRewrite")
                 : L("selectiontranslate.settings.kindAnswer"))
                .font(.caption)
                .foregroundStyle(action.isRewrite ? Color.accentColor : Color.secondary)
            if index < 9 {
                Text(verbatim: "⌥\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
            } else {
                Spacer().frame(width: 26)
            }
            Button {
                move(index, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(L("selectiontranslate.settings.moveUp"))
            Button {
                move(index, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == actions.count - 1)
            .help(L("selectiontranslate.settings.moveDown"))
            if action.isCustom {
                Button {
                    editingID = editingID == action.id ? nil : action.id
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help(L("selectiontranslate.settings.editAction"))
                Button(role: .destructive) {
                    actions.removeAll { $0.id == action.id }
                    if editingID == action.id { editingID = nil }
                    save()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L("selectiontranslate.settings.deleteAction"))
            }
        }
    }

    @ViewBuilder
    private func customEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("selectiontranslate.settings.actionName", text: Binding(
                get: { actions[safe: index]?.name ?? "" },
                set: { value in
                    guard actions.indices.contains(index) else { return }
                    actions[index].name = value
                    save()
                }))
            Text("selectiontranslate.settings.actionPrompt")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { actions[safe: index]?.prompt ?? "" },
                set: { value in
                    guard actions.indices.contains(index) else { return }
                    actions[index].prompt = value
                    save()
                }))
                .font(.system(size: 12))
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            Text("selectiontranslate.settings.actionPromptHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("selectiontranslate.settings.actionKind", selection: Binding(
                get: { actions[safe: index]?.replaces ?? true },
                set: { value in
                    guard actions.indices.contains(index) else { return }
                    actions[index].replaces = value
                    save()
                })) {
                Text("selectiontranslate.settings.kindRewriteLong").tag(true)
                Text("selectiontranslate.settings.kindAnswerLong").tag(false)
            }
        }
        .padding(.leading, 24)
    }

    private func move(_ index: Int, by delta: Int) {
        let destination = index + delta
        guard actions.indices.contains(index), actions.indices.contains(destination) else { return }
        actions.swapAt(index, destination)
        save()
    }

    private func save() {
        SelectionActionStore.all = actions
    }

    // MARK: - 键盘

    private var keyboardSection: some View {
        Section {
            Toggle("selectiontranslate.settings.optionDigits", isOn: $optionDigits)
            Text("selectiontranslate.settings.optionDigitsHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            // id 与 SelectionTranslateTool.hotkeys() 一致。
            ModuleHotkeyRows(ids: SelectionTranslateTool.hotkeyIDs)
            Text("selectiontranslate.settings.keyboardHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("settings.tab.hotkeys")
        }
    }

    // MARK: - AI 动作

    private var aiSection: some View {
        Section {
            // 和「AI」页功能表里的「划词助手 · AI 动作」是同一行、同一份设置。
            AIFeatureRow(definition: .selectionActions, showsManage: true)
            Text("selectiontranslate.settings.aiEngineHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("selectiontranslate.settings.aiCloudDisclosure")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OfflineModelRow(translator: .corrector,
                            title: "selectiontranslate.settings.aiModelTitle",
                            notInstalledHelp: "selectiontranslate.settings.aiModelNotInstalled",
                            installedHelp: "selectiontranslate.settings.aiModelInstalled")
        } header: {
            Text("selectiontranslate.settings.aiSection")
        }
    }

    // MARK: - 翻译

    @ViewBuilder
    private var translateSection: some View {
        Section {
            Picker("selectiontranslate.settings.target", selection: $target) {
                ForEach(TranslationLanguage.all) { language in
                    Text(language.endonym).tag(language.code)
                }
            }
            Picker("selectiontranslate.settings.secondaryTarget", selection: $secondaryTarget) {
                ForEach(TranslationLanguage.all) { language in
                    Text(language.endonym).tag(language.code)
                }
            }
            Text("selectiontranslate.settings.targetHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("selectiontranslate.settings.autoSpeak", isOn: $autoSpeak)
        } header: {
            Text("selectiontranslate.settings.languageSection")
        }

        TranslationEngineSection(definition: .selectionTranslate)
    }

    // MARK: - 学习

    private var learnSection: some View {
        Section {
            Picker("selectiontranslate.settings.learnNative", selection: $learnNative) {
                ForEach(SelectionAssistantSettings.learnLanguages) { language in
                    Text(language.endonym).tag(language.code)
                }
            }
            Picker("selectiontranslate.settings.learnTarget", selection: $learnTarget) {
                ForEach(SelectionAssistantSettings.learnLanguages) { language in
                    Text(language.endonym).tag(language.code)
                }
            }
            if learnNative == learnTarget {
                Text("selectiontranslate.settings.learnSameLanguage")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("selectiontranslate.settings.learnHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("selectiontranslate.settings.accent", selection: $accent) {
                Text("selectiontranslate.learn.us").tag("us")
                Text("selectiontranslate.learn.uk").tag("uk")
            }
            Toggle("selectiontranslate.settings.learnAutoSpeak", isOn: $learnAutoSpeak)
            EnglishDictionaryRow()
        } header: {
            Text("selectiontranslate.settings.learnSection")
        }
    }

    // MARK: - 权限

    private var permissionSection: some View {
        Section {
            HStack {
                Text("selectiontranslate.settings.accessibility")
                Spacer()
                if Permissions.hasAccessibility {
                    Text("selectiontranslate.settings.accessibilityGranted")
                        .foregroundStyle(.secondary)
                } else {
                    Text("selectiontranslate.settings.accessibilityMissing")
                        .foregroundStyle(.orange)
                    Button("selectiontranslate.settings.grant") {
                        Permissions.promptAccessibility()
                    }
                }
            }
            HStack {
                Text("selectiontranslate.settings.screenRecording")
                Spacer()
                if Permissions.hasScreenRecording {
                    Text("selectiontranslate.settings.accessibilityGranted")
                        .foregroundStyle(.secondary)
                } else {
                    Text("selectiontranslate.settings.accessibilityMissing")
                        .foregroundStyle(.orange)
                    Button("selectiontranslate.settings.grant") {
                        Permissions.requestScreenRecording()
                    }
                }
            }
            Text("selectiontranslate.settings.screenRecordingHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("selectiontranslate.settings.permissionSection")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
