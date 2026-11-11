import Combine
import Foundation

// 用量 Store 的外壳（#164 PR4，docs/codex-assistant/DEDUPE-P2.md §2.4 类 8）：定时刷新、进行中再请求合并成结束后补一轮、
// 事件触发的节流刷新与窗口末尾补刷、报表与调用统计的后台外壳、80% 额度提醒的防重。规则照搬 Claude Code 助手 #174 之后的 Store；
// Codex 助手也换过来之后，回合完成触发的刷新与刷新撞车的请求都不再丢（DEDUPE-P2 §7 D6）。
// 两边不同的「日志怎么收成条目、周窗口怎么取、报表怎么排、调用统计怎么算」在各自模块的用量来源（`CLIUsageSource`）里；
// 设置从哪读、提醒怎么发由模块的非泛型子类覆盖三个钩子。
// 只依赖 Foundation + Combine：不读 UserDefaults、不调 L()、不发通知 —— 进 BaoboxTests（整个 Core/CLIUsage 目录都进）。

/// 一种 CLI 的用量来源：全是静态成员、在后台线程调用。各模块实现一个（`ClaudeUsageSource` / `CodexUsageSource`）。
/// 后台闭包要捕获它的元类型，所以要求 Sendable（同 `CLISessionFormat`）。
protocol CLIUsageSource: Sendable {
    associatedtype Table: CLIUsagePricingTable
    associatedtype InvocationStats: Sendable

    /// 近 `hours` 小时内改过的会话文件里的用量条目。
    static func collectEntries(sinceHoursAgo hours: Int) -> [CLIUsageEntry]
    /// 周窗口。默认 = `CLIUsageCalculator.weeklyWindow`；Codex 覆盖成「近 180h 一条用量都没有时返回 nil」（原有差异，保留）。
    static func weeklyWindow(from entries: [CLIUsageEntry], anchor: CLIUsageWeeklyAnchor) -> CLIUsageWindow<Table>?
    /// 三维度报表（排序、项目名的取法各模块不同）。
    static func buildReport(from entries: [CLIUsageEntry]) -> CLIUsageReport<Table>
    /// 近 `days` 天改过的会话文件里的调用统计（形状各模块不同）。
    static func invocationStats(days: Int) -> InvocationStats
}

extension CLIUsageSource {
    static func weeklyWindow(from entries: [CLIUsageEntry], anchor: CLIUsageWeeklyAnchor) -> CLIUsageWindow<Table>? {
        CLIUsageCalculator<Table>.weeklyWindow(from: entries, anchor: anchor)
    }
}

/// 刷新用到的设置：两个 token 预算（0 = 未设）与周窗口锚点。模块在主线程从自己的 UserDefaults 键读，值类型传进后台。
struct CLIUsageSettings: Equatable, Sendable {
    var budget: Int
    var weeklyBudget: Int
    var anchor: CLIUsageWeeklyAnchor

    /// 没有预算、周窗口按近 7 天滚动（基类 `readSettings()` 的默认值）。
    static let unset = CLIUsageSettings(
        budget: 0,
        weeklyBudget: 0,
        anchor: CLIUsageWeeklyAnchor(fixed: false, clampingWeekday: 2, hour: 0)
    )
}

/// 用量 Store 基类：当前 5 小时窗口、周窗口、今日累计，报表与调用统计。
///
/// 模块写一个非泛型子类放 `static let shared`（泛型类型里不能有静态存储属性）、设置键常量，并覆盖下面三个钩子；
/// `@Published` 全在这里，子类不加（同 `CLISessionIndex<Format>`）。`@Published` 只在主线程写，重 IO 都在后台，完成回调在主线程。
@MainActor
class CLIUsageStore<Source: CLIUsageSource>: ObservableObject {
    typealias Window = CLIUsageWindow<Source.Table>
    typealias Totals = CLIUsageTotals<Source.Table>
    typealias Report = CLIUsageReport<Source.Table>

    /// 5 小时额度窗口；nil = 无活跃窗口。
    @Published private(set) var fiveHourWindow: Window?
    /// 周窗口；nil = 近 7 天无用量（滚动块口径）。固定锚点口径下的有无看来源的 `weeklyWindow`（Claude 始终有值，Codex 近 180h 有过用量才有）。
    @Published private(set) var weeklyWindow: Window?
    /// 今日累计；nil = 今天没有用量。
    @Published private(set) var todayTotals: Totals?
    /// 是否正在刷新（供 UI 显示转圈）。补的那一轮接着算，中间不熄。
    @Published private(set) var isRefreshing = false

    /// 菜单刷新的采集窗口（小时）：周窗口要近 7 天，默认 180h（168h + 余量）。5h / 今日只关心近 24h，是这批条目的天然子集。
    let collectHours: Int
    /// 定时刷新的间隔（秒）。
    let autoRefreshInterval: TimeInterval

    /// 5h / 周窗口 80% 提醒的防重状态（两者独立）。仅主线程访问。
    private var budgetReminder = CLIUsageBudgetReminder()
    private var weeklyBudgetReminder = CLIUsageBudgetReminder()
    /// 防重入标记：有一轮在后台跑（含补的那一轮）。
    private var refreshing = false
    /// 刷新进行中又来了请求（定时器、事件、补刷、设置变化）：这一轮结束后再刷一轮（来几次都只补一轮）。
    /// 否则刚好撞上的请求会被吞掉 —— 比如启动时那轮全量解析还没完，回合就结束了。
    private var refreshAgain = false
    /// 事件触发的刷新：间隔内只马上放行一次，间隔里来的在间隔结束时补一次。
    private var eventRefreshThrottle: CLIUsageRefreshThrottle
    /// 排着的补刷（`eventRefreshThrottle` 说要补的那一次）。
    private var trailingRefresh: DispatchWorkItem?
    private var timer: Timer?

    /// - Parameters:
    ///   - collectHours: 菜单刷新收集近多少小时改过的文件（默认 180）。
    ///   - autoRefreshInterval: 定时刷新的间隔（默认 5 分钟）。
    ///   - eventThrottle: 事件触发的刷新两次放行之间至少隔多久（默认 60 秒）。测试传短间隔。
    init(collectHours: Int = 180, autoRefreshInterval: TimeInterval = 300, eventThrottle: TimeInterval = 60) {
        self.collectHours = collectHours
        self.autoRefreshInterval = autoRefreshInterval
        self.eventRefreshThrottle = CLIUsageRefreshThrottle(interval: eventThrottle)
    }

    // MARK: - 子类覆盖（主线程调用）

    /// 预算与周窗口锚点（模块从自己的 UserDefaults 键读）。锚点在刷新开始时读，预算在结果回来时读。默认 `CLIUsageSettings.unset`。
    func readSettings() -> CLIUsageSettings {
        .unset
    }

    /// 之前提醒过的窗口过去了（防重记录已清空）。Claude 据此可选发「额度已恢复」；默认什么也不做（Codex）。
    func budgetWindowChanged(weekly: Bool) {}

    /// 这次刚用到预算的 80%（同一个窗口只来一次）：`percent` = 用量占预算的百分比（四舍五入）。默认什么也不做。
    func budgetReached(percent: Int, window: Window, weekly: Bool) {}

    // MARK: - 定时刷新

    /// activate 时启动：立刻刷新一次，之后每 `autoRefreshInterval` 秒一次。
    func startAutoRefresh() {
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: autoRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 停定时器，顺带取消排着的补刷。
    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
        trailingRefresh?.cancel()
        trailingRefresh = nil
    }

    /// 收到事件时的节流刷新：距上次放行满 `eventThrottle` 秒马上刷；间隔内来的在间隔结束时补刷一次（只补一次，不叠加），
    /// 所以每个回合结束后的用量都刷得到（规则在 `CLIUsageRefreshThrottle`）。
    /// Claude 在回合结束（Stop）与等你确认（Notification）的 hook 事件时调，Codex 在回合完成的 notify 事件时调。
    func refreshThrottledFromEvent() {
        let now = Date()
        switch eventRefreshThrottle.request(at: now) {
        case .now:
            trailingRefresh?.cancel()
            trailingRefresh = nil
            refresh()
        case .trailing(let fireDate):
            trailingRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.trailingRefresh = nil
                    if self.eventRefreshThrottle.fireTrailing(at: Date()) {
                        self.refresh()
                    }
                }
            }
            trailingRefresh = work
            // 延迟夹在 0...间隔：系统时钟往回拨过也不会一等几个小时（补刷时窗口跟着新时钟重新起算）。
            let delay = min(eventRefreshThrottle.interval, max(0, fireDate.timeIntervalSince(now)))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .alreadyScheduled:
            break
        }
    }

    // MARK: - 刷新

    /// 后台收集近 `collectHours` 小时改过的文件的用量，一次算出 5h 窗口、今日累计与周窗口，回主线程发布，再做 80% 额度提醒。
    /// 进行中再调只记一笔，这一轮结束后再刷一轮（转圈接着转）。
    func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        isRefreshing = true
        let anchor = readSettings().anchor   // 主线程读设置，值类型传进后台。
        let hours = collectHours
        DispatchQueue.global(qos: .utility).async {
            let entries = Source.collectEntries(sinceHoursAgo: hours)
            let window = CLIUsageCalculator<Source.Table>.activeWindow(from: entries)
            let today = CLIUsageCalculator<Source.Table>.todayTotals(from: entries)
            let weekly = Source.weeklyWindow(from: entries, anchor: anchor)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fiveHourWindow = window
                    self.todayTotals = today
                    self.weeklyWindow = weekly
                    self.refreshing = false
                    self.checkBudgets(window: window, weekly: weekly)
                    if self.refreshAgain {
                        // 转圈接着转：补的这一轮马上开始。
                        self.refreshAgain = false
                        self.refresh()
                    } else {
                        self.isRefreshing = false
                    }
                }
            }
        }
    }

    /// 三维度报表：收集近 `days` 天改过的文件。后台计算，回主线程。
    func report(days: Int, completion: @escaping (Report) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let entries = Source.collectEntries(sinceHoursAgo: days * 24)
            let report = Source.buildReport(from: entries)
            DispatchQueue.main.async {
                completion(report)
            }
        }
    }

    /// 调用统计：后台遍历近 `days` 天改过的会话文件，主线程回调。
    func invocationStats(days: Int, completion: @escaping (Source.InvocationStats) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let stats = Source.invocationStats(days: days)
            DispatchQueue.main.async {
                completion(stats)
            }
        }
    }

    // MARK: - 额度提醒

    /// 5h 与周窗口各查一次（先 5h 后周，各自防重）；预算在结果回来时读。没有窗口的那一项不查。
    private func checkBudgets(window: Window?, weekly: Window?) {
        let settings = readSettings()
        if let window {
            let outcome = budgetReminder.check(windowStart: window.start, totalTokens: window.totals.totalTokens, budget: settings.budget)
            deliver(outcome, window: window, weekly: false)
        }
        if let weekly {
            let outcome = weeklyBudgetReminder.check(windowStart: weekly.start, totalTokens: weekly.totals.totalTokens, budget: settings.weeklyBudget)
            deliver(outcome, window: weekly, weekly: true)
        }
    }

    /// 先报「窗口已切换」，再报「到 80%」（同一次检查两样都可能有：新窗口一开始就过了线）。
    private func deliver(_ outcome: CLIUsageBudgetReminder.Outcome, window: Window, weekly: Bool) {
        if outcome.windowChanged {
            budgetWindowChanged(weekly: weekly)
        }
        if let percent = outcome.reachedPercent {
            budgetReached(percent: percent, window: window, weekly: weekly)
        }
    }
}
