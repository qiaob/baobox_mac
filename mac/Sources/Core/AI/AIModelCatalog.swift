import Foundation

/// 各服务商有哪些模型（docs/ai-service/DESIGN.md §3.4）：内置的常用名单（没填 Key 也能选）+ 从服务商拉取的全部模型（填了 Key 后）。
/// 设置页模型名的下拉框（`ModelComboBox`）从这里取列表；拉取结果只放内存，按账号存。
@MainActor
final class AIModelCatalog: ObservableObject {
    static let shared = AIModelCatalog()

    enum Status: Equatable {
        case idle
        case loading
        case loaded(Int)
        case failed(String)
    }

    /// 账号 id → 服务商返回的对话模型（已过滤、常用的排前面）。
    @Published private(set) var fetched: [String: [String]] = [:]
    @Published private(set) var statuses: [String: Status] = [:]
    /// 指向本机的服务（Ollama）：账号 id → 模型名 → 文件大小。加载太大的模型会把内存占满，设置页据此提醒。
    @Published private(set) var localSizes: [String: [String: Int64]] = [:]

    /// 上次自动拉取时的「Key 有没有、地址是什么」：没变就不重拉（展开账号时不至于每次都请求）。
    private var signatures: [String: String] = [:]

    private init() {}

    /// 下拉列表：拉到了用服务商返回的，没拉到（或返回空）用内置名单。
    func items(for account: AICloudAccount) -> [String] {
        if let list = fetched[account.id], !list.isEmpty { return list }
        return account.kind.suggestedModels
    }

    func status(for accountID: String) -> Status { statuses[accountID] ?? .idle }

    /// 自动拉取：这个账号的 Key / 地址变了、或上次没拉成，才重新拉。
    func refreshIfNeeded(_ accountID: String, signature: String) async {
        if signatures[accountID] == signature, case .loaded = status(for: accountID) { return }
        signatures[accountID] = signature
        await refresh(accountID)
    }

    /// 拉一次服务商的模型列表。地址不对或缺 Key 时不拉。
    func refresh(_ accountID: String) async {
        guard let config = AIModelStore.shared.accountConfig(accountID) else { return }
        statuses[accountID] = .loading
        do {
            let client = AICloudClient(config: config)
            let ids = try await client.listModels()
            let ordered = Self.order(ids, suggested: config.provider.suggestedModels)
            fetched[accountID] = ordered
            statuses[accountID] = .loaded(ordered.count)
            // 本机服务顺带读每个模型多大（不是 Ollama、读不到就算了）。
            if AICloudSettings.isLocalHost(config.baseURL) {
                localSizes[accountID] = (try? await client.ollamaSizes()) ?? [:]
            }
        } catch is CancellationError {
            statuses[accountID] = .idle
        } catch {
            statuses[accountID] = .failed(error.localizedDescription)
        }
    }

    /// 删了账号：清掉它的列表。
    func forget(_ accountID: String) {
        fetched[accountID] = nil
        statuses[accountID] = nil
        signatures[accountID] = nil
        localSizes[accountID] = nil
    }

    /// 本机服务上这个模型的文件大小；不知道时为 nil。
    func localSize(accountID: String, model: String) -> Int64? {
        localSizes[accountID]?[model.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// 去掉明显不是对话模型的（向量、语音、图片、审核…）并去重；内置名单里有的排前面（按名单顺序），其余按字母排。
    static func order(_ ids: [String], suggested: [String]) -> [String] {
        var seen = Set<String>()
        let chat = ids.filter { isChatModel($0) && seen.insert($0).inserted }
        let available = Set(chat)
        let head = suggested.filter { available.contains($0) }
        let headSet = Set(head)
        let rest = chat.filter { !headSet.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return head + rest
    }

    private static let nonChatMarkers = ["embed", "tts", "whisper", "dall-e", "moderation", "davinci", "babbage",
                                         "audio", "realtime", "transcribe", "image", "rerank", "speech", "sora"]

    static func isChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return !nonChatMarkers.contains { lower.contains($0) }
    }
}
