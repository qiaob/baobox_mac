import Foundation
import XCTest

/// 文件来源合并（docs/launcher/TECH_DESIGN.md §6.4，PR 11）：内存里的表怎么匹配、内存来源怎么确认文件还在、
/// 合并器先回来的先交、按规范路径去重、来源取并集、取消。
final class LauncherFileMergerTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - 规范路径与合并

    func testKeyCanonicalizesSymlinkedSystemFolders() {
        XCTAssertEqual(LauncherFileMerge.key(for: "/tmp/claude-501/a.py"), "/private/tmp/claude-501/a.py")
        XCTAssertEqual(LauncherFileMerge.key(for: "/private/tmp/claude-501/a.py"), "/private/tmp/claude-501/a.py")
        XCTAssertEqual(LauncherFileMerge.key(for: "/var/folders/x"), "/private/var/folders/x")
        XCTAssertEqual(LauncherFileMerge.key(for: "/etc"), "/private/etc")
        XCTAssertEqual(LauncherFileMerge.key(for: "/tmpfiles/a"), "/tmpfiles/a", "只换整段")
        XCTAssertEqual(LauncherFileMerge.key(for: "/System/Volumes/Data/Users/me/a.md"), "/Users/me/a.md")
        XCTAssertEqual(LauncherFileMerge.key(for: "/Users/me/dir/"), "/Users/me/dir")
    }

    func testMergeUnionsOriginsAndKeepsTheNote() {
        var merged: [String: LauncherFileHit] = [:]
        var order: [String] = []
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        LauncherFileMerge.merge([LauncherFileHit(path: "/private/tmp/c/a.py", modified: old)], origin: .scanned,
                                into: &merged, order: &order)
        LauncherFileMerge.merge([LauncherFileHit(path: "/tmp/c/a.py", lastUsed: new, modified: new, note: "Claude Code · cmb"),
                                 LauncherFileHit(path: "/Users/me/b.md")], origin: .known, into: &merged, order: &order)
        XCTAssertEqual(order, ["/private/tmp/c/a.py", "/Users/me/b.md"])
        let a = merged["/private/tmp/c/a.py"]
        XCTAssertEqual(a?.origins, [.scanned, .known])
        XCTAssertEqual(a?.note, "Claude Code · cmb")
        XCTAssertEqual(a?.modified, new)
        XCTAssertEqual(a?.lastUsed, new)
        XCTAssertEqual(a?.path, "/private/tmp/c/a.py", "路径写成规范路径")
    }

    // MARK: - 内存里的表

    func testCatalogMatchesLikeSpotlight() {
        let catalog = LauncherFileCatalog(files: [
            .init(path: "/p/s/add-approval-hook.py"),
            .init(path: "/p/s/Résumé Final.PDF"),
            .init(path: "/p/s/ＡＢＣ.txt"),
            .init(path: "/p/s/发票-2026.jpg"),
            .init(path: "/p/s/notes.md", isDirectory: true),
        ])
        func names(_ request: LauncherFileSearchRequest) -> [String] {
            catalog.matches(request, limit: 100).indices.map { catalog.entries[$0].name }
        }
        XCTAssertEqual(names(.nameContains(["APPROVAL-HOOK"])), ["add-approval-hook.py"], "不分大小写")
        XCTAssertEqual(names(.nameContains(["resume", "final"])), ["Résumé Final.PDF"], "不分声调，每个词都要有")
        XCTAssertEqual(names(.nameContains(["abc"])), ["ＡＢＣ.txt"], "全角半角")
        XCTAssertEqual(names(.nameContains(["发票"])), ["发票-2026.jpg"])
        XCTAssertEqual(names(.nameContains(["zzz"])), [])
        XCTAssertEqual(names(.exactName("NOTES.md", pathSuffix: "s/notes.md")), ["notes.md"])
        XCTAssertEqual(catalog.hit(at: 4).isDirectory, true)
        XCTAssertEqual(catalog.hit(at: 0).path, "/p/s/add-approval-hook.py")
        XCTAssertEqual(catalog.directories, ["/p/s"], "同一个目录只存一份")
    }

    func testCatalogMatchesDecomposedNames() {
        let decomposed = "한글.txt".decomposedStringWithCanonicalMapping
        let catalog = LauncherFileCatalog(files: [.init(path: "/p/" + decomposed)])
        XCTAssertEqual(catalog.matches(.nameContains(["한글"]), limit: 10).total, 1, "APFS 上分解形式的名字也能用合成形式的词找到")
    }

    func testCatalogKeepsTheNewestWhenOverTheLimit() {
        let catalog = LauncherFileCatalog(files: (0..<10).map {
            .init(path: "/d/file\($0).txt", modified: Date(timeIntervalSince1970: Double($0)))
        })
        let (indices, total) = catalog.matches(.nameContains(["file"]), limit: 3)
        XCTAssertEqual(total, 10)
        XCTAssertEqual(indices.map { catalog.entries[$0].name }, ["file9.txt", "file8.txt", "file7.txt"])
    }

    func testCatalogCarriesExtras() {
        let used = Date(timeIntervalSince1970: 5_000)
        let catalog = LauncherFileCatalog(files: [.init(path: "/d/a.md", lastUsed: used, note: "Claude Code · x"), .init(path: "/d/b.md"),
                                                  .init(path: "/d/a.md")])
        XCTAssertEqual(catalog.count, 2, "同一个路径只留第一条")
        XCTAssertEqual(catalog.hit(at: 0).lastUsed, used)
        XCTAssertEqual(catalog.hit(at: 0).note, "Claude Code · x")
        XCTAssertNil(catalog.hit(at: 1).note)
    }

    // MARK: - 内存来源

    private func search(_ backend: LauncherFileSearching, _ request: LauncherFileSearchRequest,
                        timeout: TimeInterval = 5) -> [LauncherFileSearchBatch] {
        let expectation = expectation(description: "search")
        let collected = BatchCollector()
        backend.search(request) { batch in
            collected.append(batch)
            if batch.isComplete { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: timeout)
        return collected.batches
    }

    func testMemorySearchVerifiesExistence() throws {
        let present = folder.appendingPathComponent("report.md")
        try Data("x".utf8).write(to: present)
        let subfolder = folder.appendingPathComponent("report.d")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let source = LauncherMemoryFileSearch(label: "test", verifiesExistence: true)
        source.replace(LauncherFileCatalog(files: [
            .init(path: present.path),
            .init(path: folder.appendingPathComponent("report-deleted.md").path),
            .init(path: subfolder.path),
        ]))
        let batch = try XCTUnwrap(search(source, .nameContains(["report"])).last)
        XCTAssertEqual(Set(batch.hits.map(\.path)), [present.path, subfolder.path], "不在磁盘上的不交")
        XCTAssertEqual(batch.hits.first { $0.path == subfolder.path }?.isDirectory, true, "是不是文件夹以磁盘为准")
        XCTAssertNotNil(batch.hits.first { $0.path == present.path }?.modified)
    }

    func testMemorySearchWithoutVerificationTrustsTheTable() throws {
        let source = LauncherMemoryFileSearch(label: "test", verifiesExistence: false)
        source.replace(LauncherFileCatalog(files: [.init(path: "/nonexistent/dir/report.md")]))
        XCTAssertEqual(try XCTUnwrap(search(source, .nameContains(["report"])).last).hits.map(\.path), ["/nonexistent/dir/report.md"])
        XCTAssertEqual(source.entryCount, 1)
    }

    // MARK: - 合并器

    func testMergedSearchDeliversFastSourcesFirstAndDedupes() throws {
        let slow = FakeFileSearch(delay: 0.3, hits: [LauncherFileHit(path: "/Users/me/a/notes.md"),
                                                    LauncherFileHit(path: "/tmp/c/hook.py")])
        let fast = FakeFileSearch(delay: 0, hits: [LauncherFileHit(path: "/private/tmp/c/hook.py")])
        let empty = FakeFileSearch(delay: 0.05, hits: [])
        let merged = LauncherMergedFileSearch(sources: [
            .init(name: "spotlight", origin: .spotlight, backend: slow, delay: 0.05),
            .init(name: "scanned", origin: .scanned, backend: fast),
            .init(name: "known", origin: .known, backend: empty),
        ])
        let batches = search(merged, .nameContains(["o"]))
        XCTAssertEqual(batches.count, 2, "立刻查的两个凑齐了交一次，Spotlight 回来再交一次")
        XCTAssertEqual(batches.first?.hits.map(\.path), ["/private/tmp/c/hook.py"], "快的先交")
        XCTAssertEqual(batches.first?.isComplete, false)
        let last = try XCTUnwrap(batches.last)
        XCTAssertTrue(last.isComplete)
        XCTAssertEqual(Set(last.hits.map(\.path)), ["/private/tmp/c/hook.py", "/Users/me/a/notes.md"], "/tmp 和 /private/tmp 并成一条")
        XCTAssertEqual(last.hits.first { $0.path == "/private/tmp/c/hook.py" }?.origins, [.scanned, .spotlight])
        XCTAssertEqual(last.sources.map(\.name), ["spotlight", "scanned", "known"], "各来源的统计按来源的次序")
        XCTAssertEqual(last.sources.map(\.hitCount), [2, 1, 0])
        XCTAssertEqual(last.totalCount, 3)
    }

    func testImmediateSourcesAreDeliveredTogether() throws {
        let a = FakeFileSearch(delay: 0, hits: [LauncherFileHit(path: "/a/x.txt")])
        let b = FakeFileSearch(delay: 0.01, hits: [LauncherFileHit(path: "/b/x.txt")])
        let spotlight = FakeFileSearch(delay: 0, hits: [])
        let merged = LauncherMergedFileSearch(sources: [
            .init(name: "spotlight", origin: .spotlight, backend: spotlight, delay: 0.2),
            .init(name: "a", origin: .scanned, backend: a),
            .init(name: "b", origin: .clipboard, backend: b),
        ], firstBatchDeadline: 0.5)   // 期限放宽，只看「凑齐了交一次」，不受机器忙不忙影响
        let batches = search(merged, .nameContains(["x"]))
        XCTAssertEqual(batches.map(\.hits.count), [2, 2], "立刻查的两个都回来才交第一次（不是一个一次）；Spotlight 空着回来时补一次完成")
        XCTAssertEqual(batches.map(\.isComplete), [false, true])
    }

    func testFirstBatchDoesNotWaitForAStuckSource() throws {
        // 某个 stat 卡在断开的网络盘上：已经回来的到期限就先交。
        let fast = FakeFileSearch(delay: 0, hits: [LauncherFileHit(path: "/a/hook.py")])
        let stuck = FakeFileSearch(delay: 0.6, hits: [LauncherFileHit(path: "/Volumes/nas/hook.py")])
        let merged = LauncherMergedFileSearch(sources: [
            .init(name: "scanned", origin: .scanned, backend: fast),
            .init(name: "clipboard", origin: .clipboard, backend: stuck),
        ], firstBatchDeadline: 0.05)
        let collected = TimedBatchCollector()
        let done = expectation(description: "complete")
        merged.search(.nameContains(["hook"])) { batch in
            collected.append(batch)
            if batch.isComplete { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
        let batches = collected.batches
        XCTAssertEqual(batches.count, 2)
        let first = try XCTUnwrap(batches.first)
        XCTAssertFalse(first.batch.isComplete)
        XCTAssertEqual(first.batch.hits.map(\.path), ["/a/hook.py"], "到期限先交已经回来的")
        XCTAssertLessThan(first.after, 0.3, "不等卡住的那个（它 0.6 秒才回来）")
        XCTAssertEqual(batches.last?.batch.hits.count, 2, "后到的照常并入")
    }

    func testNoEarlyBatchWhenEverythingIsQuick() {
        let a = FakeFileSearch(delay: 0, hits: [LauncherFileHit(path: "/a/x")])
        let b = FakeFileSearch(delay: 0.01, hits: [LauncherFileHit(path: "/b/x")])
        let merged = LauncherMergedFileSearch(sources: [.init(name: "a", origin: .scanned, backend: a),
                                                        .init(name: "b", origin: .clipboard, backend: b)],
                                              firstBatchDeadline: 0.5)
        let batches = search(merged, .nameContains(["x"]))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(batches.map(\.hits.count), [2], "都在期限内回来：照旧凑齐了交一次")
    }

    // MARK: - 换表后只重查内存来源（PR 11 复查后定）

    func testRequeryAfterCompleteKeepsSpotlightRows() throws {
        let spotlight = FakeFileSearch(delay: 0.05, hits: [LauncherFileHit(path: "/Users/me/proj/hook.py")])
        let memory = LauncherMemoryFileSearch(label: "test.requery", verifiesExistence: false)
        memory.replace(LauncherFileCatalog(files: [.init(path: "/private/tmp/c/old-hook.py")]))
        let merged = LauncherMergedFileSearch(sources: [
            .init(name: "spotlight", origin: .spotlight, backend: spotlight, delay: 0.02),
            .init(name: "scanned", origin: .scanned, backend: memory),
        ])
        let collected = BatchCollector()
        let first = expectation(description: "first complete")
        let second = expectation(description: "requery complete")
        merged.search(.nameContains(["hook"])) { batch in
            collected.append(batch)
            guard batch.isComplete else { return }
            if collected.batches.filter(\.isComplete).count == 1 { first.fulfill() } else { second.fulfill() }
        }
        wait(for: [first], timeout: 5)
        let before = collected.batches.count
        memory.replace(LauncherFileCatalog(files: [.init(path: "/private/tmp/c/old-hook.py"), .init(path: "/private/tmp/c/new-hook.py")]))
        merged.requeryImmediateSources()
        wait(for: [second], timeout: 5)
        let after = Array(collected.batches.dropFirst(before))
        XCTAssertFalse(after.isEmpty)
        for batch in after {
            XCTAssertTrue(batch.hits.contains { $0.path == "/Users/me/proj/hook.py" }, "换表后交出的每一批都还有 Spotlight 的行")
        }
        XCTAssertEqual(Set(try XCTUnwrap(after.last).hits.map(\.path)),
                       ["/Users/me/proj/hook.py", "/private/tmp/c/old-hook.py", "/private/tmp/c/new-hook.py"], "新表的结果换上了")
        XCTAssertEqual(spotlight.searchCount, 1, "Spotlight 不重查")
    }

    func testRequeryWhileSpotlightIsOnItsWayLetsItFinish() throws {
        let spotlight = FakeFileSearch(delay: 0.3, hits: [LauncherFileHit(path: "/Users/me/proj/hook.py")])
        let memory = LauncherMemoryFileSearch(label: "test.requery2", verifiesExistence: false)
        let merged = LauncherMergedFileSearch(sources: [
            .init(name: "spotlight", origin: .spotlight, backend: spotlight, delay: 0.02),
            .init(name: "scanned", origin: .scanned, backend: memory),
        ])
        let collected = BatchCollector()
        let done = expectation(description: "complete")
        merged.search(.nameContains(["hook"])) { batch in
            collected.append(batch)
            if batch.isComplete { done.fulfill() }
        }
        Thread.sleep(forTimeInterval: 0.1)   // Spotlight 已经发出去、还在路上
        memory.replace(LauncherFileCatalog(files: [.init(path: "/private/tmp/c/hook.py")]))
        merged.requeryImmediateSources()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(spotlight.searchCount, 1, "还在路上的 Spotlight 不取消、不重发")
        XCTAssertEqual(spotlight.cancelCount, 0)
        let last = try XCTUnwrap(collected.batches.last)
        XCTAssertEqual(Set(last.hits.map(\.path)), ["/Users/me/proj/hook.py", "/private/tmp/c/hook.py"])
        XCTAssertEqual(collected.batches.filter(\.isComplete).count, 1)
    }

    func testRequeryAfterCancelDoesNothing() {
        let memory = FakeFileSearch(delay: 0, hits: [LauncherFileHit(path: "/a/x")])
        let merged = LauncherMergedFileSearch(sources: [.init(name: "scanned", origin: .scanned, backend: memory)])
        _ = search(merged, .nameContains(["x"]))
        merged.cancel()
        merged.requeryImmediateSources()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(memory.searchCount, 1, "取消了的查询不重查")
    }

    func testDelayedSourceIsDebounced() {
        let spotlight = FakeFileSearch(delay: 0, hits: [LauncherFileHit(path: "/u/abc.txt")])
        let memory = FakeFileSearch(delay: 0, hits: [])
        let merged = LauncherMergedFileSearch(sources: [
            .init(name: "spotlight", origin: .spotlight, backend: spotlight, delay: 0.15),
            .init(name: "scanned", origin: .scanned, backend: memory),
        ])
        let collected = BatchCollector()
        for word in ["a", "ab"] {
            merged.search(.nameContains([word])) { collected.append($0) }
            Thread.sleep(forTimeInterval: 0.03)
        }
        let done = expectation(description: "last")
        merged.search(.nameContains(["abc"])) { batch in
            collected.append(batch)
            if batch.isComplete { done.fulfill() }
        }
        wait(for: [done], timeout: 5)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(memory.searchCount, 3, "内存里的来源每次输入都立刻查")
        XCTAssertEqual(spotlight.searchCount, 1, "有延迟的来源只在输入停下后查一次")
        XCTAssertEqual(collected.batches.filter(\.isComplete).count, 1)
    }

    func testMergedSearchDropsStaleResults() throws {
        let backend = FakeFileSearch(delay: 0.2, hits: [LauncherFileHit(path: "/a/old.txt")])
        let merged = LauncherMergedFileSearch(sources: [.init(name: "a", origin: .spotlight, backend: backend)])
        let collected = BatchCollector()
        merged.search(.nameContains(["old"])) { collected.append($0) }
        merged.cancel()
        let expectation = expectation(description: "second")
        merged.search(.nameContains(["new"])) { batch in
            collected.append(batch)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(collected.batches.count, 1, "取消了的、被顶掉的不再交")
        XCTAssertEqual(backend.cancelCount, 1)
    }

    func testMergedSearchWithoutSourcesCompletesEmpty() {
        let batches = search(LauncherMergedFileSearch(sources: []), .nameContains(["x"]))
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.hits.count, 0)
    }
}

/// 收集回调（回调在别的线程）。
private final class BatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LauncherFileSearchBatch] = []

    func append(_ batch: LauncherFileSearchBatch) {
        lock.lock()
        storage.append(batch)
        lock.unlock()
    }

    var batches: [LauncherFileSearchBatch] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 收集回调和它到的时间（从建这个收集器起算，秒）。
private final class TimedBatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let start = DispatchTime.now().uptimeNanoseconds
    private var storage: [(batch: LauncherFileSearchBatch, after: TimeInterval)] = []

    func append(_ batch: LauncherFileSearchBatch) {
        lock.lock()
        storage.append((batch, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000))
        lock.unlock()
    }

    var batches: [(batch: LauncherFileSearchBatch, after: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 假的后端：过一会儿交回固定的命中；被取消 / 顶掉的不交。
private final class FakeFileSearch: LauncherFileSearching, @unchecked Sendable {
    private let delay: TimeInterval
    private let hits: [LauncherFileHit]
    private let lock = NSLock()
    private var generation = 0
    private(set) var cancelCount = 0
    private(set) var searchCount = 0

    init(delay: TimeInterval, hits: [LauncherFileHit]) {
        self.delay = delay
        self.hits = hits
    }

    func search(_ request: LauncherFileSearchRequest, completion: @escaping @Sendable (LauncherFileSearchBatch) -> Void) {
        lock.lock()
        generation += 1
        searchCount += 1
        let ticket = generation
        lock.unlock()
        let hits = hits
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock()
            let current = ticket == generation
            lock.unlock()
            guard current else { return }
            completion(LauncherFileSearchBatch(hits: hits, totalCount: hits.count, elapsed: delay, timedOut: false))
        }
    }

    func cancel() {
        lock.lock()
        generation += 1
        cancelCount += 1
        lock.unlock()
    }
}
