import Foundation

/// Codex 助手 —— 定价表、用量条目解析、5 小时 + 周额度窗口与报表。
///
/// 窗口 / 周窗口 / 今日 / 报表 / 额度提醒的算法与 Claude Code 助手共用 `Core/CLIUsage/`（有单元测试，
/// 两个模块之间仍不互相依赖）；这里只留 Codex 自己的部分：定价表、rollout 文件的解析、设置键与提醒的发送。
/// 费用为按公开定价的**估算**，UI 处处标「估算」；很多 Codex 用户走 ChatGPT 订阅（无按量计费），
/// 故费用为次要信息、token 数为主（报表按 token 数排序）。
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

/// Codex 的定价表（每百万 token 美元单价，估算常量，来源日期 2026-07，随时可能变）。
/// OpenAI 口径：input 已含缓存读（cached input 是 input 里打折的那部分），没有「缓存写」。
enum CodexPricingTable: CLIUsagePricingTable {
    static let inputIncludesCacheRead = true

    /// 按 model id 关键字匹配定价；未知返回 nil（共用层记 0 费用并标 unpriced）。
    static func pricing(for modelID: String) -> ModelPricing? {
        let id = modelID.lowercased()
        // gpt-5 覆盖 gpt-5-codex（默认 Codex 模型族）。
        if id.contains("gpt-5") {
            return rates(inputPerM: 1.25, cachedInputPerM: 0.125, outputPerM: 10)
        }
        if id.contains("o4-mini") || id.contains("o3-mini") {
            return rates(inputPerM: 1.1, cachedInputPerM: 0.275, outputPerM: 4.4)
        }
        if id.contains("o3") {
            return rates(inputPerM: 2, cachedInputPerM: 0.5, outputPerM: 8)
        }
        if id.contains("gpt-4.1") {
            return rates(inputPerM: 2, cachedInputPerM: 0.5, outputPerM: 8)
        }
        if id.contains("codex-mini") {
            return rates(inputPerM: 1.5, cachedInputPerM: 0.375, outputPerM: 6)
        }
        return nil
    }

    /// Codex 的三项单价 → 共用结构：缓存输入 = 共用层的缓存读，缓存写恒为 0。
    private static func rates(inputPerM: Double, cachedInputPerM: Double, outputPerM: Double) -> ModelPricing {
        ModelPricing(inputPerM: inputPerM, outputPerM: outputPerM, cacheWritePerM: 0, cacheReadPerM: cachedInputPerM)
    }
}

// MARK: - 聚合模型（共用层套上 Codex 定价表；名字不变，UI 照旧引用）

/// 一组 token 与估算费用的累计。`totalTokens` = input + output（input 已含缓存输入）。
typealias CodexUsageTotals = CLIUsageTotals<CodexPricingTable>
/// 一个额度窗口（5h 或周）。`end == start + span`。
typealias CodexUsageWindow = CLIUsageWindow<CodexPricingTable>
/// 周窗口锚点配置。
typealias CodexWeeklyAnchor = CLIUsageWeeklyAnchor
/// 报表一行（按天 / 按项目 / 按模型通用）。
typealias CodexUsageBucket = CLIUsageBucket<CodexPricingTable>
/// 三维度报表。
typealias CodexUsageReport = CLIUsageReport<CodexPricingTable>

private typealias CodexUsageCalculator = CLIUsageCalculator<CodexPricingTable>

extension CLIUsageTotals where Table == CodexPricingTable {
    /// 缓存输入（Codex 的叫法）= 共用层的 `cacheRead`；`input` 已含这部分。
    var cachedInput: Int {
        get { cacheRead }
        set { cacheRead = newValue }
    }
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

// MARK: - 用量单例

/// 用量聚合：当前 5h 窗口、周窗口、今日累计、报表、调用统计。
@MainActor
final class CodexUsageStore: ObservableObject {
    static let shared = CodexUsageStore()

    /// nil = 无活跃 5h 窗口。
    @Published private(set) var fiveHourWindow: CodexUsageWindow?
    /// nil = 近 7 天无用量（滚动块口径）；固定锚点口径下近 180h 有过用量就有值（见 `weeklyWindow(from:anchor:)`）。
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

    /// 5h / 周窗口 80% 提醒的防重状态（防重复轰炸，两者独立）。仅主线程访问。
    private var budgetReminder = CLIUsageBudgetReminder()
    private var weeklyBudgetReminder = CLIUsageBudgetReminder()
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
            let window = CodexUsageCalculator.activeWindow(from: entries)
            let today = CodexUsageCalculator.todayTotals(from: entries)
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
        return CodexWeeklyAnchor(
            fixed: defaults.object(forKey: weeklyFixedKey) as? Bool ?? false,
            clampingWeekday: defaults.object(forKey: weeklyWeekdayKey) as? Int ?? 2,
            hour: defaults.object(forKey: weeklyHourKey) as? Int ?? 0
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

    /// Codex 没有「额度已恢复」提醒：窗口切换只清防重记录（共用层已清）。
    private func checkBudgetReminder(window: CodexUsageWindow?) {
        guard let window else { return }
        let budget = UserDefaults.standard.integer(forKey: Self.budgetKey)
        let outcome = budgetReminder.check(windowStart: window.start, totalTokens: window.totals.totalTokens, budget: budget)
        if let percent = outcome.reachedPercent, AIToolsNotifierSettings.budgetAlertEnabled {
            CodexNotify.shared.notifyBudget(percent: percent, weekly: false)
        }
    }

    private func checkWeeklyBudgetReminder(window: CodexUsageWindow?) {
        guard let window else { return }
        let budget = UserDefaults.standard.integer(forKey: Self.weeklyBudgetKey)
        let outcome = weeklyBudgetReminder.check(windowStart: window.start, totalTokens: window.totals.totalTokens, budget: budget)
        if let percent = outcome.reachedPercent, AIToolsNotifierSettings.budgetAlertEnabled {
            CodexNotify.shared.notifyBudget(percent: percent, weekly: true)
        }
    }
}

// MARK: - 后台解析（nonisolated static）

extension CodexUsageStore {

    /// 收集近 N 小时内 mtime 文件的用量条目，按 §2 口径处理每文件的增量 / 累计。
    nonisolated fileprivate static func collectEntries(sinceHoursAgo hours: Int) -> [CLIUsageEntry] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3_600)
        var entries: [CLIUsageEntry] = []

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
            autoreleasepool {  // 每个文件读完就放掉临时对象，峰值不随文件数累加（#93）
                guard let data = try? Data(contentsOf: url) else { return }
                entries.append(contentsOf: parseFile(data: data, fallbackDate: mtime))
            }
        }
        return entries
    }

    /// 解析单个 rollout 文件为用量条目序列（按 §2 口径）。
    nonisolated fileprivate static func parseFile(data: Data, fallbackDate: Date) -> [CLIUsageEntry] {
        // 会话级维度：cwd（项目）与最后可见 model。
        var cwd = ""
        var modelID = ""

        // 三条候选路径的事件集合，每条带 (timestamp, input, cachedInput, output)。
        struct Counts { let ts: Date; let input: Int; let cachedInput: Int; let output: Int }
        var lastEvents: [Counts] = []      // info.last_token_usage（增量）
        var totalEvents: [Counts] = []     // info.total_token_usage（累计）
        var topEvents: [Counts] = []       // payload 顶层计数（增量）

        for lineData in data.split(separator: 0x0A) {
            guard let object = CLIJSONL.parseObject(Data(lineData)) else { continue }

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
                                         input: CLIUsageEntry.tokenCount(last["input_tokens"]),
                                         cachedInput: CLIUsageEntry.tokenCount(last["cached_input_tokens"]),
                                         output: CLIUsageEntry.tokenCount(last["output_tokens"])))
            }
            if let total = info?["total_token_usage"] as? [String: Any] {
                totalEvents.append(Counts(ts: ts,
                                          input: CLIUsageEntry.tokenCount(total["input_tokens"]),
                                          cachedInput: CLIUsageEntry.tokenCount(total["cached_input_tokens"]),
                                          output: CLIUsageEntry.tokenCount(total["output_tokens"])))
            }
            // payload 顶层计数（仅当无 info 时才作为增量来源，避免与 info 双计）。
            if info == nil, let payload, payload["input_tokens"] != nil || payload["output_tokens"] != nil {
                topEvents.append(Counts(ts: ts,
                                        input: CLIUsageEntry.tokenCount(payload["input_tokens"]),
                                        cachedInput: CLIUsageEntry.tokenCount(payload["cached_input_tokens"]),
                                        output: CLIUsageEntry.tokenCount(payload["output_tokens"])))
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

        // 缓存输入记作共用层的缓存读（input 已含这部分）；Codex 没有缓存写。
        return chosen.map { c in
            CLIUsageEntry(timestamp: c.ts, modelID: modelID, projectPath: cwd,
                         input: c.input, output: c.output, cacheRead: c.cachedInput)
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
        return ts.flatMap { CLIJSONL.parseDate($0) } ?? fallback
    }

    // MARK: 窗口与报表（算法在共用层，这里只传 Codex 的口径）

    /// 周窗口。与 Claude 有一处原有差异，照旧保留：近 180h 一条用量都没有时，固定锚点口径也返回 nil
    /// （Claude 那边返回一个 0 用量、有起止的窗口）。
    nonisolated fileprivate static func weeklyWindow(from entries: [CLIUsageEntry], anchor: CodexWeeklyAnchor) -> CodexUsageWindow? {
        guard !entries.isEmpty else { return nil }
        return CodexUsageCalculator.weeklyWindow(from: entries, anchor: anchor)
    }

    /// 三维度报表：按项目 / 按模型两张表按 token 数从高到低排；取不到 cwd 的用量归到 "unknown" 项目。
    nonisolated fileprivate static func buildReport(from entries: [CLIUsageEntry]) -> CodexUsageReport {
        CodexUsageCalculator.buildReport(
            from: entries,
            order: .byTokens,
            locale: L10n.locale,
            projectBucket: { path in
                path.isEmpty
                    ? (id: "unknown", label: "unknown")
                    : (id: path, label: CodexSessionIndex.projectName(fromPath: path))
            }
        )
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
            autoreleasepool {  // 每个文件读完就放掉临时对象，峰值不随文件数累加（#93）
                guard let data = try? Data(contentsOf: url) else { return }

                for lineData in data.split(separator: 0x0A) {
                    guard let object = CLIJSONL.parseObject(Data(lineData)) else { continue }
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
}
