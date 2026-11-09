import SwiftUI

/// 设置页「AI」（docs/ai-service/DESIGN.md §6）：云端服务配置 + 本地模型一览。
/// 各模块自己的设置页只放「用哪个引擎」；Key 只进钥匙串，这里从不把已存的 Key 显示出来。
struct AISettingsView: View {
    static let tabID = "ai"

    @ObservedObject private var ai = AIService.shared
    @AppStorage(AICloudSettings.providerKey) private var provider = AICloudProvider.anthropic.rawValue
    @AppStorage(AICloudSettings.maxTokensKey) private var maxTokens = AICloudSettings.defaultMaxTokens
    @AppStorage(AICloudSettings.perMinuteKey) private var perMinute = AICloudSettings.defaultPerMinute
    @State private var model = ""
    @State private var baseURL = ""
    @State private var keyInput = ""
    @State private var keyFailed = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    private var currentProvider: AICloudProvider {
        AICloudProvider(rawValue: provider) ?? .anthropic
    }

    var body: some View {
        Form {
            Section {
                Text("ai.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("ai.settings.provider", selection: $provider) {
                    ForEach(AICloudProvider.allCases) { item in
                        Text(item.title).tag(item.rawValue)
                    }
                }
                .onChange(of: provider) { _, _ in
                    loadFields()
                    ai.refreshCloudConfiguration()
                    testResult = nil
                }
                TextField("ai.settings.baseURL", text: $baseURL, prompt: Text(verbatim: currentProvider.defaultBaseURL))
                    .onSubmit { saveFields() }
                TextField("ai.settings.model", text: $model,
                          prompt: Text(verbatim: currentProvider.defaultModel.isEmpty
                                       ? "gpt-4o-mini / qwen2.5:7b" : currentProvider.defaultModel))
                    .onSubmit { saveFields() }
                Text(currentProvider == .anthropic ? "ai.settings.modelHelpAnthropic" : "ai.settings.modelHelpOpenAI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                keyRow
                HStack {
                    Button(testing ? L("ai.settings.testing") : L("ai.settings.test")) {
                        runTest()
                    }
                    .disabled(testing)
                    if let testResult {
                        Text(verbatim: testResult)
                            .font(.caption)
                            .foregroundStyle(testOK ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                Text(ai.cloudConfigured ? "ai.settings.statusReady" : "ai.settings.cloudNotConfigured")
                    .font(.caption)
                    .foregroundStyle(ai.cloudConfigured ? Color.secondary : Color.orange)
            } header: {
                Text("ai.settings.cloudSection")
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
        .onAppear { loadFields() }
        .onDisappear { saveFields() }
    }

    @ViewBuilder
    private var keyRow: some View {
        HStack {
            SecureField("ai.settings.apiKey", text: $keyInput,
                        prompt: Text(ai.hasAPIKey ? "ai.settings.keySaved" : "ai.settings.keyPlaceholder"))
                .onSubmit { saveKey() }
            Button("ai.settings.saveKey") { saveKey() }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if ai.hasAPIKey {
                Button("ai.settings.deleteKey", role: .destructive) {
                    ai.deleteAPIKey()
                    testResult = nil
                }
            }
        }
        Text(keyFailed ? "ai.settings.keySaveFailed"
             : (currentProvider == .openAICompatible ? "ai.settings.keyHelpOpenAI" : "ai.settings.keyHelp"))
            .font(.caption)
            .foregroundStyle(keyFailed ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func loadFields() {
        let defaults = UserDefaults.standard
        model = defaults.string(forKey: AICloudSettings.modelKey(currentProvider)) ?? ""
        baseURL = defaults.string(forKey: AICloudSettings.baseURLKey(currentProvider)) ?? ""
        keyInput = ""
        keyFailed = false
    }

    /// 模型和地址失焦 / 回车 / 离开页面 / 测试前存一次（不在每次敲键时写，免得半截地址触发配置变化）。
    private func saveFields() {
        let defaults = UserDefaults.standard
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmedModel, forKey: AICloudSettings.modelKey(currentProvider))
        defaults.set(trimmedURL, forKey: AICloudSettings.baseURLKey(currentProvider))
        ai.refreshCloudConfiguration()
    }

    private func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyFailed = !ai.saveAPIKey(key)
        keyInput = ""
        testResult = nil
    }

    private func runTest() {
        saveFields()
        testing = true
        testResult = nil
        Task {
            let error = await ai.testConnection()
            testing = false
            testOK = error == nil
            testResult = error ?? L("ai.settings.testOK")
        }
    }
}
