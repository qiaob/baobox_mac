import Foundation

/// Codex 助手的会话数据源：快速切换面板的会话栏与中心窗口的会话页共用（`Core/CLISession/CLISessionSource.swift`，
/// #164 PR3；原 `CodexQuickSwitchSource`，在 `AIToolsQuickSwitchPanel.swift` 里）。
/// 第二行 = 项目 · 相对时间；续接直接开新终端窗口（不做已开窗口聚焦：按进程找正在跑的会话只有 Claude 那边有、只认 claude 进程）。
@MainActor
struct CodexSessionSource: CLISessionSource {
    var sessions: [CodexSessionSummary] { CodexSessionIndex.shared.sessions }

    func refresh() {
        CodexSessionIndex.shared.refresh()
    }

    /// 行元信息：项目名 · 相对时间（无项目名时仅相对时间）。
    func metadataLine(for session: CodexSessionSummary) -> String {
        let relative = AIToolsFormat.relative(session.lastActivity)
        return session.projectName.isEmpty ? relative : "\(session.projectName) · \(relative)"
    }

    func resume(_ session: CodexSessionSummary) {
        // MVP：直接开新终端窗口续接（不做已开窗口聚焦，Codex 侧无该能力）。
        TerminalLauncher.run(command: CodexResumeCommand.command(sessionID: session.id),
                             in: session.projectPath.isEmpty ? nil : session.projectPath)
    }

    func resumeCommand(for session: CodexSessionSummary) -> String {
        CodexResumeCommand.fullCommand(sessionID: session.id, cwd: session.projectPath)
    }
}

/// Codex 续接命令构造（数据源的续接与复制共用）。单引号转义用 Core 的 `Shell.quote`（#164）。
enum CodexResumeCommand {
    /// 终端执行的续接命令：`codex resume <id>`。
    static func command(sessionID: String) -> String {
        let bin = CodexEnv.findCodexBinary()
        return "\(Shell.quote(bin)) resume \(Shell.quote(sessionID))"
    }

    /// 供「复制命令」用：附带 cd 到项目目录。
    static func fullCommand(sessionID: String, cwd: String) -> String {
        let resume = command(sessionID: sessionID)
        guard !cwd.isEmpty else { return resume }
        return "cd \(Shell.quote(cwd)) && \(resume)"
    }
}
