import Combine
import Foundation
import XCTest

/// 会话索引基类：刷新、复用、删除、导出、清理、磁盘缓存。假格式指向每个测试自己的临时目录，
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

    func testRefreshWhileOneIsRunningIsIgnored() throws {
        // 记录现状：进行中再调直接丢弃（DEDUPE.md §5.2 C4；PR4 改成「结束后补刷一次」时这条跟着改）。
        try prepare(FakeCachedFormat.root)
        let index = CLISessionIndex<FakeCachedFormat>()

        index.refresh()
        index.refresh()
        spinMainRunLoop { !index.isRefreshing }

        XCTAssertEqual(FakeCachedFormat.root.scans, 3, "第二次调用没有再扫一遍")
        XCTAssertEqual(index.sessions.count, 3)
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
        spinMainRunLoop { self.cachedRecords()?.count == 2 }
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

    func testFlushWritesACacheThatANewIndexStartsFrom() throws {
        try prepare(FakeCachedFormat.root)
        let first = refreshed(CLISessionIndex<FakeCachedFormat>())
        first.flushCache()
        spinMainRunLoop { self.cachedRecords()?.count == 3 }

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
