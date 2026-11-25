import Foundation

/// Claude Code 助手给快速入口的文字动作「交给 Claude Code」（docs/launcher/TECH_DESIGN.md §5.4，第 10 步）：在偏好终端里开一个
/// 新的 claude 会话，把输入框里的文字（粘贴的多行原文保住换行）作为第一条消息 —— `'<claude>' '<文字>'`，文字经 `Shell.quote`
/// （`LauncherShellHandoff.promptLine`），是一个参数，不会被 shell 展开或执行。
/// - 目录：最近一次会话所在的项目目录（会话索引的内存缓存 `ClaudeSessionIndex.shared.sessions`，新→旧；零磁盘 IO），
///   标题写成「交给 Claude Code（<项目名>）」；拿不到时用主目录，标题不写项目。
/// - 没装 Claude Code（`ClaudeEnv.isInstalled`，同菜单）不声明 —— 约定 7「未安装即降级」；也免得第一次访问会话索引时
///   在主线程同步读它的缓存文件（装了的话 `activate()` 早就读过了）。
/// - 档位 55（靠后：存为片段那一档之后、润色之前）；一大段文字（含粘贴的多行原文）时提到最前那一组。
///   超过命令行能带的长度、或者整段只是一个 ASCII 词（`update` 会被当成子命令）不出（`LauncherShellHandoff.canHandOff`）。
/// - 项目目录不在了（删了、搬了）就在主目录开：`cd '<目录>' 2>/dev/null || cd ~; …`（`LauncherShellHandoff.inDirectory`）。
/// 写在扩展里，不动 `ClaudeCodeTool.swift`。
extension ClaudeCodeTool {
    func launcherCommands() -> [LauncherCommand] {
        guard ClaudeEnv.isInstalled else { return [] }
        let recent = ClaudeSessionIndex.shared.sessions.first?.projectPath ?? ""
        let project = LauncherShellHandoff.projectName(recent)
        let directory = project == nil ? NSHomeDirectory() : recent
        let title = project.map { L("claudecode.launcher.handOffTo \($0)") } ?? L("claudecode.launcher.handOff")
        return [
            // 设置页的功能开关那一行用固定的名字（标题带最近的项目名，第 13 步）。
            .textAction(id: "claudecode.text.handOff", title: title, settingsTitle: L("claudecode.launcher.handOff"),
                        symbolName: "bubble.left.and.bubble.right",
                        suggestion: LauncherSuggestionTraits(priority: 55, boostedKinds: [.longText]),
                        hint: "交给 Claude Code 的第一条消息",
                        appliesTo: { LauncherShellHandoff.canHandOff($0) }) { text in
                let binary = ClaudeEnv.findClaudeBinary() ?? "claude"
                let line = LauncherShellHandoff.promptLine(binary: binary, prompt: text)
                TerminalLauncher.run(command: LauncherShellHandoff.inDirectory(directory, line), in: nil)
            },
        ]
    }
}
