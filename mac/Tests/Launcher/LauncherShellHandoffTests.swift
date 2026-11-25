import Foundation
import XCTest

/// 把文字交给终端时拼的那一行（docs/launcher/TECH_DESIGN.md §5.4，第 10 步）：文字经 `Shell.quote` 后作为一个参数原样到达，
/// 不被拆开、展开、执行；「在终端里运行」和自己在 zsh 里敲那一行一样。这里真的交给 `/bin/zsh -c` 跑一遍（只 printf，没有副作用）。
final class LauncherShellHandoffTests: XCTestCase {

    /// 难缠的输入：单引号、反斜杠、换行、`$()`、反引号、`$变量`、`!`、`*`、以 `-` 开头、只有空格、中文、emoji。
    private let tricky = [
        "it's broken",
        "a\\b\\\\c \\n",
        "第一行\n第二行\n\n第四行",
        "$(rm -rf ~)",
        "`say hi`",
        "$HOME ${PATH} $0 $$",
        "echo hi; exit 1 && false || true | cat > /tmp/x",
        "!! !$ *.swift ~ ?",
        "-x --help",
        "--",
        "   ",
        "报错：TypeError: Cannot read properties of undefined (reading 'map') 🙈",
        "'",
        "''''",
        "\"double\" and 'single'",
        "\t制表符\r\n回车换行",
    ]

    /// 用 zsh 跑一段脚本，取 stdout。`home`：换掉 HOME（看 `cd ~` 落到哪）。
    private func zsh(_ script: String, home: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", script]
        if let home {
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home
            process.environment = environment
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testPromptArrivesAsOneUntouchedArgument() throws {
        // 一个 shell 函数冒充 claude：去掉开头的 `--`，打印参数个数和第一个参数。
        let fake = "fakeclaude() { [[ $1 == -- ]] && shift; printf '%d|%s' $# \"$1\"; }; "
        for text in tricky {
            let line = LauncherShellHandoff.promptLine(binary: "fakeclaude", prompt: text)
            XCTAssertEqual(try zsh(fake + line), "1|" + text, "原样作为一个参数：\(text.debugDescription) → \(line)")
        }
    }

    /// shell 的参数里放不进 NUL：交给 Claude Code / Codex 的文字去掉 NUL（第 10 步验证后定）。
    func testNULIsRemovedFromThePrompt() throws {
        XCTAssertEqual(LauncherShellHandoff.promptLine(binary: "claude", prompt: "a\u{0}b"), "'claude' 'ab'")
        XCTAssertEqual(LauncherShellHandoff.promptLine(binary: "claude", prompt: "\u{0}-x"), "'claude' -- '-x'", "去掉后以 - 开头照样加 --")
        let fake = "fakeclaude() { [[ $1 == -- ]] && shift; printf '%d|%s' $# \"$1\"; }; "
        XCTAssertEqual(try zsh(fake + LauncherShellHandoff.promptLine(binary: "fakeclaude", prompt: "修\u{0}一下")), "1|修一下")
    }

    func testPromptStartingWithADashGetsAnEndOfOptions() {
        XCTAssertEqual(LauncherShellHandoff.promptLine(binary: "/opt/homebrew/bin/claude", prompt: "-x"),
                       "'/opt/homebrew/bin/claude' -- '-x'")
        XCTAssertEqual(LauncherShellHandoff.promptLine(binary: "claude", prompt: "修一下这个报错"), "'claude' '修一下这个报错'")
        XCTAssertEqual(LauncherShellHandoff.promptLine(binary: "/Users/me/my tools/claude", prompt: "a"),
                       "'/Users/me/my tools/claude' 'a'", "路径里有空格也是一个词")
    }

    func testRunLineBehavesLikeTypingTheCommand() throws {
        let commands = [
            "printf '%s' 'a b'",
            "printf '%s|' one \"two three\" four",
            "printf '%s' \"$((1+2))\" `printf x`",
            "printf '%s' it\\'s",
            "printf '%s' a; printf '%s' b",
            "x=5; printf '%s' $x",
            "printf '%s' 'unterminated",
        ]
        for command in commands {
            XCTAssertEqual(try zsh(LauncherShellHandoff.runLine(command)), try zsh(command), command)
        }
    }

    func testRunLineIsOneLine() {
        for text in tricky + ["git status", "$ ls"] {
            let line = LauncherShellHandoff.runLine(text)
            XCTAssertTrue(line.hasPrefix("eval '"), line)
            // 换行只可能出现在引号里（原文带的）：原文没有换行，这一行就没有换行。
            if !text.contains(where: \.isNewline) {
                XCTAssertFalse(line.contains(where: \.isNewline), line)
            }
        }
    }

    /// 整段只是一个 ASCII 词（可能是子命令名）不交给 Claude Code / Codex（第 10 步验证后定）。
    func testSingleASCIIWordsAreNotHandedOver() {
        for text in ["update", "logout", "login", "mcp", "config", "  doctor  ", "v2", "foo-bar_baz", "UPDATE", "-x", "--help"] {
            XCTAssertFalse(LauncherShellHandoff.canHandOff(text), text)
        }
        for text in ["update the docs", "修一下", "update？", "fix: crash", "-x y", "a.b", "it's", "update\nthis"] {
            XCTAssertTrue(LauncherShellHandoff.canHandOff(text), text.debugDescription)
        }
        XCTAssertFalse(LauncherShellHandoff.canHandOff(""))
        XCTAssertFalse(LauncherShellHandoff.canHandOff(String(repeating: "a", count: LauncherShellHandoff.maxPromptBytes + 1)))
        XCTAssertTrue(LauncherShellHandoff.canHandOff(String(repeating: "a", count: 300)), "长文字不当成子命令名")
    }

    /// 项目目录不在了就落到主目录再跑；在就进去（第 10 步验证后定）。
    func testMissingDirectoryFallsBackToHome() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("my project's dir", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // `pwd -P` 给的是 /private/var/…，Foundation 解析软链给的是 /var/…：比结尾。
        XCTAssertTrue(try zsh(LauncherShellHandoff.inDirectory(project.path, "pwd -P"), home: home.path)
            .hasSuffix(base.lastPathComponent + "/my project's dir\n"))
        let gone = base.appendingPathComponent("deleted", isDirectory: true).path
        XCTAssertTrue(try zsh(LauncherShellHandoff.inDirectory(gone, "pwd -P"), home: home.path)
            .hasSuffix(base.lastPathComponent + "/home\n"), "不在就落到主目录")
        let fake = "fakeclaude() { printf '%d|%s' $# \"$1\"; }; "
        XCTAssertEqual(try zsh(fake + LauncherShellHandoff.inDirectory(gone, LauncherShellHandoff.promptLine(binary: "fakeclaude",
                                                                                                          prompt: "a; b")),
                               home: home.path), "1|a; b", "命令照常跑、文字照原样")
        XCTAssertEqual(try zsh(LauncherShellHandoff.inDirectory(gone, "echo ok"), home: home.path), "ok\n", "cd 失败的话不出声")
    }

    func testInteractiveShellStaysOpen() {
        XCTAssertEqual(LauncherShellHandoff.interactiveShell, "exec \"${SHELL:-/bin/zsh}\" -l")
    }

    func testCommandLineLimit() {
        XCTAssertTrue(LauncherShellHandoff.fitsCommandLine("修一下"))
        XCTAssertFalse(LauncherShellHandoff.fitsCommandLine(""))
        XCTAssertTrue(LauncherShellHandoff.fitsCommandLine(String(repeating: "a", count: LauncherShellHandoff.maxPromptBytes)))
        XCTAssertFalse(LauncherShellHandoff.fitsCommandLine(String(repeating: "a", count: LauncherShellHandoff.maxPromptBytes + 1)))
        XCTAssertFalse(LauncherShellHandoff.fitsCommandLine(String(repeating: "报", count: LauncherShellHandoff.maxPromptBytes / 2)),
                       "按字节算：一个汉字三个字节")
    }

    func testProjectName() {
        XCTAssertEqual(LauncherShellHandoff.projectName("/Users/me/cmb/worktrees/baobox-launcher-pr10"), "baobox-launcher-pr10")
        XCTAssertEqual(LauncherShellHandoff.projectName("/Users/me/project/"), "project")
        XCTAssertNil(LauncherShellHandoff.projectName(""))
        XCTAssertNil(LauncherShellHandoff.projectName("/"))
    }
}
