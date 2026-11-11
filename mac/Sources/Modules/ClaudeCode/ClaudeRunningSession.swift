import Foundation

/// Claude Code 助手 ——「正在跑的会话在哪个终端」的纯逻辑（#109 B3，docs/claude-code-assistant/NOTIFY_JUMP.md §3.1）。
///
/// 点通知跳回、快速切换面板续接都经 `ClaudeTerminal.focusRunningSession` 把会话所在的终端切到前台：先用 hook 记下的终端位置，
/// 再按进程找。面板要续接的会话可能早就结束了 —— reporter 不报 SessionEnd，结束了的会话连同它的位置在 `ClaudeLiveStatus`
/// 里还要留 6 小时 —— 所以面板用位置之前先过这里的两关：会话还占着那个终端（tty），那个 tty 上现在有 claude 在跑。
///
/// 只 import Foundation、不引用 App 与模块里的其他类型：进 BaoboxTests。
enum ClaudeRunningSession {

    /// hook 最近一次在哪个终端见到一个会话。
    struct Sighting: Equatable, Sendable {
        let sessionID: String
        /// 控制终端（`/dev/ttys012` 或 `ttys012`）；nil = 事件里没记（旧版脚本、没有控制终端）。
        let tty: String?
        /// 最近一次事件的时刻。
        let lastEvent: Date
    }

    /// 这个会话还占着 hook 记下的那个终端吗：同一个 tty 上后来又见到了别的会话（它结束后在同一个标签页里又开了一个，
    /// 或者标签页关了、tty 被新标签页复用），这个终端就不算它的了。没见过这个会话、或者没记 tty，确认不了，返回 false。
    static func ownsTerminal(_ sessionID: String, sightings: [Sighting]) -> Bool {
        guard let mine = sightings.first(where: { $0.sessionID == sessionID }),
              let tty = mine.tty.map(ttyName) else { return false }
        return !sightings.contains { other in
            other.sessionID != sessionID && other.tty.map(ttyName) == tty && other.lastEvent > mine.lastEvent
        }
    }

    /// 这个 tty 上现在有没有 claude 进程在跑。`processes` 是 `ps` 的快照（tty 为 nil = 没有控制终端）。
    static func claudeRuns(onTTY tty: String, processes: [(tty: String?, command: String)]) -> Bool {
        let target = ttyName(tty)
        return processes.contains { process in
            process.tty.map(ttyName) == target && isClaudeCommand(process.command)
        }
    }

    /// 命令前两个 token 里有 `claude` / `*/claude`（直接跑的二进制，或 `node …/claude`）即视为 Claude Code CLI。
    static func isClaudeCommand(_ command: String) -> Bool {
        command.split(separator: " ").prefix(2)
            .contains { $0 == "claude" || $0.hasSuffix("/claude") }
    }

    /// tty 去掉 `/dev/` 前缀：hook 记下的带（`TerminalLocation` 补上的），`ps` 列出来的不带。
    static func ttyName(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
    }
}
