import Foundation
import os

// 快速入口的文件来源（docs/launcher/TECH_DESIGN.md §6.4）：按名字搜文件。打字路径上不碰磁盘：
// 输入一变就交给后端（`LauncherFileSearching`；PR 11 起是四个来源的合并器 `LauncherMergedFileSearch`，见 `FileSources.swift`：
// 内存里的来源立刻在后台查，Spotlight 在合并器里等输入停下 80 ms 才查），带序号，新输入来了就停掉旧的；
// 后端每交回一批（合并器：内存里的来源都回来交一次，Spotlight 回来再交一次），在后台跑过滤、去副本、排序（`LauncherFileFilter`），
// 回主线程换成行交给控制器 —— 先回来的先出，后回来的并进去再排一次。
// 每次查询收齐后记一条日志：各来源各自的耗时和条数、合并去重后多少、过滤后剩多少 —— 用户据此决定要不要做自己的索引。

@MainActor
final class LauncherFileProvider {
    static let sourceID = "files"
    nonisolated private static let log = Logger(subsystem: "com.baobox.app", category: "launcher")

    private let backend: LauncherFileSearching
    private let home: String
    private var sequence = 0
    /// 正在搜（含只回来了一部分来源的、换表后正在重查内存来源的）那个请求：同一个请求别重复发。
    private(set) var inFlight: LauncherFileSearchRequest?
    /// 最近一次发起、后端那边还算数（没被取消、没被新的顶掉）的请求：换表后可以只重查内存来源（`requeryLocalSources`）。
    private var currentRequest: LauncherFileSearchRequest?
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
        currentRequest = request
        start(request, ticket: sequence, completion: completion)
    }

    /// 来源的表换了（PR 11 复查后定）：最近一次查询就是 `request`、后端那边还算数 → 只重查内存来源，结果经原来那次的回调交回
    /// （Spotlight 已经交回的那一批留着，还在路上的照常回来；不取消、不重发 Spotlight），返回 true。重查期间算正在搜这个请求，
    /// 控制器不会另外发起。不是这个请求（或已经取消了）→ false，调用方停掉重搜。
    func requeryLocalSources(for request: LauncherFileSearchRequest) -> Bool {
        guard currentRequest == request else { return false }
        inFlight = request
        backend.requeryImmediateSources()
        return true
    }

    /// 不要还没回来的结果了（输入变了、不搜文件了、面板收起）。
    func cancel() {
        guard inFlight != nil else { return }
        sequence += 1
        inFlight = nil
        currentRequest = nil
        backend.cancel()
    }

    private func start(_ request: LauncherFileSearchRequest, ticket: Int,
                       completion: @escaping @MainActor (LauncherFileSearchRequest, [LauncherItem], [LauncherItem], Bool) -> Void) {
        guard ticket == sequence else { return }
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
        var candidate = LauncherCandidate(sourceID: sourceID, entryID: hit.path,
                                          searchKeys: [LauncherSearchKey(hit.name, pinyin: false)],
                                          date: hit.recency, presetMatchScore: result.tierScore)
        // 只来自自己扫的目录的：没打前缀时最多 2 行、同档排在别的文件后面（引擎排序时给组的限额）。
        candidate.limitGroup = LauncherFileFilter.limitGroup(for: hit.origins)
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
