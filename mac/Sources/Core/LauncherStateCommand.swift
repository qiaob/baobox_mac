import Foundation

// 快速入口的情景建议（docs/launcher/TECH_DESIGN.md §5.6）：开关类快捷键动作此刻「按下去会做什么」（`stateTitle`：
// 「关闭防休眠」「停止录屏」「暂停专注」）正好就是此刻值得提一句的动作 —— 模块在 `launcherContextSuggestions()` 里
// 直接把这样的快捷键动作交出去，不用重写业务逻辑。放在 Core（不在 Core/Launcher）：`HotkeyDefinition` 不是纯 Foundation 的类型。

extension HotkeyDefinition {
    /// 此刻 `stateTitle` 有值（开关开着、正在录 / 专注……）时，变成一条同 id、同动作的命令，标题就是那句；
    /// 没有 `stateTitle`、或此刻返回 nil / 空白（此刻不值得提）为 nil。
    /// `priority`：情景建议的次序（`suggestion.priority`，小的在前；各模块的档位见 §5.6 的次序表）。
    @MainActor
    func launcherStateCommand(symbolName: String, priority: Int) -> LauncherCommand? {
        guard let title = stateTitle?()?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let action = action
        return LauncherCommand(id: id, title: title, symbolName: symbolName,
                               suggestion: LauncherSuggestionTraits(priority: priority)) { _ in action() }
    }
}
