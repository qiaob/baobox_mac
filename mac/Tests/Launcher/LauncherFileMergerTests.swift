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
        XCTAssertEqual(last.hits.map(\.path), ["/private/tmp/c/hook.py", "/Users/me/a/notes.md"], "/tmp 和 /private/tmp 并成一条")
        XCTAssertEqual(last.hits.first?.origins, [.scanned, .spotlight])
        XCTAssertEqual(last.sources.map(\.name), ["spotlight", "scanned", "known"], "各来源的统计按来源的次序")
        XCTAssertEqual(last.sources.map(\.hitCount), [2, 1, 0])
        XCTAssertEqual(last.totalCount, 3)
    }

    func testImmediateSourcesAreDeliveredTogether() throws {
        let a = FakeFileSearch(delay: 0, hits: [LauncherFileHit(path: "/a/x.txt")])
        let b = FakeFileSearch(delay: 0.05, hits: [LauncherFileHit(path: "/b/x.txt")])
        let spotlight = FakeFileSearch(delay: 0, hits: [])
        let merged = LauncherMergedFileSearch(sources: [
            .init(name: "spotlight", origin: .spotlight, backend: spotlight, delay: 0.2),
            .init(name: "a", origin: .scanned, backend: a),
            .init(name: "b", origin: .clipboard, backend: b),
        ])
        let batches = search(merged, .nameContains(["x"]))
        XCTAssertEqual(batches.map(\.hits.count), [2, 2], "立刻查的两个都回来才交第一次（不是一个一次）；Spotlight 空着回来时补一次完成")
        XCTAssertEqual(batches.map(\.isComplete), [false, true])
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
