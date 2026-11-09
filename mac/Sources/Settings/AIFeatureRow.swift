import SwiftUI

/// 一个功能用哪个模型（docs/ai-service/DESIGN.md §6.2）。「AI」页的功能表和模块自己的设置页用同一行、同一份设置
/// （同快捷键的 `HotkeyRow` 嵌进 `ModuleHotkeyRows`），改哪边都一样。
struct AIFeatureRow: View {
    let definition: AIFeatureDefinition
    /// 模块页里给「管理模型…」按钮（跳到「AI」页）；「AI」页里不用。
    let showsManage: Bool

    @ObservedObject private var store = AIModelStore.shared
    /// 本地模型下载好 / 删掉时刷新「本机」一组（「未下载」标记）。
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

    /// 实际生效的选择：指向已删掉的云端模型时按默认显示。本地模型都在列表里（没下载的标「未下载」），选了照样显示。
    private var choice: AIEngineChoice {
        _ = stored
        let choice = AIFeatureSettings.choice(feature)
        if let id = choice.modelID, store.model(id) == nil { return AIFeatureSettings.defaultChoice(feature) }
        return choice
    }

    /// 选的是哪个本地模型（`.local` = 这一类功能的默认本地模型）；不是本地时为 nil。
    private var localEntry: LocalModelEntry? {
        switch choice {
        case .local: return LocalModels.defaultEntry(for: feature.kind)
        case .localModel(let id): return LocalModels.entry(id)
        case .auto, .system, .model: return nil
        }
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
            if feature.kind == .translation {
                Text("translation.engine.auto").tag(AIEngineChoice.auto.storageValue)
                Text("translation.engine.system").tag(AIEngineChoice.system.storageValue)
            }
            // 本地模型都在「本机」一组里，一视同仁；没下载的标「未下载」（同云端模型的「未配置」）。
            Section(L("ai.feature.localGroup")) {
                ForEach(LocalModels.models(for: feature.kind)) { entry in
                    Text(verbatim: localLabel(entry)).tag(localTag(entry))
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
        if let entry = localEntry {
            let ready = entry.translator.isReady
            Text(verbatim: ready ? L("ai.feature.localModelNote \(entry.name) \(MachineInfo.text(entry.memoryNeed))")
                                 : L("ai.feature.localNotDownloaded \(entry.name)"))
                .font(.caption)
                .foregroundStyle(ready ? Color.secondary : Color.orange)
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

    /// 本地模型在下拉框里的值：这一类功能的默认本地模型存成 `.local`，其余存 `localmodel:<id>`（`AIFeatureSettings` 也这样归一）。
    private func localTag(_ entry: LocalModelEntry) -> String {
        entry.id == LocalModels.defaultEntry(for: feature.kind).id
            ? AIEngineChoice.local.storageValue : AIEngineChoice.localModel(entry.id).storageValue
    }

    private func localLabel(_ entry: LocalModelEntry) -> String {
        entry.translator.isReady ? entry.name : L("ai.feature.notDownloadedLabel \(entry.name)")
    }

    private func label(for model: AICloudModel) -> String {
        store.isConfigured(model.id) ? model.displayName : L("ai.model.unconfiguredLabel \(model.displayName)")
    }
}
