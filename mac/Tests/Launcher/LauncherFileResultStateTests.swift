import Foundation
import XCTest

/// 文件结果什么时候还要（再）搜（docs/launcher/TECH_DESIGN.md §6.4，PR 11 独立验证后修）：
/// 改错字（R → R' → R）后 R 的 Spotlight 结果照样会来；同一个请求不会反复重发。
/// 引擎、控制器在 App 里、进不了这个测试目标，所以这里照它们的写法搭一个小控制器（同样调 `LauncherFileResultState`），
/// 后面接真的合并器、内存来源和过滤，Spotlight 换成可控延迟的假后端。
final class LauncherFileResultStateTests: XCTestCase {

    private let r = LauncherFileSearchRequest.nameContains(["report.pdf"], pinnedName: "report.pdf")
    private let other = LauncherFileSearchRequest.nameContains(["report.pdfx"], pinnedName: "report.pdfx")

    // MARK: - 规则

    func testPendingWhenMissingDifferentOrIncomplete() {
        XCTAssertNil(LauncherFileResultState.pending(for: nil, have: nil), "不搜文件")
        XCTAssertEqual(LauncherFileResultState.pending(for: r, have: nil), r, "还没有结果")
        XCTAssertEqual(LauncherFileResultState.pending(for: r, have: .init(request: other, complete: true)), r, "结果是别的请求")
        XCTAssertEqual(LauncherFileResultState.pending(for: r, have: .init(request: r, complete: false)), r,
                       "只回来了一部分来源也还要搜（改错字时 R 的搜索已经被顶掉了）")
        XCTAssertNil(LauncherFileResultState.pending(for: r, have: .init(request: r, complete: true)), "回齐了")
        XCTAssertEqual(LauncherFileResultState.pending(for: r, have: LauncherFileResultState(request: r, complete: true).expired), r,
                       "换表后作废")
    }

    func testShouldStartOnlyWhenNotAlreadyRunning() {
        XCTAssertFalse(LauncherFileResultState.shouldStart(pending: nil, inFlight: nil))
        XCTAssertTrue(LauncherFileResultState.shouldStart(pending: r, inFlight: nil))
        XCTAssertTrue(LauncherFileResultState.shouldStart(pending: r, inFlight: other), "正在跑的是别的（R'）")
        XCTAssertFalse(LauncherFileResultState.shouldStart(pending: r, inFlight: r), "正在跑的就是它：不重发，等它回齐")
    }

    // MARK: - 整条路
    //
    // 不和真实时间赛跑（2026-11-25 第 10 步第四轮复查：机器忙时两次 `pump(0.03)` 之和会超过 80 ms 防抖）：
    // 合并器的防抖换成手动触发的（`ManualDebounce`），Spotlight 的结果由测试放行（`ControllableSpotlight.release`），
    // 等待一律是「等到某个条件成立」（`pump(until:)`，超时只为不挂死，不靠它定输赢）。

    @MainActor
    private func makeLauncher(spotlightFiles: [LauncherFileHit],
                              scanned: [String]) -> (MiniLauncher, ControllableSpotlight, ManualDebounce, LauncherMemoryFileSearch) {
        let spotlight = ControllableSpotlight(files: spotlightFiles)
        let debounce = ManualDebounce()
        let memory = LauncherMemoryFileSearch(label: "test.scanned", verifiesExistence: false)
        memory.replace(LauncherFileCatalog(files: scanned.map { .init(path: $0, modified: Date()) }))
        let merger = LauncherMergedFileSearch(sources: [
            .init(name: "spotlight", origin: .spotlight, backend: spotlight, delay: 0.08),
            .init(name: "scanned", origin: .scanned, backend: memory),
        ], scheduleDebounce: debounce.schedule)
        return (MiniLauncher(backend: merger), spotlight, debounce, memory)
    }

    /// 让主线程转到 `condition` 成立（超时为 false）。
    @MainActor
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        return true
    }

    /// 只用来让已经排着的主线程回调跑完（之后断言「没有再发生什么」），不靠它等结果。
    private func drain() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// 防抖到点（排着的全部触发；被新查询顶掉的那些自己不查），再等 Spotlight 收到 `searches` 次查询、放行结果。
    @MainActor
    private func fireDebounceAndRelease(_ debounce: ManualDebounce, _ spotlight: ControllableSpotlight, scheduled: Int,
                                        searches: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(pump { debounce.count == scheduled }, "防抖排了 \(scheduled) 次", file: file, line: line)
        debounce.fireAll()
        XCTAssertTrue(pump { spotlight.heldCount == searches }, "Spotlight 收到查询", file: file, line: line)
        spotlight.release()
    }

    @MainActor
    func testRetypedQueryStillGetsSpotlight() {
        let (launcher, spotlight, debounce, _) = makeLauncher(
            spotlightFiles: [LauncherFileHit(path: "/Users/me/Documents/report.pdf", modified: Date().addingTimeInterval(-3600))],
            scanned: ["/private/tmp/c/report.pdf.log"])
        launcher.type("report.pdf")
        XCTAssertTrue(pump { launcher.have != nil })
        XCTAssertEqual(launcher.have, LauncherFileResultState(request: r, complete: false), "内存来源先交了一批，R 的结果还不完整")
        launcher.type("report.pdfx")
        launcher.type("report.pdf")
        // 三次查询的防抖都还没到点：前两次被顶掉，到点后只有最后那次查 Spotlight。
        fireDebounceAndRelease(debounce, spotlight, scheduled: 3, searches: 1)
        XCTAssertTrue(pump { launcher.have?.complete == true })
        XCTAssertEqual(launcher.have, LauncherFileResultState(request: r, complete: true), "退格回到 R 之后 R 重新发起、回齐了")
        XCTAssertEqual(launcher.results.first?.hit.path, "/Users/me/Documents/report.pdf")
        XCTAssertEqual(launcher.results.first?.pinned, true, "真正的文件是固定行（不是扫的目录里的 report.pdf.log）")
        XCTAssertEqual(launcher.starts, [r, other, r], "R、R'、R 各发一次")
        XCTAssertEqual(spotlight.searchCount, 1, "Spotlight 只查最后那次（前两次在防抖里就被顶掉了）")
        drain()
        XCTAssertEqual(launcher.starts.count, 3, "回齐以后不再发")
        XCTAssertEqual(debounce.count, 0, "也没有新的防抖在排")
    }

    @MainActor
    func testRetypedFilesPrefixDoesNotHangSearching() {
        let (launcher, spotlight, debounce, _) = makeLauncher(
            spotlightFiles: [LauncherFileHit(path: "/Users/me/Documents/notes.md", modified: Date())],
            scanned: ["/private/tmp/c/notes.md.app"])
        launcher.type("f notes.md")
        XCTAssertTrue(pump { launcher.have != nil })
        launcher.type("f notes.mdx")
        launcher.type("f notes.md")
        fireDebounceAndRelease(debounce, spotlight, scheduled: 3, searches: 1)
        XCTAssertTrue(pump { launcher.have?.complete == true })
        XCTAssertFalse(launcher.isSearching, "不会一直「正在查找」")
        XCTAssertEqual(launcher.results.map(\.hit.path), ["/Users/me/Documents/notes.md"])
    }

    @MainActor
    func testTableSwapRequeriesTheCurrentInput() {
        // 刚呼出就输入文件名、自己扫的目录还没扫完：表换上之后不用再按一个键就出来；只重查内存来源，不另外发起、不重查 Spotlight。
        let (launcher, spotlight, debounce, memory) = makeLauncher(
            spotlightFiles: [LauncherFileHit(path: "/Users/me/proj/hook.py.md")], scanned: [])
        launcher.type("hook.py")
        fireDebounceAndRelease(debounce, spotlight, scheduled: 1, searches: 1)
        XCTAssertTrue(pump { launcher.have?.complete == true })
        XCTAssertEqual(launcher.results.map(\.hit.path), ["/Users/me/proj/hook.py.md"], "扫描还没完：只有 Spotlight 的")
        memory.replace(LauncherFileCatalog(files: [.init(path: "/private/tmp/c/scratchpad/hook.py", modified: Date())]))
        launcher.tablesChanged()
        XCTAssertTrue(pump { launcher.results.first?.hit.path == "/private/tmp/c/scratchpad/hook.py" }, "换表后内存来源立刻出")
        XCTAssertEqual(launcher.results.first?.pinned, true)
        XCTAssertTrue(launcher.results.contains { $0.hit.path == "/Users/me/proj/hook.py.md" }, "Spotlight 的行一直在")
        XCTAssertTrue(launcher.everyDeliveryHad("/Users/me/proj/hook.py.md"), "没有哪一次交出的结果里少了 Spotlight 的行")
        XCTAssertTrue(pump { launcher.have?.complete == true })
        drain()
        XCTAssertEqual(launcher.starts.count, 1, "没有另外发起")
        XCTAssertEqual(debounce.count, 0, "没有新的防抖在排")
        XCTAssertEqual(spotlight.searchCount, 1, "Spotlight 不多查")
        XCTAssertEqual(launcher.have?.complete, true)
    }

    @MainActor
    func testSameRequestIsNotResentWhileGathering() {
        let (launcher, spotlight, debounce, _) = makeLauncher(
            spotlightFiles: [LauncherFileHit(path: "/Users/me/a/report.pdf")], scanned: ["/private/tmp/c/report.pdf"])
        launcher.type("report.pdf")
        XCTAssertTrue(pump { launcher.have != nil })
        XCTAssertEqual(launcher.have?.complete, false, "Spotlight 还没放行：一定不完整")
        for _ in 0..<5 { launcher.refresh() }   // 后台结果回来、别的来源建完键……都会再查一次
        XCTAssertEqual(launcher.starts, [r], "正在跑的就是它：不重发")
        fireDebounceAndRelease(debounce, spotlight, scheduled: 1, searches: 1)
        XCTAssertTrue(pump { launcher.have?.complete == true })
        for _ in 0..<5 { launcher.refresh() }
        drain()
        XCTAssertEqual(launcher.starts, [r], "回齐了也不重发")
        XCTAssertEqual(spotlight.searchCount, 1)
    }
}

/// 照 `LauncherController.refresh / requestBackgroundResults / filesFound` 和 `LauncherFileProvider` 的写法搭的小控制器
/// （只有文件这一路，没有界面）。
@MainActor
private final class MiniLauncher {
    let backend: LauncherMergedFileSearch
    private(set) var text = ""
    private(set) var have: LauncherFileResultState?
    private(set) var results: [LauncherFileResult] = []
    private(set) var inFlight: LauncherFileSearchRequest?
    private(set) var starts: [LauncherFileSearchRequest] = []
    private(set) var isSearching = false
    private var sequence = 0
    private var currentRequest: LauncherFileSearchRequest?
    private var swapped = false
    private var deliveriesAfterSwap: [[String]] = []

    init(backend: LauncherMergedFileSearch) {
        self.backend = backend
    }

    func type(_ newText: String) {
        text = newText
        refresh()
    }

    /// 引擎的 `search` 里和文件有关的那几步 + 控制器的 `requestBackgroundResults`。
    func refresh() {
        let wanted = LauncherFilePolicy.request(for: LauncherQuery.parse(text), hasCalculation: false)
        if wanted == nil { have = nil }
        let pending = LauncherFileResultState.pending(for: wanted, have: have)
        isSearching = pending != nil && (have?.request != wanted || results.isEmpty)
        if let pending {
            if LauncherFileResultState.shouldStart(pending: pending, inFlight: inFlight) { start(pending) }
        } else {
            cancel()
        }
    }

    /// 控制器的 `fileTablesChanged`：正在搜文件就把结果当成不完整；最近一次查询就是它 → 只重查内存来源（同
    /// `LauncherFileProvider.requeryLocalSources`），否则停掉重搜。
    func tablesChanged() {
        guard let wanted = LauncherFilePolicy.request(for: LauncherQuery.parse(text), hasCalculation: false) else { return }
        have = have?.expired
        swapped = true
        if currentRequest == wanted {
            inFlight = wanted
            backend.requeryImmediateSources()
            return
        }
        cancel()
        refresh()
    }

    /// 换表之后交出的每一批里都有这个路径。
    func everyDeliveryHad(_ path: String) -> Bool {
        deliveriesAfterSwap.allSatisfy { $0.contains(path) }
    }

    private func start(_ request: LauncherFileSearchRequest) {
        cancel()
        sequence += 1
        inFlight = request
        currentRequest = request
        starts.append(request)
        let ticket = sequence
        backend.search(request) { batch in
            let processed = LauncherFileFilter.process(batch.hits, request: request, home: "/Users/me")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ticket == self.sequence else { return }
                    if batch.isComplete { self.inFlight = nil }
                    self.have = LauncherFileResultState(request: request, complete: batch.isComplete)
                    self.results = processed
                    if self.swapped { self.deliveriesAfterSwap.append(processed.map(\.hit.path)) }
                    self.refresh()
                }
            }
        }
    }

    private func cancel() {
        guard inFlight != nil else { return }
        sequence += 1
        inFlight = nil
        currentRequest = nil
        backend.cancel()
    }
}

/// 手动触发的防抖计时（替换合并器里的 `asyncAfter`）：排着的工作等测试调 `fireAll()` 才在合并器的队列上执行。
private final class ManualDebounce: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [(DispatchQueue, @Sendable () -> Void)] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduled.count
    }

    var schedule: LauncherMergedFileSearch.DebounceScheduler {
        { [self] _, queue, work in
            lock.lock()
            scheduled.append((queue, work))
            lock.unlock()
        }
    }

    /// 排着的全部按先后放到各自的队列上执行（被新查询顶掉的那些自己会跳过）。
    func fireAll() {
        lock.lock()
        let due = scheduled
        scheduled = []
        lock.unlock()
        for (queue, work) in due { queue.async(execute: work) }
    }
}

/// 假 Spotlight：按名字包含筛，结果先扣着，测试调 `release()` 才交回；被取消 / 顶掉的不交。
private final class ControllableSpotlight: LauncherFileSearching, @unchecked Sendable {
    private let files: [LauncherFileHit]
    private let lock = NSLock()
    private var generation = 0
    private var searches = 0
    private var held: [(ticket: Int, batch: LauncherFileSearchBatch, completion: @Sendable (LauncherFileSearchBatch) -> Void)] = []

    init(files: [LauncherFileHit]) {
        self.files = files
    }

    var searchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return searches
    }

    /// 收到了、还扣着没交的查询数。
    var heldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    func search(_ request: LauncherFileSearchRequest, completion: @escaping @Sendable (LauncherFileSearchBatch) -> Void) {
        guard case .nameContains(let words) = request.kind else { return }
        let hits = files.filter { file in words.allSatisfy { file.name.localizedCaseInsensitiveContains($0) } }
        lock.lock()
        generation += 1
        searches += 1
        held.append((generation, LauncherFileSearchBatch(hits: hits, totalCount: hits.count, elapsed: 0.1, timedOut: false),
                     completion))
        lock.unlock()
    }

    /// 把扣着的结果交回（只交还没被顶掉的那次）。
    func release() {
        lock.lock()
        let due = held.filter { $0.ticket == generation }
        held = []
        lock.unlock()
        for item in due { item.completion(item.batch) }
    }

    func cancel() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func requeryImmediateSources() {}
}
