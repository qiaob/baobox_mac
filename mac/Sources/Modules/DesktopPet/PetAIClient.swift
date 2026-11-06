import Foundation

/// 对话里的一轮（发给 AI 服务的上下文，也是本机 chat.json 里存的内容）。
struct PetChatTurn: Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var text: String
    var date = Date()
}

enum PetAIError: Error, Equatable {
    /// 没配 API Key（OpenAI 兼容接口可以不填，Anthropic 必须填）。
    case noKey
    /// 401 / 403：Key 不对或没权限。
    case unauthorized
    /// 429：被限流 / 额度用完。
    case rateLimited
    /// 529 / 5xx：服务忙或出错。
    case overloaded
    case timeout
    case offline
    /// 模型拒绝回答（Claude 的 refusal）。
    case refused
    /// 其他 HTTP 错误：状态码 + 服务给的说明（不含 Key）。
    case server(Int, String)
    /// 返回的东西读不懂。
    case malformed
}

/// 流式调用 AI 服务（docs/desktop-pet/CHAT.md §3）：`URLSession.bytes` 逐行读 SSE，不加第三方依赖。
/// - Anthropic：`POST {base}/v1/messages`，头 `x-api-key` + `anthropic-version`，事件 `content_block_delta` 里的 `text_delta`。
/// - OpenAI 兼容：`POST {base}/chat/completions`，头 `Authorization: Bearer`（没填 Key 就不带，给本机模型用），
///   每行 `data: {choices[0].delta.content}`，以 `data: [DONE]` 结束。
/// 只读文字增量；思考块、用量等其他事件一律跳过。外部返回全程容错，不 force-unwrap。
/// 在主线程上 await（不阻塞主线程；逐行解析很轻），回调直接改界面状态。
@MainActor
enum PetAIClient {
    static let anthropicBase = "https://api.anthropic.com"
    static let anthropicVersion = "2026-10-21"

    struct Request {
        var provider: PetAIProvider
        var model: String
        var baseURL: String
        var apiKey: String?
        var system: String
        var turns: [PetChatTurn]
        var maxTokens: Int
    }

    /// 发请求，每来一段文字回调一次 `onText`（在调用方的 actor 上）。结束正常返回；出错抛 `PetAIError`；
    /// 任务被取消时抛 `CancellationError`。
    static func stream(_ request: Request, onText: (String) -> Void) async throws {
        let urlRequest = try makeURLRequest(request)
        let result: (URLSession.AsyncBytes, URLResponse)
        do {
            result = try await URLSession.shared.bytes(for: urlRequest)
        } catch {
            throw networkError(error)
        }
        let (bytes, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 出错时读一点正文拿服务给的说明（最多 40 行）。
            var body = ""
            var count = 0
            do {
                for try await line in bytes.lines {
                    body += line
                    count += 1
                    if count >= 40 { break }
                }
            } catch {}
            throw httpError(status: status, body: body)
        }
        var gotText = false
        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                switch request.provider {
                case .anthropic:
                    let type = json["type"] as? String
                    if type == "content_block_delta", let delta = json["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                        gotText = true
                        onText(text)
                    } else if type == "message_delta", let delta = json["delta"] as? [String: Any],
                              delta["stop_reason"] as? String == "refusal", !gotText {
                        throw PetAIError.refused
                    } else if type == "error" {
                        let info = json["error"] as? [String: Any]
                        let kind = info?["type"] as? String ?? ""
                        if kind == "overloaded_error" || kind == "api_error" { throw PetAIError.overloaded }
                        if kind == "rate_limit_error" { throw PetAIError.rateLimited }
                        throw PetAIError.server(status, info?["message"] as? String ?? kind)
                    }
                case .openai:
                    if let choices = json["choices"] as? [[String: Any]], let first = choices.first,
                       let delta = first["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
                        gotText = true
                        onText(text)
                    } else if let info = json["error"] as? [String: Any] {
                        throw PetAIError.server(status, info["message"] as? String ?? "")
                    }
                }
            }
        } catch let error as PetAIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw networkError(error)
        }
        if !gotText { throw PetAIError.malformed }
    }

    private static func makeURLRequest(_ request: Request) throws -> URLRequest {
        let key = request.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var body: [String: Any] = ["model": request.model, "max_tokens": request.maxTokens, "stream": true]
        let url: URL?
        var headers = ["Content-Type": "application/json"]
        switch request.provider {
        case .anthropic:
            guard !key.isEmpty else { throw PetAIError.noKey }
            url = URL(string: anthropicBase + "/v1/messages")
            headers["x-api-key"] = key
            headers["anthropic-version"] = anthropicVersion
            body["system"] = request.system
            body["messages"] = request.turns.map { ["role": $0.role.rawValue, "content": $0.text] }
            // 闲聊不需要深想：低档思考，回复来得快、也便宜。
            body["output_config"] = ["effort": "low"]
        case .openai:
            var base = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            url = URL(string: base + "/chat/completions")
            if !key.isEmpty { headers["Authorization"] = "Bearer " + key }
            var messages: [[String: String]] = [["role": "system", "content": request.system]]
            messages += request.turns.map { ["role": $0.role.rawValue, "content": $0.text] }
            body["messages"] = messages
        }
        guard let url, url.scheme == "https" || url.scheme == "http" else {
            throw PetAIError.server(0, L("pet.chat.error.badURL"))
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw PetAIError.malformed }
        urlRequest.httpBody = data
        return urlRequest
    }

    private static func httpError(status: Int, body: String) -> PetAIError {
        switch status {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        case 500...599: return .overloaded
        default:
            var message = ""
            if let data = body.data(using: .utf8),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let info = json["error"] as? [String: Any] {
                    message = info["message"] as? String ?? ""
                } else if let text = json["error"] as? String {
                    message = text
                }
            }
            return .server(status, String(message.prefix(200)))
        }
    }

    private static func networkError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        let code = (error as? URLError)?.code
        switch code {
        case .timedOut?: return PetAIError.timeout
        case .notConnectedToInternet?, .networkConnectionLost?, .cannotFindHost?, .cannotConnectToHost?,
             .dnsLookupFailed?:
            return PetAIError.offline
        case .cancelled?: return CancellationError()
        default: return PetAIError.server(0, error.localizedDescription)
        }
    }
}
