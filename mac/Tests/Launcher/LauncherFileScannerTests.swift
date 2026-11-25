import Foundation
import XCTest

/// 快速入口自己扫的目录（docs/launcher/TECH_DESIGN.md §6.4「来源 B」，PR 11）：剪枝规则、根目录的整理、
/// 在临时目录里真的扫一遍（软链不跟、隐藏的和编译产物不进去、包记下不进去、上限）。
final class LauncherFileScannerTests: XCTestCase {

    private let home = "/Users/me"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ relative: String, directory: Bool = false) throws {
        let url = root.appendingPathComponent(relative)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    // MARK: - 规则

    func testDirectoryRules() {
        typealias Rules = LauncherFileScanRules
        XCTAssertEqual(Rules.directory(named: "scratchpad", path: "/private/tmp/c/scratchpad", home: home), .descend)
        for name in ["node_modules", ".git", "DerivedData", "build", "build.noindex", ".build", "Pods", ".Trash", "out.noindex",
                     ".cache", ".venv"] {
            XCTAssertEqual(Rules.directory(named: name, path: "/x/" + name, home: home), .skip, name)
        }
        XCTAssertEqual(Rules.directory(named: "Library", path: "/Users/me/Library", home: home), .skip, "~/Library")
        XCTAssertEqual(Rules.directory(named: "Library", path: "/Users/me/proj/Library", home: home), .descend)
        XCTAssertEqual(Rules.directory(named: "Baobox.app", path: "/x/Baobox.app", home: home), .skip, "App 来源有")
        XCTAssertEqual(Rules.directory(named: "Baobox.xcodeproj", path: "/x/Baobox.xcodeproj", home: home), .recordOnly)
        XCTAssertEqual(Rules.directory(named: "Deck.key", path: "/x/Deck.key", home: home), .recordOnly)
        XCTAssertTrue(Rules.recordsFile(named: "a.py"))
        XCTAssertFalse(Rules.recordsFile(named: ".DS_Store"))
    }

    func testNormalizedRoots() {
        XCTAssertEqual(LauncherFileScanRules.normalizedRoots(["/private/tmp/claude-501/", "relative/dir", "/", " /a/b ",
                                                              "/private/tmp/claude-501/x", "/a", "/private/tmp/claude-501"]),
                       ["/private/tmp/claude-501", "/a"], "去掉相对路径和根；在别的根里面的不重复扫")
    }

    // MARK: - 真的扫一遍

    func testScanPrunesAndRecords() throws {
        try make("scratchpad/add-approval-hook.py")
        try make("scratchpad/notes/报告 final.pdf")
        try make("scratchpad/.hidden.txt")
        try make("scratchpad/.cache/inside.txt")
        try make("proj/node_modules/pkg/index.js")
        try make("proj/build/out.o")
        try make("proj/out.noindex/x.o")
        try make("proj/Tool.app/Contents/Info.plist")
        try make("proj/Tool.xcodeproj/project.pbxproj")
        try make("proj/src/main.swift")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("proj/loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("proj/link.py"),
                                                   withDestinationURL: root.appendingPathComponent("proj/src/main.swift"))

        let (catalog, reports) = LauncherFileScanner.scan(roots: [root.path], home: home)
        let realRoot = try XCTUnwrap(LauncherFileScanner.realPath(root.path))
        let paths = Set(catalog.entries.indices.map { catalog.path(at: $0) })
        let expected: Set<String> = [
            "scratchpad", "scratchpad/add-approval-hook.py", "scratchpad/notes", "scratchpad/notes/报告 final.pdf",
            "proj", "proj/Tool.xcodeproj", "proj/src", "proj/src/main.swift", "proj/link.py",
        ]
        XCTAssertEqual(paths, Set(expected.map { realRoot + "/" + $0 }))
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.root, realRoot, "根解析成真实路径（/var → /private/var）")
        XCTAssertEqual(report.files, 4, "指向文件的软链 link.py 记成普通文件；指向根的 loop 不跟、不记")
        XCTAssertEqual(report.directories, 5)
        XCTAssertEqual(report.prunedDirectories, 6, ".cache、node_modules、build、out.noindex、Tool.app 没进去，Tool.xcodeproj 记下没进去")
        XCTAssertFalse(report.stoppedEarly)
        XCTAssertFalse(report.missing)
        XCTAssertGreaterThan(report.elapsed, 0, "耗时记下来了（原来 defer 在 return 拷走之后才填，永远是 0）")

        let hook = try XCTUnwrap(catalog.entries.indices.first { catalog.entries[$0].name == "add-approval-hook.py" })
        XCTAssertFalse(catalog.entries[hook].isDirectory)
        XCTAssertGreaterThan(catalog.entries[hook].modified, 0, "修改时间来自遍历时的 stat")
        XCTAssertEqual(catalog.matches(.nameContains(["APPROVAL"]), limit: 10).total, 1)
        XCTAssertTrue(catalog.hit(at: catalog.entries.indices.first { catalog.entries[$0].name == "notes" } ?? 0).isDirectory)
    }

    func testSymlinksToFilesAreRecordedOthersAreNot() throws {
        try make("real/target.txt")
        try make("real/dir", directory: true)
        try make("real/dir/inside.txt")
        let links = root.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: links.appendingPathComponent("to-file.txt"),
                                                   withDestinationURL: root.appendingPathComponent("real/target.txt"))
        try FileManager.default.createSymbolicLink(at: links.appendingPathComponent("to-dir"),
                                                   withDestinationURL: root.appendingPathComponent("real/dir"))
        try FileManager.default.createSymbolicLink(at: links.appendingPathComponent("dangling.txt"),
                                                   withDestinationURL: root.appendingPathComponent("nope.txt"))
        let (catalog, _) = LauncherFileScanner.scan(roots: [root.path], home: home)
        let realRoot = try XCTUnwrap(LauncherFileScanner.realPath(root.path))
        let paths = Set(catalog.entries.indices.map { catalog.path(at: $0) })
        XCTAssertTrue(paths.contains(realRoot + "/links/to-file.txt"), "指向文件的软链记成普通文件")
        XCTAssertFalse(paths.contains(realRoot + "/links/to-dir"), "指向目录的不记")
        XCTAssertFalse(paths.contains(realRoot + "/links/to-dir/inside.txt"), "也不跟进去")
        XCTAssertFalse(paths.contains(realRoot + "/links/dangling.txt"), "断了的不记")
        let link = try XCTUnwrap(catalog.entries.indices.first { catalog.entries[$0].name == "to-file.txt" })
        XCTAssertFalse(catalog.entries[link].isDirectory)
        XCTAssertGreaterThan(catalog.entries[link].modified, 0, "修改时间是它指向的文件的")
    }

    func testScanStopsAtTheEntryLimit() throws {
        for index in 0..<30 { try make("many/f\(index).txt") }
        let (catalog, reports) = LauncherFileScanner.scan(roots: [root.path], home: home,
                                                          limits: LauncherFileScanLimits(maxEntriesPerRoot: 10))
        XCTAssertEqual(catalog.count, 10)
        XCTAssertEqual(reports.first?.stoppedEarly, true)
    }

    func testMissingRootIsReported() {
        let (catalog, reports) = LauncherFileScanner.scan(roots: [root.appendingPathComponent("nope").path], home: home)
        XCTAssertEqual(catalog.count, 0)
        XCTAssertEqual(reports.first?.missing, true)
    }

    func testUnreadableFolderIsSkipped() throws {
        try make("open/a.txt")
        try make("locked/secret.txt")
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let (catalog, reports) = LauncherFileScanner.scan(roots: [root.path], home: home)
        let names = Set(catalog.entries.map(\.name))
        XCTAssertTrue(names.contains("a.txt"))
        XCTAssertFalse(names.contains("secret.txt"))
        XCTAssertGreaterThanOrEqual(reports.first?.unreadable ?? 0, 1)
    }
}
