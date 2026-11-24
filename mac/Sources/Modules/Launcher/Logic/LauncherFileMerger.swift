import Foundation

// 快速入口的文件来源合并器（docs/launcher/TECH_DESIGN.md §6.4，PR 11）：同一个查询同时问几个来源 ——
// Spotlight、自己扫的目录、各模块已知的文件、剪贴板里出现过的路径 —— 哪个先回来先交出去，后回来的并进去再交一次；
// 按规范路径去重（`/tmp/x` 和 `/private/tmp/x` 是同一个），同一个文件几个来源都有时来源取并集。
// 过滤和排序不在这里（`LauncherFileFilter` 对所有来源一视同仁）。只依赖 Foundation，进 BaoboxTests。

/// 一条命中从哪几个来源来。
struct LauncherFileOrigins: OptionSet, Hashable, Sendable {
    let rawValue: Int

    /// 系统的 Spotlight 索引（主目录）。
    static let spotlight = LauncherFileOrigins(rawValue: 1 << 0)
    /// 快速入口自己扫的目录（Spotlight 不建索引的地方，默认有 Claude Code 的临时目录）。
    static let scanned = LauncherFileOrigins(rawValue: 1 << 1)
    /// 各模块已知的文件（Claude Code 会话写过的）。
    static let known = LauncherFileOrigins(rawValue: 1 << 2)
    /// 剪贴板历史里出现过的路径。
    static let clipboard = LauncherFileOrigins(rawValue: 1 << 3)

    /// 用户或他的会话明确碰过的（Claude Code 写过、复制过路径）：不看目录规则（`LauncherFileFilter.isExcluded(_:home:)`）。
    static let touched: LauncherFileOrigins = [.known, .clipboard]
    /// 固定行里排在前面的：用户此刻更可能要的那一个（`LauncherFileFilter.pinnedOrder`）—— 就是明确碰过的那些。
    static let preferred: LauncherFileOrigins = touched
}

/// 一个来源这次交回了什么（日志分开记）。
struct LauncherFileSourceReport: Equatable, Sendable {
    let name: String
    /// 从合并器发起到这个来源交回（秒）。
    let elapsed: TimeInterval
    let totalCount: Int
    let hitCount: Int
    let timedOut: Bool
}

enum LauncherFileMerge {
    /// 去重用的规范路径（只是字符串规整，不碰磁盘）：
    /// - 数据卷上的写法去掉 `/System/Volumes/Data`（Spotlight 交回的是这种，2026-11-24 实测）；
    /// - `/tmp`、`/var`、`/etc` 是指向 `/private/…` 的软链，换成真的那一个（`standardizedFileURL` 反过来会去掉 `/private`，
    ///   Claude Code 的最近文件就是那样存的；自己扫的目录是 `/private/tmp/…`）；
    /// - 末尾的 `/` 去掉。
    static func key(for path: String) -> String {
        var result = LauncherPathDisplay.trimmingTrailingSlashes(path)
        let dataVolume = "/System/Volumes/Data"
        if result.hasPrefix(dataVolume + "/") { result = String(result.dropFirst(dataVolume.count)) }
        for link in ["/tmp", "/var", "/etc"] where result == link || result.hasPrefix(link + "/") {
            result = "/private" + result
            break
        }
        return result
    }

    /// 把一批命中并进已有的（按规范路径）：新路径接在后面；已有的取并集 —— 来源合并，说明取先有的，
    /// 最近使用 / 最近修改取新的，是不是文件夹以已有的为准。路径一律写成规范路径。
    static func merge(_ hits: [LauncherFileHit], origin: LauncherFileOrigins,
                      into merged: inout [String: LauncherFileHit], order: inout [String]) {
        for hit in hits {
            let key = key(for: hit.path)
            if let existing = merged[key] {
                merged[key] = LauncherFileHit(
                    path: key, isDirectory: existing.isDirectory,
                    lastUsed: newer(existing.lastUsed, hit.lastUsed), modified: newer(existing.modified, hit.modified),
                    origins: existing.origins.union(hit.origins).union(origin), note: existing.note ?? hit.note)
            } else {
                merged[key] = LauncherFileHit(path: key, isDirectory: hit.isDirectory, lastUsed: hit.lastUsed,
                                              modified: hit.modified, origins: hit.origins.union(origin), note: hit.note)
                order.append(key)
            }
        }
    }

    private static func newer(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        default: return a ?? b
        }
    }
}

/// 合并器：把几个后端并成一个。
/// - 发起：`delay == 0` 的来源（内存里的表）立刻查；有 `delay` 的（Spotlight）等这么久、期间没有新的查询才查（防抖在这里做，
///   内存里的来源不用陪着等）。
/// - 交出：立刻查的那几个都回来后交一次（它们都不到 1 ms，凑齐了交，列表只刷新一次），之后每有一个来源带着新命中回来就再交一次；
///   最后一个来源回来时一定交（`isComplete == true`）。交的总是「到目前为止的全部」。只在自己的串行队列上改状态。
final class LauncherMergedFileSearch: LauncherFileSearching, @unchecked Sendable {
    struct Source {
        let name: String
        let origin: LauncherFileOrigins
        let backend: LauncherFileSearching
        /// 防抖：这次查询发起后等多久、期间没有新的查询才查它（秒）；0 = 立刻查。
        var delay: TimeInterval = 0
    }

    let sources: [Source]
    private let queue = DispatchQueue(label: "com.baobox.app.launcher.filemerge", qos: .userInitiated)

    // 以下只在 `queue` 上读写。
    /// 每发起一次 +1：回来的结果对得上号才收。
    private var generation = 0
    private var startedAt: UInt64 = 0
    private var reports: [Int: LauncherFileSourceReport] = [:]
    private var merged: [String: LauncherFileHit] = [:]
    private var order: [String] = []
    private var totalCount = 0
    private var timedOut = false
    /// 上次交出之后又并进了新命中、还没交。
    private var pendingChange = false

    init(sources: [Source]) {
        self.sources = sources
    }

    func search(_ request: LauncherFileSearchRequest, completion: @escaping @Sendable (LauncherFileSearchBatch) -> Void) {
        queue.async { [self] in
            generation += 1
            let ticket = generation
            startedAt = DispatchTime.now().uptimeNanoseconds
            reports = [:]
            merged = [:]
            order = []
            totalCount = 0
            timedOut = false
            pendingChange = false
            guard !sources.isEmpty else {
                completion(LauncherFileSearchBatch(hits: [], totalCount: 0, elapsed: 0, timedOut: false))
                return
            }
            for (index, source) in sources.enumerated() {
                if source.delay > 0 {
                    queue.asyncAfter(deadline: .now() + source.delay) { [weak self] in
                        // 等的这段时间里又有了新的查询（或取消了）：这次不查了。
                        guard let self, ticket == self.generation else { return }
                        start(source, index: index, request: request, ticket: ticket, completion: completion)
                    }
                } else {
                    start(source, index: index, request: request, ticket: ticket, completion: completion)
                }
            }
        }
    }

    func cancel() {
        // 和 `search` 排在同一个队列上：先发起的那次一定先被顶掉，不会出现「取消在前、发起在后」的错位。
        queue.async { [self] in
            generation += 1
            sources.forEach { $0.backend.cancel() }
        }
    }

    // MARK: - 只在 queue 上

    private func start(_ source: Source, index: Int, request: LauncherFileSearchRequest, ticket: Int,
                       completion: @escaping @Sendable (LauncherFileSearchBatch) -> Void) {
        source.backend.search(request) { [weak self] batch in
            self?.queue.async { self?.receive(batch, from: index, ticket: ticket, completion: completion) }
        }
    }

    private func receive(_ batch: LauncherFileSearchBatch, from index: Int, ticket: Int,
                         completion: @Sendable (LauncherFileSearchBatch) -> Void) {
        guard ticket == generation, reports[index] == nil else { return }
        let source = sources[index]
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        reports[index] = LauncherFileSourceReport(name: source.name, elapsed: elapsed, totalCount: batch.totalCount,
                                                  hitCount: batch.hits.count, timedOut: batch.timedOut)
        LauncherFileMerge.merge(batch.hits, origin: source.origin, into: &merged, order: &order)
        totalCount += batch.totalCount
        timedOut = timedOut || batch.timedOut
        if !batch.hits.isEmpty { pendingChange = true }
        let isComplete = reports.count == sources.count
        let immediateDone = sources.indices.allSatisfy { sources[$0].delay > 0 || reports[$0] != nil }
        // 立刻查的还没凑齐时先不交（它们几乎同时回来，凑齐了只刷新一次列表）；有延迟的来源（Spotlight）回来就交。
        guard isComplete || (pendingChange && (immediateDone || source.delay > 0)) else { return }
        pendingChange = false
        completion(LauncherFileSearchBatch(
            hits: order.compactMap { merged[$0] }, totalCount: totalCount, elapsed: elapsed, timedOut: timedOut,
            isComplete: isComplete, sources: sources.indices.compactMap { reports[$0] }))
    }
}
