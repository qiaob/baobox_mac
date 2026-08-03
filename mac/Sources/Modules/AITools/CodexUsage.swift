import Foundation

/// Codex 助手 —— 定价表、用量聚合、5 小时 + 周额度窗口与报表。
///
/// 结构对照 `ClaudeUsage.swift`（**平行实现、不跨模块依赖**）。费用为按公开定价的**估算**，
/// UI 处处标「估算」；很多 Codex 用户走 ChatGPT 订阅（无按量计费），故费用为次要信息、token 数为主。
/// 重 IO 后台，`@Published` 只在主线程写（严格照 `ClaudeUsageStore.refresh`）。解析全程容错不 crash。
///
/// —— token_count 聚合口径（本文件的唯一难点，见 DESIGN §2）——
/// Codex 用量在 `event_msg` 行、`payload.type == "token_count"`，字段位置随版本有别：
///   - `info.last_token_usage`：**每回合增量**，可安全累加。
///   - `info.total_token_usage`：**累计值**，按会话取时间最大的一条、不累加。
///   - `payload` 顶层计数（无 info）：当作增量累加。
/// 判定（按文件）：文件内出现过 `last_token_usage` → 增量路径（累加全部 last）；
/// 否则出现过 `total_token_usage` → 累计路径（只取最后一条 total）；否则用 payload 顶层计数（增量累加）。
/// 二者不混用于同一文件，避免双计。

// MARK: - 定价

/// 每百万 token 的美元单价（Codex 无「缓存写」概念，cachedInput 是折扣读）。
/// 定价为估算常量，来源日期 2026-07（随时可能变）。
struct CodexPricing {
    let inputPerM: Double
    let cachedInputPerM: Double
    let outputPerM: Double

    static let zero = CodexPricing(inputPerM: 0, cachedInputPerM: 0, outputPerM: 0)

    /// 按 model id 关键字匹配定价；未知返回全 0 并标记 unpriced。
    static func pricing(for modelID: String) -> (pricing: CodexPricing, unpriced: Bool) {
        let id = modelID.lowercased()
        // gpt-5 覆盖 gpt-5-codex（默认 Codex 模型族）。
        if id.contains("gpt-5") {
            return (CodexPricing(inputPerM: 1.25, cachedInputPerM: 0.125, outputPerM: 10), false)
        }
        if id.contains("o4-mini") || id.contains("o3-mini") {
            return (CodexPricing(inputPerM: 1.1, cachedInputPerM: 0.275, outputPerM: 4.4), false)
        }
        if id.contains("o3") {
            return (CodexPricing(inputPerM: 2, cachedInputPerM: 0.5, outputPerM: 8), false)
        }
        if id.contains("gpt-4.1") {
            return (CodexPricing(inputPerM: 2, cachedInputPerM: 0.5, outputPerM: 8), false)
        }
        if id.contains("codex-mini") {
            return (CodexPricing(inputPerM: 1.5, cachedInputPerM: 0.375, outputPerM: 6), false)
        }
        return (.zero, true)
    }
}

// MARK: - 聚合模型

/// 一组 token 与估算费用的累计。
struct CodexUsageTotals {
    var input: Int = 0
    var cachedInput: Int = 0
    var output: Int = 0
    var costUSD: Double = 0
    /// 命中过未知模型（费用可能偏低）。
    var unpriced: Bool = false

    static let zero = CodexUsageTotals()

    /// Codex 计费口径以 input+output 为主（额度窗口预算比对用）。
    var totalTokens: Int { input + output }

    /// 累加一条用量并按其模型算增量费用。
    /// `input` 通常已含缓存读部分，故计费时从 input 扣除 `cachedInput`（取不到 cached 即为 0，全按 input 计）。
    mutating func add(input i: Int, cachedInput c: Int, output o: Int, modelID: String) {
        input += i
        cachedInput += c
        output += o
        let (price, isUnpriced) = CodexPricing.pricing(for: modelID)
        let billableInput = max(0, i - c)
        costUSD += Double(billableInput) / 1_000_000 * price.inputPerM
            + Double(c) / 1_000_000 * price.cachedInputPerM
            + Double(o) / 1_000_000 * price.outputPerM
        if isUnpriced { unpriced = true }
    }
}

/// 一个额度窗口（5h 或周）。`end == start + span`。
struct CodexUsageWindow {
    let start: Date
    let end: Date
    var totals: CodexUsageTotals

    /// 距重置剩余秒数（相对现在，最少 0）。
    var secondsUntilReset: TimeInterval { max(0, end.timeIntervalSinceNow) }
}

/// 周窗口锚点配置（主线程读 UserDefaults 构造，值类型跨线程安全传入后台计算）。
struct CodexWeeklyAnchor: Sendable {
    /// false = 近 7 天滚动 168h 块；true = 固定锚点（星期 + 小时）。
    let fixed: Bool
    /// 1...7（Calendar.current 口径，1=周日）。
    let weekday: Int
    /// 0...23。
    let hour: Int
}

/// 报表一行（按天 / 按项目 / 按模型通用）。
struct CodexUsageBucket: Identifiable {
    let id: String
    let label: String
    var totals: CodexUsageTotals
    /// 「按天」维度携带日期用于排序；其余为 nil。
    var date: Date?
}

/// 三维度报表。
struct CodexUsageReport {
    var byDay: [CodexUsageBucket] = []
    var byProject: [CodexUsageBucket] = []
    var byModel: [CodexUsageBucket] = []
}

/// 一个 MCP 服务器的调用统计（两级：服务器总次数 + 各工具次数）。
struct CodexMCPServerStat: Sendable {
    let server: String
    let total: Int
    let tools: [String: Int]
}

/// 调用统计（Codex 无 Skill / 斜杠命令，只有内置工具与 MCP 两类）。值类型、Sendable。
struct CodexInvocationStats: Sendable {
    /// 内置工具：工具名（shell / apply_patch / read_file …）→ 次数。
    var builtin: [String: Int] = [:]
    /// MCP：服务器名 → 该服务器统计。
    var mcp: [String: CodexMCPServerStat] = [:]
}

// MARK: - 一条已解析的用量条目（后台内部使用）

fileprivate struct CodexUsageEntry {
    let timestamp: Date
    let modelID: String
    let projectPath: String
    let input: Int
    let cachedInput: Int
    let output: Int
}

// MARK: - 用量单例

/// 用量聚合：当前 5h 窗口、周窗口、今日累计、报表、调用统计。
@MainActor
final class CodexUsageStore: ObservableObject {
    static let shared = CodexUsageStore()

    /// nil = 无活跃 5h 窗口。
    @Published private(set) var fiveHourWindow: CodexUsageWindow?
    /// nil = 近 7 天无用量（滚动块口径）；固定锚点口径下始终有值。
    @Published private(set) var weeklyWindow: CodexUsageWindow?
    @Published private(set) var todayTotals: CodexUsageTotals?
    @Published private(set) var isRefreshing = false

    /// 5h 窗口 token 预算（0 = 未设）。
    static let budgetKey = "codex.tokenBudget"
    /// 每周额度 token 预算（0 = 未设）。
    static let weeklyBudgetKey = "codex.weeklyTokenBudget"
    /// 周窗口按固定重置时间对齐（默认 false = 近 7 天滚动块）。
    static let weeklyFixedKey = "codex.weeklyResetFixed"
    /// 固定锚点：重置星期（1...7，Calendar 口径，1=周日）。默认 2（周一）。
    static let weeklyWeekdayKey = "codex.weeklyResetWeekday"
    /// 固定锚点：重置小时（0...23）。默认 0。
    static let weeklyHourKey = "codex.weeklyResetHour"

    /// 已提醒过 80% 的窗口起点集合（防重复轰炸）。仅主线程访问。
    private var remindedWindowStarts: Set<Date> = []
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

    /// 收到 notify 事件时的节流刷新（≥60s 才真正刷）。
    func refreshThrottledFromEvent() {
        guard Date().timeIntervalSince(lastHookRefresh) >= 60 else { return }
        lastHookRefresh = Date()
        refresh()
    }

    // MARK: - 刷新

    /// 后台解析近 180h 内 mtime 的 rollout 文件，一次扫描算出 5h 窗口、今日累计与周窗口。
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
                    self.fiveHourWindow = window
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
    static func weeklyAnchorConfig() -> CodexWeeklyAnchor {
        let defaults = UserDefaults.standard
        let fixed = defaults.object(forKey: weeklyFixedKey) as? Bool ?? false
        let weekday = defaults.object(forKey: weeklyWeekdayKey) as? Int ?? 2
        let hour = defaults.object(forKey: weeklyHourKey) as? Int ?? 0
        return CodexWeeklyAnchor(
            fixed: fixed,
            weekday: min(7, max(1, weekday)),
            hour: min(23, max(0, hour))
        )
    }

    /// 三维度报表：解析近 `days` 天文件。后台计算，回主线程。
    func report(days: Int, completion: @escaping (CodexUsageReport) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let entries = Self.collectEntries(sinceHoursAgo: days * 24)
            let report = Self.buildReport(from: entries)
            DispatchQueue.main.async {
                completion(report)
            }
        }
    }

    /// 调用统计：内置工具、MCP（服务器›工具两级）两类计数。后台遍历近 `days` 天文件，主线程回调。
    func invocationStats(days: Int, completion: @escaping (CodexInvocationStats) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let stats = Self.computeInvocationStats(days: days)
            DispatchQueue.main.async {
                completion(stats)
            }
        }
    }

    // MARK: - 额度提醒

    private func checkBudgetReminder(window: CodexUsageWindow?) {
        guard let window else { return }
        let budget = UserDefaults.standard.integer(forKey: Self.budgetKey)
        guard budget > 0 else { return }
        if !remindedWindowStarts.contains(window.start), remindedWindowStarts.contains(where: { $0 != window.start }) {
            remindedWindowStarts = []
        }
        let ratio = Double(window.totals.totalTokens) / Double(budget)
        if ratio >= 0.8, !remindedWindowStarts.contains(window.start) {
            remindedWindowStarts.insert(window.start)
            if AIToolsNotifierSettings.budgetAlertEnabled {
                CodexNotify.shared.notifyBudget(percent: Int((ratio * 100).rounded()), weekly: false)
            }
        }
    }

    private func checkWeeklyBudgetReminder(window: CodexUsageWindow?) {
        guard let window else { return }
        let budget = UserDefaults.standard.integer(forKey: Self.weeklyBudgetKey)
        guard budget > 0 else { return }
        if !remindedWeekStarts.contains(window.start), remindedWeekStarts.contains(where: { $0 != window.start }) {
            remindedWeekStarts = []
        }
        let ratio = Double(window.totals.totalTokens) / Double(budget)
        if ratio >= 0.8, !remindedWeekStarts.contains(window.start) {
            remindedWeekStarts.insert(window.start)
            if AIToolsNotifierSettings.budgetAlertEnabled {
                CodexNotify.shared.notifyBudget(percent: Int((ratio * 100).rounded()), weekly: true)
            }
        }
    }
}

// MARK: - 后台解析（nonisolated static）

extension CodexUsageStore {

    /// 收集近 N 小时内 mtime 文件的用量条目，按 §2 口径处理每文件的增量 / 累计。
    nonisolated fileprivate static func collectEntries(sinceHoursAgo hours: Int) -> [CodexUsageEntry] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3_600)
        var entries: [CodexUsageEntry] = []

        guard let enumerator = fm.enumerator(
            at: CodexEnv.sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate ?? Date()
            if mtime < cutoff { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            entries.append(contentsOf: parseFile(data: data, fallbackDate: mtime))
        }
        return entries
    }

    /// 解析单个 rollout 文件为用量条目序列（按 §2 口径）。
    nonisolated fileprivate static func parseFile(data: Data, fallbackDate: Date) -> [CodexUsageEntry] {
        // 会话级维度：cwd（项目）与最后可见 model。
        var cwd = ""
        var modelID = ""

        // 三条候选路径的事件集合，每条带 (timestamp, input, cachedInput, output)。
        struct Counts { let ts: Date; let input: Int; let cachedInput: Int; let output: Int }
        var lastEvents: [Counts] = []      // info.last_token_usage（增量）
        var totalEvents: [Counts] = []     // info.total_token_usage（累计）
        var topEvents: [Counts] = []       // payload 顶层计数（增量）

        for lineData in data.split(separator: 0x0A) {
            guard let object = CodexJSONLParsing.parseObject(Data(lineData)) else { continue }

            // 项目 cwd（首个非空即定）。
            if cwd.isEmpty, let c = CodexJSONLParsing.extractMeta(from: object).cwd, !c.isEmpty {
                cwd = c
            }
            // 模型 id：取会话内最后一次可见值。
            if let m = extractModel(from: object), !m.isEmpty {
                modelID = m
            }

            // 仅处理 token_count 事件（兼容顶层 / payload 嵌套两种写法）。
            let payload = object["payload"] as? [String: Any]
            let type = (payload?["type"] as? String) ?? (object["type"] as? String)
            guard type == "token_count" else { continue }
            let ts = eventDate(object, payload: payload, fallback: fallbackDate)
            let info = payload?["info"] as? [String: Any]

            if let last = info?["last_token_usage"] as? [String: Any] {
                lastEvents.append(Counts(ts: ts,
                                         input: intValue(last["input_tokens"]),
                                         cachedInput: intValue(last["cached_input_tokens"]),
                                         output: intValue(last["output_tokens"])))
            }
            if let total = info?["total_token_usage"] as? [String: Any] {
                totalEvents.append(Counts(ts: ts,
                                          input: intValue(total["input_tokens"]),
                                          cachedInput: intValue(total["cached_input_tokens"]),
                                          output: intValue(total["output_tokens"])))
            }
            // payload 顶层计数（仅当无 info 时才作为增量来源，避免与 info 双计）。
            if info == nil, let payload, payload["input_tokens"] != nil || payload["output_tokens"] != nil {
                topEvents.append(Counts(ts: ts,
                                        input: intValue(payload["input_tokens"]),
                                        cachedInput: intValue(payload["cached_input_tokens"]),
                                        output: intValue(payload["output_tokens"])))
            }
        }

        // 路径判定：last（增量，全累加）优先 → total（累计，只取最后一条）→ 顶层（增量，全累加）。
        let chosen: [Counts]
        if !lastEvents.isEmpty {
            chosen = lastEvents
        } else if !totalEvents.isEmpty {
            if let latest = totalEvents.max(by: { $0.ts < $1.ts }) {
                chosen = [latest]
            } else {
                chosen = []
            }
        } else {
            chosen = topEvents
        }

        return chosen.map { c in
            CodexUsageEntry(timestamp: c.ts, modelID: modelID, projectPath: cwd,
                            input: c.input, cachedInput: c.cachedInput, output: c.output)
        }
    }

    /// 从一行对象尽力取出 model id（顶层 / payload / turn_context / info）。
    nonisolated fileprivate static func extractModel(from object: [String: Any]) -> String? {
        if let m = object["model"] as? String, !m.isEmpty { return m }
        if let payload = object["payload"] as? [String: Any] {
            if let m = payload["model"] as? String, !m.isEmpty { return m }
            if let tc = payload["turn_context"] as? [String: Any], let m = tc["model"] as? String, !m.isEmpty { return m }
            if let info = payload["info"] as? [String: Any], let m = info["model"] as? String, !m.isEmpty { return m }
        }
        if let tc = object["turn_context"] as? [String: Any], let m = tc["model"] as? String, !m.isEmpty { return m }
        return nil
    }

    /// 事件时间戳（顶层 / payload 的 timestamp；取不到用文件 mtime）。
    nonisolated fileprivate static func eventDate(_ object: [String: Any], payload: [String: Any]?, fallback: Date) -> Date {
        let ts = (object["timestamp"] as? String) ?? (payload?["timestamp"] as? String)
        return ts.flatMap { CodexJSONLParsing.parseDate($0) } ?? fallback
    }

    // MARK: 窗口算法（与 Claude 完全同构）

    nonisolated fileprivate static func activeWindow(from entries: [CodexUsageEntry]) -> CodexUsageWindow? {
        lastActiveBlock(from: entries, span: 5 * 3_600)
    }

    /// 通用「末个活跃分块」：升序，blockStart 向下取整到小时；条目时间 > start+span 时开新块。
    /// 末块满足 now <= start+span 即为活跃窗口，否则返回 nil。span=5h 为 5 小时，span=168h 为周（滚动块）。
    nonisolated fileprivate static func lastActiveBlock(from entries: [CodexUsageEntry], span: TimeInterval) -> CodexUsageWindow? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }

        var blocks: [CodexUsageWindow] = []
        var start: Date?
        var totals = CodexUsageTotals.zero

        for entry in sorted {
            if let currentStart = start {
                if entry.timestamp > currentStart.addingTimeInterval(span) {
                    blocks.append(CodexUsageWindow(start: currentStart, end: currentStart.addingTimeInterval(span), totals: totals))
                    start = floorToHour(entry.timestamp)
                    totals = .zero
                }
            } else {
                start = floorToHour(entry.timestamp)
                totals = .zero
            }
            totals.add(input: entry.input, cachedInput: entry.cachedInput, output: entry.output, modelID: entry.modelID)
        }
        if let currentStart = start {
            blocks.append(CodexUsageWindow(start: currentStart, end: currentStart.addingTimeInterval(span), totals: totals))
        }

        guard let last = blocks.last, Date() <= last.end else { return nil }
        return last
    }

    /// 周窗口：滚动块（默认）复用分块算法、跨度 168h；固定锚点聚合 [anchorStart, anchorStart+7d) 内条目。
    nonisolated fileprivate static func weeklyWindow(from entries: [CodexUsageEntry], anchor: CodexWeeklyAnchor) -> CodexUsageWindow? {
        guard !entries.isEmpty else { return nil }
        let weekSpan: TimeInterval = 168 * 3_600
        if !anchor.fixed {
            return lastActiveBlock(from: entries, span: weekSpan)
        }
        guard let start = weekAnchorStart(before: Date(), weekday: anchor.weekday, hour: anchor.hour) else {
            return lastActiveBlock(from: entries, span: weekSpan)
        }
        let end = start.addingTimeInterval(weekSpan)
        var totals = CodexUsageTotals.zero
        for entry in entries where entry.timestamp >= start && entry.timestamp < end {
            totals.add(input: entry.input, cachedInput: entry.cachedInput, output: entry.output, modelID: entry.modelID)
        }
        return CodexUsageWindow(start: start, end: end, totals: totals)
    }

    /// `date` 之前最近一个「指定星期几的指定小时:00:00」。
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
    nonisolated fileprivate static func todayTotals(from entries: [CodexUsageEntry]) -> CodexUsageTotals? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        var totals = CodexUsageTotals.zero
        var any = false
        for entry in entries where entry.timestamp >= dayStart && entry.timestamp < dayEnd {
            any = true
            totals.add(input: entry.input, cachedInput: entry.cachedInput, output: entry.output, modelID: entry.modelID)
        }
        return any ? totals : nil
    }

    /// 三维度报表构建。
    nonisolated fileprivate static func buildReport(from entries: [CodexUsageEntry]) -> CodexUsageReport {
        var report = CodexUsageReport()
        let calendar = Calendar.current

        var byDay: [Date: CodexUsageTotals] = [:]
        var byProject: [String: CodexUsageTotals] = [:]
        var byModel: [String: CodexUsageTotals] = [:]

        let dayFormatter = DateFormatter()
        dayFormatter.locale = L10n.locale
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for entry in entries {
            let dayKey = calendar.startOfDay(for: entry.timestamp)
            var day = byDay[dayKey] ?? .zero
            day.add(input: entry.input, cachedInput: entry.cachedInput, output: entry.output, modelID: entry.modelID)
            byDay[dayKey] = day

            var proj = byProject[entry.projectPath] ?? .zero
            proj.add(input: entry.input, cachedInput: entry.cachedInput, output: entry.output, modelID: entry.modelID)
            byProject[entry.projectPath] = proj

            let modelLabel = entry.modelID.isEmpty ? "unknown" : entry.modelID
            var model = byModel[modelLabel] ?? .zero
            model.add(input: entry.input, cachedInput: entry.cachedInput, output: entry.output, modelID: entry.modelID)
            byModel[modelLabel] = model
        }

        report.byDay = byDay.map { key, value in
            CodexUsageBucket(id: dayFormatter.string(from: key), label: dayFormatter.string(from: key), totals: value, date: key)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        report.byProject = byProject.map { key, value in
            let label = key.isEmpty ? "unknown" : CodexSessionIndex.projectName(fromPath: key)
            return CodexUsageBucket(id: key.isEmpty ? "unknown" : key, label: label, totals: value, date: nil)
        }.sorted { $0.totals.totalTokens > $1.totals.totalTokens }

        report.byModel = byModel.map { key, value in
            CodexUsageBucket(id: key, label: key, totals: value, date: nil)
        }.sorted { $0.totals.totalTokens > $1.totals.totalTokens }

        return report
    }

    /// 调用统计：遍历近 `days` 天 mtime 的 rollout 文件，聚合内置工具与 MCP（服务器›工具两级）。
    nonisolated fileprivate static func computeInvocationStats(days: Int) -> CodexInvocationStats {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        // Codex 工具调用事件命名随版本不一，容错匹配这几类。
        let callTypes: Set<String> = ["function_call", "tool_call", "mcp_tool_call", "local_shell_call", "custom_tool_call"]

        var builtin: [String: Int] = [:]
        var mcp: [String: (total: Int, tools: [String: Int])] = [:]

        guard let enumerator = fm.enumerator(
            at: CodexEnv.sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return CodexInvocationStats() }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if let mtime = values?.contentModificationDate, mtime < cutoff { continue }
            guard let data = try? Data(contentsOf: url) else { continue }

            for lineData in data.split(separator: 0x0A) {
                guard let object = CodexJSONLParsing.parseObject(Data(lineData)) else { continue }
                let payload = (object["payload"] as? [String: Any]) ?? object
                let type = (payload["type"] as? String) ?? (object["type"] as? String) ?? ""
                guard callTypes.contains(type) else { continue }

                let name = (payload["name"] as? String) ?? (payload["tool"] as? String) ?? ""
                let serverField = payload["server"] as? String

                if let server = serverField, !server.isEmpty {
                    // 事件带 server 字段：MCP 两级；tool 取 name 去掉 server__ 前缀。
                    let tool = stripServerPrefix(name, server: server)
                    var entry = mcp[server] ?? (total: 0, tools: [:])
                    entry.total += 1
                    if !tool.isEmpty { entry.tools[tool, default: 0] += 1 }
                    mcp[server] = entry
                } else if name.contains("__") {
                    // 名字形如 <server>__<tool>。
                    let parts = name.components(separatedBy: "__")
                    let server = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? name
                    let tool = parts.count >= 2 ? parts[1...].joined(separator: "__") : ""
                    var entry = mcp[server] ?? (total: 0, tools: [:])
                    entry.total += 1
                    if !tool.isEmpty { entry.tools[tool, default: 0] += 1 }
                    mcp[server] = entry
                } else if type == "mcp_tool_call" {
                    let server = name.isEmpty ? "mcp" : name
                    var entry = mcp[server] ?? (total: 0, tools: [:])
                    entry.total += 1
                    mcp[server] = entry
                } else {
                    // 内置工具：local_shell_call 归一为 shell；其余按 name（缺失记 unknown）。
                    let label = type == "local_shell_call" ? "shell" : (name.isEmpty ? "unknown" : name)
                    builtin[label, default: 0] += 1
                }
            }
        }

        var stats = CodexInvocationStats()
        stats.builtin = builtin
        stats.mcp = Dictionary(uniqueKeysWithValues: mcp.map { key, value in
            (key, CodexMCPServerStat(server: key, total: value.total, tools: value.tools))
        })
        return stats
    }

    nonisolated fileprivate static func stripServerPrefix(_ name: String, server: String) -> String {
        let prefix = server + "__"
        if name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
        return name
    }

    // MARK: - 私有辅助

    nonisolated fileprivate static func floorToHour(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        let floored = (seconds / 3_600).rounded(.down) * 3_600
        return Date(timeIntervalSinceReferenceDate: floored)
    }

    nonisolated fileprivate static func intValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let i = Int(s) { return i }
        return 0
    }
}
