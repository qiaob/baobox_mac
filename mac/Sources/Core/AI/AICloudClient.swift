import Foundation

/// 云端请求出错。`AIService` 据此决定退回本地（docs/ai-service/DESIGN.md §4.3）。
enum AICloudError: LocalizedError {
    case notConfigured
    /// 本机的每分钟次数上限到了（没发出去）。
    case rateLimited
    case timeout
    case offline(String)
    /// 401 / 403：Key 不对或没权限。
    case unauthorized
    /// 429：服务方限流 / 额度用完。
    case throttled
    case http(Int, String)
    case refused
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return L("ai.error.notConfigured")
        case .rateLimited: return L("ai.error.rateLimited")
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
        }
    }
}

/// 一次云端请求要的配置（主线程读好设置和钥匙串再交过来，请求本身在后台跑）。
struct AICloudConfig {
    let provider: AICloudProvider
    let baseURL: URL
    let model: String
    /// OpenAI 兼容指向本机（Ollama）时可以为空。
    let apiKey: String
}

/// 云端 HTTP 客户端：Claude Messages API / OpenAI Chat Completions，一问一答、不流式（流式是 P1）。
/// 只用 `URLSession` 的 async 接口，不在主线程同步等待；日志里不记 Key、不记内容。
struct AICloudClient {
    let config: AICloudConfig

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// `system` 可为空；`maxTokens` 已由调用方按用户上限截好。
    func complete(system: String?, user: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        switch config.provider.api {
        case .anthropic:
            return try await anthropic(system: system, user: user, maxTokens: maxTokens, timeout: timeout,
                                       lightweight: true)
        case .openAI:
            return try await openAI(system: system, user: user, maxTokens: maxTokens, timeout: timeout,
                                    tokenField: "max_tokens")
        }
    }

    // MARK: - Claude

    /// `lightweight`：带上 `effort: low` + 关思考（翻译、纠错要快；Haiku 5.5 在 high 档以下才能关思考）。
    /// 有的模型不认这两项会回 400，那就不带再试一次。采样参数（temperature 等）新版 API 一律不收，不发。
    private func anthropic(system: String?, user: String, maxTokens: Int, timeout: TimeInterval,
                           lightweight: Bool) async throws -> String {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": user]],
        ]
        if let system, !system.isEmpty { body["system"] = system }
        if lightweight {
            body["output_config"] = ["effort": "low"]
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await send(request)
        if status == 400, lightweight {
            let message = Self.errorMessage(data).lowercased()
            if message.contains("effort") || message.contains("thinking") || message.contains("output_config") {
                return try await anthropic(system: system, user: user, maxTokens: maxTokens, timeout: timeout,
                                           lightweight: false)
            }
        }
        try Self.check(status: status, data: data)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AICloudError.badResponse
        }
        if (object["stop_reason"] as? String) == "refusal" { throw AICloudError.refused }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AICloudError.badResponse }
        return trimmed
    }

    // MARK: - OpenAI 兼容

    /// 新一些的 OpenAI 模型只认 `max_completion_tokens`：400 里提到 max_tokens 就换个字段再试一次。
    private func openAI(system: String?, user: String, maxTokens: Int, timeout: TimeInterval,
                        tokenField: String) async throws -> String {
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
        let cleaned = OfflinePrompt.clean(content)
        guard !cleaned.isEmpty else { throw AICloudError.badResponse }
        return cleaned
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

    /// 两家的错误体都是 `{"error": {"message": "..."}}`（Ollama 是 `{"error": "..."}`）。
    private static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String ?? ""
        }
        return object["error"] as? String ?? ""
    }
}
