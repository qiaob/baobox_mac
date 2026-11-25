import Foundation

/// Codex 助手给快速入口的文字动作「交给 Codex」（docs/launcher/TECH_DESIGN.md §5.4，第 10 步）：和「交给 Claude Code」同样简单 ——
/// 在偏好终端里开一个新的 codex 会话，文字作为第一条消息（`'<codex>' '<文字>'`，`LauncherShellHandoff.promptLine`）。
/// 目录：最近一次会话的项目目录（`CodexSessionIndex.shared.sessions`，内存缓存、新→旧），标题「交给 Codex（<项目名>）」；
/// 拿不到时用主目录。没装 Codex（`CodexEnv.isInstalled`，同菜单）不声明（约定 7）。
/// 档位 56（紧跟在「交给 Claude Code」后面），不提前：两个都提前的话一大段文字的兜底建议里存为片段就挤出去了。
/// 写在扩展里，不动 `AIToolsTool.swift`。
extension AIToolsTool {
    func launcherCommands() -> [LauncherCommand] {
        guard CodexEnv.isInstalled else { return [] }
        let recent = CodexSessionIndex.shared.sessions.first?.projectPath ?? ""
        let project = LauncherShellHandoff.projectName(recent)
        let directory = project == nil ? NSHomeDirectory() : recent
        let title = project.map { L("aitools.launcher.handOffTo \($0)") } ?? L("aitools.launcher.handOff")
        return [
            .textAction(id: "aitools.text.handOff", title: title, symbolName: "chevron.left.forwardslash.chevron.right",
                        suggestion: LauncherSuggestionTraits(priority: 56),
                        hint: "交给 Codex 的第一条消息",
                        appliesTo: { LauncherShellHandoff.fitsCommandLine($0) }) { text in
                TerminalLauncher.run(command: LauncherShellHandoff.promptLine(binary: CodexEnv.findCodexBinary(), prompt: text),
                                     in: directory)
            },
        ]
    }
}
