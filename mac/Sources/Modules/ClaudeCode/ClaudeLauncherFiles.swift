import Foundation

/// Claude Code 助手交给快速入口按名字搜的文件（docs/launcher/TECH_DESIGN.md §6.4，PR 11）：
/// - 要自己扫的目录：Claude Code 的临时目录 `/private/tmp/claude-<uid>`（会话的 scratchpad 在这下面，Spotlight 不索引 `/private/tmp`）。
///   代码和文档里没有现成的常量，规律是 2026-11-24 在用户的 Mac 上实测的（`/private/tmp/claude-501/<项目>/<会话>/scratchpad/…`）。
///   这里只给路径、不查存不存在（零磁盘 IO），不存在由快速入口在后台跳过。
/// - 已知文件：「最近文件」（`ClaudeFileIndex.files`，会话写过的文件，在内存里），说明写「Claude Code · 项目名」。
/// 写在扩展里（不动 `ClaudeCodeTool.swift`）：协议要求由这里的实现满足。
extension ClaudeCodeTool {
    /// Claude Code 的临时目录（按当前用户的 uid）。
    nonisolated static var temporaryRoot: String {
        "/private/tmp/claude-\(getuid())"
    }

    func launcherFileRoots() -> [String] {
        [Self.temporaryRoot]
    }

    func launcherKnownFiles() -> [LauncherKnownFile] {
        // 同一个项目的说明只格式化一次（最多 500 个文件，多半来自几个项目）。
        var notes: [String: String] = [:]
        return ClaudeFileIndex.shared.files.map { file in
            let note: String
            if let cached = notes[file.projectName] {
                note = cached
            } else {
                note = file.projectName.isEmpty ? L("claudecode.launcher.fileNoteBare")
                    : L("claudecode.launcher.fileNote \(file.projectName)")
                notes[file.projectName] = note
            }
            return LauncherKnownFile(path: file.filePath, date: file.lastWritten, note: note)
        }
    }
}
