import Foundation

/// 云端用量与每天的请求上限（#100，docs/ai-service/DESIGN.md §4.6）。
///
/// - 只算真正发到云端的请求：本机服务（Ollama 这类）不花钱，不算；测试连接、拉模型列表也不算；
/// - token 数来自服务方的回复（没报就记 0），只在成功的回复里有；
/// - 存在 UserDefaults，过了零点从零算起；
/// - 到了上限，云端请求改走本地（有的话）、宠物提示一次；点「再用 N 次」放行下一段（N = 每日上限），用完再提示。
@MainActor
final class AIUsageMeter: ObservableObject {
    static let shared = AIUsageMeter()

    static let dailyLimitKey = "ai.cloud.dailyLimit"
    /// 每天请求次数上限的可调范围与出厂值。实时字幕走云端时一分钟几十次，开着字幕开会十来分钟就会碰到出厂的 500 ——
    /// 这正是要提醒的时候：要么点「再用 500 次」，要么在设置里调高。
    static let dailyLimitRange = 100...10_000
    static let defaultDailyLimit = 500

    private static let todayKey = "ai.cloud.usageToday"

    /// 某一天的用量。
    struct Day: Codable, Equatable {
        /// 本地日期 `yyyy-MM-dd`。
        var day: String
        var requests = 0
        var inputTokens = 0
        var outputTokens = 0
        /// 今天点「再用 N 次」放行了几段。
        var extensions = 0
    }

    @Published private(set) var stored: Day
    /// 已经为哪一段放行额度提示过（同一段只提示一次）。
    private var notifiedAllowance: Int?

    private init() {
        let key = Self.dayKey(Date())
        if let data = UserDefaults.standard.data(forKey: Self.todayKey),
           let day = try? JSONDecoder().decode(Day.self, from: data), day.day == key {
            stored = day
        } else {
            stored = Day(day: key)
        }
    }

    static var dailyLimit: Int {
        get {
            let value = UserDefaults.standard.object(forKey: dailyLimitKey) as? Int ?? defaultDailyLimit
            return min(max(value, dailyLimitRange.lowerBound), dailyLimitRange.upperBound)
        }
        set { UserDefaults.standard.set(newValue, forKey: dailyLimitKey) }
    }

    /// 今天的用量（过了零点还没发过请求时是空的一天）。
    var today: Day {
        let key = Self.dayKey(Date())
        return stored.day == key ? stored : Day(day: key)
    }

    /// 今天放行到第几次：每日上限 ×（1 + 点过几次「再用」）。
    var allowance: Int { Self.dailyLimit * (1 + today.extensions) }

    var isOverLimit: Bool { today.requests >= allowance }

    /// 设置页那行：「今天 123 次 · 4.5k token」。
    var summary: String {
        let day = today
        return L("ai.usage.today \(day.requests) \(Self.compact(day.inputTokens + day.outputTokens))")
    }

    // MARK: - 计数

    /// 发云端请求前问一次：没到上限 → 记一次、放行；到了 → 不放行，这一段第一次碰到时提示。
    func admit() -> Bool {
        rollOver()
        guard stored.requests < allowance else {
            notifyOnce()
            return false
        }
        stored.requests += 1
        save()
        return true
    }

    /// 记下回复里的 token 数。
    func record(_ completion: AICloudCompletion) {
        rollOver()
        stored.inputTokens += max(0, completion.inputTokens)
        stored.outputTokens += max(0, completion.outputTokens)
        save()
    }

    /// 「再用 N 次」：放行下一段。
    func extendToday() {
        rollOver()
        stored.extensions += 1
        save()
    }

    private func rollOver() {
        let key = Self.dayKey(Date())
        guard stored.day != key else { return }
        stored = Day(day: key)
        notifiedAllowance = nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.todayKey)
        }
    }

    // MARK: - 提示

    private func notifyOnce() {
        let allowance = allowance
        guard notifiedAllowance != allowance else { return }
        notifiedAllowance = allowance
        let limit = Self.dailyLimit
        // alert：开会时（勿扰）也要立刻看到 —— 这之后字幕翻译改走本地或停掉，得让人知道、能马上放行。
        NotifyCenter.shared.post(PetNotification(
            source: "ai", level: .alert,
            title: L("ai.usage.limitTitle \(stored.requests)"),
            body: L("ai.usage.limitBody"),
            actions: [
                .init(id: "more", label: L("ai.usage.more \(limit)"), role: .primary),
                .init(id: "settings", label: L("ai.usage.settings")),
            ],
            dedupeKey: "dailyLimit"
        )) { [weak self] action in
            switch action {
            case "more": self?.extendToday()
            case "settings": Self.openSettings()
            default: break
            }
        }
    }

    private static func openSettings() {
        guard let registry = AppDelegate.shared?.registry else { return }
        AISettingsNavigation.shared.showFeatures()
        SettingsWindowController.shared.show(registry: registry, tab: AISettingsView.tabID)
    }

    // MARK: - 工具

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// token 数：≥100 万记 `1.2M`，≥1000 记 `4.5k`，否则原样（与 Claude Code 用量页同一写法）。
    static func compact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.1fk", Double(count) / 1000) }
        return "\(count)"
    }
}
