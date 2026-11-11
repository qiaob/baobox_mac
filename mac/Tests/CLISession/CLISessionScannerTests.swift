import Foundation
import XCTest

/// 一次刷新的纯逻辑：复用判断、扫描失败、缓存进出、排序。文件清单与扫描都是假的，不碰磁盘。
final class CLISessionScannerTests: XCTestCase {

    private typealias Scanner = CLISessionScanner<FakeScannerFormat>

    private func file(_ name: String, modified: TimeInterval, size: Int64 = 100) -> CLISessionFile {
        CLISessionFile(url: URL(fileURLWithPath: "/sessions/app/\(name).jsonl"),
                       modified: Date(timeIntervalSince1970: modified),
                       size: size)
    }

    private func record(for file: CLISessionFile, title: String? = nil, activity: Double? = nil) -> FakeSessionRecord {
        FakeSessionRecord(modified: file.modified.timeIntervalSince1970,
                          size: file.size,
                          title: title ?? file.url.deletingPathExtension().lastPathComponent,
                          activity: activity ?? file.modified.timeIntervalSince1970)
    }

    /// 按先后记下被扫的文件名。
    private final class ScanLog {
        var scanned: [String] = []
    }

    func testColdStartScansEveryFileAndCachesThemByPath() {
        let files = [file("a", modified: 100), file("b", modified: 300), file("c", modified: 200)]
        let log = ScanLog()

        let result = Scanner.refresh(files: files, previous: [:]) { file in
            log.scanned.append(file.url.lastPathComponent)
            return self.record(for: file)
        }

        XCTAssertEqual(log.scanned, ["a.jsonl", "b.jsonl", "c.jsonl"])
        XCTAssertEqual(result.summaries.map(\.id), ["b", "c", "a"], "新→旧")
        XCTAssertEqual(Set(result.cache.keys), Set(files.map(\.url.path)))
        XCTAssertEqual(result.cache[files[1].url.path], record(for: files[1]))
    }

    func testReusesARecordWhileModifiedTimeAndSizeAreUnchanged() {
        let old = file("a", modified: 100, size: 10)
        let cached = record(for: old, title: "缓存里的标题")

        // 缓存里存的是秒数浮点；差不到 1 ms 算没变（Date 自己的精度约 0.1 µs，正好 1 ms 的边界不稳定，测两侧）。
        let nudged = file("a", modified: 100.0009, size: 10)
        XCTAssertTrue(Scanner.isUnchanged(cached, old))
        XCTAssertTrue(Scanner.isUnchanged(cached, nudged))
        XCTAssertFalse(Scanner.isUnchanged(cached, file("a", modified: 100.0011, size: 10)))
        XCTAssertFalse(Scanner.isUnchanged(cached, file("a", modified: 99.9989, size: 10)))
        XCTAssertFalse(Scanner.isUnchanged(cached, file("a", modified: 100, size: 11)), "大小变了")

        let log = ScanLog()
        let result = Scanner.refresh(files: [nudged], previous: [old.url.path: cached]) { file in
            log.scanned.append(file.url.lastPathComponent)
            return self.record(for: file)
        }
        XCTAssertEqual(log.scanned, [], "没变的文件不读")
        XCTAssertEqual(result.summaries.map(\.title), ["缓存里的标题"])
        XCTAssertEqual(result.cache[old.url.path], cached, "复用的是上一轮的记录本身")
    }

    func testRescansWhenModifiedTimeOrSizeChanges() {
        let a = file("a", modified: 100, size: 10)
        let b = file("b", modified: 100, size: 10)
        let previous = [a.url.path: record(for: a, title: "旧 a"), b.url.path: record(for: b, title: "旧 b")]
        let grownA = file("a", modified: 100, size: 20)
        let touchedB = file("b", modified: 101, size: 10)
        let log = ScanLog()

        let result = Scanner.refresh(files: [grownA, touchedB], previous: previous) { file in
            log.scanned.append(file.url.lastPathComponent)
            return self.record(for: file, title: "新扫的")
        }

        XCTAssertEqual(log.scanned, ["a.jsonl", "b.jsonl"])
        XCTAssertEqual(result.summaries.map(\.title), ["新扫的", "新扫的"])
        XCTAssertEqual(result.cache[a.url.path]?.size, 20)
        XCTAssertEqual(result.cache[b.url.path]?.modified, 101)
    }

    func testAFileThatFailsToScanIsLeftOutAndRetriedNextTime() {
        let good = file("good", modified: 100)
        let broken = file("broken", modified: 200)

        let first = Scanner.refresh(files: [good, broken], previous: [:]) { file in
            file == broken ? nil : self.record(for: file)
        }
        XCTAssertEqual(first.summaries.map(\.id), ["good"])
        XCTAssertNil(first.cache[broken.url.path], "扫失败的不进缓存")

        let log = ScanLog()
        let second = Scanner.refresh(files: [good, broken], previous: first.cache) { file in
            log.scanned.append(file.url.lastPathComponent)
            return self.record(for: file)
        }
        XCTAssertEqual(log.scanned, ["broken.jsonl"], "下一轮只重试扫失败的那个")
        XCTAssertEqual(second.summaries.map(\.id), ["broken", "good"])
    }

    func testFilesThatDisappearLeaveTheCache() {
        let kept = file("kept", modified: 100)
        let gone = file("gone", modified: 200)
        let previous = [kept.url.path: record(for: kept), gone.url.path: record(for: gone)]

        let result = Scanner.refresh(files: [kept], previous: previous) { _ in
            XCTFail("没变的文件不该再扫")
            return nil
        }

        XCTAssertEqual(result.summaries.map(\.id), ["kept"])
        XCTAssertEqual(Array(result.cache.keys), [kept.url.path])
    }

    func testSortsNewestFirstAndKeepsTheListingOrderForTies() {
        // 最后活动时间来自记录（Claude 取会话里的末次时间戳），不一定等于文件修改时间。
        let files = (0..<6).map { file("s\($0)", modified: 1_000 + Double($0)) }
        let activity: [Double] = [50, 70, 50, 90, 70, 50]

        let result = Scanner.refresh(files: files, previous: [:]) { file in
            let index = files.firstIndex(of: file) ?? 0
            return self.record(for: file, activity: activity[index])
        }

        XCTAssertEqual(result.summaries.map(\.id), ["s3", "s1", "s4", "s0", "s2", "s5"])
    }

    func testEmptyListingGivesAnEmptyIndex() {
        let stale = file("stale", modified: 1)
        let result = Scanner.refresh(files: [], previous: [stale.url.path: record(for: stale)])
        XCTAssertTrue(result.summaries.isEmpty)
        XCTAssertTrue(result.cache.isEmpty)
    }
}
