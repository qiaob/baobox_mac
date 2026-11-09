import SwiftUI

/// 一个功能用哪个模型（docs/ai-service/DESIGN.md §6.2）：「功能名 | 下拉框（模型 · 来源）| 状态 | 去处理」。
/// 「AI」页的功能栏和各工具自己的设置页用同一行、同一份设置（同快捷键的 `HotkeyRow` 嵌进 `ModuleHotkeyRows`）。
/// 状态一眼看出能不能用；不能用时右边的按钮直接跳到「AI」页对应那一栏，把要下载的模型选好、要填 Key 的服务商展开。
struct AIFeatureRow: View {
    let definition: AIFeatureDefinition
    /// 工具设置页里多一个「AI 设置…」（跳到「AI」页）；「AI」页里不用。
    let showsManage: Bool

    @ObservedObject private var store = AIModelStore.shared
    /// 本地模型下载好 / 删掉时刷新状态和「未下载」标记。
    @ObservedObject private var localModels = LocalModelsObserver.shared
    /// 只用来跟着 UserDefaults 刷新（在别处改了这个功能也看得到）；读写都走 `AIFeatureSettings`。
    @AppStorage private var stored: String

    /// 功能名、下拉框的宽度：各行对齐。
    private static let titleWidth: CGFloat = 84
    private static let pickerWidth: CGFloat = 240

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

    private var selection: Binding<String> {
        Binding(
            get: { choice.storageValue },
            set: { raw in
                guard let picked = AIEngineChoice(storageValue: raw), picked != choice else { return }
                AIFeatureSettings.setChoice(picked, for: feature)
            })
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: definition.title)
                .frame(width: Self.titleWidth, alignment: .leading)
            Picker(selection: selection) {
                options
            } label: {
                Text(verbatim: definition.title)
            }
            .labelsHidden()
            .fixedSize()
            .frame(width: Self.pickerWidth, alignment: .leading)
            statusLabel
            Spacer(minLength: 0)
            if let fix = status.fix {
                Button(fix.title) { fix.run() }
            }
        }
        if let note {
            Text(verbatim: note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, Self.titleWidth + 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        if showsManage {
            Button("ai.feature.manage") {
                AISettingsNavigation.shared.showFeatures()
            }
            .controlSize(.small)
        }
    }

    // MARK: - 下拉框

    @ViewBuilder
    private var options: some View {
        if feature.kind == .translation {
            Text(verbatim: autoLabel).tag(AIEngineChoice.auto.storageValue)
            Text("ai.choice.system").tag(AIEngineChoice.system.storageValue)
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
                        Text(verbatim: cloudLabel(model, account: account)).tag(AIEngineChoice.model(model.id).storageValue)
                    }
                }
            }
        }
    }

    /// 「自动」后面写清这台 Mac 上实际用的是什么。
    private var autoLabel: String {
        TranslationSettings.systemAvailable
            ? L("ai.choice.autoSystem")
            : L("ai.choice.autoLocal \(LocalModels.defaultEntry(for: .translation).name)")
    }

    /// 本地模型在下拉框里的值：这一类功能的默认本地模型存成 `.local`，其余存 `localmodel:<id>`（`AIFeatureSettings` 也这样归一）。
    private func localTag(_ entry: LocalModelEntry) -> String {
        entry.id == LocalModels.defaultEntry(for: feature.kind).id
            ? AIEngineChoice.local.storageValue : AIEngineChoice.localModel(entry.id).storageValue
    }

    private func localLabel(_ entry: LocalModelEntry) -> String {
        let label = L("ai.choice.local \(entry.name)")
        return entry.translator.isReady ? label : L("ai.feature.notDownloadedLabel \(label)")
    }

    private func cloudLabel(_ model: AICloudModel, account: AICloudAccount) -> String {
        let label = L("ai.choice.cloud \(model.displayName) \(account.displayName)")
        return store.isConfigured(model.id) ? label : L("ai.model.unconfiguredLabel \(label)")
    }

    // MARK: - 状态

    private struct Fix {
        let title: String
        let run: () -> Void
    }

    private struct Readiness {
        let ok: Bool
        let text: String
        var fix: Fix?
    }

    private var status: Readiness {
        switch choice {
        case .auto:
            if TranslationSettings.systemAvailable { return Readiness(ok: true, text: L("ai.status.ok")) }
            return localReadiness(LocalModels.defaultEntry(for: .translation))
        case .system:
            return TranslationSettings.systemAvailable
                ? Readiness(ok: true, text: L("ai.status.ok"))
                : Readiness(ok: false, text: L("ai.status.needsMacOS15"))
        case .local:
            return localReadiness(LocalModels.defaultEntry(for: feature.kind))
        case .localModel(let id):
            guard let entry = LocalModels.entry(id) else { return localReadiness(LocalModels.defaultEntry(for: feature.kind)) }
            return localReadiness(entry)
        case .model(let id):
            guard let problem = store.problem(modelID: id) else { return Readiness(ok: true, text: L("ai.status.ok")) }
            let accountID = store.model(id)?.accountID
            return Readiness(ok: false, text: problem,
                             fix: Fix(title: L("ai.status.fixCloud")) { AISettingsNavigation.shared.showCloud(account: accountID) })
        }
    }

    private func localReadiness(_ entry: LocalModelEntry) -> Readiness {
        switch entry.translator.modelState {
        case .installed:
            return Readiness(ok: true, text: L("ai.status.ok"))
        case .downloading(let progress):
            return Readiness(ok: false, text: L("ai.status.downloading \(Int(progress * 100))"))
        case .verifying:
            return Readiness(ok: false, text: L("localmodel.status.verifying"))
        case .notInstalled, .failed:
            return Readiness(ok: false, text: L("ai.status.notDownloaded"),
                             fix: Fix(title: L("ai.status.fixLocal")) { AISettingsNavigation.shared.showLocal(model: entry.id) })
        }
    }

    private var statusLabel: some View {
        let status = self.status
        return Label {
            Text(verbatim: status.text)
                .lineLimit(1)
        } icon: {
            Image(systemName: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.ok ? Color.green : Color.orange)
        }
        .foregroundStyle(status.ok ? Color.secondary : Color.orange)
    }

    /// 选了云端模型、能用时，说一句会把什么发给谁（只在这时才有这一行）。
    private var note: String? {
        guard let id = choice.modelID, store.problem(modelID: id) == nil,
              let model = store.model(id), let account = store.account(model.accountID) else { return nil }
        return L("ai.feature.sends \(definition.sends) \(account.displayName)")
    }
}
