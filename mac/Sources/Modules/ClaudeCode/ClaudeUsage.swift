import Foundation

/// Claude Code 助手 —— 定价表、用量条目解析、5 小时 + 周额度窗口与报表。
///
/// 费用为按公开定价的**估算**（定价表内置常量，见 TECH_DESIGN 3.3），UI 处处标「估算」。
/// 用量去重：同一条 assistant 消息在续接/分叉文件里会重复，用 `message.id + requestId` 去重。
/// 重 IO 后台，`@Published` 只在主线程写。
///
/// 窗口 / 周窗口 / 今日 / 报表 / 额度提醒的算法在共用层 `Core/CLIUsage/`（与 Codex 助手共用，有单元测试）；
/// 这里只留 Claude 自己的部分：定价表、`~/.claude/projects` JSONL 的解析（`ClaudeUsageCollector`：按文件缓存、只重新解析改过的文件）、
/// 设置键与提醒的发送。
///
/// 本文件无独立用户可见文案（额度提醒文案在 ClaudeNotifier / ClaudeLiveStatus.swift 中定义）。

// MARK: - 定价

/// Claude 的定价表（每百万 token 美元单价）。Anthropic 口径：input 不含缓存，缓存写 / 缓存读单列。
enum ClaudePricingTable: CLIUsagePricingTable {
    static let inputIncludesCacheRead = false

    /// 按 model id 关键字匹配定价；未知返回 nil（共用层记 0 费用并标 unpriced）。
    /// 缓存写 = 输入 ×1.25(5 分钟 TTL 口径),缓存读 = 输入 ×0.1,与官方定价页一致。
    static func pricing(for modelID: String) -> ModelPricing? {
        let id = modelID.lowercased()
        if id.contains("fable") || id.contains("mythos") {
            return ModelPricing(inputPerM: 10, outputPerM: 50, cacheWritePerM: 12.5, cacheReadPerM: 1.0)
        }
        if id.contains("opus") {
            // Opus 4.1 / 4.0 / Claude 3 Opus 为 $15/$75;Opus 4.5 起降为 $5/$25。
            if id.contains("opus-4-1") || id.contains("opus-4-0")
                || id.contains("opus-4-2025") || id.contains("3-opus") {
                return ModelPricing(inputPerM: 15, outputPerM: 75, cacheWritePerM: 18.75, cacheReadPerM: 1.5)
            }
            return ModelPricing(inputPerM: 5, outputPerM: 25, cacheWritePerM: 6.25, cacheReadPerM: 0.5)
        }
        if id.contains("sonnet") {
            return ModelPricing(inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.3)
        }
        if id.contains("haiku") {
            return ModelPricing(inputPerM: 1, outputPerM: 5, cacheWritePerM: 1.25, cacheReadPerM: 0.1)
        }
        return nil
    }
}

// MARK: - 聚合模型（共用层套上 Claude 定价表；名字不变，UI 照旧引用）

/// 一组 token 与估算费用的累计。
typealias UsageTotals = CLIUsageTotals<ClaudePricingTable>
/// 一个额度窗口（5h 或周）。
typealias UsageWindow = CLIUsageWindow<ClaudePricingTable>
/// 周窗口锚点配置。
typealias WeeklyAnchor = CLIUsageWeeklyAnchor
/// 报表一行（按天 / 按项目 / 按模型通用）。
typealias UsageBucket = CLIUsageBucket<ClaudePricingTable>
/// 三维度报表。
typealias ClaudeUsageReport = CLIUsageReport<ClaudePricingTable>

private typealias ClaudeUsageCalculator = CLIUsageCalculator<ClaudePricingTable>

/// 一个 MCP 服务器的调用统计（两级：服务器总次数 + 各工具次数）。
struct ClaudeMCPServerStat: Sendable {
    let server: String
    let total: Int
    /// 工具名 → 次数。
    let tools: [String: Int]
}

/// 调用统计三类计数（排序留给 UI）。值类型、Sendable，便于后台构建后跨线程回调。
struct ClaudeInvocationStats: Sendable {
    /// Skill（tool_use name=="Skill" 的 input.skill）与斜杠命令（user 文本 <command-name>）合并计数：名称 → 次数。
    var skills: [String: Int] = [:]
    /// MCP：服务器名 → 该服务器统计。
    var mcp: [String: ClaudeMCPServerStat] = [:]
    /// 内置工具：工具名 → 次数。
    var builtin: [String: Int] = [:]
}

// MARK: - 用量单例

/// 用量聚合：当前额度窗口、今日累计、报表。
@MainActor
final class ClaudeUsageStore: ObservableObject {
    static let shared = ClaudeUsageStore()

    /// nil = 无活跃窗口。
    @Published private(set) var currentWindow: UsageWindow?
    /// nil = 近 7 天无用量（滚动块口径）；固定锚点口径下始终有值。end 依口径而定。
    @Published private(set) var weeklyWindow: UsageWindow?
    @Published private(set) var todayTotals: UsageTotals?
    @Published private(set) var isRefreshing = false

    /// 每（5 小时）额度窗口 token 预算（0 = 未设）。
    static let budgetKey = "claudecode.tokenBudget"
    /// 每周额度 token 预算（0 = 未设）。
    static let weeklyBudgetKey = "claudecode.weeklyTokenBudget"
    /// 周窗口按固定重置时间对齐（默认 false = 近 7 天滚动块）。
    static let weeklyFixedKey = "claudecode.weeklyResetFixed"
    /// 固定锚点：重置星期（1...7，Calendar 口径，1=周日）。默认 2（周一）。
    static let weeklyWeekdayKey = "claudecode.weeklyResetWeekday"
    /// 固定锚点：重置小时（0...23）。默认 0。
    static let weeklyHourKey = "claudecode.weeklyResetHour"
    /// 5h 窗口 80% 提醒的防重状态（防重复轰炸）。仅主线程访问。
    private var budgetReminder = CLIUsageBudgetReminder()
    /// 周窗口 80% 提醒的防重状态（与 5h 独立防重）。仅主线程访问。
    private var weeklyBudgetReminder = CLIUsageBudgetReminder()
    private var refreshing = false
    /// 刷新进行中又来了请求（定时器、hook、补刷、设置变化）：这一轮结束后再刷一轮（来几次都只补一轮）。
    /// 否则刚好撞上的请求会被吞掉 —— 比如启动时那轮全量解析还没完，回合就结束了。
    private var refreshAgain = false
    /// hook 事件触发的刷新：60 秒内只马上放行一次，窗口里来的在窗口结束时补一次。
    private var hookRefreshThrottle = CLIUsageRefreshThrottle(interval: 60)
    /// 排着的补刷（`hookRefreshThrottle` 说要补的那一次）。
    private var trailingRefresh: DispatchWorkItem?
    private var timer: Timer?

    private init() {}

    // MARK: - 定时刷新

    /// activate 时启动：立刻刷新一次，之后每 5 分钟一次。
    func startAutoRefresh() {
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
        trailingRefresh?.cancel()
        trailingRefresh = nil
    }

    /// 收到 hook 事件时的节流刷新：距上次 ≥ 60 秒马上刷；60 秒内来的在窗口结束时补刷一次（只补一次，不叠加），
    /// 所以每个回合结束后的用量都刷得到。`ClaudeLiveStatus` 在回合结束（Stop）与等你确认（Notification）时调。
    func refreshThrottledFromHook() {
        let now = Date()
        switch hookRefreshThrottle.request(at: now) {
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
                    if self.hookRefreshThrottle.fireTrailing(at: Date()) {
                        self.refresh()
                    }
                }
            }
            trailingRefresh = work
            // 延迟夹在 0...60 秒：系统时钟往回拨过也不会一等几个小时（补刷时窗口跟着新时钟重新起算）。
            let delay = min(hookRefreshThrottle.interval, max(0, fireDate.timeIntervalSince(now)))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .alreadyScheduled:
            break
        }
    }

    // MARK: - 刷新

    /// 菜单刷新的采集窗口（小时）：周窗口要近 7 天，取 180h（168h + 余量）。也是用量收集器缓存的保留窗口。
    nonisolated static let refreshWindowHours = 180

    /// 后台收集近 180h 内 mtime 的文件的用量（只重新解析改过的文件，见 `ClaudeUsageCollector`），一次算出 5h 窗口、今日累计与周窗口。
    /// 5h / 今日只关心近 24h，是这批条目的天然子集。进行中再调只记一笔，这一轮结束后再刷一轮。
    func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        isRefreshing = true
        let anchor = Self.weeklyAnchorConfig()   // 主线程读 UserDefaults 后传入后台。
        DispatchQueue.global(qos: .utility).async {
            let entries = Self.collectEntries(sinceHoursAgo: Self.refreshWindowHours)
            let window = ClaudeUsageCalculator.activeWindow(from: entries)
            let today = ClaudeUsageCalculator.todayTotals(from: entries)
            let weekly = ClaudeUsageCalculator.weeklyWindow(from: entries, anchor: anchor)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.currentWindow = window
                    self.todayTotals = today
                    self.weeklyWindow = weekly
                    self.refreshing = false
                    self.checkBudgetReminder(window: window)
                    self.checkWeeklyBudgetReminder(window: weekly)
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

    /// 主线程读取周窗口锚点配置（值类型，可安全传入后台）。
    static func weeklyAnchorConfig() -> WeeklyAnchor {
        let defaults = UserDefaults.standard
        return WeeklyAnchor(
            fixed: defaults.object(forKey: weeklyFixedKey) as? Bool ?? false,
            clampingWeekday: defaults.object(forKey: weeklyWeekdayKey) as? Int ?? 2,   // 默认周一。
            hour: defaults.object(forKey: weeklyHourKey) as? Int ?? 0
        )
    }

    /// 三维度报表：解析近 `days` 天文件。后台计算，回主线程。
    func report(days: Int, completion: @escaping (ClaudeUsageReport) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let entries = Self.collectEntries(sinceHoursAgo: days * 24)
            let report = Self.buildReport(from: entries)
            DispatchQueue.main.async {
                completion(report)
            }
        }
    }

    /// 调用统计：Skill/斜杠命令、MCP（服务器›工具两级）、内置工具三类计数。
    /// 后台遍历近 `days` 天 mtime 的会话文件，主线程回调。
    func invocationStats(days: Int, completion: @escaping (ClaudeInvocationStats) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let stats = Self.computeInvocationStats(days: days)
            DispatchQueue.main.async {
                completion(stats)
            }
        }
    }

    // MARK: - 额度提醒

    private func checkBudgetReminder(window: UsageWindow?) {
        guard let window else { return }
        let budget = UserDefaults.standard.integer(forKey: Self.budgetKey)
        let outcome = budgetReminder.check(windowStart: window.start, totalTokens: window.totals.totalTokens, budget: budget)
        // 检测到窗口已切换：可选发「额度已恢复」。
        if outcome.windowChanged, ClaudeNotifierSettings.budgetRestoreEnabled {
            ClaudeNotifier.shared.notifyBudgetRestored()
        }
        if let percent = outcome.reachedPercent, ClaudeNotifierSettings.budgetAlertEnabled {
            ClaudeNotifier.shared.notifyBudget(percent: percent, windowEnd: window.end)
        }
    }

    /// 周预算提醒：与 `checkBudgetReminder` 同构，独立 key 与独立防重状态。
    private func checkWeeklyBudgetReminder(window: UsageWindow?) {
        guard let window else { return }
        let budget = UserDefaults.standard.integer(forKey: Self.weeklyBudgetKey)
        let outcome = weeklyBudgetReminder.check(windowStart: window.start, totalTokens: window.totals.totalTokens, budget: budget)
        if outcome.windowChanged, ClaudeNotifierSettings.budgetRestoreEnabled {
            ClaudeNotifier.shared.notifyWeeklyBudgetRestored()
        }
        if let percent = outcome.reachedPercent, ClaudeNotifierSettings.budgetAlertEnabled {
            ClaudeNotifier.shared.notifyWeeklyBudget(percent: percent, windowEnd: window.end)
        }
    }
}

// MARK: - 后台解析（nonisolated static）

extension ClaudeUsageStore {

    /// 用量条目的收集器：按文件缓存解析结果（只在内存），没变的文件不再读，结果与全量解析逐条相同（#109）。
    /// 菜单刷新与报表共用一份缓存；缓存只留近 180h 改过的文件，报表要的更早的文件照旧每次解析。
    nonisolated static let usageCollector = ClaudeUsageCollector(
        projectsDir: ClaudeEnv.projectsDir,
        retentionHours: refreshWindowHours,
        fallbackProjectPath: { ClaudeSessionIndex.demungeDirName($0) }
    )

    /// 收集近 N 小时内 mtime 文件的去重用量条目。
    nonisolated fileprivate static func collectEntries(sinceHoursAgo hours: Int) -> [CLIUsageEntry] {
        usageCollector.collect(sinceHoursAgo: hours).entries
    }

    /// 三维度报表：按项目 / 按模型两张表按估算费用从高到低排；项目显示名取路径最后一段（`ClaudeSessionIndex`）。
    nonisolated fileprivate static func buildReport(from entries: [CLIUsageEntry]) -> ClaudeUsageReport {
        ClaudeUsageCalculator.buildReport(
            from: entries,
            order: .byCost,
            locale: L10n.locale,
            projectBucket: { path in (id: path, label: ClaudeSessionIndex.projectName(fromPath: path)) }
        )
    }

    /// 调用统计：遍历近 `days` 天 mtime 的会话文件，聚合 Skill/斜杠命令、MCP、内置工具三类计数。
    nonisolated fileprivate static func computeInvocationStats(days: Int) -> ClaudeInvocationStats {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        // 斜杠命令标记解析（<command-name>/foo</command-name>）；编译失败则跳过该路统计。
        let commandRegex = try? NSRegularExpression(pattern: "<command-name>([^<]*)</command-name>", options: [])

        var skills: [String: Int] = [:]
        var builtin: [String: Int] = [:]
        // server → (总次数, [tool: 次数])
        var mcp: [String: (total: Int, tools: [String: Int])] = [:]

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudeEnv.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ClaudeInvocationStats() }

        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mtime, mtime < cutoff { continue }
                autoreleasepool {  // 每个文件读完就放掉临时对象，峰值不随文件数累加（#93）
                    guard let data = try? Data(contentsOf: file) else { return }

                    for lineData in data.split(separator: 0x0A) {
                        guard let object = CLIJSONL.parseObject(Data(lineData)),
                              let type = object["type"] as? String,
                              let message = object["message"] as? [String: Any] else { continue }

                        if type == "user" {
                            // 斜杠命令标记 → 并入 skills。
                            guard let regex = commandRegex else { continue }
                            let text = allText(fromContent: message["content"])
                            guard !text.isEmpty else { continue }
                            let range = NSRange(text.startIndex..<text.endIndex, in: text)
                            for match in regex.matches(in: text, options: [], range: range) {
                                guard match.numberOfRanges >= 2,
                                      let r = Range(match.range(at: 1), in: text) else { continue }
                                var name = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
                                if name.hasPrefix("/") { name.removeFirst() }
                                guard !name.isEmpty else { continue }
                                skills[name, default: 0] += 1
                            }
                            continue
                        }

                        guard type == "assistant",
                              let content = message["content"] as? [[String: Any]] else { continue }

                        for block in content where (block["type"] as? String) == "tool_use" {
                            guard let name = block["name"] as? String, !name.isEmpty else { continue }

                            if name == "Skill" {
                                // input.skill 为技能名，取不到则跳过（不计入）。
                                if let input = block["input"] as? [String: Any],
                                   let skill = input["skill"] as? String, !skill.isEmpty {
                                    skills[skill, default: 0] += 1
                                }
                            } else if name.hasPrefix("mcp__") {
                                // mcp__<server>__<tool>：拆出 server 与 tool；拆不出整名归到 server 名下。
                                let rest = String(name.dropFirst("mcp__".count))
                                let parts = rest.components(separatedBy: "__")
                                let server = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? rest
                                let tool = parts.count >= 2 ? parts[1...].joined(separator: "__") : nil
                                var entry = mcp[server] ?? (total: 0, tools: [:])
                                entry.total += 1
                                if let tool, !tool.isEmpty {
                                    entry.tools[tool, default: 0] += 1
                                }
                                mcp[server] = entry
                            } else {
                                builtin[name, default: 0] += 1
                            }
                        }
                    }
                }
            }
        }

        var stats = ClaudeInvocationStats()
        stats.skills = skills
        stats.builtin = builtin
        stats.mcp = Dictionary(uniqueKeysWithValues: mcp.map { key, value in
            (key, ClaudeMCPServerStat(server: key, total: value.total, tools: value.tools))
        })
        return stats
    }

    /// 拼接 message.content 中的全部文本（字符串或 text 块数组）。
    nonisolated fileprivate static func allText(fromContent content: Any?) -> String {
        guard let content else { return "" }
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block in
                (block["type"] as? String) == "text" ? block["text"] as? String : nil
            }.joined(separator: "\n")
        }
        return ""
    }
}
