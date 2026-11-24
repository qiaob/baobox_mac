import Foundation

/// 快速入口空着时的情景建议（docs/launcher/TECH_DESIGN.md §5.6）：正在专注 →「暂停专注」「结束专注」；
/// 暂停中 →「继续专注」「结束专注」。只读内存（`FocusHealthController.session`）。
/// - 暂停 / 继续：「开始 / 暂停专注」那个快捷键动作此刻的 `stateTitle`，同 id（`focushealth.focus`）、同动作（`toggleFocus`）。
/// - 结束：`endFocusEarly(countAsDone: true)`，同暂停卡片上的「结束这一轮」、菜单「提前结束 ▸ 记为完成」（用户 2026-11-08 选的：
///   结束算完成）。没有对应的快捷键，id 是 `focushealth.endFocus`。
/// 写在扩展里（不动 `FocusHealthTool.swift`）：协议要求由这里的实现满足。
extension FocusHealthTool {
    func launcherContextSuggestions() -> [LauncherCommand] {
        let controller = FocusHealthController.shared
        guard controller.session.inFocus else { return [] }
        let toggleSymbol = controller.session.phase == .focusing ? "pause.circle" : "play.circle"
        var commands = hotkeys().filter { $0.id == "focushealth.focus" }
            .compactMap { $0.launcherStateCommand(symbolName: toggleSymbol) }
        commands.append(LauncherCommand(id: "focushealth.endFocus", title: L("focus.launcher.end"), symbolName: "stop.circle") { _ in
            FocusHealthController.shared.endFocusEarly(countAsDone: true)
        })
        return commands
    }
}
