import Foundation
import XCTest

/// `TerminalLauncher.run` 写的一次性 `.command` 脚本：内容怎么拼、目录里只留最近 20 个（docs/codex-assistant/DEDUPE-P2.md §2.4 类 5）。
/// 文件都在系统临时目录下每个测试自己的随机目录里，不碰真实的 `Baobox/Terminal/launch/`。
final class TerminalLaunchScriptTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaoboxTerminalLaunchScriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        root = directory
    }

    // MARK: - 脚本内容

    func testScriptChangesIntoTheDirectoryThenRunsTheCommand() {
        XCTAssertEqual(TerminalLaunchScript.contents(command: "'claude' --resume 'abc'", directory: "/Users/me/My Project"),
                       "#!/bin/zsh\ncd '/Users/me/My Project'\n'claude' --resume 'abc'\n")
    }

    func testNoDirectoryOrAnEmptyOneMeansNoCd() {
        XCTAssertEqual(TerminalLaunchScript.contents(command: "codex resume x", directory: nil), "#!/bin/zsh\ncodex resume x\n")
        XCTAssertEqual(TerminalLaunchScript.contents(command: "codex resume x", directory: ""), "#!/bin/zsh\ncodex resume x\n")
    }

    func testDirectoryIsSingleQuotedAndTheCommandIsWrittenAsIs() {
        XCTAssertEqual(TerminalLaunchScript.contents(command: "echo \"$HOME\" `id`", directory: "/tmp/o'neil $x"),
                       "#!/bin/zsh\ncd '/tmp/o'\\''neil $x'\necho \"$HOME\" `id`\n")
    }

    /// 真的交给 zsh 跑：目录名里有单引号、空格、`$`、反引号与中文也 cd 得进去。
    func testZshChangesIntoATrickyDirectory() throws {
        let directory = root.appendingPathComponent("it's a $dir `x` 中文", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("launch.command")
        try Data(TerminalLaunchScript.contents(command: "pwd", directory: directory.path).utf8).write(to: script)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", script.path]   // -f：不读用户的 .zshenv 等启动文件
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let printed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(URL(fileURLWithPath: printed).resolvingSymlinksInPath().path,
                       directory.resolvingSymlinksInPath().path)
    }

    // MARK: - 只留最近 20 个

    func testKeepsTwentyScripts() {
        XCTAssertEqual(TerminalLaunchScript.keepCount, 20)
    }

    func testPruneDeletesTheOldestBeyondTheLimit() throws {
        let names = try writeScripts(25)

        TerminalLaunchScript.prune(root, keep: 20)

        XCTAssertEqual(remaining(), Set(names.suffix(20)), "按修改时间删掉最旧的 5 个")
    }

    func testPruneLeavesTheDirectoryAloneAtOrBelowTheLimit() throws {
        let twenty = try writeScripts(20)
        TerminalLaunchScript.prune(root, keep: 20)
        XCTAssertEqual(remaining(), Set(twenty))

        let fewer = try writeScripts(3, prefix: "extra")
        TerminalLaunchScript.prune(root, keep: 30)
        XCTAssertEqual(remaining(), Set(twenty + fewer))
    }

    /// 隐藏文件（`.DS_Store` 之类）不算数、也不删，哪怕它们最旧。
    func testPruneIgnoresHiddenFiles() throws {
        try write(".DS_Store", modified: Date(timeIntervalSince1970: 1_000))
        try write(".older", modified: Date(timeIntervalSince1970: 2_000))
        let names = try writeScripts(22)

        TerminalLaunchScript.prune(root, keep: 20)

        XCTAssertEqual(remaining(), Set(names.suffix(20)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".DS_Store").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".older").path))
    }

    func testPruneOfAMissingDirectoryDoesNothing() {
        let missing = root.appendingPathComponent("missing", isDirectory: true)

        TerminalLaunchScript.prune(missing, keep: 20)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "不替调用方建目录")
    }

    // MARK: - 小工具

    /// 写 count 个脚本，修改时间依次晚一分钟；返回按从旧到新排的文件名。
    private func writeScripts(_ count: Int, prefix: String = "script") throws -> [String] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return try (0..<count).map { offset in
            let name = String(format: "%@-%02d.command", prefix, offset)
            try write(name, modified: start.addingTimeInterval(TimeInterval(offset * 60)))
            return name
        }
    }

    private func write(_ name: String, modified: Date) throws {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/zsh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// 目录里还剩的不隐藏的文件名。
    private func remaining() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") })
    }
}
