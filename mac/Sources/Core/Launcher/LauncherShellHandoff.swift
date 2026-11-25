import Foundation

// 把快速入口里的文字交给终端（docs/launcher/TECH_DESIGN.md §5.4「在终端里运行」「交给 Claude Code」，第 10 步）：
// 拼成写进一次性脚本（`TerminalLauncher.run`）的那一行。文字一律经 `Shell.quote`（单引号包裹，里面的 `$`、反引号、`\`、
// 换行都原样，不展开）再拼进命令 —— 交给 claude 的是一个参数，不会被 shell 拆开、展开或执行。
// 快速入口自己（在终端里运行、在终端里打开文件夹）和 Claude Code / Codex 助手共用。只依赖 Foundation，进 BaoboxTests。

enum LauncherShellHandoff {
    /// 交给命令行的文字最多这么多字节：macOS 一条命令的参数加环境变量合计 1 MB（`ARG_MAX`），留足余量。
    static let maxPromptBytes = 200_000

    /// 在文件夹里打开终端：起一个交互的登录 shell（脚本跑完不退出，停在那个目录里）。
    static let interactiveShell = "exec \"${SHELL:-/bin/zsh}\" -l"

    /// 「在终端里运行」：`eval '<命令>'`。命令就是用户贴进来、确认过的那一行，原样交给 shell（和在终端里自己敲一样）；
    /// 包一层引号的好处是脚本里永远只有这一行 —— 命令里的引号没配对也只是这一行报错，不会吞掉后面的东西。
    static func runLine(_ command: String) -> String {
        "eval " + Shell.quote(command)
    }

    /// 「交给 Claude Code / Codex」：`'<可执行文件>' '<文字>'`，文字是一个参数（新会话的第一条消息，换行保住）。
    /// 文字以 `-` 开头时前面加 `--`，免得被当成选项。
    static func promptLine(binary: String, prompt: String) -> String {
        Shell.quote(binary) + (prompt.hasPrefix("-") ? " -- " : " ") + Shell.quote(prompt)
    }

    /// 文字能不能整段交给命令行（不超过 `maxPromptBytes`）。打字时调：`utf8.count` 对 Swift 原生字符串是 O(1)。
    static func fitsCommandLine(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= maxPromptBytes
    }

    /// 项目目录的显示名（最后一段）；空的、只有 `/` 的为 nil。
    static func projectName(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
