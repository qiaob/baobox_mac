import Foundation

/// `TerminalLauncher.run` 写的一次性 `.command` 脚本：内容怎么拼、目录里只留最近几个（#164，docs/codex-assistant/DEDUPE-P2.md §2.4 类 5）。
/// 照搬原 `TerminalLauncher`（`ClaudeEnv.swift`）的拼法与清理，输出逐字相同。只 import Foundation：进 BaoboxTests。
enum TerminalLaunchScript {

    /// 目录里留几个旧脚本。
    static let keepCount = 20

    /// `#!/bin/zsh` + （有目录时）`cd '<目录>'` + 命令，每段一行。directory 为 nil 或空串时不 cd；命令原样写，不转义。
    static func contents(command: String, directory: String?) -> String {
        var script = "#!/bin/zsh\n"
        if let directory, !directory.isEmpty {
            script += "cd \(Shell.quote(directory))\n"
        }
        script += command + "\n"
        return script
    }

    /// 目录里超过 keep 个文件时，按修改时间删掉最旧的，只留 keep 个（隐藏文件不算、不删）。
    /// 目录不存在、读不了就什么也不做。调用方在写新脚本**之前**清（同原来），所以写完那一刻最多 keep + 1 个。
    static func prune(_ directory: URL, keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), files.count > keep else { return }
        let sorted = files.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l < r
        }
        for url in sorted.prefix(sorted.count - keep) {
            try? fm.removeItem(at: url)
        }
    }
}
