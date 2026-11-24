import Foundation
import os

// 快速入口的文件来源（docs/launcher/TECH_DESIGN.md §6.4）：按名字搜文件。打字路径上不搜：
// 输入停下 80 ms 再交给后端（`LauncherFileSearching`；PR 11 起是四个来源的合并器 `LauncherMergedFileSearch`，
// 见 `FileSources.swift`），带序号，新输入来了就停掉旧的；后端每交回一批（合并器：每有一个来源回来就交一次到目前为止的全部），
// 在后台跑过滤、去副本、排序（`LauncherFileFilter`），回主线程换成行交给控制器 —— 先回来的先出，后回来的并进去再排一次。
// 每次查询收齐后记一条日志：各来源各自的耗时和条数、合并去重后多少、过滤后剩多少 —— 用户据此决定要不要做自己的索引。

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
    /// 正在搜（含还在等防抖的、只回来了一部分来源的）那个请求：同一个请求别重复发。
    private(set) var inFlight: LauncherFileSearchRequest?
    /// 这次查询第一批行交给控制器用了多久（记日志）。
    private var firstRowsMilliseconds: Double?

    init(backend: LauncherFileSearching, home: String = NSHomeDirectory()) {
        self.backend = backend
        self.home = home
    }

    /// 搜这个请求（停掉还没回来的上一次）；结果在主线程回调，可能不止一次（先回来的来源先交）：`pinned` 是固定在最前的
    /// （片段的确切命中、输入像文件名时名字正好是它的），`ranked` 交给排序，`complete` = 所有来源都回来了（最后一次）。
    func search(_ request: LauncherFileSearchRequest,
                completion: @escaping @MainActor (LauncherFileSearchRequest, _ pinned: [LauncherItem], _ ranked: [LauncherItem],
                                                  _ complete: Bool) -> Void) {
        cancel()
        sequence += 1
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
                       completion: @escaping @MainActor (LauncherFileSearchRequest, [LauncherItem], [LauncherItem], Bool) -> Void) {
        guard ticket == sequence else { return }
        debounceWork = nil
        let home = home
        let issued = DispatchTime.now().uptimeNanoseconds
        firstRowsMilliseconds = nil
        backend.search(request) { batch in
            // 后端的线程（不是主线程）：过滤排序也在这里做。
            let results = LauncherFileFilter.process(batch.hits, request: request, home: home)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.sequence else { return }
                    let pinned = results.filter(\.pinned).map { Self.item(for: $0, home: home) }
                    let ranked = results.filter { !$0.pinned }.map { Self.item(for: $0, home: home) }
                    let total = Double(DispatchTime.now().uptimeNanoseconds - issued) / 1_000_000
                    if self.firstRowsMilliseconds == nil { self.firstRowsMilliseconds = total }
                    if batch.isComplete {
                        self.inFlight = nil
                        Self.log.notice("file search (\(Self.kindName(request), privacy: .public)): \(Self.sourcesSummary(batch), privacy: .public); \(batch.hits.count, privacy: .public) merged, \(results.count, privacy: .public) after filtering (\(pinned.count, privacy: .public) pinned); first rows \(self.firstRowsMilliseconds ?? total, format: .fixed(precision: 0), privacy: .public) ms, all \(total, format: .fixed(precision: 0), privacy: .public) ms")
                    }
                    completion(request, pinned, ranked, batch.isComplete)
                }
            }
        }
    }

    /// 各来源各自的耗时和条数：`spotlight 210 ms 1117 found 1117 read; scanned 1 ms 2 …`。
    nonisolated static func sourcesSummary(_ batch: LauncherFileSearchBatch) -> String {
        guard !batch.sources.isEmpty else {
            return "results in \(Int((batch.elapsed * 1000).rounded())) ms, \(batch.totalCount) found, \(batch.hits.count) read\(batch.timedOut ? " (timed out)" : "")"
        }
        return batch.sources.map { source in
            "\(source.name) \(Int((source.elapsed * 1000).rounded())) ms \(source.totalCount) found \(source.hitCount) read\(source.timedOut ? " (timed out)" : "")"
        }.joined(separator: "; ")
    }

    /// 一条结果 → 面板条目：标题是名字，副标题是所在目录（主目录缩写成 `~`，太长中间截断），来源给了说明时写在目录前面
    /// （「Claude Code · cmb · /private/tmp/…/scratchpad」）；右侧小字「文件 / 文件夹」；
    /// 匹配分是档（排序同分时看使用记录、再看谁新），记使用记录（常开的文件以后排前面）。
    static func item(for result: LauncherFileResult, home: String) -> LauncherItem {
        let hit = result.hit
        let candidate = LauncherCandidate(sourceID: sourceID, entryID: hit.path,
                                          searchKeys: [LauncherSearchKey(hit.name, pinyin: false)],
                                          date: hit.recency, presetMatchScore: result.tierScore)
        let parent = LauncherPathDisplay.split(hit.path).parent
        let directory: String
        if let note = hit.note, !note.isEmpty {
            // 说明和目录加起来别比单独的目录长太多：目录让出说明占的地方（最少留 30 个字符）。
            let budget = max(30, LauncherPathDisplay.maxDirectoryLabelLength - note.count - 3)
            directory = note + " · " + LauncherPathDisplay.directoryLabel(parent, home: home, maxLength: budget)
        } else {
            directory = LauncherPathDisplay.directoryLabel(parent, home: home)
        }
        // `.app` 已经被过滤掉了（App 来源有），所以这里没有要当 App 启动的包。
        return LauncherFileActions.item(candidate: candidate, path: hit.path, title: hit.name, subtitle: directory,
                                        isDirectory: hit.isDirectory, isPackage: false, recordsUsage: true)
    }

    private static func kindName(_ request: LauncherFileSearchRequest) -> String {
        switch request.kind {
        case .nameContains(let words):
            return "name contains \(words.count) word(s)" + (request.pinnedName == nil ? "" : ", looks like a file name")
        case .exactName: return "exact name"
        }
    }
}
