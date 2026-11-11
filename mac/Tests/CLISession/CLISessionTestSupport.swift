import Foundation
import XCTest

// 会话索引共用层的测试夹具：假的摘要 / 记录 / 格式、临时目录、等主线程回调的小工具。
// 真实的 Claude / Codex 格式留在各自模块里（不编进测试）；这里的假格式照真的那样自己读文件：
// 会话文件是一行 JSON {"title": "…", "activity": <秒>}，没有 activity 就拿文件修改时间当最后活动时间。

/// 假摘要：项目 = 会话文件所在目录。
struct FakeSessionSummary: CLISessionSummary, Equatable {
    let id: String
    let fileURL: URL
    let projectPath: String
    let projectName: String
    let title: String
    let lastActivity: Date

    static func make(_ record: FakeSessionRecord, fileURL: URL) -> FakeSessionSummary {
        let projectPath = fileURL.deletingLastPathComponent().path
        return FakeSessionSummary(
            id: fileURL.deletingPathExtension().lastPathComponent,
            fileURL: fileURL,
            projectPath: projectPath,
            projectName: CLISessionPaths.projectName(fromPath: projectPath),
            title: record.title,
            lastActivity: Date(timeIntervalSince1970: record.activity)
        )
    }
}

/// 假缓存记录。
struct FakeSessionRecord: CLISessionRecord, Equatable {
    let modified: Double
    let size: Int64
    let title: String
    let activity: Double
}

/// 只给 `CLISessionScanner` 用的格式：文件清单与扫描都由测试直接传，这里只负责「记录 → 摘要」。
enum FakeScannerFormat: CLISessionFormat {
    static func sessionFiles() -> [CLISessionFile] { [] }
    static func scan(_ file: CLISessionFile) -> FakeSessionRecord? { nil }
    static func summary(of record: FakeSessionRecord, fileURL: URL) -> FakeSessionSummary {
        FakeSessionSummary.make(record, fileURL: fileURL)
    }
    static var cacheFileURL: URL? { nil }
    static var logRoot: URL { URL(fileURLWithPath: "/nonexistent-baobox-cli-session-tests", isDirectory: true) }
    static func markdown(fileURL: URL, title: String) -> String? { nil }
}

/// 假格式的根目录与扫描计数。格式全是静态成员、没法按实例传参，所以每个测试开头把它指向自己的临时目录。
final class FakeFormatRoot: @unchecked Sendable {
    private let lock = NSLock()
    private var url = URL(fileURLWithPath: "/nonexistent-baobox-cli-session-tests", isDirectory: true)
    private var scanCount = 0

    var current: URL { lock.withLock { url } }
    var scans: Int { lock.withLock { scanCount } }

    func use(_ newURL: URL) {
        lock.withLock {
            url = newURL
            scanCount = 0
        }
    }

    func resetScans() { lock.withLock { scanCount = 0 } }
    func countScan() { lock.withLock { scanCount += 1 } }
}

/// 读磁盘的假格式：会话在 `<根>/logs/<项目>/<会话>.jsonl`（与 Claude Code 同样的两层布局）。
protocol FakeDiskFormat: CLISessionFormat where Summary == FakeSessionSummary, Record == FakeSessionRecord {
    static var root: FakeFormatRoot { get }
}

extension FakeDiskFormat {
    static var logRoot: URL { root.current.appendingPathComponent("logs", isDirectory: true) }

    static func sessionFiles() -> [CLISessionFile] {
        CLISessionFiles.jsonlInSubdirectories(of: logRoot)
    }

    static func scan(_ file: CLISessionFile) -> FakeSessionRecord? {
        root.countScan()
        guard let data = try? Data(contentsOf: file.url),
              let object = CLIJSONL.parseObject(data),
              let title = object["title"] as? String else { return nil }
        let activity = (object["activity"] as? Double) ?? file.modified.timeIntervalSince1970
        return FakeSessionRecord(modified: file.modified.timeIntervalSince1970, size: file.size, title: title, activity: activity)
    }

    static func summary(of record: FakeSessionRecord, fileURL: URL) -> FakeSessionSummary {
        FakeSessionSummary.make(record, fileURL: fileURL)
    }

    static func markdown(fileURL: URL, title: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return nil }
        return "# \(title)\n\n\(text)"
    }
}

/// 落盘缓存的假格式（像 Claude Code）：缓存在 `<根>/support/index-cache.json`。
enum FakeCachedFormat: FakeDiskFormat {
    static let root = FakeFormatRoot()
    static var cacheFileURL: URL? {
        root.current.appendingPathComponent("support", isDirectory: true).appendingPathComponent("index-cache.json")
    }
}

/// 只在内存缓存的假格式（像 Codex）。
enum FakeUncachedFormat: FakeDiskFormat {
    static let root = FakeFormatRoot()
    static var cacheFileURL: URL? { nil }
}

/// 经子类用索引（模块里的 `ClaudeSessionIndex` / `CodexSessionIndex` 都是非泛型子类）。
final class FakeSessionIndex: CLISessionIndex<FakeCachedFormat> {}

/// 新建一个随机临时目录（测试结束时删掉）。
func makeSessionTestDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("baobox-cli-session-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: url)
    }
    return url
}

/// 在 `root` 下写一个文件（建好中间目录）并把修改时间设成 `modified`。返回文件 URL。
@discardableResult
func writeSessionTestFile(_ relativePath: String, _ contents: String, modified: Date, under root: URL) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
}

/// 写一个假格式认得的会话文件（`logs/` 下的相对路径）。
@discardableResult
func writeFakeSession(
    _ relativePath: String,
    title: String,
    activity: Double? = nil,
    modified: Date,
    in root: URL
) throws -> URL {
    var object: [String: Any] = ["title": title]
    if let activity { object["activity"] = activity }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let text = String(decoding: data, as: UTF8.self)
    return try writeSessionTestFile("logs/" + relativePath, text, modified: modified, under: root)
}

/// 转主线程的 RunLoop 直到条件成立：索引在后台扫完后经 `DispatchQueue.main` 回写，而测试就跑在主线程上。
@MainActor
func spinMainRunLoop(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    until condition: () -> Bool
) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("等了 \(timeout) 秒条件仍不成立", file: file, line: line)
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}

/// 转主线程的 RunLoop 一段固定时间（确认「什么也没发生」时用）。
@MainActor
func spinMainRunLoop(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
}

/// 2026-11-10 08:00:00 UTC 起的第 `offset` 秒（测试里的「现在」附近）。
func sessionTestTime(_ offset: TimeInterval = 0) -> Date {
    Date(timeIntervalSince1970: 1_794_297_600 + offset)
}
