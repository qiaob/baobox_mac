import AVFoundation
import SwiftUI

/// 设置 › 宠物 › AI 对话（#55，docs/desktop-pet/CHAT.md §3）：服务商、Base URL、模型、API Key（钥匙串）、
/// 测试连接、回复长度与次数上限、朗读开关、隐私说明。
struct PetAIServiceSection: View {
    @AppStorage(PetAISettings.providerKey) private var provider = PetAIProvider.anthropic.rawValue
    @AppStorage(PetAISettings.anthropicModelKey) private var anthropicModel = ""
    @AppStorage(PetAISettings.openaiModelKey) private var openaiModel = ""
    @AppStorage(PetAISettings.openaiBaseURLKey) private var openaiBaseURL = ""
    @AppStorage(PetAISettings.maxTokensKey) private var maxTokens = 600
    @AppStorage(PetAISettings.perMinuteKey) private var perMinute = 6
    @AppStorage(PetAISettings.speakKey) private var speak = true
    @AppStorage(PetAISettings.speakWhenBusyKey) private var speakWhenBusy = false
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    private var selected: PetAIProvider { PetAIProvider(rawValue: provider) ?? .anthropic }

    var body: some View {
        Section("pet.ai.section") {
            Picker("pet.ai.provider", selection: $provider) {
                Text("pet.ai.provider.anthropic").tag(PetAIProvider.anthropic.rawValue)
                Text("pet.ai.provider.openai").tag(PetAIProvider.openai.rawValue)
            }
            .onChange(of: provider) { _, _ in
                refreshKey()
                testResult = nil
            }
            if selected == .openai {
                TextField("pet.ai.baseURL", text: $openaiBaseURL, prompt: Text(verbatim: PetAISettings.defaultOpenAIBaseURL))
                Text("pet.ai.baseURLHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("pet.ai.model", text: $openaiModel, prompt: Text(verbatim: PetAISettings.defaultOpenAIModel))
            } else {
                TextField("pet.ai.model", text: $anthropicModel, prompt: Text(verbatim: PetAISettings.defaultAnthropicModel))
            }
            HStack {
                SecureField("pet.ai.apiKey", text: $keyDraft,
                            prompt: Text(hasKey ? LocalizedStringKey("pet.ai.apiKeySaved") : LocalizedStringKey("pet.ai.apiKeyEmpty")))
                Button("pet.ai.saveKey") {
                    PetAIKeychain.setKey(keyDraft, for: selected)
                    keyDraft = ""
                    refreshKey()
                    testResult = nil
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if hasKey {
                    Button("pet.ai.deleteKey", role: .destructive) {
                        PetAIKeychain.deleteKey(for: selected)
                        refreshKey()
                        testResult = nil
                    }
                }
            }
            Text(selected == .openai ? LocalizedStringKey("pet.ai.keyHintOpenAI") : LocalizedStringKey("pet.ai.keyHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("pet.ai.test") { test() }
                    .disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                if let testResult {
                    Text(verbatim: testResult.text)
                        .font(.caption)
                        .foregroundStyle(testResult.ok ? Color.green : Color.orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            Stepper(value: $maxTokens, in: 100...4000, step: 100) {
                Text(L("pet.ai.maxTokens \(maxTokens)"))
            }
            Stepper(value: $perMinute, in: 1...60) {
                Text(L("pet.ai.perMinute \(perMinute)"))
            }
            Toggle("pet.ai.speak", isOn: $speak)
            Toggle("pet.ai.speakWhenBusy", isOn: $speakWhenBusy)
                .disabled(!speak)
            Text("pet.ai.privacy")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { refreshKey() }
    }

    private func refreshKey() {
        hasKey = PetAIKeychain.hasKey(for: selected)
    }

    /// 发一句最短的话试试：通了显示回复的开头，不通用和聊天里一样的话说明原因。
    private func test() {
        testing = true
        testResult = nil
        let provider = selected
        let request = PetAIClient.Request(
            provider: provider, model: PetAISettings.model, baseURL: PetAISettings.openaiBaseURL,
            apiKey: PetAIKeychain.key(for: provider), system: "Reply with the single word: OK",
            turns: [PetChatTurn(role: .user, text: "ping")], maxTokens: 100
        )
        Task { @MainActor in
            var reply = ""
            do {
                try await PetAIClient.stream(request) { reply += $0 }
                testResult = (true, L("pet.ai.testOK \(String(reply.prefix(40)))"))
            } catch {
                testResult = (false, PetChatController.describe(error, name: "Baobox"))
            }
            testing = false
        }
    }
}

/// 设置 › 宠物 › 形象 下面：当前角色的人设与声音（#55）。改了下次发消息就用新的。
struct PetCharacterVoiceSection: View {
    let package: PetPackage
    @State private var persona = ""
    @State private var zhVoice = ""
    @State private var enVoice = ""
    @State private var pitch = 1.0
    @State private var rate = 0.5
    @State private var loadedID = ""
    @State private var preview = PetVoice()

    private var prefix: String { "pet.ai.voice.\(package.id)." }

    var body: some View {
        Section(L("pet.ai.characterSection \(package.name)")) {
            VStack(alignment: .leading, spacing: 4) {
                Text("pet.ai.persona")
                TextEditor(text: $persona)
                    .font(.callout)
                    .frame(minHeight: 70, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                HStack {
                    Button("pet.ai.savePersona") {
                        let isDefault = persona.trimmingCharacters(in: .whitespacesAndNewlines)
                            == PetPersona.defaultPersona(for: package)
                        PetAISettings.setPersona(isDefault ? nil : persona, for: package.id)
                    }
                    Button("pet.ai.resetPersona") {
                        PetAISettings.setPersona(nil, for: package.id)
                        persona = PetPersona.defaultPersona(for: package)
                    }
                    Spacer()
                }
            }
            Picker("pet.ai.voiceZh", selection: $zhVoice) {
                Text("pet.ai.voiceDefault").tag("")
                ForEach(PetPersona.voices(chinese: true), id: \.identifier) { voice in
                    Text(verbatim: voice.name).tag(voice.identifier)
                }
            }
            .onChange(of: zhVoice) { _, value in store(value, "zh") }
            Picker("pet.ai.voiceEn", selection: $enVoice) {
                Text("pet.ai.voiceDefault").tag("")
                ForEach(PetPersona.voices(chinese: false), id: \.identifier) { voice in
                    Text(verbatim: voice.name).tag(voice.identifier)
                }
            }
            .onChange(of: enVoice) { _, value in store(value, "en") }
            Slider(value: $pitch, in: 0.5...2) { Text("pet.ai.pitch") }
                .onChange(of: pitch) { _, value in UserDefaults.standard.set(value, forKey: prefix + "pitch") }
            Slider(value: $rate, in: 0.3...0.7) { Text("pet.ai.rate") }
                .onChange(of: rate) { _, value in UserDefaults.standard.set(value, forKey: prefix + "rate") }
            HStack {
                Button("pet.ai.preview") {
                    let voice = PetPersona.resolve(for: package)
                    preview.stop()
                    preview.speak(L("pet.ai.previewLine \(package.name)"), persona: voice)
                }
                Spacer()
            }
        }
        .onAppear { load() }
        .onChange(of: package.id) { _, _ in load() }
    }

    private func load() {
        guard loadedID != package.id else { return }
        loadedID = package.id
        let resolved = PetPersona.resolve(for: package)
        persona = resolved.persona
        zhVoice = resolved.zhVoice ?? ""
        enVoice = resolved.enVoice ?? ""
        pitch = resolved.pitch
        rate = resolved.rate
    }

    private func store(_ value: String, _ language: String) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: prefix + language)
        } else {
            UserDefaults.standard.set(value, forKey: prefix + language)
        }
    }
}
