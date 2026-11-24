import Foundation
import os

// 快速入口的文件来源（docs/launcher/TECH_DESIGN.md §6.4）：按名字搜文件。打字路径上不搜：
// 输入停下 80 ms 再交给后端（`LauncherFileSearching`，这一版是 Spotlight），带序号，新输入来了就停掉旧的；
// 后端交回原始命中后，在后台跑过滤、去副本、排序（`LauncherFileFilter`），回主线程换成行交给控制器。
// 每次查询记一条日志：后端收齐用了多久、拿回多少、过滤后剩多少 —— 用户据此决定要不要做自己的索引。

@MainActor
final class LauncherFileProvider {
    static let sourceID = "files"
    /// 输入停下多久才搜。
    static let debounceInterval: TimeInterval = 0.08
    nonisolated private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")

    private let backend: LauncherFileSearching
    private let home: String
    private var sequence = 0
    private var debounceWork: DispatchWorkItem?
    /// 正在搜（含还在等防抖的）那个请求：同一个请求别重复发。
    private(set) var inFlight: LauncherFileSearchRequest?

    init(backend: LauncherFileSearching = LauncherSpotlightFileSearch(), home: String = NSHomeDirectory()) {
        self.backend = backend
        self.home = home
    }

    /// 搜这个请求（停掉还没回来的上一次）；结果在主线程回调：`pinned` 是片段的确切命中（固定在最前），`ranked` 交给排序。
    func search(_ request: LauncherFileSearchRequest,
                completion: @escaping @MainActor (LauncherFileSearchRequest, _ pinned: [LauncherItem], _ ranked: [LauncherItem]) -> Void) {
        cancel()
        inFlight = request
        let ticket = sequence
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.start(request, ticket: ticket, completion: completion) }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// 不要还没回来的结果了（输入变了、不搜文件了、面板收起）。
    func cancel() {
        guard inFlight != nil else { return }
        sequence += 1
        debounceWork?.cancel()
        debounceWork = nil
        inFlight = nil
        backend.cancel()
    }

    private func start(_ request: LauncherFileSearchRequest, ticket: Int,
                       completion: @escaping @MainActor (LauncherFileSearchRequest, [LauncherItem], [LauncherItem]) -> Void) {
        guard ticket == sequence else { return }
        debounceWork = nil
        let home = home
        let issued = DispatchTime.now().uptimeNanoseconds
        backend.search(request) { batch in
            // 后端的线程（不是主线程）：过滤排序也在这里做。
            let results = LauncherFileFilter.process(batch.hits, request: request, home: home)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.sequence else { return }
                    self.inFlight = nil
                    let pinned = results.filter(\.pinned).map { Self.item(for: $0, home: home) }
                    let ranked = results.filter { !$0.pinned }.map { Self.item(for: $0, home: home) }
                    let total = Double(DispatchTime.now().uptimeNanoseconds - issued) / 1_000_000
                    Self.log.notice("file search (\(Self.kindName(request), privacy: .public)): results in \(batch.elapsed * 1000, format: .fixed(precision: 0), privacy: .public) ms, \(batch.totalCount, privacy: .public) found, \(batch.hits.count, privacy: .public) read, \(results.count, privacy: .public) after filtering; \(total, format: .fixed(precision: 0), privacy: .public) ms until rows\(batch.timedOut ? " (timed out)" : "", privacy: .public)")
                    completion(request, pinned, ranked)
                }
            }
        }
    }

    /// 一条结果 → 面板条目：标题是名字，副标题是所在目录（主目录缩写成 `~`，太长中间截断），右侧小字「文件 / 文件夹」；
    /// 匹配分是档（排序同分时看使用记录、再看谁新），记使用记录（常开的文件以后排前面）。
    static func item(for result: LauncherFileResult, home: String) -> LauncherItem {
        let hit = result.hit
        let candidate = LauncherCandidate(sourceID: sourceID, entryID: hit.path,
                                          searchKeys: [LauncherSearchKey(hit.name, pinyin: false)],
                                          date: hit.recency, presetMatchScore: result.tierScore)
        let directory = LauncherPathDisplay.directoryLabel(LauncherPathDisplay.split(hit.path).parent, home: home)
        // `.app` 已经被过滤掉了（App 来源有），所以这里没有要当 App 启动的包。
        return LauncherFileActions.item(candidate: candidate, path: hit.path, title: hit.name, subtitle: directory,
                                        isDirectory: hit.isDirectory, isPackage: false, recordsUsage: true)
    }

    private static func kindName(_ request: LauncherFileSearchRequest) -> String {
        switch request.kind {
        case .nameContains(let words): return "name contains \(words.count) word(s)"
        case .exactName: return "exact name"
        }
    }
}
