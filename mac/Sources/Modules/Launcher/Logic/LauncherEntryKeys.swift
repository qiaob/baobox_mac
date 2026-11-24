import Foundation

// 快速入口里别的模块交来的条目（剪贴板历史、文本片段……）的搜索键（docs/launcher/TECH_DESIGN.md §3.2、§5.2）。
// 这类来源唯一的成本是建键（剪贴板几千条，不转拼音也要几十毫秒），所以按「条目键 + 文字」缓存，只给新出现或文字变了的补建；
// 呼出那一下缺得多时只同步建最新的一小批，其余交给后台。只依赖 Foundation，进 BaoboxTests。
// 建键本身（`makeKeys`）是纯函数、`LauncherSearchKey` 是 Sendable，可以在后台队列跑。

/// 一个条目要建哪些搜索键。
struct LauncherEntryKeySpec: Equatable, Sendable {
    /// 条目键 = 「来源 id/条目 id」（同 `LauncherCandidate.key`）。
    let key: String
    let title: String
    let searchText: String
    /// 标题转不转拼音。全文一律不转：长文本转拼音每个汉字 6–8 µs，剪贴板这类还全是噪音（§5.2 实测）。
    let pinyin: Bool
    /// 条目的时间：缺的键多时先建新的。不参与「文字变没变」的比较。
    let date: Date?

    /// 标题也不转拼音的来源：剪贴板（几千条、内容杂，转拼音每次要七八百毫秒，还会让 `jie` 这类查询多中一千条噪音，§5.2 实测；
    /// 中文内容直接打中文搜）。其余来源（片段）的标题转拼音。
    static let titlePinyinOffSourceIDs: Set<String> = ["clipboard"]

    init(sourceID: String, entryID: String, title: String, searchText: String, pinyin: Bool, date: Date?) {
        self.key = LauncherCandidate.key(sourceID: sourceID, entryID: entryID)
        self.title = title
        self.searchText = searchText
        self.pinyin = pinyin
        self.date = date
    }

    /// 同一个条目、文字和拼音设置都没变：缓存的键可以接着用。
    func hasSameText(as other: LauncherEntryKeySpec) -> Bool {
        key == other.key && title == other.title && searchText == other.searchText && pinyin == other.pinyin
    }

    /// 建搜索键。第一个是标题（排序同分时看它的长度）：
    /// - 标题转拼音时：标题（转拼音）+ 全文（不转）；全文为空或和标题相同时只有标题。
    /// - 标题不转拼音、且标题就是全文的开头（剪贴板：标题是第一行）时只建全文一个键 ——
    ///   标题能中的全文都能中，省一半的建键时间和内存。
    func makeKeys() -> [LauncherSearchKey] {
        let text = searchText
        if text.isEmpty || text == title {
            return [LauncherSearchKey(title, pinyin: pinyin)]
        }
        if !pinyin && text.hasPrefix(title) {
            return [LauncherSearchKey(text, pinyin: false)]
        }
        return [LauncherSearchKey(title, pinyin: pinyin), LauncherSearchKey(text, pinyin: false)]
    }
}

/// 条目搜索键的缓存：按条目键记「文字 → 搜索键」，文字没变就复用。面板呼出、预热时用，打字时不碰。
struct LauncherEntryKeyCache {
    private var entries: [String: (spec: LauncherEntryKeySpec, keys: [LauncherSearchKey])] = [:]

    init() {}

    /// 缓存了几个条目。
    var count: Int { entries.count }

    /// 这个条目的键（文字和缓存的一致时）；没有或文字变了为 nil。
    func keys(for spec: LauncherEntryKeySpec) -> [LauncherSearchKey]? {
        guard let cached = entries[spec.key], cached.spec.hasSameText(as: spec) else { return nil }
        return cached.keys
    }

    /// 缺键的条目（新出现的、文字变了的），顺序同传入的。
    func missing(_ specs: [LauncherEntryKeySpec]) -> [LauncherEntryKeySpec] {
        specs.filter { keys(for: $0) == nil }
    }

    /// 记下一个条目的键（后台建好的、刚同步建的）。同一个条目键旧的被换掉。
    mutating func insert(_ spec: LauncherEntryKeySpec, keys: [LauncherSearchKey]) {
        entries[spec.key] = (spec, keys)
    }

    /// 同步建这些条目的键并记下；返回建了几个。
    @discardableResult
    mutating func build(_ specs: [LauncherEntryKeySpec]) -> Int {
        for spec in specs {
            insert(spec, keys: spec.makeKeys())
        }
        return specs.count
    }

    /// 只留这些条目键：来源里已经没有的（删掉的、过期的）从缓存里去掉。
    mutating func retain(_ keys: Set<String>) {
        entries = entries.filter { keys.contains($0.key) }
    }

    /// 缺的键先建哪些：新的在前（没有时间的当作最新），取前 `budget` 个现在建，其余留给后台。
    /// 同一时间的保持传入的先后，结果是确定的。
    static func split(_ missing: [LauncherEntryKeySpec], budget: Int)
        -> (now: [LauncherEntryKeySpec], later: [LauncherEntryKeySpec]) {
        let budget = max(0, budget)
        guard missing.count > budget else { return (missing, []) }
        let ordered = missing.enumerated().sorted { lhs, rhs in
            let l = lhs.element.date ?? .distantFuture
            let r = rhs.element.date ?? .distantFuture
            if l != r { return l > r }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return (Array(ordered.prefix(budget)), Array(ordered.dropFirst(budget)))
    }

    /// 建一批键（后台队列上调）。
    static func makeKeys(_ specs: [LauncherEntryKeySpec]) -> [(spec: LauncherEntryKeySpec, keys: [LauncherSearchKey])] {
        specs.map { ($0, $0.makeKeys()) }
    }
}
