import Foundation

/// 服务商账号：一份 Key + 地址（docs/ai-service/DESIGN.md §3.1）。Key 在钥匙串，这里只有不敏感的字段。
struct AICloudAccount: Codable, Identifiable, Equatable {
    var id: String
    /// 用户起的名字；空 = 显示服务名。
    var name: String
    /// `AICloudProvider` 的 rawValue（认不出来的当自定义）。
    var provider: String
    /// 空 = 该服务的默认地址。
    var baseURL: String

    var kind: AICloudProvider { AICloudProvider(rawValue: provider) ?? .openAICompatible }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.title : trimmed
    }
}

/// 账号下的一个模型。
struct AICloudModel: Codable, Identifiable, Equatable {
    var id: String
    var accountID: String
    /// 用户起的名字（下拉框里显示）；空 = 显示模型名。
    var name: String
    /// 发给服务商的模型名，如 `claude-haiku-5-5`。
    var model: String

    var modelName: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return modelName.isEmpty ? L("ai.model.unnamed") : modelName
    }
}

/// 云端服务商账号与模型（docs/ai-service/DESIGN.md §3.1）：增删改、持久化、配置是否完整、Key 的内存缓存。
/// 账号和模型是 UserDefaults 里的 JSON，Key 在钥匙串（启动时读进内存，请求时不再碰钥匙串）。
@MainActor
final class AIModelStore: ObservableObject {
    static let shared = AIModelStore()

    static let accountsKey = "ai.accounts"
    static let modelsKey = "ai.models"

    @Published private(set) var accounts: [AICloudAccount] = []
    @Published private(set) var models: [AICloudModel] = []
    /// 存了 Key 的账号（设置页显示「已保存」用；不暴露 Key 本身）。
    @Published private(set) var accountsWithKey: Set<String> = []

    private var keys: [String: String] = [:]

    private init() {
        let accounts = Self.decodeList(AICloudAccount.self, key: Self.accountsKey)
        let accountIDs = Set(accounts.map(\.id))
        self.accounts = accounts
        models = Self.decodeList(AICloudModel.self, key: Self.modelsKey).filter { accountIDs.contains($0.accountID) }
        for account in accounts {
            if let key = AIKeychain.load(accountID: account.id) { keys[account.id] = key }
        }
        accountsWithKey = Set(keys.keys)
    }

    // MARK: - 查询

    func account(_ id: String) -> AICloudAccount? { accounts.first { $0.id == id } }

    func model(_ id: String) -> AICloudModel? { models.first { $0.id == id } }

    func models(of accountID: String) -> [AICloudModel] { models.filter { $0.accountID == accountID } }

    /// 实际用的地址：没填用服务的默认地址；不像网址（或自定义没填）返回 nil。
    func baseURL(of account: AICloudAccount) -> URL? {
        AICloudSettings.validatedURL(account.baseURL, fallback: account.kind.defaultBaseURL)
    }

    /// 这个账号要不要 Key（地址指向本机的 OpenAI 兼容服务可以不填）。
    func needsKey(_ account: AICloudAccount) -> Bool {
        guard let url = baseURL(of: account) else { return true }
        return !AICloudSettings.keyOptional(account.kind, baseURL: url)
    }

    /// 这个模型的请求配置；nil = 配置不完整（模型被删、地址不对、没填模型名、缺 Key）。
    func config(modelID: String) -> AICloudConfig? {
        guard let model = model(modelID), let account = account(model.accountID),
              let url = baseURL(of: account), !model.modelName.isEmpty else { return nil }
        let key = keys[account.id] ?? ""
        if key.isEmpty, !AICloudSettings.keyOptional(account.kind, baseURL: url) { return nil }
        return AICloudConfig(provider: account.kind, baseURL: url, model: model.modelName, apiKey: key,
                             accountID: account.id)
    }

    func isConfigured(_ modelID: String) -> Bool { config(modelID: modelID) != nil }

    /// 账号级的请求配置（拉模型列表用，不针对某个模型）；nil = 地址不对或缺 Key。
    func accountConfig(_ accountID: String) -> AICloudConfig? {
        guard let account = account(accountID), let url = baseURL(of: account) else { return nil }
        let key = keys[account.id] ?? ""
        if key.isEmpty, !AICloudSettings.keyOptional(account.kind, baseURL: url) { return nil }
        return AICloudConfig(provider: account.kind, baseURL: url, model: "", apiKey: key, accountID: account.id)
    }

    /// 配置哪里不完整（设置页提示用）；nil = 完整。
    func problem(modelID: String) -> String? {
        guard let model = model(modelID), let account = account(model.accountID) else {
            return L("ai.problem.deleted")
        }
        guard let url = baseURL(of: account) else {
            if AICloudSettings.urlProblem(account.baseURL, fallback: account.kind.defaultBaseURL) == .insecure {
                return L("ai.problem.baseURLInsecure")
            }
            return L("ai.problem.baseURL")
        }
        if model.modelName.isEmpty { return L("ai.problem.model") }
        if keys[account.id] == nil, !AICloudSettings.keyOptional(account.kind, baseURL: url) {
            return L("ai.problem.key")
        }
        return nil
    }

    /// 下拉框、状态行里显示的名字。
    func displayName(modelID: String) -> String? { model(modelID)?.displayName }

    // MARK: - 账号

    /// 新建账号：名字默认 = 服务名（同一家第二个叫「服务名 2」）；自动带一个模型（有默认模型的用默认模型，Ollama 和自定义留空让用户填）。
    @discardableResult
    func addAccount(_ provider: AICloudProvider) -> AICloudAccount {
        let sameKind = accounts.filter { $0.kind == provider }.count
        let name = sameKind == 0 ? provider.title : "\(provider.title) \(sameKind + 1)"
        let account = AICloudAccount(id: UUID().uuidString, name: name, provider: provider.rawValue, baseURL: "")
        accounts.append(account)
        models.append(AICloudModel(id: UUID().uuidString, accountID: account.id, name: "", model: provider.defaultModel))
        persist()
        return account
    }

    func updateAccount(_ id: String, _ change: (inout AICloudAccount) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index])
        persist()
        AIService.shared.resetCooldown(accountID: id)
    }

    /// 连带删掉它的模型和 Key；用到这些模型的功能改回默认。
    func deleteAccount(_ id: String) {
        let removed = Set(models(of: id).map(\.id))
        accounts.removeAll { $0.id == id }
        models.removeAll { $0.accountID == id }
        AIKeychain.delete(accountID: id)
        keys[id] = nil
        accountsWithKey = Set(keys.keys)
        persist()
        AIService.shared.resetCooldown(accountID: id)
        AIFeatureSettings.clearChoices(usingModels: removed)
    }

    // MARK: - 模型

    /// 加一个模型：这个账号还没用默认模型就先填上默认模型，否则留空让用户填。
    @discardableResult
    func addModel(to accountID: String) -> AICloudModel? {
        guard let account = account(accountID) else { return nil }
        let taken = Set(models(of: accountID).map(\.modelName))
        let suggestion = taken.contains(account.kind.defaultModel) ? "" : account.kind.defaultModel
        let model = AICloudModel(id: UUID().uuidString, accountID: accountID, name: "", model: suggestion)
        models.append(model)
        persist()
        return model
    }

    func updateModel(_ id: String, _ change: (inout AICloudModel) -> Void) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        change(&models[index])
        persist()
        AIService.shared.resetCooldown(accountID: models[index].accountID)
    }

    /// 用到它的功能改回默认。
    func deleteModel(_ id: String) {
        models.removeAll { $0.id == id }
        persist()
        AIFeatureSettings.clearChoices(usingModels: [id])
    }

    // MARK: - Key

    /// 存进钥匙串；返回是否成功。
    func saveKey(_ key: String, accountID: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let account = account(accountID),
              AIKeychain.save(trimmed, accountID: accountID, label: account.displayName) else { return false }
        keys[accountID] = trimmed
        accountsWithKey = Set(keys.keys)
        AIService.shared.resetCooldown(accountID: accountID)
        return true
    }

    func deleteKey(accountID: String) {
        AIKeychain.delete(accountID: accountID)
        keys[accountID] = nil
        accountsWithKey = Set(keys.keys)
        AIService.shared.resetCooldown(accountID: accountID)
    }

    // MARK: - 持久化

    /// 编码失败（理论上不会，字段都是字符串）也要说出来，别让配置悄悄没存上（#101）。
    private func persist() {
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        do {
            defaults.set(try encoder.encode(accounts), forKey: Self.accountsKey)
            defaults.set(try encoder.encode(models), forKey: Self.modelsKey)
        } catch {
            StorageWriteFailure.report(L("storage.what.aiAccounts"), reason: error.localizedDescription)
        }
    }

    /// 逐条解码：某一条字段不对只丢那一条，不至于整张表读不出来、下次保存时把别的也冲掉。
    private static func decodeList<Element: Decodable>(_ type: Element.Type, key: String) -> [Element] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([Lenient<Element>].self, from: data) else { return [] }
        return items.compactMap(\.value)
    }

    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}
