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
    static func pricing(for modelID: String) -> (pricing: ModelPricing, unpriced: Bool) {
        let id = modelID.lowercased()
        if id.contains("opus") {
            return (ModelPricing(inputPerM: 15, outputPerM: 75, cacheWritePerM: 18.75, cacheReadPerM: 1.5), false)
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

// MARK: - 一条已解析的用量条目（后台内部使用）

/// 去重后参与聚合的一条 assistant 用量。
private struct UsageEntry {
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
    @Published private(set) var todayTotals: UsageTotals?
    @Published private(set) var isRefreshing = false

    /// 每额度窗口 token 预算（0 = 未设）。
    static let budgetKey = "claudecode.tokenBudget"
    /// 已提醒过 80% 的窗口起点集合（防重复轰炸）。仅主线程访问。
    private var remindedWindowStarts: Set<Date> = []
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

    /// 后台解析近 24h 内 mtime 的文件，算当前窗口与今日累计。
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async {
            let entries = Self.collectEntries(sinceHoursAgo: 24)
            let window = Self.activeWindow(from: entries)
            let today = Self.todayTotals(from: entries)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.currentWindow = window
                    self.todayTotals = today
                    self.refreshing = false
                    self.isRefreshing = false
                    self.checkBudgetReminder(window: window)
                }
            }
        }
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
}

// MARK: - 后台解析（nonisolated static）

extension ClaudeUsageStore {

    /// 收集近 N 小时内 mtime 文件的去重用量条目。
    nonisolated fileprivate static funccollectEntries(sinceHoursAgo hours: Int) -> [UsageEntry] {
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
    nonisolated fileprivate static funcactiveWindow(from entries: [UsageEntry]) -> UsageWindow? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        let fiveHours: TimeInterval = 5 * 3_600

        var blocks: [UsageWindow] = []
        var start: Date?
        var totals = UsageTotals.zero

        for entry in sorted {
            if let currentStart = start {
                if entry.timestamp > currentStart.addingTimeInterval(fiveHours) {
                    blocks.append(UsageWindow(start: currentStart, end: currentStart.addingTimeInterval(fiveHours), totals: totals))
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
            blocks.append(UsageWindow(start: currentStart, end: currentStart.addingTimeInterval(fiveHours), totals: totals))
        }

        guard let last = blocks.last, Date() <= last.end else { return nil }
        return last
    }

    /// 今日（本地时区）累计。
    nonisolated fileprivate static functodayTotals(from entries: [UsageEntry]) -> UsageTotals? {
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
    nonisolated fileprivate static funcbuildReport(from entries: [UsageEntry]) -> ClaudeUsageReport {
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

    // MARK: - 私有辅助

    /// 时间戳向下取整到整点（对齐 UTC 小时，稳定不随时区漂移）。
    nonisolated fileprivate static funcfloorToHour(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        let floored = (seconds / 3_600).rounded(.down) * 3_600
        return Date(timeIntervalSinceReferenceDate: floored)
    }

    /// 容错取整数（可能是 Int / Double / NSNumber / 字符串）。
    nonisolated fileprivate static funcintValue(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let i = Int(s) { return i }
        return 0
    }
}
