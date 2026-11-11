import Foundation
import XCTest

/// 快速切换面板续接时，hook 记下的终端位置还能不能用（DEDUPE.md §5.1 B3，NOTIFY_JUMP.md §3.1）：
/// 会话还占着那个 tty（后来没在同一个 tty 上见过别的会话），且那个 tty 上现在有 claude 在跑。
final class ClaudeRunningSessionTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func sighting(_ id: String, _ tty: String?, at seconds: TimeInterval) -> ClaudeRunningSession.Sighting {
        ClaudeRunningSession.Sighting(sessionID: id, tty: tty, lastEvent: start.addingTimeInterval(seconds))
    }

    // MARK: - 还占着那个终端吗

    func testSoleSightingOwnsItsTerminal() {
        XCTAssertTrue(ClaudeRunningSession.ownsTerminal("s1", sightings: [sighting("s1", "/dev/ttys003", at: 0)]))
    }

    func testUnseenSessionOrMissingTTYCannotBeConfirmed() {
        XCTAssertFalse(ClaudeRunningSession.ownsTerminal("s1", sightings: []))
        XCTAssertFalse(ClaudeRunningSession.ownsTerminal("s1", sightings: [sighting("s2", "/dev/ttys003", at: 0)]))
        XCTAssertFalse(ClaudeRunningSession.ownsTerminal("s1", sightings: [sighting("s1", nil, at: 0)]),
                       "没记 tty 的位置确认不了")
    }

    /// 会话结束后（reporter 不报 SessionEnd，它还留在实时状态里），同一个标签页里又开了一个：那个标签页归后来的会话。
    func testALaterSessionOnTheSameTTYTakesTheTerminalOver() {
        let sightings = [sighting("s1", "/dev/ttys003", at: 0), sighting("s2", "/dev/ttys003", at: 10)]
        XCTAssertFalse(ClaudeRunningSession.ownsTerminal("s1", sightings: sightings))
        XCTAssertTrue(ClaudeRunningSession.ownsTerminal("s2", sightings: sightings))
    }

    /// 同一个标签页里先跑过别的会话、后来才是它（比如结束后又 `--resume` 回来）：它是最新的，终端归它。
    func testAnEarlierSessionOnTheSameTTYDoesNotMatter() {
        let sightings = [sighting("s2", "/dev/ttys003", at: 0), sighting("s1", "/dev/ttys003", at: 10)]
        XCTAssertTrue(ClaudeRunningSession.ownsTerminal("s1", sightings: sightings))
    }

    /// 同一个目录在几个标签页里各开一个会话：各占各的 tty，互不影响（按进程猜分不清的正是这种）。
    func testSessionsInOtherTabsDoNotMatter() {
        let sightings = [
            sighting("s1", "/dev/ttys003", at: 0),
            sighting("s2", "/dev/ttys004", at: 10),
            sighting("s3", "/dev/ttys005", at: 20),
        ]
        XCTAssertTrue(ClaudeRunningSession.ownsTerminal("s1", sightings: sightings))
        XCTAssertTrue(ClaudeRunningSession.ownsTerminal("s2", sightings: sightings))
        XCTAssertTrue(ClaudeRunningSession.ownsTerminal("s3", sightings: sightings))
    }

    func testTTYWithAndWithoutDevPrefixIsTheSameTerminal() {
        let sightings = [sighting("s1", "/dev/ttys003", at: 0), sighting("s2", "ttys003", at: 10)]
        XCTAssertFalse(ClaudeRunningSession.ownsTerminal("s1", sightings: sightings))
    }

    func testLaterSightingWithoutTTYDoesNotTakeOver() {
        let sightings = [sighting("s1", "/dev/ttys003", at: 0), sighting("s2", nil, at: 10)]
        XCTAssertTrue(ClaudeRunningSession.ownsTerminal("s1", sightings: sightings))
    }

    /// 同一时刻在同一个 tty 上见到两个会话：谁也不算后来者，两个都还算占着（只有严格更晚才接手）。
    func testSimultaneousSightingsDoNotTakeOver() {
        let sightings = [sighting("s1", "/dev/ttys003", at: 0), sighting("s2", "/dev/ttys003", at: 0)]
        XCTAssertTrue(ClaudeRunningSession.ownsTerminal("s1", sightings: sightings))
        XCTAssertTrue(ClaudeRunningSession.ownsTerminal("s2", sightings: sightings))
    }

    // MARK: - 那个 tty 上有 claude 在跑吗

    func testClaudeOnTheTTYCounts() {
        let processes: [(tty: String?, command: String)] = [
            (tty: "ttys003", command: "-zsh"),
            (tty: "ttys003", command: "claude --resume 7b1c"),
        ]
        XCTAssertTrue(ClaudeRunningSession.claudeRuns(onTTY: "/dev/ttys003", processes: processes))
        XCTAssertTrue(ClaudeRunningSession.claudeRuns(onTTY: "ttys003", processes: processes))
    }

    /// 会话结束了、标签页里只剩 shell（或别的程序）：不算，面板照常开新窗口续接。
    func testOnlyAShellLeftOnTheTTYDoesNotCount() {
        let processes: [(tty: String?, command: String)] = [
            (tty: "ttys003", command: "-zsh"),
            (tty: "ttys003", command: "vim notes.md"),
        ]
        XCTAssertFalse(ClaudeRunningSession.claudeRuns(onTTY: "/dev/ttys003", processes: processes))
    }

    func testClaudeOnAnotherTTYDoesNotCount() {
        let processes: [(tty: String?, command: String)] = [(tty: "ttys004", command: "claude")]
        XCTAssertFalse(ClaudeRunningSession.claudeRuns(onTTY: "/dev/ttys003", processes: processes))
    }

    func testProcessesWithoutATTYAreIgnored() {
        let processes: [(tty: String?, command: String)] = [(tty: nil, command: "claude")]
        XCTAssertFalse(ClaudeRunningSession.claudeRuns(onTTY: "/dev/ttys003", processes: processes))
    }

    func testNodeLaunchedClaudeCounts() {
        let processes: [(tty: String?, command: String)] = [(tty: "ttys003", command: "node /opt/homebrew/bin/claude")]
        XCTAssertTrue(ClaudeRunningSession.claudeRuns(onTTY: "/dev/ttys003", processes: processes))
    }

    // MARK: - 进程是不是 Claude Code CLI

    func testClaudeCommands() {
        for command in [
            "claude",
            "claude --resume 7b1c",
            "/Users/me/.claude/local/claude",
            "/opt/homebrew/bin/claude --continue",
            "node /usr/local/bin/claude",
        ] {
            XCTAssertTrue(ClaudeRunningSession.isClaudeCommand(command), command)
        }
    }

    func testNonClaudeCommands() {
        for command in [
            "",
            "-zsh",
            "claude-code-acp",
            "/Applications/Claude.app/Contents/MacOS/Claude",
            "node /Users/me/server.js",
        ] {
            XCTAssertFalse(ClaudeRunningSession.isClaudeCommand(command), command)
        }
    }

    func testTTYName() {
        XCTAssertEqual(ClaudeRunningSession.ttyName("/dev/ttys003"), "ttys003")
        XCTAssertEqual(ClaudeRunningSession.ttyName("ttys003"), "ttys003")
        XCTAssertEqual(ClaudeRunningSession.ttyName("console"), "console")
    }

    // MARK: - ps 快照与宿主终端

    func testProcessTableDropsTheColumnAlignmentBeforeTheCommand() {
        let output = [
            "    1     0 ??       /sbin/launchd",
            "  812     1 ??       /Applications/iTerm.app/Contents/MacOS/iTerm2",
            " 4242   812 ttys003  -zsh",
            " 4300  4242 ttys003  node /opt/homebrew/bin/claude --resume abc",
        ].joined(separator: "\n")
        let table = ClaudeRunningSession.parseProcessTable(output)
        XCTAssertEqual(table.count, 4)
        XCTAssertEqual(table[812]?.command, "/Applications/iTerm.app/Contents/MacOS/iTerm2", "对齐空格去掉了")
        XCTAssertEqual(table[812]?.ppid, 1)
        XCTAssertNil(table[812]?.tty, "?? = 没有控制终端")
        XCTAssertEqual(table[4300]?.tty, "ttys003")
        XCTAssertEqual(table[4300]?.command, "node /opt/homebrew/bin/claude --resume abc")
        XCTAssertTrue(ClaudeRunningSession.isClaudeCommand(table[4300]?.command ?? ""))
    }

    func testProcessTableKeepsSpacesInsideTheCommand() {
        let table = ClaudeRunningSession.parseProcessTable(
            "  901     1 ??       /Applications/Visual Studio Code.app/Contents/MacOS/Electron --type=x")
        XCTAssertEqual(table[901]?.command, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron --type=x")
    }

    func testProcessTableSkipsMalformedLines() {
        XCTAssertTrue(ClaudeRunningSession.parseProcessTable("garbage\n   12 x ?? cmd\n   13     1 ??\n").isEmpty)
    }

    func testAppBundlePathFromACommandLine() {
        XCTAssertEqual(ClaudeRunningSession.appBundlePath(inCommand: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
                       "/Applications/iTerm.app")
        XCTAssertEqual(ClaudeRunningSession.appBundlePath(inCommand: "   /Applications/Otty.app/Contents/MacOS/Otty --x"),
                       "/Applications/Otty.app", "前导空格不影响")
        XCTAssertEqual(ClaudeRunningSession.appBundlePath(
            inCommand: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
                       "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app",
                       "嵌套的 Helper 归它自己，宿主终端要往父进程上找")
        XCTAssertNil(ClaudeRunningSession.appBundlePath(inCommand: "-zsh"))
        XCTAssertNil(ClaudeRunningSession.appBundlePath(inCommand: "/usr/bin/login -fp someone"))
    }
}
