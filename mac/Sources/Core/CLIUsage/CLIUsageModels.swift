import Foundation

/// AI 编程助手用量统计的共用层 —— 数据模型（Claude Code 助手与 Codex 助手共用）。
/// 统计的是这两个命令行工具自己的会话日志；Baobox 自己调云端模型的次数是另一回事，在 `Core/AI/AIUsageMeter.swift`。
///
/// **纯 Foundation**：不引用 `L()`、App / 模块类型、UserDefaults，单元测试（BaoboxTests）直接编这个目录。
/// 两边真正不同的东西都留在各自模块里：会话文件怎么解析成 `CLIUsageEntry`、定价表（实现
/// `CLIUsagePricingTable`）、设置键与提醒文案。算法见 `CLIUsageCalculator.swift`。

// MARK: - 定价

/// 每百万 token 的美元单价。
struct ModelPricing: Equatable, Sendable {
    let inputPerM: Double
    let outputPerM: Double
    let cacheWritePerM: Double
    let cacheReadPerM: Double

    static let zero = ModelPricing(inputPerM: 0, outputPerM: 0, cacheWritePerM: 0, cacheReadPerM: 0)

    /// 一条用量的估算费用（美元）。
    ///
    /// 两种口径的加法顺序分别照搬两边原来的实现：浮点加法不满足结合律，换个顺序末位就可能不同。
    /// - `inputIncludesCacheRead == false`（Claude）：输入 + 输出 + 缓存写 + 缓存读，各按各的价。
    /// - `inputIncludesCacheRead == true`（Codex）：input 已含缓存读，先从 input 扣掉缓存读（扣到 0 为止）
    ///   再按输入价算，缓存读按折扣价算；缓存写放最后（Codex 没有缓存写，恒为 0，加 0 不改变结果）。
    func cost(of entry: CLIUsageEntry, inputIncludesCacheRead: Bool) -> Double {
        if inputIncludesCacheRead {
            let billableInput = max(0, entry.input - entry.cacheRead)
            return Double(billableInput) / 1_000_000 * inputPerM
                + Double(entry.cacheRead) / 1_000_000 * cacheReadPerM
                + Double(entry.output) / 1_000_000 * outputPerM
                + Double(entry.cacheWrite) / 1_000_000 * cacheWritePerM
        }
        return Double(entry.input) / 1_000_000 * inputPerM
            + Double(entry.output) / 1_000_000 * outputPerM
            + Double(entry.cacheWrite) / 1_000_000 * cacheWritePerM
            + Double(entry.cacheRead) / 1_000_000 * cacheReadPerM
    }
}

/// 一个工具的定价表 + token 记账口径。实现留在各自模块（定价表跟着模块走），以泛型参数传进共用层。
protocol CLIUsagePricingTable {
    /// `input` 是否已经包含缓存读的那部分。
    /// - false（Claude / Anthropic 口径）：input、缓存写、缓存读各自单列；token 总数四项相加。
    /// - true（Codex / OpenAI 口径）：input 已含缓存读，计费时扣掉；token 总数不再重复加缓存读。
    static var inputIncludesCacheRead: Bool { get }

    /// 按 model id 查单价；nil = 不认识的模型（费用记 0，并标 unpriced）。
    static func pricing(for modelID: String) -> ModelPricing?
}

// MARK: - 用量条目

/// 参与聚合的一条用量（Claude：一条去重后的 assistant 消息；Codex：一个 token_count 增量）。
/// `input` 的含义随定价表口径而定，见 `CLIUsagePricingTable.inputIncludesCacheRead`。
struct CLIUsageEntry: Equatable, Sendable {
    let timestamp: Date
    let modelID: String
    let projectPath: String
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int

    init(timestamp: Date, modelID: String, projectPath: String,
         input: Int, output: Int, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.timestamp = timestamp
        self.modelID = modelID
        self.projectPath = projectPath
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    /// 一条记录 token 数的上限：真实值远到不了（一次请求不会有一万亿 token），只用来挡住损坏的日志 ——
    /// 超出 Int 范围的小数转 Int、或几个 Int.max 累加，都会直接崩溃。
    static let maxTokenCount = 1_000_000_000_000

    /// 容错取 token 数（JSON 里可能是 Int / Double / NSNumber / 字符串），取不到记 0；
    /// 结果限制在 0...`maxTokenCount`（负数记 0，过大的记上限）。
    static func tokenCount(_ value: Any?) -> Int {
        let raw: Int
        if let i = value as? Int {
            raw = i
        } else if let d = value as? Double {
            if d.isNaN {
                raw = 0
            } else {
                raw = Int(exactly: d.rounded(.towardZero)) ?? (d > 0 ? maxTokenCount : 0)
            }
        } else if let n = value as? NSNumber {
            raw = n.intValue
        } else if let s = value as? String, let i = Int(s) {
            raw = i
        } else {
            raw = 0
        }
        return min(max(raw, 0), maxTokenCount)
    }
}

// MARK: - 聚合模型

/// 一组 token 与估算费用的累计。
struct CLIUsageTotals<Table: CLIUsagePricingTable>: Equatable, Sendable {
    var input: Int = 0
    var output: Int = 0
    var cacheWrite: Int = 0
    var cacheRead: Int = 0
    var costUSD: Double = 0
    /// 命中过未知模型（费用可能偏低）。
    var unpriced: Bool = false

    static var zero: CLIUsageTotals { CLIUsageTotals() }

    /// 计费口径下的 token 总数（额度窗口预算比对、Codex 报表排序用）。
    /// Claude：四项相加；Codex：input 已含缓存读，不再加缓存读（= input + output）。
    var totalTokens: Int {
        Table.inputIncludesCacheRead
            ? input + output + cacheWrite
            : input + output + cacheWrite + cacheRead
    }

    /// 累加一条用量，并按其模型算增量费用。
    mutating func add(_ entry: CLIUsageEntry) {
        input += entry.input
        output += entry.output
        cacheWrite += entry.cacheWrite
        cacheRead += entry.cacheRead
        let pricing = Table.pricing(for: entry.modelID)
        costUSD += (pricing ?? .zero).cost(of: entry, inputIncludesCacheRead: Table.inputIncludesCacheRead)
        if pricing == nil { unpriced = true }
    }
}

/// 一个额度窗口（5h 或周）。`end == start + 跨度`。
struct CLIUsageWindow<Table: CLIUsagePricingTable>: Equatable, Sendable {
    let start: Date
    let end: Date
    var totals: CLIUsageTotals<Table>

    /// 距重置剩余秒数（相对现在，最少 0）。
    var secondsUntilReset: TimeInterval { max(0, end.timeIntervalSinceNow) }
}

/// 周窗口锚点配置（主线程读 UserDefaults 构造，值类型跨线程安全传入后台计算）。
struct CLIUsageWeeklyAnchor: Equatable, Sendable {
    /// false = 近 7 天滚动 168h 块；true = 固定锚点（星期 + 小时）。
    let fixed: Bool
    /// 1...7（Calendar 口径，1=周日）。
    let weekday: Int
    /// 0...23。
    let hour: Int
}

extension CLIUsageWeeklyAnchor {
    /// 由设置里读到的原始值构造：星期夹到 1...7，小时夹到 0...23。
    init(fixed: Bool, clampingWeekday weekday: Int, hour: Int) {
        self.init(fixed: fixed, weekday: min(7, max(1, weekday)), hour: min(23, max(0, hour)))
    }
}

/// 报表一行（按天 / 按项目 / 按模型通用）。
struct CLIUsageBucket<Table: CLIUsagePricingTable>: Identifiable, Sendable {
    let id: String
    let label: String
    var totals: CLIUsageTotals<Table>
    /// 「按天」维度携带日期用于排序；其余为 nil。
    var date: Date?
}

/// 三维度报表。
struct CLIUsageReport<Table: CLIUsagePricingTable>: Sendable {
    var byDay: [CLIUsageBucket<Table>] = []
    var byProject: [CLIUsageBucket<Table>] = []
    var byModel: [CLIUsageBucket<Table>] = []
}

/// 「按项目」「按模型」两张表的排序（都是从大到小）。
enum CLIUsageReportOrder: Sendable {
    /// 按估算费用（Claude）。
    case byCost
    /// 按 token 总数（Codex：很多用户走 ChatGPT 订阅，费用是次要信息）。
    case byTokens
}
