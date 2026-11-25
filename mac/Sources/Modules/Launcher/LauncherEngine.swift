import Foundation

// 快速入口的查询（docs/launcher/TECH_DESIGN.md §5）：呼出时把各来源的条目装进来，之后每次输入变化：
// `LauncherQuery.parse` 拆前缀 → 计算结果、文本识别（没打前缀时，固定在最前）→ `LauncherRanking.rank` 排序 → 换成面板的行。
// 同步、只读内存，打字路径上不建搜索键、不碰磁盘。

/// 行左边的图标。
enum LauncherRowIcon: Equatable {
    /// 文件的图标（App 用真实图标），值是路径。
    case file(String)
    /// SF Symbol（命令用所属工具的图标）。
    case symbol(String)
}

/// 行的样子。
enum LauncherRowStyle: Equatable {
    /// 普通的一行：图标 + 标题 + 右侧小字。
    case standard
    /// 计算结果：结果用大一号的字，下面一行小字是「理解成了什么」；`failed` = 出错（结果的位置是那句说明，⏎ 不做事）。
    case calculation(interpretation: String, failed: Bool)
}

/// 面板里的一行（只有显示用的值）。
struct LauncherRow: Identifiable, Equatable {
    /// 条目键 = 「来源 id/条目 id」；计算结果、文本识别的行是引擎给的固定 id。
    let id: String
    let title: String
    /// 右侧小字：「App」/ 所属工具名 /「剪贴板」/ 计算结果的种类 / 识别结果的「徽章 · 行标签」。
    let source: String
    let icon: LauncherRowIcon
    var style: LauncherRowStyle = .standard
}

/// 一个来源交给引擎的条目：排序用的纯值 + 显示的行 + ⏎ 做什么。
struct LauncherItem {
    let candidate: LauncherCandidate
    let row: LauncherRow
    let run: @MainActor () -> Void
}

/// 「输入即出」的一行（计算结果、文本识别）：固定排在最前，不进排序、不记使用；⏎ 复制，⌘⏎ 插入前台 App。
struct LauncherInstant {
    let row: LauncherRow
    /// 复制 / 插入的文字；nil = 出错的结果（除以零），⏎ 不做事。
    let copyText: String?
}

/// 一次查询的结果。
struct LauncherSearchOutcome {
    /// 拆掉前缀后的查询词（「这个输入选了谁」按它记）。
    let queryText: String
    let rows: [LauncherRow]
    /// 这次参与排序的候选数。
    let candidateCount: Int
    /// 查询耗时（秒）。
    let duration: TimeInterval
}

@MainActor
final class LauncherEngine {
    /// 输入为空时最多显示几行「最常用的」。
    static let emptyQueryLimit = 8
    /// 没打前缀时这些来源最多出几行：剪贴板几千条，不限的话一个常见词就把 App 和命令挤下去（`c ` 前缀下不限）。
    static let unscopedSourceLimits = ["clipboard": 5]

    private var allCandidates: [LauncherCandidate] = []
    private var candidatesBySource: [String: [LauncherCandidate]] = [:]
    private var itemsByKey: [String: LauncherItem] = [:]
    private var prefixBySource: [String: String] = [:]
    /// 这次输入的计算结果、识别结果，按行 id。每次查询换一批。
    private var instantsByKey: [String: LauncherInstant] = [:]
    /// 计算结果的语言（界面语言），呼出时取一次。
    private var calcLocale = Locale(identifier: "en")

    /// 装进这次呼出的全部条目。条目键重复的只留第一个。
    /// `sourceIDs`：这一期有的来源；只有它们的前缀生效（`f ` 这类以后才有的来源前缀不拆，整段当查询词）。
    func load(_ items: [LauncherItem], sourceIDs: Set<String>) {
        var all: [LauncherCandidate] = []
        var bySource: [String: [LauncherCandidate]] = [:]
        var byKey: [String: LauncherItem] = [:]
        all.reserveCapacity(items.count)
        byKey.reserveCapacity(items.count)
        for item in items where byKey[item.candidate.key] == nil {
            byKey[item.candidate.key] = item
            all.append(item.candidate)
            bySource[item.candidate.sourceID, default: []].append(item.candidate)
        }
        allCandidates = all
        candidatesBySource = bySource
        itemsByKey = byKey
        prefixBySource = LauncherQuery.defaultPrefixBySource.filter { sourceIDs.contains($0.key) }
        calcLocale = L10n.locale
    }

    /// 收起时调：放掉条目（和它们带的闭包）。
    func clear() {
        allCandidates = []
        candidatesBySource = [:]
        itemsByKey = [:]
        instantsByKey = [:]
    }

    func item(forKey key: String) -> LauncherItem? {
        itemsByKey[key]
    }

    /// 计算结果、识别结果的行（不是这类行为 nil）。
    func instant(forKey key: String) -> LauncherInstant? {
        instantsByKey[key]
    }

    /// 查一次。没打前缀时先放计算结果、识别结果（固定在最前）；查询词为空时只给用过的（使用分 > 0）最多 8 行；
    /// 否则按排序取前 50 行（没打前缀时剪贴板最多 5 行）。
    func search(_ input: String, records: LauncherUsageRecords, now: Date) -> LauncherSearchOutcome {
        let start = DispatchTime.now().uptimeNanoseconds
        let query = LauncherQuery.parse(input, prefixBySource: prefixBySource)

        var instants: [LauncherInstant] = []
        if LauncherInstantPolicy.runsCalculator(query),
           let calculation = LauncherCalculatorProvider.instant(for: query.text, now: now, locale: calcLocale) {
            instants.append(calculation)
        }
        if LauncherInstantPolicy.runsTextRecognition(query, hasCalculation: !instants.isEmpty) {
            instants.append(contentsOf: LauncherTextFormatProvider.instants(for: query.text))
        }
        instantsByKey = Dictionary(instants.map { ($0.row.id, $0) }, uniquingKeysWith: { first, _ in first })

        let pool: [LauncherCandidate]
        if let sourceIDs = query.sourceIDs {
            pool = sourceIDs.flatMap { candidatesBySource[$0] ?? [] }
        } else {
            pool = allCandidates
        }
        let ranked: [LauncherRankedItem]
        if query.text.isEmpty {
            ranked = LauncherRanking.rank(pool, query: "", records: records, now: now, limit: Self.emptyQueryLimit)
                .items.filter { $0.usageScore > 0 }
        } else {
            ranked = LauncherRanking.rank(pool, query: query.text, records: records, now: now,
                                          sourceLimits: query.isUnscoped ? Self.unscopedSourceLimits : [:]).items
        }
        let rows = instants.map(\.row) + ranked.compactMap { itemsByKey[$0.key]?.row }
        let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return LauncherSearchOutcome(queryText: query.text, rows: rows, candidateCount: pool.count, duration: duration)
    }
}
