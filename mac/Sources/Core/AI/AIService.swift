import Foundation
import os

/// 一次请求走哪：内置的本地模型、本机下载的 Qwen3 大模型（`LocalModelEntry.id`），或某个云端模型（`AICloudModel.id`）。
enum AIRoute: Hashable {
    case local
    case localModel(String)
    case cloud(String)

    /// 云端模型 id（不是云端时为 nil）。
    var modelID: String? {
        if case .cloud(let id) = self { return id }
        return nil
    }
}

/// AI 服务层（docs/ai-service/DESIGN.md）：用到模型的地方都从这里进，按 `AIRoute` 走本地或某个云端模型。
///
/// - 两类调用：翻译（原文 + 语言 + 术语表 → 译文）、通用生成（提示词 → 回复）；
/// - 本地后端：Hy-MT2 管翻译、Qwen3-1.7B 管通用生成 —— 进程和下载仍由 `OfflineTranslator` 负责，这里只转调；
/// - 云端后端：`AIModelStore` 里的账号 + 模型（翻译用提示词实现），Key 在钥匙串；
/// - 云端出错（断网、超时、401、429、本机限额、回复被截断）时自动退回本地（有的话），结果里标 `usedFallback`；
///   服务级错误后 30 秒内这个账号的请求直接走本地，不让每句字幕都先等一次超时。
///
/// 系统翻译（`TranslationSession`）不进服务层：框架只认挂在视图上的 `.translationTask`，会话继续挂在浮层和字幕条上。
@MainActor
final class AIService {
    static let shared = AIService()

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
        let route: AIRoute
        /// 要的是云端、云端出错改用了本地。
        let usedFallback: Bool
    }

    private static let log = Logger(subsystem: "com.baobox.app", category: "ai")
    /// 云端出服务级错误后，这个账号多久内直接走本地。
    private static let cooldown: TimeInterval = 30

    private var recentRequests: [Date] = []
    /// 账号 id → 这之前直接走本地。
    private var unavailableUntil: [String: Date] = [:]

    private init() {}

    // MARK: - 状态

    func isLocalReady(_ model: LocalModel) -> Bool { model.backend.isReady }

    /// 这条路现在能不能用：云端 = 模型配置完整；本地 = 模型已下载。
    func isReady(_ route: AIRoute, local model: LocalModel) -> Bool {
        switch route {
        case .local: return isLocalReady(model)
        case .localModel(let id): return LocalModels.isInstalled(id)
        case .cloud(let id): return AIModelStore.shared.isConfigured(id)
        }
    }

    /// 通用类功能这次走哪：选了云端模型且配置完整 → 云端；选了本机大模型且已下载 → 它；否则内置本地模型
    /// （docs/ai-service/DESIGN.md §3.2，docs/local-models/DESIGN.md §5）。
    func route(for feature: AIFeature) -> AIRoute {
        switch AIFeatureSettings.choice(feature) {
        case .model(let id) where AIModelStore.shared.isConfigured(id): return .cloud(id)
        case .localModel(let id) where LocalModels.isInstalled(id): return .localModel(id)
        default: return .local
        }
    }

    /// 这条路要用到的本地推理进程；云端为 nil。调用方据此常驻（`beginKeepAlive` / `endKeepAlive` 配对，会顺带把模型加载起来，
    /// 所以只对实际要用的那个调用）和判断「还在加载」。
    func localBackend(for route: AIRoute, local model: LocalModel) -> OfflineTranslator? {
        switch route {
        case .local: return model.backend
        case .localModel(let id): return LocalModels.entry(id)?.translator
        case .cloud: return nil
        }
    }

    /// 改了账号的地址、Key 或它下面的模型：清掉冷却，下一句就重新试云端。
    func resetCooldown(accountID: String) {
        unavailableUntil[accountID] = nil
    }

    // MARK: - 翻译

    /// 把 `text` 译成 `target`。`timeout` 只管云端（实时字幕给几秒，超时这句改用本地）。
    func translate(_ text: String, to target: TranslationLanguage, from source: TranslationLanguage? = nil,
                   glossary: [GlossaryEntry] = [], route: AIRoute, timeout: TimeInterval = 30) async throws -> Reply {
        let local: () async throws -> String = {
            try await OfflineTranslator.shared.translate(text, to: target, from: source, glossary: glossary)
        }
        if case .localModel(let id) = route {
            let prompt = AIPrompts.translation(text: text, target: target, source: source, glossary: glossary)
            // Qwen3 一次只收一条消息：规矩和原文拼在一起；关掉思考，低温度求稳。
            return try await withLocalModel(id, fallback: isLocalReady(.translation) ? local : nil) { backend, extra in
                try await backend.respond(to: prompt.system + "\n\n" + prompt.user,
                                          maxTokens: max(256, text.count * 3) + extra, sampling: .correction)
            }
        }
        guard let modelID = route.modelID else {
            return Reply(text: try await local(), route: .local, usedFallback: false)
        }
        return try await withCloud(modelID: modelID, fallback: isLocalReady(.translation) ? local : nil) { client, cap in
            let prompt = AIPrompts.translation(text: text, target: target, source: source, glossary: glossary)
            return try await client.complete(system: prompt.system, user: prompt.user,
                                             maxTokens: min(cap, max(256, text.count * 3)), timeout: timeout)
        }
    }

    // MARK: - 通用生成

    /// 一问一答。本地走 Qwen3（`sampling` 只对本地有效；云端新版 API 不收采样参数）。
    func generate(_ prompt: String, maxTokens: Int, sampling: OfflineTranslator.Sampling, route: AIRoute,
                  timeout: TimeInterval = 60) async throws -> Reply {
        let local: () async throws -> String = {
            OfflinePrompt.clean(try await OfflineTranslator.corrector.respond(to: prompt, maxTokens: maxTokens,
                                                                              sampling: sampling))
        }
        if case .localModel(let id) = route {
            return try await withLocalModel(id, fallback: isLocalReady(.generation) ? local : nil) { backend, extra in
                OfflinePrompt.clean(try await backend.respond(to: prompt, maxTokens: maxTokens + extra, sampling: sampling))
            }
        }
        guard let modelID = route.modelID else {
            return Reply(text: try await local(), route: .local, usedFallback: false)
        }
        return try await withCloud(modelID: modelID, fallback: isLocalReady(.generation) ? local : nil) { client, cap in
            // Qwen3 的「/no_think」软开关对云端模型没意义，去掉免得被当成内容。
            let user = prompt.replacingOccurrences(of: "/no_think", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 云端模型可能先想再答，给点余量；仍受用户设的上限约束。
            return try await client.complete(system: nil, user: user, maxTokens: min(cap, max(256, maxTokens)),
                                             timeout: timeout)
        }
    }

    // MARK: - 纠错 + 翻译合一（实时字幕的纠错和翻译选了同一个云端模型时）

    /// 一条请求「先改识别错字再翻译」，少一次往返。只走云端、不自动退回：调用方失败时按原流程分别处理。
    func correctAndTranslate(_ text: String, context: String, to target: TranslationLanguage,
                             glossary: [GlossaryEntry], modelID: String, timeout: TimeInterval) async throws
        -> (corrected: String, translation: String) {
        let reply = try await withCloud(modelID: modelID, fallback: nil) { client, cap in
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
    func testConnection(modelID: String) async -> String? {
        let store = AIModelStore.shared
        guard let config = store.config(modelID: modelID) else {
            return store.problem(modelID: modelID) ?? AICloudError.notConfigured.localizedDescription
        }
        // 本机服务（Ollama）第一次要把整个模型读进内存，等久一点；报错也别说「云端」。
        let local = AICloudSettings.isLocalHost(config.baseURL)
        do {
            _ = try await AICloudClient(config: config).complete(system: nil, user: "Reply with the single word: OK",
                                                                 maxTokens: 64, timeout: local ? 120 : 20)
        } catch AICloudError.truncated {
            // 回复被截断也说明连接、Key、模型名都没问题。
        } catch AICloudError.timeout where local {
            return L("ai.error.localTimeout")
        } catch AICloudError.offline where local {
            return L("ai.error.localOffline")
        } catch {
            return error.localizedDescription
        }
        resetCooldown(accountID: config.accountID)
        return nil
    }

    // MARK: - 本机大模型

    /// 推理模型（DeepSeek-R1 蒸馏）先思考再回答，思考很长：输出上限多给这么多，免得答案没写出来就截断。
    private static let reasoningExtraTokens = 3072

    /// 选定的本地模型：没下载（被删了）或出错（进程起不来、超时、推理模型没想完…）时退回这一类的默认本地模型（有的话）。
    /// `request` 的第二个参数是推理模型要多给的输出上限（其余为 0）。
    private func withLocalModel(_ id: String, fallback: (() async throws -> String)?,
                                request: (OfflineTranslator, Int) async throws -> String) async throws -> Reply {
        func fallBack(_ error: Error) async throws -> Reply {
            guard let fallback else { throw error }
            return Reply(text: try await fallback(), route: .local, usedFallback: true)
        }
        guard let entry = LocalModels.entry(id), entry.translator.isReady else {
            return try await fallBack(OfflineTranslationError.modelMissing)
        }
        do {
            let text = try await request(entry.translator, entry.isReasoning ? Self.reasoningExtraTokens : 0)
            // 推理模型想到一半就到上限：清理后还以 <think> 开头 = 没有答案，别把思考过程当结果。
            if entry.isReasoning, text.hasPrefix("<think>") { throw AICloudError.truncated }
            return Reply(text: text, route: .localModel(id), usedFallback: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.log.error("local model \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return try await fallBack(error)
        }
    }

    // MARK: - 云端公共流程

    /// 配置 → 冷却期 → 本机限额（每分钟、每天）→ 请求；出错时有本地就退回本地。
    private func withCloud(modelID: String, fallback: (() async throws -> String)?,
                           request: (AICloudClient, Int) async throws -> AICloudCompletion) async throws -> Reply {
        func fallBack(_ error: Error) async throws -> Reply {
            guard let fallback else { throw error }
            return Reply(text: try await fallback(), route: .local, usedFallback: true)
        }
        guard let config = AIModelStore.shared.config(modelID: modelID) else {
            return try await fallBack(AICloudError.notConfigured)
        }
        if let until = unavailableUntil[config.accountID], until > Date() {
            return try await fallBack(AICloudError.offline(""))
        }
        guard acquireRequestSlot() else { return try await fallBack(AICloudError.rateLimited) }
        // 每天的上限只管花钱的：本机服务（Ollama）不算（#100）。
        let metered = !AICloudSettings.isLocalHost(config.baseURL)
        if metered, !AIUsageMeter.shared.admit() { return try await fallBack(AICloudError.dailyLimit) }
        do {
            let completion = try await request(AICloudClient(config: config), AICloudSettings.maxTokens)
            if metered { AIUsageMeter.shared.record(completion) }
            unavailableUntil[config.accountID] = nil
            return Reply(text: completion.text, route: .cloud(modelID), usedFallback: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.log.error("cloud request failed: \(error.localizedDescription, privacy: .public)")
            if Self.isServiceDown(error) {
                unavailableUntil[config.accountID] = Date().addingTimeInterval(Self.cooldown)
            }
            return try await fallBack(error)
        }
    }

    /// 断网、超时、Key 不对、被限流、服务端 5xx：这段时间里接着请求也多半失败，先走本地。
    /// 回复格式不对、被拒答、被截断只是这一句的事，不冷却。
    private static func isServiceDown(_ error: Error) -> Bool {
        guard let error = error as? AICloudError else { return false }
        switch error {
        case .timeout, .offline, .unauthorized, .throttled: return true
        case .http(let status, _): return status >= 500
        case .notConfigured, .rateLimited, .dailyLimit, .refused, .badResponse, .truncated: return false
        }
    }

    /// 每分钟次数上限（滑动窗口，所有云端模型合计）：到了就不发，免得误刷费用。
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
