import Combine
import SwiftUI

/// 设置页「AI」（docs/ai-service/DESIGN.md §6.1）：服务商与模型 + 各功能用哪个模型（按工具分组，同快捷键页）+ 用量上限 + 本地模型。
/// Key 只进钥匙串，这里从不把已存的 Key 显示出来。文本框随输入保存（Key 除外，要点「保存」）。
struct AISettingsView: View {
    static let tabID = "ai"

    @ObservedObject var registry: ToolRegistry
    @ObservedObject private var store = AIModelStore.shared
    @ObservedObject private var catalog = AIModelCatalog.shared
    @AppStorage(AICloudSettings.maxTokensKey) private var maxTokens = AICloudSettings.defaultMaxTokens
    @AppStorage(AICloudSettings.perMinuteKey) private var perMinute = AICloudSettings.defaultPerMinute
    /// 刚加的账号默认展开。
    @State private var justAdded: String?
    /// 各账号 Key 输入框里正在输的（账号 id → 文字）；存完清空。
    @State private var keyInputs: [String: String] = [:]
    @State private var keyFailed: Set<String> = []
    /// 模型 id → 测试结果。
    @State private var testResults: [String: TestResult] = [:]
    @State private var testing: Set<String> = []
    @State private var pendingDelete: AICloudAccount?
    /// 功能选择变了就加一，让模型下面的「用在：…」重算。
    @State private var choicesRevision = 0

    private struct TestResult {
        let ok: Bool
        let text: String
    }

    private struct FeatureGroup: Identifiable {
        let id: String
        let name: String
        let definitions: [AIFeatureDefinition]
    }

    /// 预填了地址的 OpenAI 兼容服务（添加菜单中间那一组）。
    private static let presets: [AICloudProvider] = AICloudProvider.allCases.filter {
        $0 != .anthropic && $0 != .ollama && $0 != .openAICompatible
    }

    private var groups: [FeatureGroup] {
        registry.tools
            .map { FeatureGroup(id: $0.id, name: $0.name, definitions: $0.aiFeatures()) }
            .filter { !$0.definitions.isEmpty }
    }

    var body: some View {
        let usage = modelUsage()
        Form {
            Section {
                Text("ai.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if store.accounts.isEmpty {
                    Text("ai.settings.accountsEmpty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(store.accounts) { account in
                    TappableDisclosure(initiallyExpanded: account.id == justAdded) {
                        accountDetails(account, usage: usage)
                    } label: {
                        accountLabel(account)
                    }
                }
                addAccountMenu
            } header: {
                Text("ai.settings.accountsSection")
            }

            Section {
                Text("ai.settings.featuresHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("ai.settings.featuresSection")
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.definitions, id: \.feature.id) { definition in
                        AIFeatureRow(definition: definition)
                    }
                } header: {
                    Text(verbatim: group.name)
                }
            }

            Section {
                Stepper(value: $maxTokens, in: AICloudSettings.maxTokensRange, step: 128) {
                    Text(L("ai.settings.maxTokens \(maxTokens)"))
                }
                Stepper(value: $perMinute, in: AICloudSettings.perMinuteRange, step: 10) {
                    Text(L("ai.settings.perMinute \(perMinute)"))
                }
                Text("ai.settings.limitsHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("ai.settings.limitsSection")
            }

            Section {
                Text("ai.settings.privacy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("ai.settings.privacySection")
            }

            Section {
                OfflineModelRow()
                OfflineModelRow(translator: .corrector,
                                title: "ai.settings.generationModel",
                                notInstalledHelp: "ai.settings.generationModelHelp",
                                installedHelp: "ai.settings.generationModelInstalled")
            } header: {
                Text("ai.settings.localSection")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: AIFeatureSettings.didChange)) { _ in
            choicesRevision += 1
        }
        .confirmationDialog(
            Text(verbatim: L("ai.settings.deleteAccountTitle \(pendingDelete?.displayName ?? "")")),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { account in
            Button("ai.settings.deleteAccountConfirm", role: .destructive) {
                deleteAccount(account)
            }
        } message: { _ in
            Text("ai.settings.deleteAccountMessage")
        }
    }

    // MARK: - 服务商账号

    private func accountLabel(_ account: AICloudAccount) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: account.displayName)
            if account.displayName != account.kind.title {
                Text(verbatim: account.kind.title)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            keyBadge(account)
            Text(verbatim: L("ai.settings.modelCount \(store.models(of: account.id).count)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func keyBadge(_ account: AICloudAccount) -> some View {
        if !store.needsKey(account) {
            Text("ai.settings.keyStatusLocal")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if store.accountsWithKey.contains(account.id) {
            Text("ai.settings.keyStatusSaved")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("ai.settings.keyStatusMissing")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func accountDetails(_ account: AICloudAccount, usage: [String: [String]]) -> some View {
        TextField("ai.settings.accountName", text: accountBinding(account.id, \.name),
                  prompt: Text(verbatim: account.kind.title))
        TextField("ai.settings.baseURL", text: accountBinding(account.id, \.baseURL),
                  prompt: Text(verbatim: account.kind.defaultBaseURL.isEmpty
                               ? "https://example.com/v1" : account.kind.defaultBaseURL))
        Text(verbatim: baseURLHelp(account))
            .font(.caption)
            .foregroundStyle(store.baseURL(of: account) == nil ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        keyRow(account)
        HStack(alignment: .firstTextBaseline) {
            Text("ai.settings.modelsHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L("ai.settings.refreshModels")) {
                Task { await catalog.refresh(account.id) }
            }
            .controlSize(.small)
            .disabled(store.accountConfig(account.id) == nil || catalog.status(for: account.id) == .loading)
        }
        // 展开账号、存了 Key、改了地址（停手半秒后）就去拉服务商的模型列表；没变就不重拉。
        .task(id: listSignature(account)) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await catalog.refreshIfNeeded(account.id, signature: listSignature(account))
        }
        if let line = listStatus(account) {
            Text(verbatim: line.text)
                .font(.caption)
                .foregroundStyle(line.warning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(store.models(of: account.id)) { model in
            modelRow(model, account: account, usedBy: usage[model.id] ?? [])
        }
        HStack {
            Button("ai.settings.addModel") {
                store.addModel(to: account.id)
            }
            Spacer()
            Button("ai.settings.deleteAccount", role: .destructive) {
                pendingDelete = account
            }
        }
    }

    /// 拉模型列表要看的状态：Key 有没有、地址是什么。
    private func listSignature(_ account: AICloudAccount) -> String {
        "\(account.id)|\(store.accountsWithKey.contains(account.id))|\(account.baseURL)"
    }

    /// 模型下拉列表的来源说明。
    private func listStatus(_ account: AICloudAccount) -> (text: String, warning: Bool)? {
        switch catalog.status(for: account.id) {
        case .loading:
            return (L("ai.settings.modelsLoading"), false)
        case .loaded(let count):
            return (L("ai.settings.modelsLoaded \(count)"), false)
        case .failed(let message):
            if let url = store.baseURL(of: account), AICloudSettings.isLocalHost(url) {
                return (L("ai.settings.modelsFailedLocal"), true)
            }
            return (L("ai.settings.modelsFailed \(message)"), true)
        case .idle:
            return store.accountConfig(account.id) == nil ? (L("ai.settings.modelsSuggested"), false) : nil
        }
    }

    private func baseURLHelp(_ account: AICloudAccount) -> String {
        if store.baseURL(of: account) == nil, !account.baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return L("ai.settings.baseURLInvalid")
        }
        return account.kind.defaultBaseURL.isEmpty
            ? L("ai.settings.baseURLHelpCustom")
            : L("ai.settings.baseURLHelpDefault \(account.kind.defaultBaseURL)")
    }

    @ViewBuilder
    private func keyRow(_ account: AICloudAccount) -> some View {
        let hasKey = store.accountsWithKey.contains(account.id)
        let input = keyInputs[account.id] ?? ""
        HStack {
            SecureField("ai.settings.apiKey", text: keyBinding(account.id),
                        prompt: Text(verbatim: hasKey ? L("ai.settings.keySaved") : L("ai.settings.keyPlaceholder")))
                .onSubmit { saveKey(account.id) }
            Button("ai.settings.saveKey") {
                saveKey(account.id)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasKey {
                Button("ai.settings.deleteKey", role: .destructive) {
                    store.deleteKey(accountID: account.id)
                }
            }
        }
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: keyFailed.contains(account.id) ? L("ai.settings.keySaveFailed") : keyHelp(account))
                .font(.caption)
                .foregroundStyle(keyFailed.contains(account.id) ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let url = account.kind.keyPageURL {
                Link(L("ai.settings.getKey"), destination: url)
                    .font(.caption)
            }
        }
    }

    private func keyHelp(_ account: AICloudAccount) -> String {
        switch account.kind {
        case .ollama: return L("ai.settings.keyHelpLocal")
        case .openAICompatible: return L("ai.settings.keyHelpOpenAI")
        default: return L("ai.settings.keyHelp")
        }
    }

    // MARK: - 模型

    @ViewBuilder
    private func modelRow(_ model: AICloudModel, account: AICloudAccount, usedBy: [String]) -> some View {
        HStack(spacing: 8) {
            TextField("ai.settings.modelName", text: modelBinding(model.id, \.name),
                      prompt: Text("ai.settings.modelNamePrompt"))
                .labelsHidden()
            ModelComboBox(text: modelBinding(model.id, \.model),
                          items: catalog.items(for: account),
                          placeholder: account.kind.modelExample.isEmpty ? L("ai.settings.modelID")
                                                                         : account.kind.modelExample)
                .frame(minWidth: 200)
            Button(testing.contains(model.id) ? L("ai.settings.testing") : L("ai.settings.test")) {
                runTest(model.id)
            }
            .disabled(testing.contains(model.id))
            Button(role: .destructive) {
                testResults[model.id] = nil
                store.deleteModel(model.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("ai.settings.deleteModel"))
        }
        if let result = testResults[model.id] {
            Text(verbatim: result.text)
                .font(.caption)
                .foregroundStyle(result.ok ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !usedBy.isEmpty {
            Text(verbatim: L("ai.settings.usedBy \(ListFormatter.localizedString(byJoining: usedBy))"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 模型 id → 选了它的功能名。
    private func modelUsage() -> [String: [String]] {
        _ = choicesRevision
        var result: [String: [String]] = [:]
        for group in groups {
            for definition in group.definitions {
                if let id = AIFeatureSettings.choice(definition.feature).modelID {
                    result[id, default: []].append(definition.title)
                }
            }
        }
        return result
    }

    // MARK: - 添加 / 删除

    private var addAccountMenu: some View {
        Menu {
            Button(AICloudProvider.anthropic.title) { add(.anthropic) }
            Divider()
            ForEach(Self.presets) { provider in
                Button(provider.title) { add(provider) }
            }
            Divider()
            Button(AICloudProvider.ollama.title) { add(.ollama) }
            Button(AICloudProvider.openAICompatible.title) { add(.openAICompatible) }
        } label: {
            Label(L("ai.settings.addAccount"), systemImage: "plus")
        }
        .fixedSize()
    }

    private func add(_ provider: AICloudProvider) {
        justAdded = store.addAccount(provider).id
    }

    private func deleteAccount(_ account: AICloudAccount) {
        for model in store.models(of: account.id) {
            testResults[model.id] = nil
        }
        keyInputs[account.id] = nil
        keyFailed.remove(account.id)
        catalog.forget(account.id)
        store.deleteAccount(account.id)
    }

    // MARK: - Key 与测试

    private func saveKey(_ accountID: String) {
        let input = keyInputs[accountID] ?? ""
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if store.saveKey(input, accountID: accountID) {
            keyFailed.remove(accountID)
        } else {
            keyFailed.insert(accountID)
        }
        keyInputs[accountID] = ""
        for model in store.models(of: accountID) {
            testResults[model.id] = nil
        }
    }

    private func runTest(_ modelID: String) {
        testing.insert(modelID)
        testResults[modelID] = nil
        Task {
            let error = await AIService.shared.testConnection(modelID: modelID)
            testing.remove(modelID)
            testResults[modelID] = TestResult(ok: error == nil, text: error ?? L("ai.settings.testOK"))
        }
    }

    // MARK: - 绑定（随输入保存）

    private func accountBinding(_ id: String, _ field: WritableKeyPath<AICloudAccount, String>) -> Binding<String> {
        Binding(get: { store.account(id)?[keyPath: field] ?? "" },
                set: { value in store.updateAccount(id) { $0[keyPath: field] = value } })
    }

    private func modelBinding(_ id: String, _ field: WritableKeyPath<AICloudModel, String>) -> Binding<String> {
        Binding(get: { store.model(id)?[keyPath: field] ?? "" },
                set: { value in store.updateModel(id) { $0[keyPath: field] = value } })
    }

    private func keyBinding(_ id: String) -> Binding<String> {
        Binding(get: { keyInputs[id] ?? "" }, set: { keyInputs[id] = $0 })
    }
}
