import Foundation

/// 快速入口的快捷键 id，只在这里写一次：模块（`LauncherTool.toggleHotkeyID`）和 Core 里按 id 查快捷键的地方
/// （`LauncherHotkeyConflictCheck`）都引用它。id 也是持久化的键名（`hotkey.launcher.toggle`），改了用户录的键位就丢了。
enum LauncherHotkeyID {
    /// 呼出 / 收起快速入口。
    static let toggle = "launcher.toggle"
}
