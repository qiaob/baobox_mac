import Foundation

/// Claude Code 助手的会话数据源：快速切换面板的会话栏与中心窗口的会话页共用（`Core/CLISession/CLISessionSource.swift`，
/// #164 PR3；原 `ClaudeQuickSwitchSource`，在 `ClaudeQuickSwitchPanel.swift` 里）。
/// 第二行 = 菜单同款的会话行方案（`SessionRowFormatStore`）；续接先找正在跑的窗口 —— 与点通知跳回同一个
/// `ClaudeTerminal.focusRunningSession`，先用 hook 记下的终端位置。
@MainActor
struct ClaudeSessionSource: CLISessionSource {
    var sessions: [ClaudeSessionSummary] { ClaudeSessionIndex.shared.sessions }

    func refresh() {
        ClaudeSessionIndex.shared.refresh()
    }

    /// 第二行 = 菜单同款的会话行方案。
    func metadataLine(for session: ClaudeSessionSummary) -> String {
        SessionRowFormatStore.shared.metadataLine(for: session)
    }

    func resume(_ session: ClaudeSessionSummary) {
        // 会话已在某个终端窗口里跑、且能定位到那个窗口时,只把它切到前台:先用 hook 记下的位置(同一目录开着几个会话
        // 不会认错,Otty 也认得),确认那个终端里还有 claude 在跑才用;再按进程找。
        // 其余情况(没在跑 / 定位不到宿主终端,如 tmux、SSH)一律照常开新窗口。
        let isNewest = ClaudeSessionIndex.shared.sessions
            .first(where: { $0.projectPath == session.projectPath })?.id == session.id
        let sessionID = session.id
        let projectPath = session.projectPath
        ClaudeTerminal.focusRunningSession(
            sessionID: sessionID, projectPath: projectPath,
            location: ClaudeLiveStatus.shared.currentTerminal(of: sessionID),
            confirmRunning: true, isNewestInProject: isNewest
        ) { focused in
            if !focused {
                ClaudeTerminal.resume(sessionID: sessionID, in: projectPath)
            }
        }
    }

    func resumeCommand(for session: ClaudeSessionSummary) -> String {
        ClaudeTerminal.resumeCommandString(sessionID: session.id, in: session.projectPath)
    }
}
