import Foundation

/// 快速入口空着时的情景建议（docs/launcher/TECH_DESIGN.md §5.6）：有 Claude Code 会话在等你确认 →「切到 <项目> · 在等你确认」，
/// 每个在等的会话一条（新的在前），回车跳到它所在的终端 —— 同点「等你确认」通知（hook 记下的终端位置，没记下按进程猜）。
/// 「在等」就是实时状态里现成的 `waiting`（hooks 的 Notification 事件），只读内存（`ClaudeLiveStatus.sessions`）；
/// 没装 Claude Code / 没装 hooks 时实时状态是空的，就没有。注意这个状态在你回了那个提示之后、回合结束（Stop）之前不会变，
/// 和菜单状态行「N 等待确认」一样（hooks 只报 Stop / Notification / SessionStart / UserPromptSubmit）。
/// id 带会话（`claudecode.waiting.<会话 id>`）：两个会话同时在等时各一行。
/// 写在扩展里（不动 `ClaudeCodeTool.swift`）：协议要求由这里的实现满足。
extension ClaudeCodeTool {
    func launcherContextSuggestions() -> [LauncherCommand] {
        let waiting = ClaudeLiveStatus.shared.sessions.values.filter { session in
            if case .waiting = session.state { return true }
            return false
        }
        return waiting.sorted { $0.lastEvent > $1.lastEvent }.map { session in
            let sessionID = session.sessionID
            let cwd = session.cwd
            let terminal = session.terminal
            return LauncherCommand(id: "claudecode.waiting.\(sessionID)",
                                   title: L("claudecode.launcher.waiting \(session.projectName)"),
                                   symbolName: symbolName) { _ in
                ClaudeTerminal.focusRunningSession(sessionID: sessionID, projectPath: cwd, location: terminal,
                                                   confirmRunning: false, isNewestInProject: true) { _ in }
            }
        }
    }
}
