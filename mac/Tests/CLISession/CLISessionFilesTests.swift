import Foundation
import XCTest

/// 两种列会话文件的办法与清理旧会话。都在临时目录里做，不碰真实的 `~/.claude` / `~/.codex`。
/// #164 PR6 起审计、调用统计、最近文件索引、Codex 用量与磁盘统计也改用这两个函数：「和原来手写的遍历逐项相同」那两条
/// 拿原来的写法当参照，连先后、修改时间、大小一起比。
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

    /// 审计、Claude 调用统计、最近文件索引原来各自手写的两层遍历（#164 PR6 之前）：列出来的文件、先后、修改时间与大小都和它相同，
    /// 文件的上级目录名就是原来的项目目录名（munged，取不到 cwd 时反推项目路径用）。
    func testSubdirectoryListingMatchesTheHandWrittenWalkItReplaced() throws {
        try writeProjectFixture()

        let files = CLISessionFiles.jsonlInSubdirectories(of: root)
        let reference = handWrittenTwoLevelWalk(root)

        XCTAssertEqual(files.count, 12)
        XCTAssertEqual(files, reference.map(\.file), "同样的文件、同样的先后、同样的修改时间与大小")
        XCTAssertEqual(files.map { $0.url.deletingLastPathComponent().lastPathComponent }, reference.map(\.projectDirectory))
    }

    private func writeProjectFixture() throws {
        for (index, project) in ["-Users-me-work-app", "-Users-me-work-tool", "-Users-me-notes", "-tmp-scratch"].enumerated() {
            for session in 0..<3 {
                let name = UUID().uuidString.lowercased()
                try write("\(project)/\(name).jsonl", String(repeating: "x", count: index * 10 + session),
                          modified: sessionTestTime(Double(-index * 3_600 - session * 60)))
            }
            try write("\(project)/memory.md")                          // 不是 .jsonl
            try write("\(project)/\(UUID().uuidString.lowercased())/subagents/agent.jsonl")   // 孙目录不进
        }
        try write("loose.jsonl")
        try write(".hidden/one.jsonl")
    }

    /// 原来三处的写法（`ClaudeFileIndex.scanAll` 那份：取不到修改时间 / 大小记 1970 / 0）。
    private func handWrittenTwoLevelWalk(_ root: URL) -> [(file: CLISessionFile, projectDirectory: String)] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [(file: CLISessionFile, projectDirectory: String)] = []
        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                result.append((
                    CLISessionFile(url: file,
                                   modified: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                                   size: Int64(values?.fileSize ?? 0)),
                    projectDir.lastPathComponent
                ))
            }
        }
        return result
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

    /// Codex 用量、调用统计与磁盘统计原来各自手写的递归遍历（#164 PR6 之前）：列出来的文件与先后和它相同，修改时间与大小照实。
    func testRecursiveListingMatchesTheHandWrittenWalkItReplaced() throws {
        for (day, count) in [("2026/11/09", 2), ("2026/11/10", 3), ("2026/10/31", 1)] {
            for index in 0..<count {
                try write("\(day)/rollout-2026-11-10T08-0\(index)-\(UUID().uuidString.lowercased()).jsonl",
                          String(repeating: "y", count: 5 + index), modified: sessionTestTime(Double(-index * 600)))
            }
        }
        try write("2026/11/10/notes.txt")
        try write("2026/11/10/.partial.jsonl")
        try write(".cache/x.jsonl")
        try makeDirectory("2026/11/10/folder.jsonl")

        let files = CLISessionFiles.jsonlRecursively(under: root)
        let reference = handWrittenRecursiveWalk(root)

        XCTAssertEqual(files.count, 6)
        XCTAssertEqual(files.map(\.url), reference.map(\.url), "同样的文件、同样的先后")
        XCTAssertEqual(files.map { Optional($0.modified) }, reference.map(\.modified))
        XCTAssertEqual(files.map(\.size), reference.map(\.size))
        let totalBytes: Int64 = files.reduce(0) { $0 + $1.size }
        XCTAssertEqual(totalBytes, 34, "磁盘统计按它加总：5 + 6、5 + 6 + 7、5")
    }

    /// 原来三处的写法（Codex 用量那份：枚举器、只要普通文件；大小另取）。
    private func handWrittenRecursiveWalk(_ root: URL) -> [(url: URL, modified: Date?, size: Int64)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [(url: URL, modified: Date?, size: Int64)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            result.append((url, values?.contentModificationDate, Int64(size)))
        }
        return result
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
