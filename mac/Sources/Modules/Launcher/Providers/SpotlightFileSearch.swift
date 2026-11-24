import Foundation

// 快速入口文件搜索的 Spotlight 后端（docs/launcher/TECH_DESIGN.md §6.4）：`NSMetadataQuery` 按名字查主目录，
// 结果收齐（初次收集完成）就停，不进实时更新；只交回原始命中，过滤和排序在 `LauncherFileFilter`。
//
// 线程：查询只在自己的串行 OperationQueue 上碰。`operationQueue` 设成它，`start()` 也在它上面调
// （头文件：start 必须在 operationQueue 或主线程上调），「收集完成」的通知也就在它上面发出，读结果在这里做，不占主线程。
//
// 实测（2026-11-24，M3，主目录 82.5 万条索引）：名字「包含」的查询收齐要 200–440 ms，几乎和命中多少无关
// （4 条和 2785 条都约 200 ms）；第一次进度通知 10 ms 左右就来，但只有 20 条，排序没法用，所以等收齐。
// 「等于」的查询（片段）约 50 ms。`kMDItemPath` 从值表里读不出来（返回 nil），要经 `NSMetadataItem` 取，
// 1–3 千条 4–10 ms。

final class LauncherSpotlightFileSearch: LauncherFileSearching, @unchecked Sendable {
    /// 最多读这么多条（按修改时间新的在前读）：再多的只是更旧的噪音，读它们白花时间。
    static let maxHits = 5000
    /// 收集太久（索引正忙、mds 卡住）就不等了，交回到那时为止的。
    static let timeout: TimeInterval = 3

    private static let attributes = [NSMetadataItemPathKey, NSMetadataItemContentTypeKey,
                                     NSMetadataItemLastUsedDateKey, NSMetadataItemFSContentChangeDateKey]

    private let queue: OperationQueue

    // 以下只在 `queue` 上读写。
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var completion: (@Sendable (LauncherFileSearchBatch) -> Void)?
    private var startedAt: UInt64 = 0
    /// 每开始一次 +1：超时、通知对得上号才交结果。
    private var generation = 0

    init() {
        queue = OperationQueue()
        queue.name = "com.baobox.app.launcher.spotlight"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    func search(_ request: LauncherFileSearchRequest, completion: @escaping @Sendable (LauncherFileSearchBatch) -> Void) {
        queue.addOperation { [self] in
            stopCurrent()
            generation += 1
            let ticket = generation
            let query = NSMetadataQuery()
            query.operationQueue = queue
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            query.predicate = Self.predicate(for: request)
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
            // 通知在 operationQueue 上发出；这里 queue: nil = 就地执行，已经在 `queue` 上了。
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                              object: query, queue: nil) { [weak self] _ in
                self?.finish(ticket, timedOut: false)
            }
            self.query = query
            self.completion = completion
            startedAt = DispatchTime.now().uptimeNanoseconds
            guard query.start() else {
                finish(ticket, timedOut: false)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                self?.queue.addOperation { self?.finish(ticket, timedOut: true) }
            }
        }
    }

    func cancel() {
        queue.addOperation { [self] in stopCurrent() }
    }

    /// 名字（`kMDItemFSName`）包含每个词，不分大小写和声调；片段是名字等于最后一段（不分大小写）。
    static func predicate(for request: LauncherFileSearchRequest) -> NSPredicate {
        switch request.kind {
        case .nameContains(let words):
            let parts = words.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
            return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        case .exactName(let name, _):
            return NSPredicate(format: "%K ==[c] %@", NSMetadataItemFSNameKey, name)
        }
    }

    // MARK: - 只在 queue 上

    /// 收齐了（或超时、没启动起来）：读出结果、停掉查询、交回去。
    private func finish(_ ticket: Int, timedOut: Bool) {
        guard ticket == generation, let query, let completion else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        query.disableUpdates()
        let total = query.resultCount
        var hits: [LauncherFileHit] = []
        hits.reserveCapacity(min(total, Self.maxHits))
        for index in 0..<min(total, Self.maxHits) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let values = item.values(forAttributes: Self.attributes),
                  let path = values[NSMetadataItemPathKey] as? String
            else { continue }
            let type = values[NSMetadataItemContentTypeKey] as? String
            hits.append(LauncherFileHit(path: path, isDirectory: type == "public.folder",
                                        lastUsed: values[NSMetadataItemLastUsedDateKey] as? Date,
                                        modified: values[NSMetadataItemFSContentChangeDateKey] as? Date))
        }
        stopCurrent()
        completion(LauncherFileSearchBatch(hits: hits, totalCount: total, elapsed: elapsed, timedOut: timedOut))
    }

    private func stopCurrent() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query?.stop()
        query = nil
        completion = nil
    }
}
