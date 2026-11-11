import Foundation
import XCTest

/// `Shell.quote`（拼进 shell 命令的单引号转义）与 `Shell.output`（跑小命令取 stdout），docs/codex-assistant/DEDUPE-P2.md §2.4 类 4、类 5。
/// 转义的结果交给真的 zsh / sh 回读一遍：读回来的必须与原串逐字节相同。
final class ShellTests: XCTestCase {

    /// 刁钻输入：单引号（含连续、首尾）、空格、换行与回车、`$` 与反引号、反斜杠、双引号、glob、`!`、`%`、`-` 开头、非 ASCII。
    private let trickyStrings = [
        "",
        "plain",
        "with space",
        "it's",
        "'",
        "''",
        "'leading and trailing'",
        "a''b'''c",
        "$HOME $(id) ${PATH}",
        "`id`",
        "back\\slash \\n \\'",
        "\"double\" quotes",
        "line1\nline2\n",
        "carriage\rreturn\ttab",
        "*?[a-z]~ {a,b}",
        "!! !$ history",
        "100% %s %d",
        "-n",
        "--resume 0b1d-4f",
        "/Users/o'neil/My Projects/中文 目录",
        "emoji 🎉 é e\u{301} ß",
        "; rm -rf / # && || | > < &"
    ]

    // MARK: - quote

    func testQuoteWrapsInSingleQuotes() {
        XCTAssertEqual(Shell.quote("abc"), "'abc'")
        XCTAssertEqual(Shell.quote("with space"), "'with space'")
    }

    func testQuoteOfEmptyStringIsAPairOfQuotes() {
        XCTAssertEqual(Shell.quote(""), "''")
    }

    func testQuoteWritesInnerSingleQuotesAsCloseEscapeReopen() {
        XCTAssertEqual(Shell.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(Shell.quote("'"), "''\\'''")
        XCTAssertEqual(Shell.quote("''"), "''\\'''\\'''")
    }

    func testQuoteLeavesEverythingElseVerbatim() {
        let text = "$HOME `id` \\n\n中文 \"x\""
        XCTAssertEqual(Shell.quote(text), "'" + text + "'")
    }

    func testZshReadsQuotedTextBackByteForByte() throws {
        try assertShellReadsBack("/bin/zsh", options: ["-f"])   // -f：不读用户的 .zshenv 等启动文件
    }

    func testShReadsQuotedTextBackByteForByte() throws {
        try assertShellReadsBack("/bin/sh")
    }

    /// 每个刁钻串转义后拼成 `printf %s <转义>` 写进脚本文件，交给 shell 跑，stdout 与原串的 UTF-8 字节逐个相同。
    /// 走脚本文件而不是 `-c` 参数：Foundation 的 `Process` 会把参数按 NFD 分解（é → e + ◌́），脚本文件逐字节原样
    /// （续接用的 `.command` 也是脚本文件）。
    private func assertShellReadsBack(_ shell: String, options: [String] = [],
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaoboxShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("printf.sh")
        for text in trickyStrings {
            try Data(("printf %s " + Shell.quote(text) + "\n").utf8).write(to: script)
            let output = try run(shell, options + [script.path])
            XCTAssertEqual(output, Data(text.utf8), "\(shell) 读回来的与原串不同：\(text.debugDescription)",
                           file: file, line: line)
        }
    }

    /// 测试自己起子进程（不借 `Shell.output`，免得两边一起错时互相掩盖）。
    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    // MARK: - output

    func testOutputReadsStdout() {
        XCTAssertEqual(Shell.output("/bin/echo", ["hello", "world"]), "hello world\n")
    }

    func testOutputPassesArgumentsWithoutAShell() {
        XCTAssertEqual(Shell.output("/bin/echo", ["$HOME", "`id`", "a b"]), "$HOME `id` a b\n")
    }

    func testOutputIgnoresTheExitCodeAndDropsStderr() {
        XCTAssertEqual(Shell.output("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"]), "out\n")
    }

    func testOutputOfAnExecutableThatCannotStartIsNil() {
        XCTAssertNil(Shell.output("/nonexistent-baobox-shell-tests/tool", []))
    }

    /// 输出比管道缓冲（64 KB）大很多：先读完 stdout 再等退出，不会把子进程卡死。
    func testOutputReadsMoreThanAPipeBuffer() {
        let output = Shell.output("/bin/sh", ["-c", "yes 0123456789 | head -c 300000"])
        XCTAssertEqual(output?.utf8.count, 300_000)
    }

    func testOutputThatIsNotUTF8IsNil() {
        XCTAssertNil(Shell.output("/usr/bin/printf", ["\\200\\377"]))
    }
}
