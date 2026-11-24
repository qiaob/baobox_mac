import AppKit

/// 此刻快速入口的快捷键是不是和正在运行的别的启动器撞了（docs/launcher/TECH_DESIGN.md §9）：快速入口的设置页、面板最下面的提示、
/// 粘贴被挡下时的回执都用它。只读内存（`HotkeyCenter` 的登记、`NSWorkspace.runningApplications`），不读盘。规则在 `LauncherHotkeyConflict`。
@MainActor
enum LauncherHotkeyConflictCheck {
    /// 快速入口的呼出键此刻是不是 ⌘Space。
    static var launcherHotkeyIsCommandSpace: Bool {
        guard let combo = HotkeyCenter.shared.combo(for: LauncherHotkeyConflict.launcherHotkeyID) else { return false }
        return LauncherHotkeyConflict.isCommandSpace(keyCode: combo.keyCode, carbonModifiers: combo.carbonModifiers)
    }

    /// 正在运行、默认也用 ⌘Space 的启动器的名字；快速入口的快捷键不是 ⌘Space、或没有这样的 App 时为 nil。
    static func conflictingLauncherName() -> String? {
        let combo = HotkeyCenter.shared.combo(for: LauncherHotkeyConflict.launcherHotkeyID)
        return LauncherHotkeyConflict.conflictingLauncher(
            keyCode: combo?.keyCode, carbonModifiers: combo?.carbonModifiers,
            runningBundleIDs: NSWorkspace.shared.runningApplications.map(\.bundleIdentifier))
    }
}
