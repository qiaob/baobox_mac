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
    /// 输入像一个文件名（`add-approval-hook.py`，`LauncherFileNameQuery`）：名字完全等于它（不分大小写）的固定排在最前（PR 11）。
    var pinnedName: String? = nil

    static func nameContains(_ words: [String], pinnedName: String? = nil) -> LauncherFileSearchRequest {
        LauncherFileSearchRequest(kind: .nameContains(words), pinnedName: pinnedName)
    }

    static func exactName(_ name: String, pathSuffix: String) -> LauncherFileSearchRequest {
        LauncherFileSearchRequest(kind: .exactName(name, pathSuffix: pathSuffix))
    }
}

/// 文件搜索的后端：给一个请求，异步交回原始命中（不过滤、不排序），可以取消。
/// 实现有 Spotlight（`Providers/SpotlightFileSearch.swift`）、内存里的表（`LauncherMemoryFileSearch`：自己扫的目录、
/// 各模块已知的文件、剪贴板里的路径），快速入口用的是把它们并起来的 `LauncherMergedFileSearch`（PR 11，§6.4）。
/// 过滤和排序（`LauncherFileFilter`）、引擎、界面不管后面是哪一个。
protocol LauncherFileSearching: AnyObject, Sendable {
    /// 开始搜。`completion` 在任意线程回调：单个来源回调一次；合并器每有一个来源回来就交一次「到目前为止的全部」，
    /// 最后一次 `isComplete == true`。被 `cancel()` 或下一次 `search` 顶掉的不再回调。同一时刻只跑一个。
    func search(_ request: LauncherFileSearchRequest, completion: @escaping @Sendable (LauncherFileSearchBatch) -> Void)
    /// 停掉还没回来的那次。
    func cancel()
    /// 来源的表换了：同一次查询只把内存里的来源再查一遍（合并器，PR 11 复查后加）；单个来源不用管（默认什么都不做）。
    func requeryImmediateSources()
}

extension LauncherFileSearching {
    func requeryImmediateSources() {}
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
    /// 这是最后一批（合并器：所有来源都回来了）。单个来源总是 true。
    var isComplete = true
    /// 合并器：已经回来的各来源各自的统计（日志分开记）。单个来源为空。
    var sources: [LauncherFileSourceReport] = []
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
    /// 从哪几个来源来的（合并器打上；同一个文件几个来源都有时是它们的并集）。
    var origins: LauncherFileOrigins = []
    /// 来源给的一句说明（已知文件：「Claude Code · 项目名」），显示在副标题里；没有为 nil。
    var note: String? = nil

    init(path: String, isDirectory: Bool = false, lastUsed: Date? = nil, modified: Date? = nil,
         origins: LauncherFileOrigins = [], note: String? = nil) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.lastUsed = lastUsed
        self.modified = modified
        self.origins = origins
        self.note = note
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
    /// 固定排在最前：带 `/` 的片段的确切命中，或输入像文件名时名字完全等于它的（PR 11）。
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
    /// - 查询词像一个文件名（`add-approval-hook.py`，PR 11）：名字完全等于它的固定排在最前（`pinnedName`）；
    ///   这样的词至少有 3 个字符（`a.b`），不带前缀的长度门槛自然满足。
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
        let pinnedName = LauncherFileNameQuery.fileName(in: text)
        if query.sourceID == nil, pinnedName == nil, weightedLength(text) < unscopedMinimumLength { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.isEmpty ? nil : .nameContains(words, pinnedName: pinnedName)
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
    /// 只来自自己扫的目录（来源 B）的文件的限额组（PR 11）：没打前缀时最多 2 行（`unscopedScannedOnlyLimit`），
    /// 同一档里排在来自 Spotlight、已知文件、剪贴板路径的文件后面。固定行和 `f ` 前缀下不受限。
    static let scannedOnlyGroup = "files.scannedOnly"
    static let unscopedScannedOnlyLimit = 2

    /// 这条命中的限额组：只来自自己扫的目录的是 `scannedOnlyGroup`；同时还来自别的来源的不算。
    static func limitGroup(for origins: LauncherFileOrigins) -> String? {
        origins == .scanned ? scannedOnlyGroup : nil
    }
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

    /// 一条命中要不要去掉（PR 11 审后定）：来自已知文件（Claude Code 写过的）或剪贴板路径（用户复制过路径的）的，
    /// 是用户或他的会话明确碰过的文件，不看目录规则（隐藏目录、`~/Library`、`node_modules`、`build`……：
    /// `~/.claude/settings.json`、`.github/workflows/x.yml` 照出），只去掉 `.app` 本身（App 来源有）；
    /// 同一个文件 Spotlight / 自己扫的目录也有时按这个算。只来自 Spotlight、自己扫的目录的照旧 `isExcluded(path:home:)`。
    static func isExcluded(_ hit: LauncherFileHit, home: String) -> Bool {
        if !hit.origins.isDisjoint(with: .touched) { return hit.name.lowercased().hasSuffix(".app") }
        return isExcluded(path: hit.path, home: home)
    }

    /// 原始命中 → 给界面的结果：去掉噪音（`isExcluded(_:home:)`）→ 片段只留路径以整个片段结尾的 → 同名的只留最新的 3 份 →
    /// 按匹配的档排（高的在前），同档新的在前（最近使用 / 最近修改），再按路径 → 最多 `limit` 条。文件夹和文件同等对待。
    /// 固定的行（片段的确切命中、输入像文件名时名字完全等于它的，PR 11）排在最前，最多 3 行，次序见 `pinnedOrder`。
    static func process(_ hits: [LauncherFileHit], request: LauncherFileSearchRequest, home: String,
                        limit: Int = maxResults) -> [LauncherFileResult] {
        var results: [LauncherFileResult] = []
        var pinned: [LauncherFileResult] = []
        switch request.kind {
        case .nameContains(let words):
            let queries = words.map { LauncherMatchQuery(folded($0)) }
            let whole = words.count > 1 ? LauncherMatchQuery(folded(words.joined(separator: " "))) : nil
            for hit in hits where !isExcluded(hit, home: home) {
                if let name = request.pinnedName, hit.name.caseInsensitiveCompare(name) == .orderedSame {
                    pinned.append(LauncherFileResult(hit: hit, tierScore: LauncherMatch.exactScore, pinned: true))
                    continue
                }
                results.append(LauncherFileResult(hit: hit, tierScore: tierScore(name: hit.name, queries: queries, whole: whole),
                                                  pinned: false))
            }
        case .exactName(let name, let pathSuffix):
            let suffix = "/" + pathSuffix.lowercased()
            for hit in hits where hit.name.caseInsensitiveCompare(name) == .orderedSame
                && hit.path.lowercased().hasSuffix(suffix) && !isExcluded(hit, home: home) {
                pinned.append(LauncherFileResult(hit: hit, tierScore: LauncherMatch.exactScore, pinned: true))
            }
        }
        pinned = Array(pinned.sorted(by: pinnedOrder).prefix(maxCopiesPerName))
        results = keepingNewestCopies(results)
        results.sort { a, b in
            if a.tierScore != b.tierScore { return a.tierScore > b.tierScore }
            if a.hit.recency != b.hit.recency { return a.hit.recency > b.hit.recency }
            return a.hit.path < b.hit.path
        }
        return Array((pinned + results).prefix(max(0, limit)))
    }

    /// 同名的几份里哪一档在前（PR 11 独立验证后定，三档）：
    /// 0 = 用户碰过的（已知文件 C、剪贴板路径 D）—— 他此刻更可能要的那一个；
    /// 1 = 其余不是只来自扫的目录的（Spotlight，项目里真正的文件）；
    /// 2 = 只来自扫的目录的（Claude Code 临时目录里各会话的副本、中间产物）。
    /// 所以只有扫的目录里才有的文件（用户最初那个例子）照样排第一，而项目里有同名文件时项目里的在前。
    static func copyTier(_ origins: LauncherFileOrigins) -> Int {
        if !origins.isDisjoint(with: .preferred) { return 0 }
        return origins == .scanned ? 2 : 1
    }

    /// 固定行的次序：按 `copyTier` 的三档，档内新的在前（最近使用 / 最近修改），再按路径。
    static func pinnedOrder(_ a: LauncherFileResult, _ b: LauncherFileResult) -> Bool {
        let aTier = copyTier(a.hit.origins)
        let bTier = copyTier(b.hit.origins)
        if aTier != bTier { return aTier < bTier }
        if a.hit.recency != b.hit.recency { return a.hit.recency > b.hit.recency }
        return a.hit.path < b.hit.path
    }

    /// 同名（不分大小写）的只留 `maxCopiesPerName` 份：一百多个 worktree 里同一个文件不会刷满一屏。
    /// 挑哪几份（PR 11 独立验证后定）：先按 `copyTier` 的三档（碰过的 → Spotlight 等 → 只来自扫的目录的），档内新的在前 ——
    /// 不然扫的目录里 3 份更新的副本会把 Spotlight 的副本全挤掉。带不带前缀都这样。
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
            return Array(copies.sorted(by: pinnedOrder).prefix(maxCopiesPerName))
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

    /// Spotlight 交回的路径是数据卷上的写法（`/System/Volumes/Data/Users/me/…`，2026-11-24 实测），
    /// 换回大家熟悉的 `/Users/me/…`：否则 `~/Library` 过滤不掉、主目录缩写不成 `~`。只换主目录下的（搜的就是主目录）。
    static func canonicalPath(_ path: String, home: String) -> String {
        let dataVolume = "/System/Volumes/Data"
        let home = LauncherPathDisplay.trimmingTrailingSlashes(home)
        guard path.hasPrefix(dataVolume + home + "/") || path == dataVolume + home else { return path }
        return String(path.dropFirst(dataVolume.count))
    }

    /// 去掉声调、全角转半角（「résumé」「ＡＢＣ」和 resume、ABC 打一样的分）；大小写由打分自己处理。
    static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
