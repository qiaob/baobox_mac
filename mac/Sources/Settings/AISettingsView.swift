import Combine
import SwiftUI

/// 设置页「AI」（docs/ai-service/DESIGN.md §6.1）：顶部切三栏 ——「功能」（每个功能用哪个模型、能不能用、去处理，默认这栏）、
/// 「本机模型」（docs/local-models/DESIGN.md）、「云端模型」（服务商与模型）。设置本身就是引导：新手先看到功能和状态。
/// Key 只进钥匙串，这里从不把已存的 Key 显示出来。文本框随输入保存（Key 除外，要点「保存」）。
struct AISettingsView: View {
    static let tabID = "ai"

    @ObservedObject var registry: ToolRegistry
    @ObservedObject private var store = AIModelStore.shared
    @ObservedObject private var catalog = AIModelCatalog.shared
    @ObservedObject private var navigation = AISettingsNavigation.shared
    @AppStorage(AICloudSettings.maxTokensKey) private var maxTokens = AICloudSettings.defaultMaxTokens
    @AppStorage(AICloudSettings.perMinuteKey) private var perMinute = AICloudSettings.defaultPerMinute
    @AppStorage(AIUsageMeter.dailyLimitKey) private var dailyLimit = AIUsageMeter.defaultDailyLimit
    @ObservedObject private var usage = AIUsageMeter.shared
    /// 刚加的账号默认展开。
    @State private var justAdded: String?
    /// 各账号 Key 输入框里正在输的（账号 id → 文字）；存完清空。
    @State private var keyInputs: [String: String] = [:]
    @State private var keyFailed: Set<String> = []
    /// 模型 id → 测试结果。
    @State private var testResults: [String: TestResult] = [:]
    @State private var testing: Set<String> = []
    @State private var pendingDelete: AICloudAccount?
    /// 本机服务上很大的模型：测试前先确认（加载会把内存占满）。
    @State private var pendingBigTest: AICloudModel?
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

    /// 服务商详情表格左列（标签）的宽度：几个标签都放得下，右列各行左边对齐。
    private static let labelWidth: CGFloat = 64
    /// 模型行里「显示名称」输入框的宽度。
    private static let nameWidth: CGFloat = 130

    private var groups: [FeatureGroup] {
        registry.tools
            .map { FeatureGroup(id: $0.id, name: $0.name, definitions: $0.aiFeatures()) }
            .filter { !$0.definitions.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 三栏：功能（默认，先看每个功能用什么、能不能用）/ 本机模型 / 云端模型。
            Picker("", selection: $navigation.pane) {
                ForEach(AISettingsPane.allCases) { pane in
                    Text(verbatim: pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            .padding(.bottom, 2)
            switch navigation.pane {
            case .features: featuresPane
            case .local: LocalModelsPane()
            case .cloud: cloudPane
            }
        }
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
        .alert(Text("ai.settings.bigModelTitle"),
               isPresented: Binding(get: { pendingBigTest != nil }, set: { if !$0 { pendingBigTest = nil } }),
               presenting: pendingBigTest) { model in
            Button("ai.settings.testAnyway") { runTest(model.id) }
            Button("localmodel.cancel", role: .cancel) {}
        } message: { model in
            Text(verbatim: bigModelWarning(model) ?? "")
        }
    }

    // MARK: - 功能栏

    /// 每个功能一行：用哪个模型、有问题点哪里去处理、建议用哪个（docs/ai-service/DESIGN.md §6.2）；
    /// 最下面收起「用量上限与隐私」，里面列出现在会把什么发给谁。
    private var featuresPane: some View {
        Form {
            Section {
                caption(L("ai.settings.featuresIntro"))
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
                TappableDisclosure {
                    Stepper(value: $dailyLimit, in: AIUsageMeter.dailyLimitRange, step: 100) {
                        Text(L("ai.settings.dailyLimit \(dailyLimit)"))
                    }
                    if usage.isOverLimit {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            caption(L("ai.settings.overLimit"), warning: true)
                            Button(L("ai.usage.more \(dailyLimit)")) { usage.extendToday() }
                        }
                    }
                    Stepper(value: $perMinute, in: AICloudSettings.perMinuteRange, step: 10) {
                        Text(L("ai.settings.perMinute \(perMinute)"))
                    }
                    Stepper(value: $maxTokens, in: AICloudSettings.maxTokensRange, step: 128) {
                        Text(L("ai.settings.maxTokens \(maxTokens)"))
                    }
                    caption(L("ai.settings.limitsHelp"))
                    caption(L("ai.settings.privacy"))
                    caption(cloudSends)
                } label: {
                    // 收起时也看得到今天用了多少（#100）。
                    HStack {
                        Text("ai.settings.advanced")
                        Spacer()
                        Text(verbatim: usage.summary)
                            .foregroundStyle(usage.isOverLimit ? Color.orange : Color.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 云端模型栏

    private var cloudPane: some View {
        let usage = modelUsage()
        return Form {
            Section {
                caption(L("ai.settings.cloudIntro"))
            }
            Section {
                if store.accounts.isEmpty {
                    caption(L("ai.settings.accountsEmpty"))
                }
                ForEach(store.accounts) { account in
                    // 刚加的、或从功能栏「去填写」跳过来的那个服务商直接展开。
                    TappableDisclosure(initiallyExpanded: account.id == justAdded
                                       || account.id == navigation.focusAccount) {
                        accountDetails(account, usage: usage)
                    } label: {
                        accountLabel(account)
                    }
                }
                addAccountMenu
            } header: {
                Text("ai.settings.accountsSection")
            }
        }
        .formStyle(.grouped)
        .onDisappear { navigation.focusAccount = nil }
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

    /// 展开后的内容：每行左边是固定宽度的标签、右边是占满剩余宽度的控件，说明文字都在右边、左对齐
    /// （docs/local-models/DESIGN.md §7）。没用 `Grid`：它按理想宽度定列宽，右列撑不满一行。
    private func accountDetails(_ account: AICloudAccount, usage: [String: [String]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldRow("ai.settings.accountName") {
                TextField("", text: accountBinding(account.id, \.name), prompt: Text(verbatim: account.kind.title))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            fieldRow("ai.settings.baseURL") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: accountBinding(account.id, \.baseURL),
                              prompt: Text(verbatim: account.kind.defaultBaseURL.isEmpty
                                           ? "https://example.com/v1" : account.kind.defaultBaseURL))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    caption(baseURLHelp(account), warning: store.baseURL(of: account) == nil)
                }
            }
            fieldRow("ai.settings.apiKey") {
                keyCell(account)
            }
            fieldRow("ai.settings.models") {
                modelsCell(account, usage: usage)
            }
            HStack {
                Spacer()
                Button("ai.settings.deleteAccount", role: .destructive) {
                    pendingDelete = account
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        // 展开账号、存了 Key、改了地址（停手半秒后）就去拉服务商的模型列表；没变就不重拉。
        .task(id: listSignature(account)) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await catalog.refreshIfNeeded(account.id, signature: listSignature(account))
        }
    }

    /// 一行：左边固定宽度的标签（各行对齐），右边占满剩余宽度。
    private func fieldRow<Content: View>(_ key: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyCell(_ account: AICloudAccount) -> some View {
        let hasKey = store.accountsWithKey.contains(account.id)
        let input = keyInputs[account.id] ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SecureField("", text: keyBinding(account.id),
                            prompt: Text(verbatim: hasKey ? L("ai.settings.keySaved") : L("ai.settings.keyPlaceholder")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
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
                caption(keyFailed.contains(account.id) ? L("ai.settings.keySaveFailed") : keyHelp(account),
                        warning: keyFailed.contains(account.id))
                if let url = account.kind.keyPageURL {
                    Link(L("ai.settings.getKey"), destination: url)
                        .font(.caption)
                        .fixedSize()
                }
            }
        }
    }

    private func modelsCell(_ account: AICloudAccount, usage: [String: [String]]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 列标题：和下面每一行的两个输入框对齐。
            HStack(spacing: 8) {
                Text("ai.settings.modelNameColumn")
                    .frame(width: Self.nameWidth, alignment: .leading)
                Text("ai.settings.modelIDColumn")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(store.models(of: account.id)) { model in
                modelRow(model, account: account, usedBy: usage[model.id] ?? [])
            }
            HStack(spacing: 8) {
                Button("ai.settings.addModel") {
                    store.addModel(to: account.id)
                }
                Button(L("ai.settings.refreshModels")) {
                    Task { await catalog.refresh(account.id) }
                }
                .disabled(store.accountConfig(account.id) == nil || catalog.status(for: account.id) == .loading)
            }
            if let line = listStatus(account) {
                caption(line.text, warning: line.warning)
            }
        }
    }

    // MARK: - 模型

    private func modelRow(_ model: AICloudModel, account: AICloudAccount, usedBy: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                TextField("", text: modelBinding(model.id, \.name), prompt: Text("ai.settings.modelNamePrompt"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Self.nameWidth)
                ModelComboBox(text: modelBinding(model.id, \.model),
                              items: catalog.items(for: account),
                              placeholder: account.kind.modelExample.isEmpty ? L("ai.settings.modelID")
                                                                             : account.kind.modelExample)
                    .frame(minWidth: 160)
                Button(testing.contains(model.id) ? L("ai.settings.testing") : L("ai.settings.test")) {
                    requestTest(model, account: account)
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
            if let size = catalog.localSize(accountID: account.id, model: model.model) {
                let warning = bigModelWarning(model)
                caption(warning ?? L("ai.settings.localModelSize \(MachineInfo.text(size))"), warning: warning != nil)
            }
            if let result = testResults[model.id] {
                caption(result.text, warning: !result.ok)
            }
            if !usedBy.isEmpty {
                caption(L("ai.settings.usedBy \(ListFormatter.localizedString(byJoining: usedBy))"))
            }
        }
    }

    /// 本机服务上的模型太大（加载会把内存占满）时的提醒；不大或不知道多大时为 nil（docs/local-models/DESIGN.md §6）。
    private func bigModelWarning(_ model: AICloudModel) -> String? {
        guard let size = catalog.localSize(accountID: model.accountID, model: model.model) else { return nil }
        let total = MachineInfo.totalMemory
        guard LocalModels.isTooBig(memoryNeed: size + LocalModels.runtimeOverhead, totalMemory: total) else { return nil }
        return L("ai.settings.localModelTooBig \(MachineInfo.text(size)) \(MachineInfo.text(total))")
    }

    /// 现在会发到云端的：每个选了能用的云端模型的功能一行「字幕翻译：会把识别出来的每一句话发给「Anthropic Claude」。」。
    private var cloudSends: String {
        _ = choicesRevision
        var lines: [String] = []
        for group in groups {
            for definition in group.definitions {
                guard let id = AIFeatureSettings.choice(definition.feature).modelID, store.problem(modelID: id) == nil,
                      let model = store.model(id), let account = store.account(model.accountID) else { continue }
                lines.append(L("ai.settings.sendsLine \(definition.title) \(definition.sends) \(account.displayName)"))
            }
        }
        return lines.isEmpty ? L("ai.settings.sendsNone") : lines.joined(separator: "\n")
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
        if !account.baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
           let problem = AICloudSettings.urlProblem(account.baseURL, fallback: account.kind.defaultBaseURL) {
            switch problem {
            case .invalid: return L("ai.settings.baseURLInvalid")
            case .insecure: return L("ai.settings.baseURLInsecure")
            }
        }
        return account.kind.defaultBaseURL.isEmpty
            ? L("ai.settings.baseURLHelpCustom")
            : L("ai.settings.baseURLHelpDefault \(account.kind.defaultBaseURL)")
    }

    private func keyHelp(_ account: AICloudAccount) -> String {
        switch account.kind {
        case .ollama: return L("ai.settings.keyHelpLocal")
        case .openAICompatible: return L("ai.settings.keyHelpOpenAI")
        default: return L("ai.settings.keyHelp")
        }
    }

    /// 说明文字：小字、左对齐、可换行。
    private func caption(_ text: String, warning: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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

    /// 本机服务上的大模型先确认再测（测试会把整个模型读进内存）。
    private func requestTest(_ model: AICloudModel, account: AICloudAccount) {
        if bigModelWarning(model) != nil {
            pendingBigTest = model
        } else {
            runTest(model.id)
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
