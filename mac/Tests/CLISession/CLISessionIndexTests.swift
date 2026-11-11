import Combine
import Foundation
import XCTest

/// 会话索引基类：刷新（含进行中再请求的合并）、复用、删除、导出、清理、磁盘缓存（含同步 flush）。假格式指向每个测试自己的临时目录，
/// 后台扫描经 `DispatchQueue.main` 回写，测试转主线程 RunLoop 等它。
@MainActor
final class CLISessionIndexTests: XCTestCase {

    // MARK: - 夹具

    /// 建临时目录、把假格式指向它，写三个会话：app 下两个、tool 下一个（最后活动时间 tool > app/b > app/a）。
    @discardableResult
    private func prepare(_ root: FakeFormatRoot, sessions: Bool = true) throws -> URL {
        let directory = try makeSessionTestDirectory(self)
        root.use(directory)
        if sessions {
            try writeFakeSession("app/a.jsonl", title: "修登录页", activity: 1_000, modified: sessionTestTime(-300), in: directory)
            try writeFakeSession("app/b.jsonl", title: "写周报", activity: 2_000, modified: sessionTestTime(-200), in: directory)
            try writeFakeSession("tool/c.jsonl", title: "调构建脚本", activity: 3_000, modified: sessionTestTime(-100), in: directory)
        }
        return directory
    }

    private func refreshed<Format: CLISessionFormat>(_ index: CLISessionIndex<Format>) -> CLISessionIndex<Format> {
        index.refresh()
        spinMainRunLoop { !index.isRefreshing }
        return index
    }

    /// 缓存文件里的记录；文件还没写出来或写到一半时为 nil。
    private func cachedRecords() -> [String: FakeSessionRecord]? {
        guard let url = FakeCachedFormat.cacheFileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: FakeSessionRecord].self, from: data)
    }

    // MARK: - 刷新

    func testRefreshPublishesSessionsNewestFirstAndStopsTheSpinner() throws {
        try prepare(FakeCachedFormat.root)
        let index = CLISessionIndex<FakeCachedFormat>()
        XCTAssertTrue(index.sessions.isEmpty)

        index.refresh()
        XCTAssertTrue(index.isRefreshing)
        spinMainRunLoop { !index.isRefreshing }

        XCTAssertEqual(index.sessions.map(\.id), ["c", "b", "a"])
        XCTAssertEqual(index.sessions.map(\.title), ["调构建脚本", "写周报", "修登录页"])
        XCTAssertEqual(index.sessions.map(\.projectName), ["tool", "app", "app"])
        XCTAssertEqual(FakeCachedFormat.root.scans, 3)
    }

    func testRequestsWhileARefreshIsRunningAddExactlyOneMorePass() throws {
        // DEDUPE.md §5.2 C4：进行中再来的请求不丢，这一轮结束后补一轮；来几次都只补一轮（PR1 时直接丢弃）。
        try prepare(FakeCachedFormat.root)
        let index = CLISessionIndex<FakeCachedFormat>()

        index.refresh()
        index.refresh()   // 主线程还没让出去，后台那一轮回不来：这三次都撞在进行中
        index.refresh()
        index.refresh()
        spinMainRunLoop { !index.isRefreshing }   // 补的那一轮是在同一个主线程回合里接着发起的，转圈熄了就是全跑完了

        XCTAssertEqual(FakeCachedFormat.root.listings, 2, "补了一轮，只补一轮")
        XCTAssertEqual(FakeCachedFormat.root.scans, 3, "补的那一轮复用上一轮扫出来的记录，没变的文件不再读")
        XCTAssertEqual(index.sessions.map(\.id), ["c", "b", "a"])
    }

    /// 删除撞上一轮进行中的刷新、删完又请求刷新（清理旧会话就是这样）：那一轮在删除之前列的目录，它的结果不发布，
    /// 补扫一轮再发布 —— 刚删的会话一刻也不回到列表（DEDUPE.md §5.2 C4；PR1 时第二次请求被吞，旧结果把它放了回来）。
    func testADeleteDuringARefreshIsNotPutBackByThatRefresh() throws {
        try prepare(FakeCachedFormat.root)
        let index = refreshed(CLISessionIndex<FakeCachedFormat>())
        let victim = try XCTUnwrap(index.sessions.first { $0.id == "b" })
        let hold = FakeCachedFormat.root.holdNextListing()

        index.refresh()
        XCTAssertTrue(hold.waitUntilReached(), "这一轮已经列完目录（b 还在里面）")
        var deleted: Bool?
        index.deleteSession(victim) { deleted = $0 }
        spinMainRunLoop { deleted != nil }
        index.refresh()
        var published: [[String]] = []
        let subscription = index.$sessions.dropFirst().sink { published.append($0.map(\.id)) }
        hold.release()
        spinMainRunLoop { !index.isRefreshing }
        subscription.cancel()

        XCTAssertEqual(deleted, true)
        XCTAssertEqual(index.sessions.map(\.id), ["c", "a"])
        XCTAssertEqual(published, [["c", "a"]], "过时的那一轮没有发布")
        XCTAssertEqual(FakeCachedFormat.root.listings, 3, "预热一轮 + 撞上的一轮 + 补的一轮")
        index.flushCache()
        XCTAssertEqual(cachedRecords().map { Set($0.keys) }, Set(index.sessions.map(\.fileURL.path)), "缓存里也没有 b")
    }

    /// 只删除、没人再请求刷新：进行中的那一轮照样补扫一轮，不把刚删的会话放回来。
    func testADeleteDuringARefreshMakesThatRefreshRunAgain() throws {
        try prepare(FakeCachedFormat.root)
        let index = refreshed(CLISessionIndex<FakeCachedFormat>())
        let victim = try XCTUnwrap(index.sessions.first { $0.id == "b" })
        let hold = FakeCachedFormat.root.holdNextListing()

        index.refresh()
        XCTAssertTrue(hold.waitUntilReached())
        var deleted: Bool?
        index.deleteSession(victim) { deleted = $0 }
        spinMainRunLoop { deleted != nil }
        var published: [[String]] = []
        let subscription = index.$sessions.dropFirst().sink { published.append($0.map(\.id)) }
        hold.release()
        spinMainRunLoop { !index.isRefreshing }
        subscription.cancel()

        XCTAssertEqual(index.sessions.map(\.id), ["c", "a"])
        XCTAssertEqual(published, [["c", "a"]])
        XCTAssertEqual(FakeCachedFormat.root.listings, 3)
    }

    func testUnchangedFilesAreNotReadAgain() throws {
        let directory = try prepare(FakeCachedFormat.root)
        let index = refreshed(CLISessionIndex<FakeCachedFormat>())
        XCTAssertEqual(FakeCachedFormat.root.scans, 3)

        try writeFakeSession("app/a.jsonl", title: "修登录页（续）", activity: 4_000, modified: sessionTestTime(-10), in: directory)
        _ = refreshed(index)

        XCTAssertEqual(FakeCachedFormat.root.scans, 4, "只重读改过的那个文件")
        XCTAssertEqual(index.sessions.map(\.title), ["修登录页（续）", "调构建脚本", "写周报"])
    }

    func testChangesThroughASubclassReachObjectWillChange() throws {
        // 模块里的索引都是非泛型子类，@Published 在泛型基类里：经子类实例改，界面照样收到变化。
        try prepare(FakeCachedFormat.root)
        let index = FakeSessionIndex()
        var changes = 0
        let subscription = index.objectWillChange.sink { _ in changes += 1 }

        index.refresh()
        spinMainRunLoop { !index.isRefreshing }

        XCTAssertGreaterThanOrEqual(changes, 2, "isRefreshing 开、sessions 与 isRefreshing 回写")
        XCTAssertEqual(index.sessions.count, 3)
        XCTAssertEqual(FakeSessionIndex.projectName(fromPath: "/Users/me/work/app"), "app", "静态成员经继承照旧能调")
        subscription.cancel()
    }

    // MARK: - 删除 / 导出

    func testDeleteSessionRemovesTheFileTheRowAndTheCacheEntry() throws {
        try prepare(FakeCachedFormat.root)
        let index = refreshed(CLISessionIndex<FakeCachedFormat>())
        let victim = try XCTUnwrap(index.sessions.first { $0.id == "b" })

        var deleted: Bool?
        index.deleteSession(victim) { deleted = $0 }
        spinMainRunLoop { deleted != nil }

        XCTAssertEqual(deleted, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.fileURL.path))
        XCTAssertEqual(index.sessions.map(\.id), ["c", "a"])

        index.flushCache()
        XCTAssertEqual(cachedRecords()?.count, 2, "flush 返回时已经写好")
        XCTAssertNil(cachedRecords()?[victim.fileURL.path], "删掉的会话也出了缓存")

        var deletedAgain: Bool?
        index.deleteSession(victim) { deletedAgain = $0 }
        spinMainRunLoop { deletedAgain != nil }
        XCTAssertEqual(deletedAgain, false, "文件已经没了：删除失败，列表不动")
        XCTAssertEqual(index.sessions.map(\.id), ["c", "a"])
    }

    func testExportHandsTheSessionTitleToTheFormat() throws {
        try prepare(FakeCachedFormat.root)
        let index = refreshed(CLISessionIndex<FakeCachedFormat>())
        let session = try XCTUnwrap(index.sessions.first { $0.id == "a" })

        var markdown: String??
        index.exportMarkdown(session) { markdown = .some($0) }
        spinMainRunLoop { markdown != nil }
        XCTAssertEqual(markdown, .some(#"# 修登录页"# + "\n\n" + #"{"activity":1000,"title":"修登录页"}"#))

        try FileManager.default.removeItem(at: session.fileURL)
        var missing: String??
        index.exportMarkdown(session) { missing = .some($0) }
        spinMainRunLoop { missing != nil }
        XCTAssertEqual(missing, .some(nil), "读失败回调 nil")
    }

    // MARK: - 清理旧会话

    func testCleanupDeletesOldSessionsAndRefreshesBeforeCallingBack() throws {
        let directory = try prepare(FakeCachedFormat.root, sessions: false)
        let now = Date()
        try writeFakeSession("app/old.jsonl", title: "上个月", modified: now.addingTimeInterval(-40 * 86_400), in: directory)
        try writeFakeSession("app/new.jsonl", title: "今天", modified: now, in: directory)
        let oldSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("logs/app/old.jsonl").path)[.size] as? Int
        )
        let index = refreshed(CLISessionIndex<FakeCachedFormat>())
        XCTAssertEqual(index.sessions.count, 2)

        var result: (count: Int, bytes: Int64)?
        var refreshingAtCallback: Bool?
        index.cleanup(olderThanDays: 30) { count, bytes in
            result = (count, bytes)
            refreshingAtCallback = index.isRefreshing
        }
        spinMainRunLoop { result != nil }

        XCTAssertEqual(result?.count, 1)
        XCTAssertEqual(result?.bytes, Int64(oldSize))
        XCTAssertEqual(refreshingAtCallback, true, "先 refresh() 再回调")
        spinMainRunLoop { !index.isRefreshing }
        XCTAssertEqual(index.sessions.map(\.title), ["今天"])
    }

    // MARK: - 磁盘缓存

    /// DEDUPE.md §5.2 C6：`willTerminate` 调完 flush 进程随时会退出，flush 返回时缓存必须已经在盘上（PR1 时写盘派到了后台）。
    func testFlushHasWrittenTheCacheWhenItReturns() throws {
        try prepare(FakeCachedFormat.root)
        let index = refreshed(CLISessionIndex<FakeCachedFormat>())

        index.flushCache()   // 刚刷新完，1 秒防抖还没到：盘上的缓存只可能是 flush 写的

        XCTAssertEqual(cachedRecords().map { Set($0.keys) }, Set(index.sessions.map(\.fileURL.path)))
        XCTAssertEqual(cachedRecords()?.values.map(\.title).sorted(), ["修登录页", "写周报", "调构建脚本"].sorted())
    }

    func testFlushWritesACacheThatANewIndexStartsFrom() throws {
        try prepare(FakeCachedFormat.root)
        let first = refreshed(CLISessionIndex<FakeCachedFormat>())
        first.flushCache()
        XCTAssertEqual(cachedRecords()?.count, 3)

        FakeCachedFormat.root.resetScans()
        let second = refreshed(CLISessionIndex<FakeCachedFormat>())

        XCTAssertEqual(FakeCachedFormat.root.scans, 0, "新实例读入了缓存，三个文件都没变，一个也不用读")
        XCTAssertEqual(second.sessions, first.sessions)
    }

    func testRefreshSavesTheCacheAboutASecondLater() throws {
        try prepare(FakeCachedFormat.root)
        let index = refreshed(CLISessionIndex<FakeCachedFormat>())
        XCTAssertNil(cachedRecords(), "1 秒防抖：刚刷新完还没写")

        // 防抖的落盘只弱引用索引，索引得活着。
        withExtendedLifetime(index) {
            spinMainRunLoop(timeout: 5) { self.cachedRecords()?.count == 3 }
        }
    }

    func testAnUnreadableCacheIsIgnored() throws {
        let directory = try prepare(FakeCachedFormat.root)
        try writeSessionTestFile("support/index-cache.json", "{not json", modified: Date(), under: directory)

        _ = refreshed(CLISessionIndex<FakeCachedFormat>())

        XCTAssertEqual(FakeCachedFormat.root.scans, 3, "坏缓存当没有，全部重扫")
    }

    func testAnIndexWithoutACacheFileWritesNothing() throws {
        let directory = try prepare(FakeUncachedFormat.root)
        let index = refreshed(CLISessionIndex<FakeUncachedFormat>())
        XCTAssertEqual(index.sessions.map(\.id), ["c", "b", "a"])

        index.flushCache()
        spinMainRunLoop(for: 1.3)   // 过了 1 秒防抖也没有写盘

        let written = FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String] ?? []
        XCTAssertEqual(Set(written), ["logs", "logs/app", "logs/app/a.jsonl", "logs/app/b.jsonl", "logs/tool", "logs/tool/c.jsonl"])
    }
}
