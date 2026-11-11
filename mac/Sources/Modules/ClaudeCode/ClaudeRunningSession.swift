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

    /// `ps -axo pid=,ppid=,tty=,command=` 的输出 → pid → (ppid, tty, command)。tty 为 `??`（无控制终端）时记 nil。
    /// ps 按列对齐，切完三列后 command 前面还带着对齐用的空格，要去掉：以前没去，命令行里的 App 路径带着前导空格，
    /// `Bundle(path:)` 认不出终端，「按进程找宿主终端」在真机上从来没成功过（#164 PR1 查到，iTerm2 / Otty 实测）。
    static func parseProcessTable(_ output: String) -> [Int32: (ppid: Int32, tty: String?, command: String)] {
        var table: [Int32: (ppid: Int32, tty: String?, command: String)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            let tty = fields[2] == "??" ? nil : String(fields[2])
            table[pid] = (ppid, tty, fields[3].trimmingCharacters(in: .whitespaces))
        }
        return table
    }

    /// 命令行里 App 包的路径：`/Applications/iTerm.app/Contents/MacOS/iTerm2 …` → `/Applications/iTerm.app`；
    /// 不是 App 包里的可执行文件返回 nil。按第一个 `.app/Contents/MacOS/` 切（嵌套的 Helper.app 归它自己，往上一层父进程再找）。
    static func appBundlePath(inCommand command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(trimmed[..<range.lowerBound]) + ".app"
    }
}
