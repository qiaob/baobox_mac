import Foundation
import XCTest

/// 把文字交给终端时拼的那一行（docs/launcher/TECH_DESIGN.md §5.4，PR 10）：文字经 `Shell.quote` 后作为一个参数原样到达，
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

    /// 用 zsh 跑一段脚本，取 stdout。
    private func zsh(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", script]
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
