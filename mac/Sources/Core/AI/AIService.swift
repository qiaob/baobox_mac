import Foundation
import os

/// AI 服务层（docs/ai-service/DESIGN.md）：用到模型的地方都从这里进，按「本地 / 云端」路由。
///
/// - 两类调用：翻译（原文 + 语言 + 术语表 → 译文）、通用生成（提示词 → 回复）；
/// - 本地后端：Hy-MT2 管翻译、Qwen3-1.7B 管通用生成 —— 进程和下载仍由 `OfflineTranslator` 负责，这里只转调；
/// - 云端后端：一个服务同时管翻译和生成（翻译用提示词实现），Key 在钥匙串；
/// - 云端出错（断网、超时、401、429、本机限额）时自动退回本地（有的话），结果里标 `usedFallback`；
///   出错后 30 秒内直接走本地，不让每句字幕都先等一次超时。
///
/// 系统翻译（`TranslationSession`）不进服务层：框架只认挂在视图上的 `.translationTask`，会话继续挂在浮层和字幕条上。
@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()

    enum Route: String, CaseIterable, Identifiable {
        case local
        case cloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .local: return L("ai.route.local")
            case .cloud: return L("ai.route.cloud")
            }
        }
    }

    /// 本地的两个模型。
    enum LocalModel {
        /// 翻译：Hy-MT2-1.8B。
        case translation
        /// 通用生成（纠错、纪要、周报、润色）：Qwen3-1.7B。
        case generation

        /// 嵌套类型不继承外层的主线程隔离，这里单独标上（`OfflineTranslator.shared` 是主线程隔离的）。
        @MainActor
        var backend: OfflineTranslator {
            switch self {
            case .translation: return .shared
            case .generation: return .corrector
            }
        }
    }

    struct Reply {
        let text: String
        /// 实际走的是哪边。
        let route: Route
        /// 要的是云端、云端出错改用了本地。
        let usedFallback: Bool
    }

    /// 云端服务配置完整（有 Key 或指向本机、有模型、地址像样）。设置页和各模块的引擎选择据此置灰。
    @Published private(set) var cloudConfigured = false
    /// 当前这家存了 Key（设置页显示「已保存」用；不暴露 Key 本身）。
    @Published private(set) var hasAPIKey = false

    private static let log = Logger(subsystem: "com.baobox.app", category: "ai")
    /// 云端出错后多久内直接走本地。
    private static let cooldown: TimeInterval = 30

    private var cloudKey: String?
    private var recentRequests: [Date] = []
    private var cloudUnavailableUntil: Date?

    private init() {
        refreshCloudConfiguration()
    }

    // MARK: - 状态

    /// 设置改了（服务商、地址、模型、Key）后调用。
    func refreshCloudConfiguration() {
        let provider = AICloudSettings.provider
        cloudKey = AIKeychain.load(provider)
        hasAPIKey = cloudKey != nil
        cloudConfigured = cloudConfig() != nil
        cloudUnavailableUntil = nil
    }

    private func cloudConfig() -> AICloudConfig? {
        let provider = AICloudSettings.provider
        guard let baseURL = AICloudSettings.baseURL(provider) else { return nil }
        let model = AICloudSettings.model(provider)
        guard !model.isEmpty else { return nil }
        let key = cloudKey ?? ""
        if key.isEmpty, !AICloudSettings.keyOptional(provider, baseURL: baseURL) { return nil }
        return AICloudConfig(provider: provider, baseURL: baseURL, model: model, apiKey: key)
    }

    func isLocalReady(_ model: LocalModel) -> Bool { model.backend.isReady }

    /// 本地模型的推理进程正在启动（首次加载要几秒）。
    func isLocalStarting(_ model: LocalModel) -> Bool { model.backend.isStartingServer }

    /// 这条路现在能不能用：云端 = 配置完整；本地 = 模型已下载。
    func isReady(_ route: Route, model: LocalModel) -> Bool {
        switch route {
        case .cloud: return cloudConfigured
        case .local: return isLocalReady(model)
        }
    }

    /// 本地模型常驻（实时翻译、听写期间）；与 `endLocalKeepAlive` 配对。
    func beginLocalKeepAlive(_ model: LocalModel) { model.backend.beginKeepAlive() }
    func endLocalKeepAlive(_ model: LocalModel) { model.backend.endKeepAlive() }

    // MARK: - Key

    func saveAPIKey(_ key: String) -> Bool {
        let saved = AIKeychain.save(key, for: AICloudSettings.provider)
        refreshCloudConfiguration()
        return saved
    }

    func deleteAPIKey() {
        AIKeychain.delete(AICloudSettings.provider)
        refreshCloudConfiguration()
    }

    // MARK: - 翻译

    /// 把 `text` 译成 `target`。`timeout` 只管云端（实时字幕给几秒，超时这句改用本地）。
    func translate(_ text: String, to target: TranslationLanguage, from source: TranslationLanguage? = nil,
                   glossary: [GlossaryEntry] = [], route: Route, timeout: TimeInterval = 30) async throws -> Reply {
        let local: () async throws -> String = {
            try await OfflineTranslator.shared.translate(text, to: target, from: source, glossary: glossary)
        }
        guard route == .cloud else { return Reply(text: try await local(), route: .local, usedFallback: false) }
        return try await withCloud(fallback: isLocalReady(.translation) ? local : nil) { client, maxTokens in
            let prompt = AIPrompts.translation(text: text, target: target, source: source, glossary: glossary)
            return try await client.complete(system: prompt.system, user: prompt.user,
                                             maxTokens: min(maxTokens, max(256, text.count * 3)), timeout: timeout)
        }
    }

    // MARK: - 通用生成

    /// 一问一答。本地走 Qwen3（`sampling` 只对本地有效；云端新版 API 不收采样参数）。
    func generate(_ prompt: String, maxTokens: Int, sampling: OfflineTranslator.Sampling, route: Route,
                  timeout: TimeInterval = 60) async throws -> Reply {
        let local: () async throws -> String = {
            OfflinePrompt.clean(try await OfflineTranslator.corrector.respond(to: prompt, maxTokens: maxTokens,
                                                                              sampling: sampling))
        }
        guard route == .cloud else { return Reply(text: try await local(), route: .local, usedFallback: false) }
        return try await withCloud(fallback: isLocalReady(.generation) ? local : nil) { client, cap in
            // Qwen3 的「/no_think」软开关对云端模型没意义，去掉免得被当成内容。
            let user = prompt.replacingOccurrences(of: "/no_think", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 云端模型可能先想再答，给点余量；仍受用户设的上限约束。
            return try await client.complete(system: nil, user: user, maxTokens: min(cap, max(256, maxTokens)),
                                             timeout: timeout)
        }
    }

    // MARK: - 纠错 + 翻译合一（实时字幕两项都选云端时）

    /// 一条请求「先改识别错字再翻译」，少一次往返。只走云端、不自动退回：调用方失败时按原流程分别走本地。
    func correctAndTranslate(_ text: String, context: String, to target: TranslationLanguage,
                             glossary: [GlossaryEntry], timeout: TimeInterval) async throws
        -> (corrected: String, translation: String) {
        let reply = try await withCloud(fallback: nil) { client, cap in
            let prompt = AIPrompts.correctAndTranslate(text: text, context: context, target: target,
                                                       glossary: glossary)
            return try await client.complete(system: prompt.system, user: prompt.user,
                                             maxTokens: min(cap, max(256, text.count * 5)), timeout: timeout)
        }
        guard let parsed = AIPrompts.parseCorrectAndTranslate(reply.text) else { throw AICloudError.badResponse }
        return parsed
    }

    // MARK: - 测试连接

    /// 发一条很短的请求；nil = 通了，否则是出错原因。不算进每分钟次数，也不触发退回本地。
    func testConnection() async -> String? {
        refreshCloudConfiguration()
        guard let config = cloudConfig() else { return AICloudError.notConfigured.localizedDescription }
        do {
            _ = try await AICloudClient(config: config).complete(system: nil, user: "Reply with the single word: OK",
                                                                 maxTokens: 64, timeout: 20)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - 云端公共流程

    /// 配置 → 本机限额 → 冷却期 → 请求；出错时有本地就退回本地。
    private func withCloud(fallback: (() async throws -> String)?,
                           request: (AICloudClient, Int) async throws -> String) async throws -> Reply {
        func fallBack(_ error: Error) async throws -> Reply {
            guard let fallback else { throw error }
            return Reply(text: try await fallback(), route: .local, usedFallback: true)
        }
        guard let config = cloudConfig() else { return try await fallBack(AICloudError.notConfigured) }
        if let until = cloudUnavailableUntil, until > Date() {
            return try await fallBack(AICloudError.offline(""))
        }
        guard acquireRequestSlot() else { return try await fallBack(AICloudError.rateLimited) }
        do {
            let text = try await request(AICloudClient(config: config), AICloudSettings.maxTokens)
            cloudUnavailableUntil = nil
            return Reply(text: text, route: .cloud, usedFallback: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.log.error("cloud request failed: \(error.localizedDescription, privacy: .public)")
            if Self.isServiceDown(error) {
                cloudUnavailableUntil = Date().addingTimeInterval(Self.cooldown)
            }
            return try await fallBack(error)
        }
    }

    /// 断网、超时、Key 不对、被限流、服务端 5xx：这段时间里接着请求也多半失败，先走本地。
    /// 回复格式不对、被拒答只是这一句的事，不冷却。
    private static func isServiceDown(_ error: Error) -> Bool {
        guard let error = error as? AICloudError else { return false }
        switch error {
        case .timeout, .offline, .unauthorized, .throttled: return true
        case .http(let status, _): return status >= 500
        case .notConfigured, .rateLimited, .refused, .badResponse: return false
        }
    }

    /// 每分钟次数上限（滑动窗口）：到了就不发，免得误刷费用。
    private func acquireRequestSlot() -> Bool {
        let now = Date()
        recentRequests.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentRequests.count < AICloudSettings.perMinute else { return false }
        recentRequests.append(now)
        return true
    }
}

/// 云端用的提示词。
enum AIPrompts {
    /// 翻译：系统提示定规矩，用户消息只放原文。带上术语表（与本地 Hy-MT2 同一套 `TranslationGlossary.references`）。
    static func translation(text: String, target: TranslationLanguage, source: TranslationLanguage?,
                            glossary: [GlossaryEntry]) -> (system: String, user: String) {
        let from = source.map { " from \($0.englishName)" } ?? ""
        var system = """
        You are a translation engine. Translate the user's text\(from) into \(target.englishName). \
        Output only the translation: no explanations, no notes, no quotation marks. Keep the line breaks.
        """
        let references = TranslationGlossary.references(for: text, target: target, entries: glossary)
        if !references.isEmpty {
            system += "\nUse these translations for the following terms:\n"
                + references.map { "- \($0.source) → \($0.target)" }.joined(separator: "\n")
        }
        return (system, text)
    }

    /// 纠错 + 翻译：输出一行 JSON。
    static func correctAndTranslate(text: String, context: String, target: TranslationLanguage,
                                    glossary: [GlossaryEntry]) -> (system: String, user: String) {
        var system = """
        你同时做两件事：
        1. 「待纠正」是一段中文语音识别结果，可能有同音字、近音字识别错误。结合「上文」只改正明显识别错的字词；\
        不要改写句子，不要增删内容。没有错就原样保留。
        2. 把改正后的句子翻译成 \(target.englishName)，只译这一句。
        只输出一行 JSON：{"corrected": "改正后的中文", "translation": "译文"}，不要别的内容。
        """
        let references = TranslationGlossary.references(for: text, target: target, entries: glossary)
        if !references.isEmpty {
            system += "\n术语译法：\n" + references.map { "- \($0.source) → \($0.target)" }.joined(separator: "\n")
        }
        let user = "上文：\(context.isEmpty ? "（无）" : context)\n待纠正：\(text)"
        return (system, user)
    }

    /// 从回复里找出 JSON（模型偶尔会包一层 ```json）。
    static func parseCorrectAndTranslate(_ reply: String) -> (corrected: String, translation: String)? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let corrected = (object["corrected"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let translation = (object["translation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !corrected.isEmpty, !translation.isEmpty else { return nil }
        return (corrected, translation)
    }
}
