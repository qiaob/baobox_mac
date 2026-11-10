import SwiftUI

/// 一个功能用哪个模型（docs/ai-service/DESIGN.md §6.2）：一行三列「功能名 | 下拉框（模型 · 来源）| 一句话」，右边最多一个按钮。
/// 第三列只说一件事：有问题就说问题（「去下载」「去填写」）；没问题时，用的就是建议的模型写「✓ 建议的模型」，
/// 不是就写「建议 X：理由」加「改用」（建议跟着功能走，§6.3）。
/// 「AI」页的功能栏和各工具自己的设置页用同一行、同一份设置（同快捷键的 `HotkeyRow` 嵌进 `ModuleHotkeyRows`）。
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
        let line = self.line
        HStack(spacing: 10) {
            Text(verbatim: definition.rowTitle)
                .lineLimit(1)
                .frame(width: Self.titleWidth, alignment: .leading)
            Picker(selection: selection) {
                options
            } label: {
                Text(verbatim: definition.rowTitle)
            }
            .labelsHidden()
            // 平时按标签本身的宽度靠左；名字太长就截断成「…」，不压到第三列。外层固定宽度让各行第三列对齐。
            .frame(maxWidth: Self.pickerWidth, alignment: .leading)
            .frame(width: Self.pickerWidth, alignment: .leading)
            message(line)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = action(for: line) {
                Button(action.title) { action.run() }
            }
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

    // MARK: - 第三列

    /// 第三列说的那一件事。
    private enum Line {
        /// 选的这个现在用不了（橙色 ⚠），能处理的带按钮。
        case problem(String, Action?)
        /// 正在下载 / 校验（灰色），等着就行。
        case busy(String)
        /// 用的就是建议的模型。
        case matched(AIRecommendation)
        /// 用的不是建议的：建议哪个、为什么。
        case suggested(AIRecommendation)
    }

    private struct Action {
        let title: String
        let run: () -> Void
    }

    /// 有问题先说问题；没问题再和建议比。
    private var line: Line {
        if let problem { return problem }
        let recommendation = definition.recommendation
        return recommendation.isUsed(by: choice) ? .matched(recommendation) : .suggested(recommendation)
    }

    /// 选的这个现在为什么用不了；nil = 能用。
    private var problem: Line? {
        switch choice {
        case .auto:
            if TranslationSettings.systemAvailable { return nil }
            return localProblem(LocalModels.defaultEntry(for: .translation))
        case .system:
            return TranslationSettings.systemAvailable ? nil : .problem(L("ai.status.needsMacOS15"), nil)
        case .local:
            return localProblem(LocalModels.defaultEntry(for: feature.kind))
        case .localModel(let id):
            return localProblem(LocalModels.entry(id) ?? LocalModels.defaultEntry(for: feature.kind))
        case .model(let id):
            guard let text = store.problem(modelID: id) else { return nil }
            let accountID = store.model(id)?.accountID
            return .problem(text, Action(title: L("ai.status.fixCloud")) {
                AISettingsNavigation.shared.showCloud(account: accountID)
            })
        }
    }

    private func localProblem(_ entry: LocalModelEntry) -> Line? {
        switch entry.translator.modelState {
        case .installed:
            return nil
        case .downloading(let progress):
            return .busy(L("ai.status.downloading \(Int(progress * 100))"))
        case .verifying:
            return .busy(L("localmodel.status.verifying"))
        case .notInstalled, .failed:
            return .problem(L("ai.status.notDownloaded"), Action(title: L("ai.status.fixLocal")) {
                AISettingsNavigation.shared.showLocal(model: entry.id)
            })
        }
    }

    private func action(for line: Line) -> Action? {
        switch line {
        case .problem(_, let action):
            return action
        case .suggested(let recommendation):
            let feature = self.feature
            return Action(title: L("ai.advice.switch")) {
                AIFeatureSettings.setChoice(recommendation.choice, for: feature)
            }
        case .busy, .matched:
            return nil
        }
    }

    @ViewBuilder
    private func message(_ line: Line) -> some View {
        switch line {
        case .problem(let text, _):
            Label {
                Text(verbatim: text).lineLimit(1)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(Color.orange)
        case .busy(let text):
            Label {
                Text(verbatim: text).lineLimit(1)
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
            .foregroundStyle(Color.secondary)
        case .matched(let recommendation):
            Label {
                Text("ai.advice.matched").lineLimit(1)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            }
            .foregroundStyle(Color.secondary)
            .help(recommendation.detail)
        case .suggested(let recommendation):
            // 「建议 」灰、模型名正常色、「：理由」灰。
            (Text(verbatim: L("ai.advice.prefix")).foregroundStyle(Color.secondary)
                + Text(verbatim: recommendation.name)
                + Text(verbatim: L("ai.advice.reason \(recommendation.reason)")).foregroundStyle(Color.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .help(recommendation.detail)
        }
    }
}
