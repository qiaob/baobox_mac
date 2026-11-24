import Foundation

// 快速入口内存里的文件表（docs/launcher/TECH_DESIGN.md §6.4，PR 11）：自己扫的目录、各模块已知的文件、剪贴板里出现过的路径
// 各是一张这样的表，查询时只读内存（`LauncherMemoryFileSearch` 在自己的后台队列上查，不在主线程、不在打字路径上）。
// 只存必要的：所在目录（同一个目录的条目共用一个字符串）、名字、折叠过的名字（查询时不用再转）、是不是文件夹、修改时间。
// 只依赖 Foundation，进 BaoboxTests。

/// 一张文件表。值类型、建好就不变：换表 = 整张换掉（来源用锁保护那一个引用），查询拿到的是一份快照。
struct LauncherFileCatalog: Sendable {
    struct Entry: Sendable {
        /// 所在目录在 `directories` 里的下标。
        let directory: Int32
        let isDirectory: Bool
        let name: String
        /// 名字转小写、去掉声调、全角转半角、合成成 NFC（`fold`）：查询词同样折叠后按字节找。
        let folded: String
        /// 最近修改（1970 年起的秒数）；不知道为 0。
        let modified: Double
    }

    /// 来源给的、建表时就有的附加信息（已知文件的时间和说明、剪贴板路径的复制时间）。大多数条目没有，单独放。
    struct Extra: Sendable {
        var lastUsed: Date?
        var note: String?
    }

    /// 建表用的一条（已知文件、剪贴板里的路径；自己扫的目录直接一条条往里加）。
    struct File: Equatable, Sendable {
        let path: String
        var isDirectory = false
        var modified: Date? = nil
        var lastUsed: Date? = nil
        var note: String? = nil
    }

    private(set) var directories: [String] = []
    private(set) var entries: [Entry] = []
    private(set) var extras: [Int: Extra] = [:]
    /// 只在建表时用：目录 → 下标。
    private var directoryIndex: [String: Int32] = [:]

    init() {}

    /// 从一组路径建（同一个路径只留第一条）。路径都是绝对路径；名字为空的（`/`）不收。
    init(files: [File]) {
        var seen = Set<String>()
        for file in files {
            let (parent, name) = LauncherPathDisplay.split(file.path)
            guard !name.isEmpty, seen.insert(LauncherPathDisplay.join(parent, name)).inserted else { continue }
            let directory = addDirectory(parent)
            append(directory: directory, name: name, isDirectory: file.isDirectory,
                   modified: file.modified?.timeIntervalSince1970 ?? 0,
                   extra: file.lastUsed == nil && file.note == nil ? nil : Extra(lastUsed: file.lastUsed, note: file.note))
        }
        directoryIndex = [:]
    }

    var count: Int { entries.count }

    /// 加一个目录（已有就返回原来的下标）。
    mutating func addDirectory(_ path: String) -> Int32 {
        if let index = directoryIndex[path] { return index }
        let index = Int32(directories.count)
        directories.append(path)
        directoryIndex[path] = index
        return index
    }

    mutating func append(directory: Int32, name: String, isDirectory: Bool, modified: Double, extra: Extra? = nil) {
        if let extra { extras[entries.count] = extra }
        entries.append(Entry(directory: directory, isDirectory: isDirectory, name: name, folded: Self.fold(name),
                             modified: modified))
    }

    /// 建完了：放掉只在建表时用的索引。
    mutating func finishBuilding() {
        directoryIndex = [:]
    }

    func path(at index: Int) -> String {
        LauncherPathDisplay.join(directories[Int(entries[index].directory)], entries[index].name)
    }

    func hit(at index: Int) -> LauncherFileHit {
        let entry = entries[index]
        let extra = extras[index]
        return LauncherFileHit(path: path(at: index), isDirectory: entry.isDirectory, lastUsed: extra?.lastUsed,
                               modified: entry.modified > 0 ? Date(timeIntervalSince1970: entry.modified) : nil,
                               note: extra?.note)
    }

    /// 名字匹配这个请求的条目：名字包含每个词（不分大小写、声调、全半角，和 Spotlight 的 `CONTAINS[cd]` 同样的意思）；
    /// 片段是名字等于最后一段（路径对不对得上由过滤去看）。超过 `limit` 条时留修改时间新的。返回下标和一共匹配了多少条。
    func matches(_ request: LauncherFileSearchRequest, limit: Int) -> (indices: [Int], total: Int) {
        var indices: [Int] = []
        switch request.kind {
        case .nameContains(let words):
            let needles = words.map { Array(Self.fold($0).utf8) }.filter { !$0.isEmpty }
            guard !needles.isEmpty else { return ([], 0) }
            for index in entries.indices where needles.allSatisfy({ Self.contains(entries[index].folded, $0) }) {
                indices.append(index)
            }
        case .exactName(let name, _):
            let target = Self.fold(name)
            for index in entries.indices where entries[index].folded == target {
                indices.append(index)
            }
        }
        let total = indices.count
        if total > limit {
            indices.sort { entries[$0].modified > entries[$1].modified }
            indices.removeSubrange(max(0, limit)...)
        }
        return (indices, total)
    }

    /// 匹配用的折叠：纯 ASCII 的只转小写（快、多数名字是这样）；其余去掉声调、全角转半角、转小写，再合成成 NFC ——
    /// APFS 上的名字可能是分解形式（韩文、带声调的字母），输入法打出来的是合成形式，按字节找之前要统一。
    static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            let lower = text.lowercased()
            return lower == text ? text : lower
        }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    /// `haystack` 的 UTF-8 里有没有 `needle` 这一串字节。
    static func contains(_ haystack: String, _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.utf8.count else { return false }
        let found = haystack.utf8.withContiguousStorageIfAvailable { bytes in
            needle.withUnsafeBufferPointer { pattern in
                memmem(bytes.baseAddress, bytes.count, pattern.baseAddress, pattern.count) != nil
            }
        }
        if let found { return found }
        let bytes = Array(haystack.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            needle.withUnsafeBufferPointer { pattern in
                memmem(buffer.baseAddress, buffer.count, pattern.baseAddress, pattern.count) != nil
            }
        }
    }
}

/// 一个存在的路径是什么（跟着软链走）；不存在、读不了为 nil。只在后台调。
enum LauncherFileStat {
    static func lookup(_ path: String) -> (isDirectory: Bool, modified: Date)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return ((info.st_mode & S_IFMT) == S_IFDIR, Date(timeIntervalSince1970: modified))
    }
}

/// 内存表这个来源：表由外面整张换（任意线程，锁保护），查询在自己的串行后台队列上做，交回原始命中。
/// `verifiesExistence`：名字匹配上的条目先确认还在磁盘上（`stat`，只查匹配上的那几条），顺带拿到是不是文件夹和修改时间 ——
/// 已知文件、剪贴板里的路径要这样（清单里的文件可能早被删了）；自己扫的目录刚扫过，不查。
final class LauncherMemoryFileSearch: LauncherFileSearching, @unchecked Sendable {
    /// 最多交回这么多条（修改时间新的在前），同 Spotlight。
    static let maxHits = 5000
    /// 要确认存在时最多查这么多条（按最近使用 / 修改新的在前）：一个很短的词可能匹配上清单里的大半。
    static let maxVerified = 300

    let verifiesExistence: Bool
    private let queue: DispatchQueue
    private let lock = NSLock()
    // 以下由 `lock` 保护。
    private var catalog = LauncherFileCatalog()
    private var generation = 0

    init(label: String, verifiesExistence: Bool) {
        self.verifiesExistence = verifiesExistence
        queue = DispatchQueue(label: "com.baobox.app.launcher.files." + label, qos: .userInitiated)
    }

    /// 换上一张新表（任意线程）。
    func replace(_ catalog: LauncherFileCatalog) {
        lock.lock()
        self.catalog = catalog
        lock.unlock()
    }

    /// 现在这张表有多少条。
    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return catalog.count
    }

    func search(_ request: LauncherFileSearchRequest, completion: @escaping @Sendable (LauncherFileSearchBatch) -> Void) {
        let ticket = bumpGeneration()
        queue.async { [self] in
            let start = DispatchTime.now().uptimeNanoseconds
            guard let snapshot = snapshot(ifCurrent: ticket) else { return }
            let (indices, total) = snapshot.matches(request, limit: Self.maxHits)
            var hits = indices.map(snapshot.hit(at:))
            if verifiesExistence {
                hits = Self.existing(hits)
            }
            guard isCurrent(ticket) else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            completion(LauncherFileSearchBatch(hits: hits, totalCount: verifiesExistence ? hits.count : total,
                                               elapsed: elapsed, timedOut: false))
        }
    }

    func cancel() {
        _ = bumpGeneration()
    }

    /// 还在磁盘上的（最多查 `maxVerified` 条，新的在前）：是不是文件夹、修改时间换成磁盘上的。
    static func existing(_ hits: [LauncherFileHit]) -> [LauncherFileHit] {
        let candidates = hits.count > maxVerified
            ? Array(hits.sorted { $0.recency > $1.recency }.prefix(maxVerified)) : hits
        return candidates.compactMap { hit in
            guard let info = LauncherFileStat.lookup(hit.path) else { return nil }
            return LauncherFileHit(path: hit.path, isDirectory: info.isDirectory, lastUsed: hit.lastUsed,
                                   modified: info.modified, origins: hit.origins, note: hit.note)
        }
    }

    private func bumpGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ ticket: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ticket == generation
    }

    private func snapshot(ifCurrent ticket: Int) -> LauncherFileCatalog? {
        lock.lock()
        defer { lock.unlock() }
        return ticket == generation ? catalog : nil
    }
}
