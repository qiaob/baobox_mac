import Foundation

// 快速入口按名字搜文件（docs/launcher/TECH_DESIGN.md §6.4）：什么时候搜、搜什么，和拿回来以后怎么过滤、去副本、排序。
// 搜本身由一个可替换的后端做（`LauncherFileSearching`，这一版是 Spotlight），后端只交回原始命中；
// 这里的规则对任何后端都一样，以后换成自己的内存索引也照用。只依赖 Foundation，进 BaoboxTests。
//
// 实测（2026-11-24，用户的 Mac）：主目录下 Spotlight 索引 82.5 万条，`~/Library` 约 35.5 万、`~/cmb/worktrees`
// （一百多个 git worktree，同一份源码的副本）约 28.2 万、`node_modules` 约 6.2 万；查 `TECH_DESIGN.md` 命中 1086 条，
// 几乎全是副本。所以问题不在找不找得到，而在噪音和排序 —— 这就是下面这些规则。

/// 一次文件搜索要搜什么。
struct LauncherFileSearchRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// 名字包含每一个词（不分大小写和声调）。
        case nameContains([String])
        /// 带 `/` 的片段（`png-final/8-prefix-c-light.png`）：名字等于最后一段，路径以整个片段结尾。
        case exactName(String, pathSuffix: String)
    }

    let kind: Kind

    static func nameContains(_ words: [String]) -> LauncherFileSearchRequest {
        LauncherFileSearchRequest(kind: .nameContains(words))
    }

    static func exactName(_ name: String, pathSuffix: String) -> LauncherFileSearchRequest {
        LauncherFileSearchRequest(kind: .exactName(name, pathSuffix: pathSuffix))
    }
}

/// 文件搜索的后端：给一个请求，异步交回原始命中（不过滤、不排序），可以取消。
/// 这一版是 Spotlight（`Providers/SpotlightFileSearch.swift`）；以后换成自己的内存索引（让 Spotlight 当爬虫、
/// 启动后在后台把全部文件名读进内存，用自己的匹配引擎搜）只换这一层，过滤和排序（`LauncherFileFilter`）、引擎、界面都不动。
protocol LauncherFileSearching: AnyObject, Sendable {
    /// 开始搜。`completion` 在任意线程回调一次；被 `cancel()` 或下一次 `search` 顶掉的不回调。同一时刻只跑一个。
    func search(_ request: LauncherFileSearchRequest, completion: @escaping @Sendable (LauncherFileSearchBatch) -> Void)
    /// 停掉还没回来的那次。
    func cancel()
}

/// 后端一次交回的东西。
struct LauncherFileSearchBatch: Sendable {
    let hits: [LauncherFileHit]
    /// 后端一共找到多少条（可能比 `hits` 多：只读了前面一部分）。
    let totalCount: Int
    /// 从开始搜到结果收齐的时间（秒）。
    let elapsed: TimeInterval
    /// 超时了：交回的是到那时为止收到的。
    let timedOut: Bool
}

/// 后端交回的一条原始命中。
struct LauncherFileHit: Equatable, Sendable {
    let path: String
    /// 名字（路径的最后一段）。
    let name: String
    let isDirectory: Bool
    /// 最近使用（Spotlight 的 `kMDItemLastUsedDate`），没有为 nil。
    let lastUsed: Date?
    /// 最近修改（`kMDItemFSContentChangeDate`），没有为 nil。
    let modified: Date?

    init(path: String, isDirectory: Bool = false, lastUsed: Date? = nil, modified: Date? = nil) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.lastUsed = lastUsed
        self.modified = modified
    }

    /// 「最近」：最近使用和最近修改里新的那个；都没有时是很久以前。
    var recency: Date {
        max(lastUsed ?? .distantPast, modified ?? .distantPast)
    }
}

/// 过滤、排序后的一条。
struct LauncherFileResult: Equatable, Sendable {
    let hit: LauncherFileHit
    /// 匹配的档（1000 完全相等 / 800 开头 / 600 词首 / 400 包含），交给排序当匹配分：
    /// 同一档里不再按长度扣分，于是排序同分时看使用记录、再看谁新。
    let tierScore: Int
    /// 带 `/` 的片段的确切命中：固定排在最前。
    let pinned: Bool
}

enum LauncherFilePolicy {
    /// 没打前缀时查询词至少这么长才搜（汉字算两个：「发票」能搜，单个「发」不搜）。
    static let unscopedMinimumLength = 3
    /// 文件名最长 255 个字节；比这还长的输入不可能是名字。
    static let maxQueryLength = 255

    /// 这次输入要不要搜文件、搜什么：
    /// - `f ` 前缀：只搜文件，查询词不少于 1 个字符。
    /// - 没有前缀：查询词不少于 3 个字符（汉字算两个）；有计算结果时不搜。
    /// - 打了别的来源前缀、查询词有换行或太长时不搜。输入是路径的情况在引擎里先截走了（只出路径的行）。
    /// - 查询词里有 `/`：名字里不会有 `/`，只有像「目录/文件名」的片段才搜（按最后一段精确查名字），否则不搜。
    /// - 多个词用空格隔开时都要包含。
    static func request(for query: LauncherQuery, hasCalculation: Bool) -> LauncherFileSearchRequest? {
        let text = query.text
        guard !text.isEmpty, text.count <= maxQueryLength, !text.contains(where: \.isNewline) else { return nil }
        switch query.sourceID {
        case nil:
            if hasCalculation { return nil }
        case "files":
            break
        default:
            return nil
        }
        if text.contains("/") {
            return fragment(text).map { .exactName($0.name, pathSuffix: $0.suffix) }
        }
        if query.sourceID == nil, weightedLength(text) < unscopedMinimumLength { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.isEmpty ? nil : .nameContains(words)
    }

    /// 长度：汉字算两个（两个汉字的词和四五个字母的词差不多具体），其余一个字算一个。
    static func weightedLength(_ text: String) -> Int {
        text.reduce(0) { total, character in
            total + (character.unicodeScalars.first?.properties.isIdeographic == true ? 2 : 1)
        }
    }

    /// 像「目录/文件名」的片段：不以 `/`、`~` 开头（那是路径），不是网址，至少两段、没有空段和 `.` `..`，
    /// 最后一段像文件名（有扩展名）。返回最后一段和整个片段。
    static func fragment(_ text: String) -> (name: String, suffix: String)? {
        guard !text.hasPrefix("/"), !text.hasPrefix("~"), !text.contains("://") else { return nil }
        let segments = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 2,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let name = segments.last, looksLikeFileName(name)
        else { return nil }
        return (name, text)
    }

    /// 有扩展名的名字：点不在开头也不在末尾，扩展名 1–10 个字母数字、至少一个字母（`2.5` 不算）。
    static func looksLikeFileName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return (1...10).contains(ext.count)
            && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && ext.contains(where: \.isLetter)
    }
}

enum LauncherFileFilter {
    /// 交给界面的最多条数（没打前缀时排序再按来源上限截成 5 行）。
    static let maxResults = 30
    /// 同名的文件最多出几份（最新的几份）。
    static let maxCopiesPerName = 3

    /// 路径里任一段是这些（不分大小写）就不要：依赖、版本库、编译产物、废纸篓。
    static let excludedSegments: Set<String> = [
        "node_modules", ".git", "deriveddata", "build", "build.noindex", ".build", "pods", ".trash",
    ]
    /// 包的扩展名（小写）：包里面的文件不要。包本身照出（`.xcodeproj`、`.pages` 是文档），只有 `.app` 本身不出（App 来源已经有了）。
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "prefpane", "qlgenerator", "mdimporter",
        "saver", "photoslibrary", "musiclibrary", "tvlibrary", "xcarchive", "xcodeproj", "xcworkspace", "playground",
        "rtfd", "pages", "numbers", "key", "sparsebundle",
    ]

    /// 噪音：
    /// - `~/Library` 下的（缓存、App 的数据）；
    /// - 路径里任一段是 `node_modules`、`.git`、`DerivedData`、`build`、`build.noindex`、`.build`、`Pods`、`.Trash`；
    /// - 在隐藏文件夹（点开头）里、在任何以 `.noindex` 结尾的文件夹里、在包（`.app` 等）里面的；
    /// - `.app` 本身，以 `.noindex` 结尾的文件夹本身。
    static func isExcluded(path: String, home: String) -> Bool {
        let home = LauncherPathDisplay.trimmingTrailingSlashes(home)
        let library = home + "/Library"
        if path == library || path.hasPrefix(library + "/") { return true }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = segments.last else { return true }
        for (index, segment) in segments.enumerated() {
            let lower = segment.lowercased()
            if excludedSegments.contains(lower) || lower.hasSuffix(".noindex") { return true }
            guard index < segments.count - 1 else { break }
            if segment.hasPrefix(".") { return true }
            if let dot = lower.lastIndex(of: "."), packageExtensions.contains(String(lower[lower.index(after: dot)...])) {
                return true
            }
        }
        return last.lowercased().hasSuffix(".app")
    }

    /// 原始命中 → 给界面的结果：去掉噪音 → 片段只留路径以整个片段结尾的 → 同名的只留最新的 3 份 →
    /// 按匹配的档排（高的在前），同档新的在前（最近使用 / 最近修改），再按路径 → 最多 `limit` 条。文件夹和文件同等对待。
    static func process(_ hits: [LauncherFileHit], request: LauncherFileSearchRequest, home: String,
                        limit: Int = maxResults) -> [LauncherFileResult] {
        var results: [LauncherFileResult] = []
        switch request.kind {
        case .nameContains(let words):
            let queries = words.map { LauncherMatchQuery(folded($0)) }
            let whole = words.count > 1 ? LauncherMatchQuery(folded(words.joined(separator: " "))) : nil
            for hit in hits where !isExcluded(path: hit.path, home: home) {
                results.append(LauncherFileResult(hit: hit, tierScore: tierScore(name: hit.name, queries: queries, whole: whole),
                                                  pinned: false))
            }
        case .exactName(let name, let pathSuffix):
            let suffix = "/" + pathSuffix.lowercased()
            for hit in hits where hit.name.caseInsensitiveCompare(name) == .orderedSame
                && hit.path.lowercased().hasSuffix(suffix) && !isExcluded(path: hit.path, home: home) {
                results.append(LauncherFileResult(hit: hit, tierScore: LauncherMatch.exactScore, pinned: true))
            }
        }
        results = keepingNewestCopies(results)
        results.sort { a, b in
            if a.tierScore != b.tierScore { return a.tierScore > b.tierScore }
            if a.hit.recency != b.hit.recency { return a.hit.recency > b.hit.recency }
            return a.hit.path < b.hit.path
        }
        return Array(results.prefix(max(0, limit)))
    }

    /// 同名（不分大小写）的只留最新的 `maxCopiesPerName` 份：一百多个 worktree 里同一个文件不会刷满一屏。
    static func keepingNewestCopies(_ results: [LauncherFileResult]) -> [LauncherFileResult] {
        var groups: [String: [LauncherFileResult]] = [:]
        var order: [String] = []
        for result in results {
            let key = result.hit.name.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(result)
        }
        return order.flatMap { key -> [LauncherFileResult] in
            let copies = groups[key] ?? []
            guard copies.count > maxCopiesPerName else { return copies }
            return Array(copies.sorted { a, b in
                if a.hit.recency != b.hit.recency { return a.hit.recency > b.hit.recency }
                return a.hit.path < b.hit.path
            }.prefix(maxCopiesPerName))
        }
    }

    /// 名字匹配到哪一档。每个词各打一分（`LauncherMatch`）取最差的那个词；多个词连起来整体也匹配时取两者高的。
    /// 后端已经保证每个词都包含在名字里，打分认不出（比如全角半角写法不同）或只算得上跳字时按「包含」算。
    static func tierScore(name: String, queries: [LauncherMatchQuery], whole: LauncherMatchQuery? = nil) -> Int {
        let key = LauncherSearchKey(folded(name), pinyin: false)
        func tier(_ query: LauncherMatchQuery) -> Int {
            tierOf(LauncherMatch.score(query, in: key))
        }
        var best = queries.map(tier).min() ?? LauncherMatch.substringScore
        if let whole { best = max(best, tier(whole)) }
        return best
    }

    /// 匹配分 → 档：完全相等 1000、开头 800、词首 600、包含（以及打不出分的）400。
    static func tierOf(_ score: Int?) -> Int {
        guard let score else { return LauncherMatch.substringScore }
        if score >= LauncherMatch.exactScore { return LauncherMatch.exactScore }
        if score >= LauncherMatch.prefixScore - LauncherMatch.lengthPenaltyCap { return LauncherMatch.prefixScore }
        if score >= LauncherMatch.wordStartScore - LauncherMatch.lengthPenaltyCap { return LauncherMatch.wordStartScore }
        return LauncherMatch.substringScore
    }

    /// 上一次的结果还能不能先顶着用（新的还没回来时）：名字仍包含现在的每个词。只对「名字包含」这种搜索；片段的不留。
    static func stillMatches(name: String, request: LauncherFileSearchRequest) -> Bool {
        guard case .nameContains(let words) = request.kind else { return false }
        return words.allSatisfy { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
    }

    /// 去掉声调、全角转半角（「résumé」「ＡＢＣ」和 resume、ABC 打一样的分）；大小写由打分自己处理。
    static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
