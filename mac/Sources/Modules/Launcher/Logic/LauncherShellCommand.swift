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
            // make 的常见目标（第 10 步验证后加：`make build`、`make install` 原来认不出）。
            "make": ["build", "install", "test", "clean", "all", "run", "dev", "lint"],
        ]
    }()

    /// 英文虚词（第 10 步验证后定）：没有选项形状的词时，后面只要有一个不在引号里的词是这些，就是一句英文，不是命令 ——
    /// 「python is great for data/science」「cat videos on youtube.com」。含 `/` 的词不拆开查（复查后定：`cd my/project` 是命令）；
    /// 它算不算路径证据看 `isPath`（`and/or` 不算，所以「cat and/or dog」仍不是命令）。
    static let functionWords: Set<String> = [
        "the", "a", "an", "and", "or", "is", "are", "was", "be", "to", "of", "on", "in", "for", "with", "my", "your",
        "you", "i", "it", "this", "that", "me", "we", "not", "sure",
    ]

    /// 后面有含 `@` 的词（`ssh deploy@host`、`scp a.txt me@host:/tmp`）也算证据的命令。
    static let atCommands: Set<String> = ["ssh", "scp"]

    /// 像一条命令就给出要跑的那条命令（`$ ` 去掉、去首尾空白），否则 nil。规则：
    /// - 只认一行，每个字符都要在允许名单里（`isAllowed`：看得见、宽度有数、不会重排）。
    /// - `$ ` 开头的（从文档里复制的提示符）：后面第一个词像命令名就算（`looksLikeCommandName`；「$ 5 off」不算）。
    /// - 否则第一个词在 `knownCommands` 里、后面还有参数，而且后面至少有一个词像选项（`-x`、`--xx`）、路径（含 `/` 或 `.`，
    ///   `~`、`.`、`..`；以 `.` 结尾的不算）、赋值（`a=b`）、`ssh` / `scp` 后面含 `@` 的词，或是这个命令的常见子命令；
    ///   `sudo` 后面跟的是一条像命令的命令也算。
    /// - 没有选项形状的词时，后面有一个不在引号里的英文虚词（`functionWords`）就不算 —— 子命令位置上的那个子命令不查。
    ///   所以 `open the door`、`make it work`、`find my phone`、`cat and/or dog`、单独一个 `ls` 都不算。
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // 每个字符都要在允许名单里（换行、制表符、控制符也就不在了）。
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxLength, allowsEveryCharacter(trimmed) else { return nil }
        if trimmed.hasPrefix("$ ") {
            let command = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard let name = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  looksLikeCommandName(String(name)) else { return nil }
            return command
        }
        return isCommandLike(words(trimmed)) ? trimmed : nil
    }

    /// 拆开的一个词；`quoted` = 在引号里（`'…'`、`"…"`，以引号开头的词到以同一个引号结尾的词为止）。
    struct Word: Equatable {
        let text: String
        let quoted: Bool
    }

    /// 按空格、制表符拆词，记下哪些在引号里。词中间的撇号（`it's`）不算开引号。
    static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var open: Character?
        for piece in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let word = String(piece)
            if let quote = open {
                result.append(Word(text: word, quoted: true))
                if word.last == quote { open = nil }
                continue
            }
            if let first = word.first, first == "'" || first == "\"" {
                result.append(Word(text: word, quoted: true))
                if !(word.count > 1 && word.last == first) { open = first }
                continue
            }
            result.append(Word(text: word, quoted: false))
        }
        return result
    }

    private static func isCommandLike(_ words: [Word]) -> Bool {
        guard let first = words.first?.text, knownCommands.contains(first), words.count >= 2 else { return false }
        let rest = Array(words.dropFirst())
        let commandSubcommands = subcommands[first] ?? []
        let hasOption = rest.contains { isOption($0.text) }
        // 没有选项形状的词：一句英文的样子（虚词）就不是命令。子命令位置上的那个子命令（`npm i lodash` 的 i）不查。
        if !hasOption {
            for (index, word) in rest.enumerated() where !word.quoted {
                if index == 0, commandSubcommands.contains(word.text) { continue }
                if isFunctionWord(word.text) { return false }
            }
        }
        if hasOption || rest.contains(where: { isPath($0.text) || isAssignment($0.text) }) { return true }
        if atCommands.contains(first), rest.contains(where: { $0.text.contains("@") }) { return true }
        if let second = rest.first?.text, commandSubcommands.contains(second) { return true }
        if first == "sudo" { return isCommandLike(rest) }
        return false
    }

    /// 这个词（去掉句末标点、不分大小写）是英文虚词。含 `/` 的词不拆开（`and/or` 不是虚词，第 10 步复查后定）。
    static func isFunctionWord(_ word: String) -> Bool {
        var stripped = Substring(word)
        while let last = stripped.last, ".,!?;:…".contains(last) { stripped = stripped.dropLast() }
        return functionWords.contains(stripped.lowercased())
    }

    /// `$ ` 后面的第一个词像不像命令名：以字母、`_`、`.`、`/`、`~` 开头，只含字母数字和 `_ . + - / ~`（第 10 步验证后定）。
    static func looksLikeCommandName(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first,
              isASCIILetter(first) || "_./~".unicodeScalars.contains(first) else { return false }
        return word.unicodeScalars.allSatisfy { isASCIILetter($0) || ("0"..."9").contains($0) || "_.+-/~".unicodeScalars.contains($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// 认成命令的文字里允许出现的字符（第 10 步复查后定，取代原来的拒绝名单）：确认时看到的必须就是要跑的，所以只收
    /// 「看得见、一个字形占一格或两格、不会重排」的字符 —— ASCII 可打印字符、预组合的带变音符拉丁字母（去掉 × ÷）、CJK 标点
    /// （不含全角空格）、假名、汉字、韩文音节、全角 ASCII。组合符号、emoji、控制符、格式符（双向、零宽、软连字符、变体选择符、
    /// 标签字符）、别的空格（NBSP、全角空格）、别的文字系统（希伯来 / 阿拉伯字母会双向重排，﷽ 一个字形十来列宽）一律不收。
    /// 按 Unicode 标量逐个看，不按字素簇（组合符号会藏在簇里）。
    /// 前提：表里的字符在等宽字体下的实际宽度都不超过 `LauncherConfirmText.width` 估的数（ASCII 1、其余 2）—— 完整显示的换行靠它。
    static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20...0x7E: return true
        case 0xD7, 0xF7: return false
        case 0xC0...0x24F: return true
        case 0x3001...0x303F: return true
        case 0x3041...0x3096, 0x30A1...0x30FA, 0x30FC: return true
        case 0x3400...0x4DBF, 0x4E00...0x9FFF: return true
        case 0xAC00...0xD7A3: return true
        case 0xFF01...0xFF5E: return true
        default: return false
        }
    }

    /// 每个 Unicode 标量都在允许名单里。
    static func allowsEveryCharacter(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(isAllowed)
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

    /// 路径：`.`、`..`，以 `/`、`./`、`../`、`~` 开头；中间含 `/` 的要拆开后的各段不全是虚词或空串（`my/project`、`in/out.log`、
    /// `src/app` 算，`and/or`、`to/` 不算，第 10 步复查后定）；或含一个后面还跟着字的 `.`（`README.md`、`.env`）。
    /// 以 `.` 结尾的（`U.S.`、`e.g.`、`i.e.`、句末的 `door.`，第 10 步验证后定）、句末别的标点（`work!`）和纯数字（`3.5`）不算。
    static func isPath(_ word: String) -> Bool {
        if word == "." || word == ".." || word.hasPrefix("/") || word.hasPrefix("./") || word.hasPrefix("../")
            || word.hasPrefix("~") { return true }
        if word.contains("/") {
            return word.split(separator: "/", omittingEmptySubsequences: false).contains { part in
                !part.isEmpty && !isFunctionWord(String(part))
            }
        }
        guard !word.hasSuffix(".") else { return false }
        var stripped = Substring(word)
        while let last = stripped.last, ",!?;:…".contains(last) { stripped = stripped.dropLast() }
        guard stripped.contains(".") else { return false }
        return !stripped.allSatisfy { $0 == "." || ("0"..."9").contains($0) }
    }

    /// `a=b`：等号两边都有东西。
    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "=") else { return false }
        return equals != word.startIndex && word.index(after: equals) != word.endIndex
    }
}
