import Foundation

/// Claude Code 助手交给快速入口按名字搜的文件（docs/launcher/TECH_DESIGN.md §6.4，PR 11）：
/// - 要自己扫的目录：Claude Code 的临时目录 `/private/tmp/claude-<uid>`（会话的 scratchpad 在这下面，Spotlight 不索引 `/private/tmp`）。
///   代码和文档里没有现成的常量，规律是 2026-11-24 在用户的 Mac 上实测的（`/private/tmp/claude-501/<项目>/<会话>/scratchpad/…`）。
///   不存在由快速入口在后台跳过。
/// - 已知文件：「最近文件」（`ClaudeFileIndex.files`，会话写过的文件，在内存里），说明写「Claude Code · 项目名」。
///   它只在启动、打开 Claude 面板、设置页刷新时更新，所以每次交出时顺带触发一次后台刷新（最多 30 秒一次，`refresh()` 本身
///   在后台、防重入）：这次呼出拿到的是旧清单，下次呼出就是新的（PR 11 独立验证后加）。
/// - 没装 Claude Code（`ClaudeEnv.isInstalled`，模块现有的探测，同菜单）两样都不交 —— 免得第一次访问 `ClaudeFileIndex.shared`
///   时在主线程同步读它的缓存文件（约定 7「未安装即降级」）。
/// 写在扩展里（不动 `ClaudeCodeTool.swift`）：协议要求由这里的实现满足。
extension ClaudeCodeTool {
    /// Claude Code 的临时目录（按当前用户的 uid）。
    nonisolated static var temporaryRoot: String {
        "/private/tmp/claude-\(getuid())"
    }

    func launcherFileRoots() -> [String] {
        guard ClaudeEnv.isInstalled else { return [] }
        return [Self.temporaryRoot]
    }

    func launcherKnownFiles() -> [LauncherKnownFile] {
        guard ClaudeEnv.isInstalled else { return [] }
        if ClaudeLauncherFileRefresh.throttle.shouldRun(now: Date()) {
            ClaudeFileIndex.shared.refresh()
        }
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

/// 快速入口呼出时顺带刷新最近文件的节流（最多 30 秒一次）。只在主线程用。
@MainActor
private enum ClaudeLauncherFileRefresh {
    static var throttle = LauncherRefreshThrottle(interval: 30)
}
