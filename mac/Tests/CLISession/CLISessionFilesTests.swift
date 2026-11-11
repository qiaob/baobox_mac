import Foundation
import XCTest

/// 两种列会话文件的办法与清理旧会话。都在临时目录里做，不碰真实的 `~/.claude` / `~/.codex`。
final class CLISessionFilesTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try makeSessionTestDirectory(self)
    }

    private func write(_ relativePath: String, _ contents: String = "{}", modified: Date = sessionTestTime()) throws {
        try writeSessionTestFile(relativePath, contents, modified: modified, under: root)
    }

    private func makeDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relativePath, isDirectory: true),
                                                withIntermediateDirectories: true)
    }

    private func relativePaths(_ files: [CLISessionFile], under base: URL) -> Set<String> {
        let prefix = base.resolvingSymlinksInPath().path + "/"
        return Set(files.map { $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: "") })
    }

    private func existingFiles() -> Set<String> {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        var paths: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                paths.insert(url.resolvingSymlinksInPath().path.replacingOccurrences(of: prefix, with: ""))
            }
        }
        return paths
    }

    // MARK: - 两层（Claude Code：projects/<项目>/<会话>.jsonl）

    func testSubdirectoryListingLooksOneLevelDownOnly() throws {
        try write("loose.jsonl")                       // 根目录下的文件不算
        try write("app/one.jsonl")
        try write("app/notes.txt")                     // 不是 .jsonl
        try write("app/.draft.jsonl")                  // 隐藏文件
        try write("app/subagents/deep.jsonl")          // 孙目录不进
        try write(".hidden-project/two.jsonl")         // 隐藏目录
        try write("tool/three.jsonl")
        try makeDirectory("app/folder.jsonl")          // 名叫 x.jsonl 的目录照列（记录现状），读不了由格式的 scan 跳过

        let files = CLISessionFiles.jsonlInSubdirectories(of: root)

        XCTAssertEqual(relativePaths(files, under: root), ["app/one.jsonl", "app/folder.jsonl", "tool/three.jsonl"])
    }

    func testSubdirectoryListingCarriesModifiedTimeAndSize() throws {
        let modified = sessionTestTime(-3_600)
        try write("app/one.jsonl", "0123456789", modified: modified)

        let files = CLISessionFiles.jsonlInSubdirectories(of: root)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.size, 10)
        XCTAssertEqual(files.first?.modified, modified)
    }

    func testSubdirectoryListingOfAMissingRootIsEmpty() {
        XCTAssertEqual(CLISessionFiles.jsonlInSubdirectories(of: root.appendingPathComponent("missing")), [])
    }

    // MARK: - 递归（Codex：sessions/YYYY/MM/DD/rollout-*.jsonl）

    func testRecursiveListingFindsRegularJSONLFilesAtAnyDepth() throws {
        try write("top.jsonl")
        try write("2026/11/10/rollout-a.jsonl")
        try write("2026/11/10/notes.txt")
        try write("2026/11/10/.partial.jsonl")         // 隐藏文件
        try write(".cache/x.jsonl")                    // 隐藏目录整个跳过
        try write("folder.jsonl/inner.jsonl")          // 名叫 x.jsonl 的目录本身不算，里面的文件照找

        let files = CLISessionFiles.jsonlRecursively(under: root)

        XCTAssertEqual(relativePaths(files, under: root),
                       ["top.jsonl", "2026/11/10/rollout-a.jsonl", "folder.jsonl/inner.jsonl"])
    }

    func testRecursiveListingCarriesModifiedTimeAndSize() throws {
        let modified = sessionTestTime(-60)
        try write("2026/11/10/rollout-a.jsonl", "abc", modified: modified)

        let files = CLISessionFiles.jsonlRecursively(under: root)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.size, 3)
        XCTAssertEqual(files.first?.modified, modified)
    }

    func testRecursiveListingOfAMissingRootIsEmpty() {
        XCTAssertEqual(CLISessionFiles.jsonlRecursively(under: root.appendingPathComponent("missing")), [])
    }

    // MARK: - 清理旧会话

    func testRemoveJSONLDeletesOnlyFilesOlderThanTheCutoff() throws {
        let now = sessionTestTime()
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        try write("app/old.jsonl", "12345", modified: cutoff.addingTimeInterval(-1))
        try write("app/nested/older.jsonl", "1234567", modified: now.addingTimeInterval(-90 * 86_400))
        try write("app/at-cutoff.jsonl", "1", modified: cutoff)                       // 正好在线上：不删
        try write("app/fresh.jsonl", "1", modified: cutoff.addingTimeInterval(1))
        try write("app/old-notes.txt", "1", modified: now.addingTimeInterval(-90 * 86_400))
        try write("app/.old-hidden.jsonl", "1", modified: now.addingTimeInterval(-90 * 86_400))

        let result = CLISessionFiles.removeJSONL(under: root, olderThanDays: 30, now: now)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.bytes, 12)
        XCTAssertEqual(existingFiles(),
                       ["app/at-cutoff.jsonl", "app/fresh.jsonl", "app/old-notes.txt", "app/.old-hidden.jsonl"])
    }

    func testRemoveJSONLOnAMissingRootRemovesNothing() {
        let result = CLISessionFiles.removeJSONL(under: root.appendingPathComponent("missing"), olderThanDays: 0)
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.bytes, 0)
    }
}
