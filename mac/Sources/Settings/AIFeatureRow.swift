import SwiftUI

/// 一个功能用哪个模型（docs/ai-service/DESIGN.md §6.2）。「AI」页的功能表和模块自己的设置页用同一行、同一份设置
/// （同快捷键的 `HotkeyRow` 嵌进 `ModuleHotkeyRows`），改哪边都一样。
struct AIFeatureRow: View {
    let definition: AIFeatureDefinition
    /// 模块页里给「管理模型…」按钮（跳到「AI」页）；「AI」页里不用。
    let showsManage: Bool

    @ObservedObject private var store = AIModelStore.shared
    /// 本机大模型下载好 / 删掉时刷新「本机」一组。
    @ObservedObject private var localModels = LocalModelsObserver.shared
    /// 只用来跟着 UserDefaults 刷新（在别处改了这个功能也看得到）；读写都走 `AIFeatureSettings`。
    @AppStorage private var stored: String

    @MainActor
    init(definition: AIFeatureDefinition, showsManage: Bool = false) {
        self.definition = definition
        self.showsManage = showsManage
        _stored = AppStorage(wrappedValue: "", definition.feature.storageKey)
    }

    private var feature: AIFeature { definition.feature }

    /// 实际生效的选择：指向已删掉的云端模型、或已删除的本机大模型时按默认显示。
    private var choice: AIEngineChoice {
        _ = stored
        let choice = AIFeatureSettings.choice(feature)
        if let id = choice.modelID, store.model(id) == nil { return AIFeatureSettings.defaultChoice(feature) }
        if let id = choice.localModelID, !LocalModels.isInstalled(id) { return AIFeatureSettings.defaultChoice(feature) }
        return choice
    }

    /// 已下载的本机大模型（下拉框的「本机」一组）。
    private var installedLocalModels: [LocalModelEntry] {
        LocalModels.optional.filter { LocalModels.isInstalled($0.id) }
    }

    private var selection: Binding<String> {
        Binding(
            get: { choice.storageValue },
            set: { raw in
                guard let picked = AIEngineChoice(storageValue: raw), picked != choice else { return }
                AIFeatureSettings.setChoice(picked, for: feature)
            })
    }

    var body: some View {
        Picker(selection: selection) {
            switch feature.kind {
            case .translation:
                Text("translation.engine.auto").tag(AIEngineChoice.auto.storageValue)
                Text("translation.engine.system").tag(AIEngineChoice.system.storageValue)
                Text("translation.engine.offline").tag(AIEngineChoice.local.storageValue)
            case .generation:
                Text("ai.engine.local").tag(AIEngineChoice.local.storageValue)
            }
            if !installedLocalModels.isEmpty {
                Section(L("ai.feature.localGroup")) {
                    ForEach(installedLocalModels) { entry in
                        Text(verbatim: entry.name).tag(AIEngineChoice.localModel(entry.id).storageValue)
                    }
                }
            }
            // 每个服务商账号一组，组名 = 账号名。
            ForEach(store.accounts) { account in
                let models = store.models(of: account.id)
                if !models.isEmpty {
                    Section(account.displayName) {
                        ForEach(models) { model in
                            Text(verbatim: label(for: model)).tag(AIEngineChoice.model(model.id).storageValue)
                        }
                    }
                }
            }
        } label: {
            Text(verbatim: definition.title)
        }
        if let id = choice.localModelID, let entry = LocalModels.entry(id) {
            Text(verbatim: L("ai.feature.localModelNote \(entry.name) \(MachineInfo.text(entry.memoryNeed))"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let id = choice.modelID {
            if let problem = store.problem(modelID: id) {
                Text(verbatim: L("ai.feature.notReady \(problem)"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let model = store.model(id), let account = store.account(model.accountID) {
                Text(verbatim: L("ai.feature.sends \(definition.sends) \(account.displayName)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if showsManage {
            Button("ai.feature.manage") {
                SettingsTabSelection.shared.selectedTab = AISettingsView.tabID
            }
            .controlSize(.small)
        }
    }

    private func label(for model: AICloudModel) -> String {
        store.isConfigured(model.id) ? model.displayName : L("ai.model.unconfiguredLabel \(model.displayName)")
    }
}
