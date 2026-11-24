import Foundation

/// 快速入口空着时的情景建议（docs/launcher/TECH_DESIGN.md §5.6）：防休眠开着 →「关闭防休眠」。
/// 就是「开关防休眠」那个快捷键动作此刻的 `stateTitle`（开着时才有），同 id（`caffeinate.toggle`）、同动作（关掉并回执一句）。
/// 只读内存（`CaffeinateController.isActive`）。写在扩展里（不动 `CaffeinateTool.swift`）：协议要求由这里的实现满足。
extension CaffeinateTool {
    func launcherContextSuggestions() -> [LauncherCommand] {
        hotkeys().compactMap { $0.launcherStateCommand(symbolName: "cup.and.saucer") }
    }
}
