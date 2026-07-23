import Foundation

/// Claude Code 助手 —— 定价表、用量聚合、5 小时额度窗口与报表。
///
/// 费用为按公开定价的**估算**（定价表内置常量，见 TECH_DESIGN 3.3），UI 处处标「估算」。
/// 用量去重：同一条 assistant 消息在续接/分叉文件里会重复，用 `message.id + requestId` 去重。
/// 重 IO 后台，`@Published` 只在主线程写。
///
/// 本文件无独立用户可见文案（额度提醒文案在 ClaudeNotifier / ClaudeLiveStatus.swift 中定义）。

// MARK: - 定价

/// 每百万 token 的美元单价。
struct ModelPricing {
    let inputPerM: Double
    let outputPerM: Double
    let cacheWritePerM: Double
    let cacheReadPerM: Double

    static let zero = ModelPricing(inputPerM: 0, outputPerM: 0, cacheWritePerM: 0, cacheReadPerM: 0)

    /// 按 model id 关键字匹配定价；未知返回全 0 并标记 unpriced。
    /// 缓存写 = 输入 ×1.25(5 分钟 TTL 口径),缓存读 = 输入 ×0.1,与官方定价页一致。
    static func pricing(for modelID: String) -> (pricing: ModelPricing, unpriced: Bool) {
        let id = modelID.lowercased()
        if id.contains("fable") || id.contains("mythos") {
            return (ModelPricing(inputPerM: 10, outputPerM: 50, cacheWritePerM: 12.5, cacheReadPerM: 1.0), false)
        }
        if id.contains("opus") {
            // Opus 4.1 / 4.0 / Claude 3 Opus 为 $15/$75;Opus 4.5 起降为 $5/$25。
            if id.contains("opus-4-1") || id.contains("opus-4-0")
                || id.contains("opus-4-2025") || id.contains("3-opus") {
                return (ModelPricing(inputPerM: 15, outputPerM: 75, cacheWritePerM: 18.75, cacheReadPerM: 1.5), false)
            }
            return (ModelPricing(inputPerM: 5, outputPerM: 25, cacheWritePerM: 6.25, cacheReadPerM: 0.5), false)
        }
        if id.contains("sonnet") {
            return (ModelPricing(inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.3), false)
        }
        if id.contains("haiku") {
            return (ModelPricing(inputPerM: 1, outputPerM: 5, cacheWritePerM: 1.25, cacheReadPerM: 0.1), false)
        }
        return (.zero, true)
    }
}

// MARK: - 聚合模型

/// 一组 token 与估算费用的累计。
struct UsageTotals {
    var input: Int = 0
    var output: Int = 0
    var cacheWrite: Int = 0
    var cacheRead: Int = 0
    var costUSD: Double = 0
    /// 命中过未知模型（费用可能偏低）。
    var unpriced: Bool = false

    static let zero = UsageTotals()

    /// 计费口径下的 token 总数（用于额度窗口预算比对）。
    var totalTokens: Int { input + output + cacheWrite + cacheRead }

    /// 累加一条消息的用量，并按其模型算增量费用。
    mutating func add(input i: Int, output o: Int, cacheWrite cw: Int, cacheRead cr: Int, modelID: String) {
        input += i
        output += o
        cacheWrite += cw
        cacheRead += cr
        let (price, isUnpriced) = ModelPricing.pricing(for: modelID)
        costUSD += Double(i) / 1_000_000 * price.inputPerM
            + Double(o) / 1_000_000 * price.outputPerM
            + Double(cw) / 1_000_000 * price.cacheWritePerM
            + Double(cr) / 1_000_000 * price.cacheReadPerM
        if isUnpriced { unpriced = true }
    }
}

/// 一个 5 小时额度窗口。`end == start + 5h`。
struct UsageWindow {
    let start: Date
    let end: Date
    var totals: UsageTotals

    /// 距重置剩余秒数（相对现在，最少 0）。
    var secondsUntilReset: TimeInterval { max(0, end.timeIntervalSinceNow) }
}

/// 周窗口锚点配置（主线程读 UserDefaults 构造，值类型跨线程安全传入后台计算）。
struct WeeklyAnchor: Sendable {
    /// false = 近 7 天滚动 168h 块；true = 固定锚点（星期 + 小时）。
    let fixed: Bool
    /// 1...7（Calendar.current 口径，1=周日）。
    let weekday: Int
    /// 0...23。
    let hour: Int
}

/// 报表一行（按天 / 按项目 / 按模型通用）。
struct UsageBucket: Identifiable {
    let id: String
    let label: String
    var totals: UsageTotals
    /// 「按天」维度携带日期用于排序；其余为 nil。
    var date: Date?
}

/// 三维度报表。
struct ClaudeUsageReport {
    var byDay: [UsageBucket] = []
    var byProject: [UsageBucket] = []
    var byModel: [UsageBucket] = []
}

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

// MARK: - 一条已解析的用量条目（后台内部使用）

/// 去重后参与聚合的一条 assistant 用量。
fileprivate struct UsageEntry {
    let timestamp: Date
    let modelID: String
    let projectPath: String
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
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
    /// 已提醒过 80% 的窗口起点集合（防重复轰炸）。仅主线程访问。
    private var remindedWindowStarts: Set<Date> = []
    /// 已提醒过 80% 的周窗口起点集合（与 5h 独立防重）。仅主线程访问。
    private var remindedWeekStarts: Set<Date> = []
    private var refreshing = false
    private var lastHookRefresh: Date = .distantPast
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
    }

    /// 收到 hook 事件时的节流刷新（≥60s 才真正刷）。
    func refreshThrottledFromHook() {
        guard Date().timeIntervalSince(lastHookRefresh) >= 60 else { return }
        lastHookRefresh = Date()
        refresh()
    }

    // MARK: - 刷新

    /// 后台解析近 180h 内 mtime 的文件，一次扫描算出 5h 窗口、今日累计与周窗口。
    /// 5h / 今日只关心近 24h，是这批条目的天然子集；周窗口需近 7 天故采集窗口取 180h（168h + 余量）。
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        isRefreshing = true
        let anchor = Self.weeklyAnchorConfig()   // 主线程读 UserDefaults 后传入后台。
        DispatchQueue.global(qos: .utility).async {
            let entries = Self.collectEntries(sinceHoursAgo: 180)
            let window = Self.activeWindow(from: entries)
            let today = Self.todayTotals(from: entries)
            let weekly = Self.weeklyWindow(from: entries, anchor: anchor)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.currentWindow = window
                    self.todayTotals = today
                    self.weeklyWindow = weekly
                    self.refreshing = false
                    self.isRefreshing = false
                    self.checkBudgetReminder(window: window)
                    self.checkWeeklyBudgetReminder(window: weekly)
                }
            }
        }
    }

    /// 主线程读取周窗口锚点配置（值类型，可安全传入后台）。
    static func weeklyAnchorConfig() -> WeeklyAnchor {
        let defaults = UserDefaults.standard
        let fixed = defaults.object(forKey: weeklyFixedKey) as? Bool ?? false
        let weekday = defaults.object(forKey: weeklyWeekdayKey) as? Int ?? 2   // 默认周一。
        let hour = defaults.object(forKey: weeklyHourKey) as? Int ?? 0
        return WeeklyAnchor(
            fixed: fixed,
            weekday: min(7, max(1, weekday)),
            hour: min(23, max(0, hour))
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
        guard budget > 0 else { return }
        // 清掉非当前窗口的旧记录，顺带处理「窗口切换」。
        if !remindedWindowStarts.contains(window.start), remindedWindowStarts.contains(where: { $0 != window.start }) {
            // 检测到窗口已切换：可选发「额度已恢复」。
            if ClaudeNotifierSettings.budgetRestoreEnabled {
                ClaudeNotifier.shared.notifyBudgetRestored()
            }
            remindedWindowStarts = []
        }
        let ratio = Double(window.totals.totalTokens) / Double(budget)
        if ratio >= 0.8, !remindedWindowStarts.contains(window.start) {
            remindedWindowStarts.insert(window.start)
            if ClaudeNotifierSettings.budgetAlertEnabled {
                ClaudeNotifier.shared.notifyBudget(percent: Int((ratio * 100).rounded()), windowEnd: window.end)
            }
        }
    }

    /// 周预算提醒：与 `checkBudgetReminder` 同构，独立 key 与独立防重集合。
    private func checkWeeklyBudgetReminder(window: UsageWindow?) {
        guard let window else { return }
        let budget = UserDefaults.standard.integer(forKey: Self.weeklyBudgetKey)
        guard budget > 0 else { return }
        // 清掉非当前周窗口的旧记录，顺带处理「周窗口切换」。
        if !remindedWeekStarts.contains(window.start), remindedWeekStarts.contains(where: { $0 != window.start }) {
            if ClaudeNotifierSettings.budgetRestoreEnabled {
                ClaudeNotifier.shared.notifyWeeklyBudgetRestored()
            }
            remindedWeekStarts = []
        }
        let ratio = Double(window.totals.totalTokens) / Double(budget)
        if ratio >= 0.8, !remindedWeekStarts.contains(window.start) {
            remindedWeekStarts.insert(window.start)
            if ClaudeNotifierSettings.budgetAlertEnabled {
                ClaudeNotifier.shared.notifyWeeklyBudget(percent: Int((ratio * 100).rounded()), windowEnd: window.end)
            }
        }
    }
}

// MARK: - 后台解析（nonisolated static）

extension ClaudeUsageStore {

    /// 收集近 N 小时内 mtime 文件的去重用量条目。
    nonisolated fileprivate static func collectEntries(sinceHoursAgo hours: Int) -> [UsageEntry] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3_600)
        var entries: [UsageEntry] = []
        var seenKeys = Set<String>()

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudeEnv.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let mungedName = projectDir.lastPathComponent
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mtime, mtime < cutoff { continue }
                guard let data = try? Data(contentsOf: file) else { continue }

                for lineData in data.split(separator: 0x0A) {
                    guard let object = ClaudeJSONLParsing.parseObject(Data(lineData)),
                          (object["type"] as? String) == "assistant",
                          let message = object["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any] else { continue }

                    // 去重键：message.id + requestId；两者都缺则不去重直接计入。
                    let messageID = message["id"] as? String
                    let requestID = object["requestId"] as? String
                    if let messageID, let requestID {
                        let key = messageID + "|" + requestID
                        if seenKeys.contains(key) { continue }
                        seenKeys.insert(key)
                    } else if let messageID {
                        if seenKeys.contains(messageID) { continue }
                        seenKeys.insert(messageID)
                    }

                    let ts = object["timestamp"] as? String
                    let date = ts.flatMap { ClaudeJSONLParsing.parseDate($0) } ?? mtime ?? Date()
                    let modelID = message["model"] as? String ?? ""
                    let projectPath = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? ClaudeSessionIndex.demungeDirName(mungedName)

                    entries.append(UsageEntry(
                        timestamp: date,
                        modelID: modelID,
                        projectPath: projectPath,
                        input: intValue(usage["input_tokens"]),
                        output: intValue(usage["output_tokens"]),
                        cacheWrite: intValue(usage["cache_creation_input_tokens"]),
                        cacheRead: intValue(usage["cache_read_input_tokens"])
                    ))
                }
            }
        }
        return entries
    }

    /// 5h 窗口算法（对齐 ccusage）：升序，blockStart 向下取整到小时；超 5h 开新块。
    /// 若 `now <= 末块.start + 5h` 则末块为活跃窗口，否则无活跃窗口。
    /// 实现委托给参数化的 `lastActiveBlock(from:span:)`，与周窗口共用同一分块逻辑。
    nonisolated fileprivate static func activeWindow(from entries: [UsageEntry]) -> UsageWindow? {
        lastActiveBlock(from: entries, span: 5 * 3_600)
    }

    /// 通用「末个活跃分块」算法（跨度参数化）：升序，blockStart 向下取整到小时；
    /// 条目时间 > `blockStart + span` 时开新块。末块满足 `now <= blockStart + span` 即为活跃窗口，否则返回 nil。
    /// span=5h 为 5 小时窗口，span=168h 为周窗口（滚动块口径），两者行为一致。
    nonisolated fileprivate static func lastActiveBlock(from entries: [UsageEntry], span: TimeInterval) -> UsageWindow? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }

        var blocks: [UsageWindow] = []
        var start: Date?
        var totals = UsageTotals.zero

        for entry in sorted {
            if let currentStart = start {
                if entry.timestamp > currentStart.addingTimeInterval(span) {
                    blocks.append(UsageWindow(start: currentStart, end: currentStart.addingTimeInterval(span), totals: totals))
                    start = floorToHour(entry.timestamp)
                    totals = .zero
                }
            } else {
                start = floorToHour(entry.timestamp)
                totals = .zero
            }
            totals.add(input: entry.input, output: entry.output, cacheWrite: entry.cacheWrite, cacheRead: entry.cacheRead, modelID: entry.modelID)
        }
        if let currentStart = start {
            blocks.append(UsageWindow(start: currentStart, end: currentStart.addingTimeInterval(span), totals: totals))
        }

        guard let last = blocks.last, Date() <= last.end else { return nil }
        return last
    }

    /// 周窗口：滚动块（默认）复用分块算法、跨度换 168h；固定锚点聚合 [anchorStart, anchorStart+7d) 内条目。
    /// 滚动块无条目返回 nil；固定锚点即使 totals 为 0 也返回一个 window（有明确起止与倒计时可展示）。
    nonisolated fileprivate static func weeklyWindow(from entries: [UsageEntry], anchor: WeeklyAnchor) -> UsageWindow? {
        guard !entries.isEmpty else { return nil }
        let weekSpan: TimeInterval = 168 * 3_600
        if !anchor.fixed {
            return lastActiveBlock(from: entries, span: weekSpan)
        }
        // 固定锚点：取不到锚点则回退滚动块口径。
        guard let start = weekAnchorStart(before: Date(), weekday: anchor.weekday, hour: anchor.hour) else {
            return lastActiveBlock(from: entries, span: weekSpan)
        }
        let end = start.addingTimeInterval(weekSpan)
        var totals = UsageTotals.zero
        for entry in entries where entry.timestamp >= start && entry.timestamp < end {
            totals.add(input: entry.input, output: entry.output, cacheWrite: entry.cacheWrite, cacheRead: entry.cacheRead, modelID: entry.modelID)
        }
        return UsageWindow(start: start, end: end, totals: totals)
    }

    /// `date` 之前最近一个「指定星期几的指定小时:00:00」。取不到返回 nil（调用方回退滚动块）。
    nonisolated fileprivate static func weekAnchorStart(before date: Date, weekday: Int, hour: Int) -> Date? {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        components.second = 0
        return Calendar.current.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .backward
        )
    }

    /// 今日（本地时区）累计。
    nonisolated fileprivate static func todayTotals(from entries: [UsageEntry]) -> UsageTotals? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        var totals = UsageTotals.zero
        var any = false
        for entry in entries where entry.timestamp >= dayStart && entry.timestamp < dayEnd {
            any = true
            totals.add(input: entry.input, output: entry.output, cacheWrite: entry.cacheWrite, cacheRead: entry.cacheRead, modelID: entry.modelID)
        }
        return any ? totals : nil
    }

    /// 三维度报表构建。
    nonisolated fileprivate static func buildReport(from entries: [UsageEntry]) -> ClaudeUsageReport {
        var report = ClaudeUsageReport()
        let calendar = Calendar.current

        var byDay: [Date: UsageTotals] = [:]
        var byProject: [String: UsageTotals] = [:]
        var byModel: [String: UsageTotals] = [:]

        let dayFormatter = DateFormatter()
        dayFormatter.locale = L10n.locale
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for entry in entries {
            let dayKey = calendar.startOfDay(for: entry.timestamp)
            var day = byDay[dayKey] ?? .zero
            day.add(input: entry.input, output: entry.output, cacheWrite: entry.cacheWrite, cacheRead: entry.cacheRead, modelID: entry.modelID)
            byDay[dayKey] = day

            var proj = byProject[entry.projectPath] ?? .zero
            proj.add(input: entry.input, output: entry.output, cacheWrite: entry.cacheWrite, cacheRead: entry.cacheRead, modelID: entry.modelID)
            byProject[entry.projectPath] = proj

            let modelLabel = entry.modelID.isEmpty ? "unknown" : entry.modelID
            var model = byModel[modelLabel] ?? .zero
            model.add(input: entry.input, output: entry.output, cacheWrite: entry.cacheWrite, cacheRead: entry.cacheRead, modelID: entry.modelID)
            byModel[modelLabel] = model
        }

        report.byDay = byDay.map { key, value in
            UsageBucket(id: dayFormatter.string(from: key), label: dayFormatter.string(from: key), totals: value, date: key)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        report.byProject = byProject.map { key, value in
            UsageBucket(id: key, label: ClaudeSessionIndex.projectName(fromPath: key), totals: value, date: nil)
        }.sorted { $0.totals.costUSD > $1.totals.costUSD }

        report.byModel = byModel.map { key, value in
            UsageBucket(id: key, label: key, totals: value, date: nil)
        }.sorted { $0.totals.costUSD > $1.totals.costUSD }

        return report
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
                guard let data = try? Data(contentsOf: file) else { continue }

                for lineData in data.split(separator: 0x0A) {
                    guard let object = ClaudeJSONLParsing.parseObject(Data(lineData)),
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

    // MARK: - 私有辅助

    /// 时间戳向下取整到整点（对齐 UTC 小时，稳定不随时区漂移）。
    nonisolated fileprivate static func floorToHour(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        let floored = (seconds / 3_600).rounded(.down) * 3_600
        return Date(timeIntervalSinceReferenceDate: floored)
    }

    /// 容错取整数（可能是 Int / Double / NSNumber / 字符串）。
    nonisolated fileprivate static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let i = Int(s) { return i }
        return 0
    }
}
