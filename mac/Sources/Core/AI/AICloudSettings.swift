import Foundation
import Security

/// 云端接口的两种协议。
enum AICloudAPI {
    /// Anthropic Messages API。
    case anthropic
    /// OpenAI Chat Completions（各家兼容接口都走这条）。
    case openAI
}

/// 云端服务（docs/ai-service/DESIGN.md §3、§4.1）：Claude，一组常用的 OpenAI 兼容服务（预填地址和默认模型），
/// 本机 Ollama，以及自定义地址。每个服务各存各的地址、模型和 Key，切来切去不丢。
enum AICloudProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    case gemini
    case deepseek
    case qwen
    case moonshot
    case zhipu
    case openrouter
    case siliconflow
    case groq
    case ollama
    /// 自定义 OpenAI 兼容地址（rawValue 沿用最初版本，已存的设置和 Key 不丢）。
    case openAICompatible

    var id: String { rawValue }

    var api: AICloudAPI { self == .anthropic ? .anthropic : .openAI }

    /// 菜单里的名字：品牌名照原样，带中文说明的走本地化。
    var title: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .deepseek: return "DeepSeek"
        case .qwen: return L("ai.provider.qwen")
        case .moonshot: return L("ai.provider.moonshot")
        case .zhipu: return L("ai.provider.zhipu")
        case .openrouter: return "OpenRouter"
        case .siliconflow: return L("ai.provider.siliconflow")
        case .groq: return "Groq"
        case .ollama: return L("ai.provider.ollama")
        case .openAICompatible: return L("ai.provider.openAI")
        }
    }

    /// 没填 Base URL 时用的地址（OpenAI 兼容的都到 `/v1` 这一层，请求再拼 `/chat/completions`）。
    /// 通义千问、Kimi 用国内站；海外账号把地址改成各自的国际站即可。
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .openAICompatible: return ""
        }
    }

    /// 没填模型时用的模型：各家响应快、便宜的那档。Ollama 和自定义各人装的不一样，必须自己填。
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-haiku-5-5"
        case .openai: return "gpt-4o-mini"
        case .gemini: return "gemini-2.5-flash"
        case .deepseek: return "deepseek-chat"
        case .qwen: return "qwen-plus"
        case .moonshot: return "moonshot-v1-8k"
        case .zhipu: return "glm-4-flash"
        case .openrouter: return "openai/gpt-4o-mini"
        case .siliconflow: return "Qwen/Qwen2.5-7B-Instruct"
        case .groq: return "llama-3.1-8b-instant"
        case .ollama, .openAICompatible: return ""
        }
    }

    /// 模型输入框的占位示例（没有默认模型时给个样子）。
    var modelExample: String {
        switch self {
        case .ollama: return "qwen2.5:7b"
        case .openAICompatible: return "gpt-4o-mini"
        default: return defaultModel
        }
    }

    /// 去哪儿申请 Key（设置页「获取 API Key」链接）；本机服务和自定义没有。
    var keyPageURL: URL? {
        let text: String
        switch self {
        case .anthropic: text = "https://console.anthropic.com/settings/keys"
        case .openai: text = "https://platform.openai.com/api-keys"
        case .gemini: text = "https://aistudio.google.com/apikey"
        case .deepseek: text = "https://platform.deepseek.com/api_keys"
        case .qwen: text = "https://bailian.console.aliyun.com/?apiKey=1"
        case .moonshot: text = "https://platform.moonshot.cn/console/api-keys"
        case .zhipu: text = "https://open.bigmodel.cn/usercenter/apikeys"
        case .openrouter: text = "https://openrouter.ai/keys"
        case .siliconflow: text = "https://cloud.siliconflow.cn/account/ak"
        case .groq: text = "https://console.groq.com/keys"
        case .ollama, .openAICompatible: return nil
        }
        return URL(string: text)
    }

    /// 存在 UserDefaults 里的键前缀。Claude 和自定义沿用最初版本的前缀（自定义当时叫 `ai.cloud.openai`，
    /// 所以 OpenAI 官方这一项另起 `ai.cloud.openaiOfficial`，免得两项共用一份地址和模型）。
    fileprivate var keyPrefix: String {
        switch self {
        case .openAICompatible: return "ai.cloud.openai"
        case .openai: return "ai.cloud.openaiOfficial"
        default: return "ai.cloud.\(rawValue)"
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

    /// 实际用的地址：没填用默认；填得不像网址（或自定义没填）返回 nil（配置不完整）。
    static func baseURL(_ provider: AICloudProvider) -> URL? {
        let stored = UserDefaults.standard.string(forKey: baseURLKey(provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var text = stored.isEmpty ? provider.defaultBaseURL : stored
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// 这个服务、这个地址可以不填 Key：地址指向本机（Ollama 这类），内容也不出本机。
    static func keyOptional(_ provider: AICloudProvider, baseURL: URL) -> Bool {
        provider.api == .openAI && isLocalHost(baseURL)
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
