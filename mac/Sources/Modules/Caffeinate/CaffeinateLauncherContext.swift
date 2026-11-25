import Foundation

/// 快速入口空着时的情景建议（docs/launcher/TECH_DESIGN.md §5.6）：防休眠开着 →「关闭防休眠」。
/// 就是「开关防休眠」那个快捷键动作此刻的 `stateTitle`（开着时才有），同 id（`caffeinate.toggle`）、同动作（关掉并回执一句）。
/// 只读内存（`CaffeinateController.isActive`）。写在扩展里（不动 `CaffeinateTool.swift`）：协议要求由这里的实现满足。
extension CaffeinateTool {
    /// 情景建议的次序（小的在前，§5.6 次序表）：防休眠开着不急，排在会议、Claude Code、录屏、专注之后。
    static let launcherSuggestionPriority = 50

    func launcherContextSuggestions() -> [LauncherCommand] {
        hotkeys().compactMap {
            $0.launcherStateCommand(symbolName: "cup.and.saucer", priority: Self.launcherSuggestionPriority)
        }
    }
}
