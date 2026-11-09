import Foundation
import Security

/// 云端服务的种类（docs/ai-service/DESIGN.md §3）。
enum AICloudProvider: String, CaseIterable, Identifiable {
    /// Anthropic Claude（Messages API）。
    case anthropic
    /// OpenAI 兼容（Chat Completions，自填 Base URL；本机 Ollama 也走这条）。
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: return L("ai.provider.anthropic")
        case .openAICompatible: return L("ai.provider.openAI")
        }
    }

    /// 没填 Base URL 时用的地址。
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAICompatible: return "https://api.openai.com/v1"
        }
    }

    /// 没填模型时用的模型。Claude 默认响应快、便宜的那档；OpenAI 兼容各家模型名不同，必须自己填。
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-haiku-5-5"
        case .openAICompatible: return ""
        }
    }

    /// 存在 UserDefaults 里的键前缀：两家各存各的模型和地址，切来切去不丢。
    fileprivate var keyPrefix: String {
        switch self {
        case .anthropic: return "ai.cloud.anthropic"
        case .openAICompatible: return "ai.cloud.openai"
        }
    }
}

/// 云端服务配置。Key 在钥匙串（`AIKeychain`），这里只有不敏感的设置。
enum AICloudSettings {
    static let providerKey = "ai.cloud.provider"
    static let maxTokensKey = "ai.cloud.maxTokens"
    static let perMinuteKey = "ai.cloud.perMinute"

    static func modelKey(_ provider: AICloudProvider) -> String { provider.keyPrefix + ".model" }
    static func baseURLKey(_ provider: AICloudProvider) -> String { provider.keyPrefix + ".baseURL" }

    /// 单次回复长度上限（token）的可调范围与出厂值。
    static let maxTokensRange = 128...8192
    static let defaultMaxTokens = 1024
    /// 每分钟请求次数上限的可调范围与出厂值。实时字幕每分钟要几十次（定稿逐句 + 降频后的草稿），出厂给 120。
    static let perMinuteRange = 10...600
    static let defaultPerMinute = 120

    static var provider: AICloudProvider {
        get { UserDefaults.standard.string(forKey: providerKey).flatMap(AICloudProvider.init(rawValue:)) ?? .anthropic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    /// 实际用的模型：没填用默认。
    static func model(_ provider: AICloudProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: modelKey(provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? provider.defaultModel : stored
    }

    /// 实际用的地址：没填用默认；填得不像网址返回 nil（配置不完整）。
    static func baseURL(_ provider: AICloudProvider) -> URL? {
        let stored = UserDefaults.standard.string(forKey: baseURLKey(provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var text = stored.isEmpty ? provider.defaultBaseURL : stored
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// 地址指向本机（Ollama 这类）：可以不填 Key，内容也不出本机。
    static func isLocalHost(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    static var maxTokens: Int {
        get {
            let value = UserDefaults.standard.object(forKey: maxTokensKey) as? Int ?? defaultMaxTokens
            return min(max(value, maxTokensRange.lowerBound), maxTokensRange.upperBound)
        }
        set { UserDefaults.standard.set(newValue, forKey: maxTokensKey) }
    }

    static var perMinute: Int {
        get {
            let value = UserDefaults.standard.object(forKey: perMinuteKey) as? Int ?? defaultPerMinute
            return min(max(value, perMinuteRange.lowerBound), perMinuteRange.upperBound)
        }
        set { UserDefaults.standard.set(newValue, forKey: perMinuteKey) }
    }
}

/// 云端服务的 API Key：存钥匙串（generic password，照 `ClipboardCrypto` 的做法），不进 UserDefaults、不写日志。
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`：解锁后才读得到、不同步 iCloud、不随备份迁走。
enum AIKeychain {
    private static let service = "com.baobox.app"

    private static func account(_ provider: AICloudProvider) -> String {
        "ai.cloud.\(provider.rawValue).apiKey"
    }

    static func load(_ provider: AICloudProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(provider),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// 先删后加（钥匙串里同名项不能直接 Add）。返回是否存成功。
    @discardableResult
    static func save(_ key: String, for provider: AICloudProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        delete(provider)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(provider),
            kSecAttrLabel as String: "Baobox AI API Key (\(provider.rawValue))",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ provider: AICloudProvider) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(provider),
        ]
        SecItemDelete(query as CFDictionary)
    }
}
