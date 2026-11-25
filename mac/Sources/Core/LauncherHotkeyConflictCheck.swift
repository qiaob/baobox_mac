import AppKit

/// 此刻快速入口的快捷键是不是确实和正在运行的 Raycast 撞了（docs/launcher/TECH_DESIGN.md §9）：快速入口的设置页、
/// 面板最下面的提示、粘贴被挡下时的回执都用它。规则在 `LauncherHotkeyConflict.confirmedConflict`。
/// 读的东西：`HotkeyCenter` 的登记、冲突标记和缓存的系统保留表（内存）、`NSWorkspace.runningApplications`（内存），前两样都满足时才读 Raycast 偏好里的
/// `raycastGlobalHotkey` 这一个键（`CFPreferencesCopyAppValue`，只读，不写、不同步、不读别的键）。
@MainActor
enum LauncherHotkeyConflictCheck {
    /// 确认撞了的那个 App 的名字（Raycast）；没有证据时为 nil。
    static func confirmedConflictName() -> String? {
        let id = LauncherHotkeyID.toggle
        let combo = HotkeyCenter.shared.combo(for: id)
        let registered = LauncherHotkeyConflict.isRegistered(
            hasCombo: combo != nil,
            markedConflicted: HotkeyCenter.shared.conflictedIDs.contains(id),
            systemReserved: combo.map { HotkeyCenter.shared.isSystemReserved($0) } ?? false)
        let ourCommandSpace = combo.map {
            LauncherHotkeyConflict.isCommandSpace(keyCode: $0.keyCode, carbonModifiers: $0.carbonModifiers)
        } ?? false
        let raycastRunning = ourCommandSpace && registered && NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == LauncherHotkeyConflict.raycastBundleID
        }
        // 前面都满足才去读它的偏好（一次 cfprefsd 往返）。
        let raycastHotkey = raycastRunning ? readRaycastHotkey() : nil
        return LauncherHotkeyConflict.confirmedConflict(ourKeyCode: combo?.keyCode, ourModifiers: combo?.carbonModifiers,
                                                        ourRegistered: registered, raycastRunning: raycastRunning,
                                                        raycastHotkey: raycastHotkey)
    }

    /// Raycast 偏好里的 `raycastGlobalHotkey`（如 `"Command-49"`）；没有、不是字符串时为 nil。
    private static func readRaycastHotkey() -> String? {
        CFPreferencesCopyAppValue(LauncherHotkeyConflict.raycastHotkeyKey as CFString,
                                  LauncherHotkeyConflict.raycastBundleID as CFString) as? String
    }
}
