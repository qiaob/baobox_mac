import Foundation

/// 云端请求出错。`AIService` 据此决定退回本地（docs/ai-service/DESIGN.md §4.3）。
enum AICloudError: LocalizedError {
    case notConfigured
    /// 本机的每分钟次数上限到了（没发出去）。
    case rateLimited
    /// 本机的每天请求上限到了（没发出去，见 `AIUsageMeter`）。
    case dailyLimit
    case timeout
    case offline(String)
    /// 401 / 403：Key 不对或没权限。
    case unauthorized
    /// 429：服务方限流 / 额度用完。
    case throttled
    case http(Int, String)
    case refused
    case badResponse
    /// 回复写到长度上限被截断（Claude `stop_reason: max_tokens`、OpenAI `finish_reason: length`）：半截译文不当完整结果用。
    case truncated

    var errorDescription: String? {
        switch self {
        case .notConfigured: return L("ai.error.notConfigured")
        case .rateLimited: return L("ai.error.rateLimited")
        case .dailyLimit: return L("ai.error.dailyLimit")
        case .timeout: return L("ai.error.timeout")
        case .offline(let detail):
            let base = L("ai.error.offline")
            return detail.isEmpty ? base : base + "\n" + detail
        case .unauthorized: return L("ai.error.unauthorized")
        case .throttled: return L("ai.error.throttled")
        case .http(let status, let detail):
            let base = L("ai.error.http \(status)")
            return detail.isEmpty ? base : base + "\n" + detail
        case .refused: return L("ai.error.refused")
        case .badResponse: return L("ai.error.badResponse")
        case .truncated: return L("ai.error.truncated")
        }
    }
}

/// 一次云端请求要的配置（主线程从 `AIModelStore` 取好再交过来，请求本身在后台跑）。
struct AICloudConfig {
    let provider: AICloudProvider
    let baseURL: URL
    let model: String
    /// OpenAI 兼容指向本机（Ollama）时可以为空。
    let apiKey: String
    /// 哪个账号（出服务级错误时按账号冷却）。
    let accountID: String
}

/// 一次回复：文字 + 服务方报的 token 数（没报就是 0）。
struct AICloudCompletion {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
}

/// 云端 HTTP 客户端：Claude Messages API / OpenAI Chat Completions，一问一答、不流式（流式是 P1）。
/// 只用 `URLSession` 的 async 接口，不在主线程同步等待；日志里不记 Key、不记内容。
struct AICloudClient {
    let config: AICloudConfig

    private static let anthropicVersion = "2026-10-21"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// `system` 可为空；`maxTokens` 已由调用方按用户上限截好。
    func complete(system: String?, user: String, maxTokens: Int, timeout: TimeInterval) async throws
        -> AICloudCompletion {
        switch config.provider.api {
        case .anthropic:
            return try await anthropic(system: system, user: user, maxTokens: maxTokens, timeout: timeout,
                                       tuning: .fast)
        case .openAI:
            return try await openAI(system: system, user: user, maxTokens: maxTokens, timeout: timeout,
                                    tokenField: "max_tokens")
        }
    }

    // MARK: - Claude

    /// 请求里带多少「要快」的参数。
    private enum ClaudeTuning {
        /// `effort: low` + 关思考（翻译、纠错要快；Haiku 5.5 在 high 档及以下可以关思考）。
        case fast
        /// 只带 `effort: low`：Opus 5.5、Sonnet 5.5 不允许关思考，低档思考仍然快。
        case effortOnly
        /// 都不带：模型连 effort 都不认。
        case plain
    }

    /// 模型不认关思考（400 里提到 thinking）→ 去掉 thinking、保留 effort 再发；不认 effort → 都去掉再发（docs/ai-service/DESIGN.md §4.2）。
    /// 采样参数（temperature 等）新版 API 一律不收，不发。
    private func anthropic(system: String?, user: String, maxTokens: Int, timeout: TimeInterval,
                           tuning: ClaudeTuning) async throws -> AICloudCompletion {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": user]],
        ]
        if let system, !system.isEmpty { body["system"] = system }
        switch tuning {
        case .fast:
            body["output_config"] = ["effort": "low"]
            body["thinking"] = ["type": "disabled"]
        case .effortOnly:
            body["output_config"] = ["effort": "low"]
        case .plain:
            break
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await send(request)
        if status == 400 {
            let message = Self.errorMessage(data).lowercased()
            // 先看 thinking：Opus / Sonnet 5.5 的报错可能同时提到 effort（「用 effort 控制」），不能因此把 effort 也丢掉。
            if tuning == .fast, message.contains("thinking") {
                return try await anthropic(system: system, user: user, maxTokens: maxTokens, timeout: timeout,
                                           tuning: .effortOnly)
            }
            if tuning != .plain, message.contains("effort") || message.contains("output_config") {
                return try await anthropic(system: system, user: user, maxTokens: maxTokens, timeout: timeout,
                                           tuning: .plain)
            }
        }
        try Self.check(status: status, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AICloudError.badResponse
        }
        switch object["stop_reason"] as? String {
        case "refusal": throw AICloudError.refused
        case "max_tokens": throw AICloudError.truncated
        default: break
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AICloudError.badResponse }
        // 输入 = 普通 + 写缓存 + 读缓存（我们不用缓存，后两项一般没有）。
        let usage = object["usage"] as? [String: Any] ?? [:]
        let input = Self.count(usage["input_tokens"]) + Self.count(usage["cache_creation_input_tokens"])
            + Self.count(usage["cache_read_input_tokens"])
        return AICloudCompletion(text: trimmed, inputTokens: input, outputTokens: Self.count(usage["output_tokens"]))
    }

    // MARK: - OpenAI 兼容

    /// 新一些的 OpenAI 模型只认 `max_completion_tokens`：400 里提到 max_tokens 就换个字段再试一次。
    private func openAI(system: String?, user: String, maxTokens: Int, timeout: TimeInterval,
                        tokenField: String) async throws -> AICloudCompletion {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        var messages: [[String: String]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])
        let body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            tokenField: maxTokens,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await send(request)
        if status == 400, tokenField == "max_tokens",
           Self.errorMessage(data).lowercased().contains("max_tokens") {
            return try await openAI(system: system, user: user, maxTokens: maxTokens, timeout: timeout,
                                    tokenField: "max_completion_tokens")
        }
        try Self.check(status: status, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AICloudError.badResponse
        }
        if (choices.first?["finish_reason"] as? String) == "length" { throw AICloudError.truncated }
        let cleaned = OfflinePrompt.clean(content)
        guard !cleaned.isEmpty else { throw AICloudError.badResponse }
        // 有的兼容服务不回 usage，那就记 0。
        let usage = object["usage"] as? [String: Any] ?? [:]
        return AICloudCompletion(text: cleaned, inputTokens: Self.count(usage["prompt_tokens"]),
                                 outputTokens: Self.count(usage["completion_tokens"]))
    }

    // MARK: - 模型列表

    /// 服务商的模型 id（docs/ai-service/DESIGN.md §3.4）：Claude `GET /v1/models`，OpenAI 兼容 `GET {base}/models`
    /// （Ollama 返回本机已安装的模型）。不过滤、不排序，交给 `AIModelCatalog`。
    func listModels() async throws -> [String] {
        var request: URLRequest
        switch config.provider.api {
        case .anthropic:
            var components = URLComponents(url: config.baseURL.appendingPathComponent("v1/models"),
                                           resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            guard let url = components?.url else { throw AICloudError.badResponse }
            request = URLRequest(url: url)
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request = URLRequest(url: config.baseURL.appendingPathComponent("models"))
            if !config.apiKey.isEmpty {
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        request.timeoutInterval = 15
        let (data, status) = try await send(request)
        try Self.check(status: status, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else {
            throw AICloudError.badResponse
        }
        return list.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            // Gemini 的 OpenAI 兼容接口返回「models/gemini-…」，对话接口要不带前缀的名字。
            return id.hasPrefix("models/") ? String(id.dropFirst("models/".count)) : id
        }
    }

    /// Ollama 各模型的文件大小（字节），用它的原生接口 `GET {根地址}/api/tags`（`/v1` 去掉就是根地址）。
    /// 只对指向本机的服务调用（docs/local-models/DESIGN.md §6）。
    func ollamaSizes() async throws -> [String: Int64] {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw AICloudError.badResponse
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1") { path.removeLast(3) }
        components.path = path + "/api/tags"
        components.query = nil
        guard let url = components.url else { throw AICloudError.badResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, status) = try await send(request)
        try Self.check(status: status, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            throw AICloudError.badResponse
        }
        var sizes: [String: Int64] = [:]
        for model in models {
            guard let name = model["name"] as? String ?? model["model"] as? String,
                  let size = (model["size"] as? NSNumber)?.int64Value else { continue }
            sizes[name] = size
        }
        return sizes
    }

    // MARK: - 公共

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await Self.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw AICloudError.timeout
            default: throw AICloudError.offline(error.localizedDescription)
            }
        }
    }

    private static func check(status: Int, data: Data) throws {
        switch status {
        case 200: return
        case 401, 403: throw AICloudError.unauthorized
        case 429: throw AICloudError.throttled
        default: throw AICloudError.http(status, String(errorMessage(data).prefix(200)))
        }
    }

    /// 回复里的 token 数；缺了或类型不对算 0。
    private static func count(_ value: Any?) -> Int {
        max(0, (value as? NSNumber)?.intValue ?? 0)
    }

    /// 两家的错误体都是 `{"error": {"message": "..."}}`（Ollama 是 `{"error": "..."}`）。
    private static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String ?? ""
        }
        return object["error"] as? String ?? ""
    }
}
