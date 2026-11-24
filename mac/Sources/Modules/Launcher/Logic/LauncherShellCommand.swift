import Foundation

// 输入像不像一条终端命令（docs/launcher/TECH_DESIGN.md §5.4「像命令」）：像的话兜底建议的第一条是「在终端里运行」。
// 保守：宁可漏认，不要把一句英文当成命令。规则只看这段文字本身，纯函数、每次按键跑一次；只依赖 Foundation，进 BaoboxTests。

enum LauncherShellCommand {
    /// 再长就不认（一条命令不会这么长，几 MB 的粘贴也不用整段拆词）。
    static let maxLength = 2_000

    /// 认得的命令（第一个词）。只收常见的；大小写要一致（`Find my phone` 不算）。
    static let knownCommands: Set<String> = [
        "git", "npm", "npx", "pnpm", "yarn", "brew", "cd", "ls", "cat", "curl", "wget", "ssh", "scp", "docker", "kubectl",
        "make", "python", "python3", "pip", "node", "swift", "xcodebuild", "open", "sudo", "rm", "mv", "cp", "mkdir",
        "chmod", "grep", "find", "tail", "ps", "kill", "export",
    ]

    /// 几个命令的常见子命令：`git status`、`docker ps` 这样后面没有选项、路径的也认。pnpm、yarn 和 npm 共用一组。
    static let subcommands: [String: Set<String>] = {
        let npm: Set<String> = ["install", "i", "add", "remove", "run", "test", "start", "build", "ci", "init", "publish",
                                "update", "upgrade", "uninstall", "outdated", "exec", "dev", "link"]
        return [
            "git": ["status", "commit", "push", "pull", "clone", "checkout", "switch", "branch", "log", "diff", "add",
                    "fetch", "merge", "rebase", "stash", "reset", "restore", "init", "show", "tag", "remote", "blame",
                    "cherry-pick", "revert", "worktree"],
            "npm": npm, "pnpm": npm, "yarn": npm,
            "docker": ["ps", "run", "build", "pull", "push", "images", "exec", "logs", "compose", "stop", "start", "rm",
                       "rmi", "inspect", "restart", "login", "volume", "network", "system"],
            "kubectl": ["get", "describe", "logs", "apply", "delete", "exec", "port-forward", "rollout", "config", "scale",
                        "top", "edit", "create", "cp", "label", "annotate"],
            "brew": ["install", "uninstall", "reinstall", "upgrade", "update", "list", "search", "info", "services",
                     "doctor", "cleanup", "tap", "outdated"],
        ]
    }()

    /// 像一条命令就给出要跑的那条命令（`$ ` 去掉、去首尾空白），否则 nil。规则：
    /// - 只认一行；`$ ` 开头的（从文档里复制的提示符）都算，后面不能是空的。
    /// - 否则第一个词在 `knownCommands` 里、后面还有参数，而且后面至少有一个词像选项（`-x`、`--xx`）、路径（含 `/` 或 `.`，
    ///   `~`、`.`、`..`）、赋值（`a=b`），或是这个命令的常见子命令；`sudo` 后面跟的是一条像命令的命令也算。
    ///   所以 `open the door`、`make it work`、`find my phone`、单独一个 `ls` 都不算。
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxLength, !trimmed.contains(where: \.isNewline) else { return nil }
        if trimmed.hasPrefix("$ ") {
            let command = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : command
        }
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return isCommandLike(words) ? trimmed : nil
    }

    private static func isCommandLike(_ words: [String]) -> Bool {
        guard let first = words.first, knownCommands.contains(first), words.count >= 2 else { return false }
        let rest = words.dropFirst()
        if rest.contains(where: { isOption($0) || isPath($0) || isAssignment($0) }) { return true }
        if let second = rest.first, subcommands[first]?.contains(second) == true { return true }
        if first == "sudo" { return isCommandLike(Array(rest)) }
        return false
    }

    /// `-x`、`-9`、`--force`、`--name=value`：一到两个连字符后面紧跟字母或数字。
    static func isOption(_ word: String) -> Bool {
        var rest = Substring(word)
        guard rest.hasPrefix("-") else { return false }
        rest = rest.dropFirst()
        if rest.hasPrefix("-") { rest = rest.dropFirst() }
        guard let next = rest.unicodeScalars.first else { return false }
        return ("a"..."z").contains(next) || ("A"..."Z").contains(next) || ("0"..."9").contains(next)
    }

    /// 路径：含 `/`；或是 `~`、`.`、`..`、`~` 开头；或含一个后面还跟着字的 `.`（`README.md`、`.env`）。
    /// 句末的标点（`door.`、`work...`）和纯数字（`3.5`）不算。
    static func isPath(_ word: String) -> Bool {
        if word.contains("/") || word == "." || word == ".." || word.hasPrefix("~") { return true }
        var stripped = Substring(word)
        while let last = stripped.last, ".,!?;:…".contains(last) { stripped = stripped.dropLast() }
        guard stripped.contains(".") else { return false }
        return !stripped.allSatisfy { $0 == "." || ("0"..."9").contains($0) }
    }

    /// `a=b`：等号两边都有东西。
    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "=") else { return false }
        return equals != word.startIndex && word.index(after: equals) != word.endIndex
    }
}
