import Foundation

// 快速入口的查询（docs/launcher/TECH_DESIGN.md §5）：呼出时把各来源的条目装进来，之后每次输入变化：
// `LauncherQuery.parse` 拆前缀 → 计算结果、文本识别（没打前缀时，固定在最前）→ `LauncherRanking.rank` 排序 → 换成面板的行。
// 同步、只读内存，打字路径上不建搜索键、不碰磁盘。
// 输入是路径时（§6.5）只出路径的行：要读磁盘，由控制器在后台查、查完交回来（`setPathResult`）；
// 还没回来时，还在同一处打字就先显示上一个路径的行（否则显示「正在查找」），免得每打一个字列表收起又长出来。
// 文件（§6.4）同样由控制器在后台搜、搜完交回来（`setFileResult`）：交回的行和内存里的候选一起排序
// （没打前缀时最多 5 行，权重最低，排在 App、命令之后），带 `/` 的片段的确切命中固定在最前；
// 新的还没回来时，上一次的结果里名字仍包含现在每个词的先顶着。
// 建议（§5.4，没打前缀、输入不是路径时）：对应建议（打开网址、写邮件、颜色、字数）插在计算结果之后、识别结果之前，
// 兜底建议（文字动作、上网搜、搜文件）接在最后 —— 输入不为空时列表里总有事可做，「没有结果」只在连兜底建议都没有时出现。

/// 行左边的图标。
enum LauncherRowIcon: Equatable {
    /// 文件的图标（App 用真实图标），值是路径。
    case file(String)
    /// SF Symbol（命令用所属工具的图标）。
    case symbol(String)
    /// 这个颜色的色块（颜色值的建议行，§5.4）。
    case swatch(LauncherColor)
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
    /// 标题后面的灰色小字（文件、文件夹行：所在目录）；nil = 没有。
    var subtitle: String? = nil
    var style: LauncherRowStyle = .standard
}

/// 一个来源交给引擎的条目：排序用的纯值 + 显示的行 + ⏎ 做什么。
struct LauncherItem {
    let candidate: LauncherCandidate
    let row: LauncherRow
    let run: @MainActor () -> Void
    /// ⌘⏎ 做什么（文件、路径行：在访达里显示）；nil = 同 ⏎。
    var alternate: (@MainActor () -> Void)? = nil
    /// Tab 把输入框换成它（路径行：完整路径，文件夹末尾带 `/`）；nil = Tab 不做事。
    var completion: String? = nil
    /// 执行时记不记使用记录（路径行不记）。
    var recordsUsage = true
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
    /// 输入是这个路径、它的结果还没查过或过期了：控制器在后台查（`LauncherPathProvider`），查完 `setPathResult`。
    var pendingPath: LauncherPathInput? = nil
    /// 这次输入要搜的文件；不搜为 nil（控制器停掉还没回来的那次）。
    var fileRequest: LauncherFileSearchRequest? = nil
    /// 要搜的文件结果还没搜过或过期了：控制器去搜（`LauncherFileProvider`），搜完 `setFileResult`。
    var pendingFiles: LauncherFileSearchRequest? = nil

    /// 有后台结果还没回来（显示的是上一次的行；一行都没有时面板显示「正在查找」）。
    var isPending: Bool { pendingPath != nil || pendingFiles != nil }
}

@MainActor
final class LauncherEngine {
    /// 输入为空时最多显示几行「最常用的」。
    static let emptyQueryLimit = 8
    /// 没打前缀时这些来源最多出几行：剪贴板几千条，不限的话一个常见词就把 App 和命令挤下去（`c ` 前缀下不限）。
    /// 文件同理：没打前缀时最多 5 行（`f ` 前缀下最多 `LauncherFileFilter.maxResults` 行）。
    static let unscopedSourceLimits = ["clipboard": 5, LauncherFileProvider.sourceID: 5]

    private var allCandidates: [LauncherCandidate] = []
    private var candidatesBySource: [String: [LauncherCandidate]] = [:]
    private var itemsByKey: [String: LauncherItem] = [:]
    private var prefixBySource: [String: String] = [:]
    /// 这次输入的计算结果、识别结果，按行 id。每次查询换一批。
    private var instantsByKey: [String: LauncherInstant] = [:]
    /// 计算结果的语言（界面语言），呼出时取一次。
    private var calcLocale = Locale(identifier: "en")
    /// 各模块声明的文字动作（§5.4）：呼出时装进来，只作为「对当前输入的建议」出现。
    var textActions: [LauncherCatalogCommand] = []
    /// 这次输入的建议行（动作类），按行 id。每次查询换一批。
    private var suggestionsByKey: [String: LauncherSuggestion] = [:]
    /// 主目录：认路径时展开 `~`。
    private let home: String
    /// 最近一次查好的路径和它的行（输入变成别的路径后，新的回来之前先显示它）。
    private var pathResult: (input: LauncherPathInput, items: [LauncherItem])?
    /// 最近一次搜好的文件：片段的确切命中（固定在最前）和交给排序的。
    private var fileResult: (request: LauncherFileSearchRequest, pinned: [LauncherItem], ranked: [LauncherItem])?
    /// 这次显示的后台来的行（路径、文件），按行 id：执行、Tab 补全时按 id 找回来。
    private var asyncItemsByKey: [String: LauncherItem] = [:]

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

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
        pathResult = nil
        fileResult = nil
        asyncItemsByKey = [:]
        textActions = []
        suggestionsByKey = [:]
    }

    func item(forKey key: String) -> LauncherItem? {
        itemsByKey[key] ?? asyncItemsByKey[key]
    }

    /// 后台查好了一个路径的行（`LauncherPathProvider`）。输入还是这个路径时，下一次 `search` 就用它们。
    func setPathResult(_ items: [LauncherItem], for input: LauncherPathInput) {
        pathResult = (input, items)
    }

    /// 后台搜好了文件（`LauncherFileProvider`）。输入要搜的还是这个时，下一次 `search` 就用它们。
    func setFileResult(pinned: [LauncherItem], ranked: [LauncherItem], for request: LauncherFileSearchRequest) {
        fileResult = (request, pinned, ranked)
    }

    /// 计算结果、识别结果的行（不是这类行为 nil）。
    func instant(forKey key: String) -> LauncherInstant? {
        instantsByKey[key]
    }

    /// 建议行里的动作行（打开网址、写邮件、兜底建议；不是这类行为 nil）。
    func suggestion(forKey key: String) -> LauncherSuggestion? {
        suggestionsByKey[key]
    }

    /// 查一次。输入是路径时只出路径的行。否则：没打前缀时先放计算结果、对应建议、识别结果（固定在最前），再放片段的确切命中；
    /// 查询词为空时只给用过的（使用分 > 0）最多 8 行；否则按排序取前 50 行（没打前缀时剪贴板、文件各最多 5 行）；
    /// 最后接兜底建议（§5.4）。
    func search(_ input: String, records: LauncherUsageRecords, now: Date) -> LauncherSearchOutcome {
        let start = DispatchTime.now().uptimeNanoseconds
        let query = LauncherQuery.parse(input, prefixBySource: prefixBySource)

        // 输入是路径：只出路径的行，不混 App、命令、剪贴板（剪贴板里恰好有这段路径文字的条目只会是噪音）。
        if query.isUnscoped, let path = LauncherPathInput.parse(query.text, home: home) {
            instantsByKey = [:]
            suggestionsByKey = [:]
            fileResult = nil
            // 还在同一处打字时先顶着上一次的行；换到别处的路径就先空着（显示「正在查找」）。
            let items = pathResult.map { $0.input == path || path.continues($0.input) ? $0.items : [] } ?? []
            asyncItemsByKey = Dictionary(items.map { ($0.row.id, $0) }, uniquingKeysWith: { first, _ in first })
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            return LauncherSearchOutcome(queryText: query.text, rows: items.map(\.row), candidateCount: items.count,
                                         duration: duration, pendingPath: pathResult?.input == path ? nil : path)
        }
        pathResult = nil
        asyncItemsByKey = [:]

        var instants: [LauncherInstant] = []
        if LauncherInstantPolicy.runsCalculator(query),
           let calculation = LauncherCalculatorProvider.instant(for: query.text, now: now, locale: calcLocale) {
            instants.append(calculation)
        }
        let calculationCount = instants.count
        if LauncherInstantPolicy.runsTextRecognition(query, hasCalculation: !instants.isEmpty) {
            instants.append(contentsOf: LauncherTextFormatProvider.instants(for: query.text))
        }
        // 建议（§5.4）：对应建议排在计算结果之后、识别结果之前，兜底建议排在最后。
        let suggestions = LauncherSuggestionProvider.suggestions(
            for: query, textActions: textActions, hasCalculation: calculationCount > 0,
            hasRecognition: instants.count > calculationCount, records: records, now: now)
        instantsByKey = Dictionary((instants + suggestions.instants).map { ($0.row.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        suggestionsByKey = Dictionary(suggestions.actions.map { ($0.row.id, $0) }, uniquingKeysWith: { first, _ in first })

        let fileRequest = LauncherFilePolicy.request(for: query, hasCalculation: instants.first?.row.id == LauncherCalculatorProvider.rowID)
        let files = currentFiles(for: fileRequest)
        asyncItemsByKey = Dictionary((files.pinned + files.ranked).map { ($0.row.id, $0) },
                                     uniquingKeysWith: { first, _ in first })

        var pool: [LauncherCandidate]
        if let sourceIDs = query.sourceIDs {
            pool = sourceIDs.flatMap { candidatesBySource[$0] ?? [] }
        } else {
            pool = allCandidates
        }
        if query.sourceIDs?.contains(LauncherFileProvider.sourceID) ?? true {
            pool += files.ranked.map(\.candidate)
        }
        let ranked: [LauncherRankedItem]
        if query.text.isEmpty {
            ranked = LauncherRanking.rank(pool, query: "", records: records, now: now, limit: Self.emptyQueryLimit)
                .items.filter { $0.usageScore > 0 }
        } else {
            ranked = LauncherRanking.rank(pool, query: query.text, records: records, now: now,
                                          sourceLimits: query.isUnscoped ? Self.unscopedSourceLimits : [:]).items
        }
        var rows: [LauncherRow] = instants.prefix(calculationCount).map(\.row)
        rows += suggestions.leadingRows
        rows += instants.dropFirst(calculationCount).map(\.row)
        rows += files.pinned.map(\.row)
        rows += ranked.compactMap { item(forKey: $0.key)?.row }
        rows += suggestions.trailing.map(\.row)
        let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return LauncherSearchOutcome(queryText: query.text, rows: rows, candidateCount: pool.count, duration: duration,
                                     fileRequest: fileRequest, pendingFiles: files.isFresh ? nil : fileRequest)
    }

    /// 这次输入能用的文件行：搜好的正是这个请求 → 用它；还没回来 → 上一次「名字包含」的结果里仍匹配的先顶着
    /// （片段的确切命中不顶）；不搜文件 → 没有，并放掉上一次的。
    private func currentFiles(for request: LauncherFileSearchRequest?)
        -> (pinned: [LauncherItem], ranked: [LauncherItem], isFresh: Bool) {
        guard let request else {
            fileResult = nil
            return ([], [], true)
        }
        guard let fileResult else { return ([], [], false) }
        if fileResult.request == request { return (fileResult.pinned, fileResult.ranked, true) }
        let stale = fileResult.ranked.filter { LauncherFileFilter.stillMatches(name: $0.row.title, request: request) }
        return ([], stale, false)
    }
}
