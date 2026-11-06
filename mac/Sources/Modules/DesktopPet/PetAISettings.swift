import Foundation
import Security

/// 宠物 AI 对话用哪家服务（#55，docs/desktop-pet/CHAT.md §3）。
enum PetAIProvider: String, CaseIterable {
    /// Anthropic Claude（Messages API）。
    case anthropic
    /// OpenAI 兼容接口（Chat Completions）：OpenAI、各家兼容服务、本机 Ollama 这类本地模型。
    case openai
}

/// 宠物 AI 对话设置（UserDefaults 键 `pet.ai.*`）。API Key 不在这里，在钥匙串（`PetAIKeychain`）。
enum PetAISettings {
    static let providerKey = "pet.ai.provider"
    static let anthropicModelKey = "pet.ai.anthropicModel"
    static let openaiModelKey = "pet.ai.openaiModel"
    static let openaiBaseURLKey = "pet.ai.openaiBaseURL"
    static let maxTokensKey = "pet.ai.maxTokens"
    static let perMinuteKey = "pet.ai.perMinute"
    static let speakKey = "pet.ai.speak"
    static let speakWhenBusyKey = "pet.ai.speakWhenBusy"

    static let defaultAnthropicModel = "claude-haiku-5-5"
    static let defaultOpenAIModel = "gpt-4o-mini"
    static let defaultOpenAIBaseURL = "https://api.openai.com/v1"

    private static var defaults: UserDefaults { .standard }

    static var provider: PetAIProvider {
        PetAIProvider(rawValue: defaults.string(forKey: providerKey) ?? "") ?? .anthropic
    }

    /// 当前服务商用的模型（没填用默认：响应快、便宜的那档）。
    static var model: String {
        switch provider {
        case .anthropic:
            return nonEmpty(defaults.string(forKey: anthropicModelKey)) ?? defaultAnthropicModel
        case .openai:
            return nonEmpty(defaults.string(forKey: openaiModelKey)) ?? defaultOpenAIModel
        }
    }

    /// OpenAI 兼容接口的 Base URL（含 /v1，不含 /chat/completions）。
    static var openaiBaseURL: String {
        nonEmpty(defaults.string(forKey: openaiBaseURLKey)) ?? defaultOpenAIBaseURL
    }

    /// 单次回复最多多少 token（防误刷费用）。
    static var maxTokens: Int {
        let value = defaults.object(forKey: maxTokensKey) as? Int ?? 600
        return min(max(value, 100), 4000)
    }

    /// 每分钟最多发几次。
    static var perMinute: Int {
        let value = defaults.object(forKey: perMinuteKey) as? Int ?? 6
        return min(max(value, 1), 60)
    }

    /// 回复读出来（默认开）。
    static var speak: Bool { defaults.object(forKey: speakKey) as? Bool ?? true }
    /// 开会 / 录屏 / 勿扰 / 正在录音时也出声（默认关：只出文字）。
    static var speakWhenBusy: Bool { defaults.object(forKey: speakWhenBusyKey) as? Bool ?? false }

    /// 某个角色的人设（用户在设置里改过的）；nil = 用默认人设。
    static func persona(for character: String) -> String? {
        nonEmpty(defaults.string(forKey: "pet.ai.persona.\(character)"))
    }

    static func setPersona(_ text: String?, for character: String) {
        let key = "pet.ai.persona.\(character)"
        if let text = nonEmpty(text) {
            defaults.set(text, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// API Key 存钥匙串（照 `ClipboardCrypto` 的做法）：只在解锁后可读、不同步 iCloud；不进 UserDefaults、不写日志。
/// 每家服务商一条（account = 服务商 id）。
enum PetAIKeychain {
    private static let service = "com.baobox.app.pet.ai"

    static func key(for provider: PetAIProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    static func hasKey(for provider: PetAIProvider) -> Bool { key(for: provider) != nil }

    /// 保存（空字符串 = 删除）。返回是否成功。
    @discardableResult
    static func setKey(_ value: String, for provider: PetAIProvider) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        deleteKey(for: provider)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return true }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecAttrLabel as String: "Baobox Pet AI Key",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func deleteKey(for provider: PetAIProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
