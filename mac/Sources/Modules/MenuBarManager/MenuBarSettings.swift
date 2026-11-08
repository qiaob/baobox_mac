import Foundation

/// 菜单栏管理的设置（docs/menubar-manager/TECH_DESIGN.md §6）。
///
/// 隐藏了哪些**不另外存**：排在占位项左边的就是隐藏的。⌘ 拖完系统会把位置写回各 App 自己的偏好，
/// App 重开、Mac 重启都还在占位项左边（2026-11-08 探针：Rectangle 476 → 574，复原后回到 476）。
enum MenuBarSettings {
    static let enabledKey = "menubar.enabled"
    static let showSqueezedKey = "menubar.showSqueezed"

    /// 默认关：打开后菜单栏里多一个看不见的占位项，之后第一次出现的图标会落进隐藏区，得用户自己决定要不要。
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// 此刻被挤掉、被刘海挡住的图标也放进 Baobox 菜单顶部那一行。
    static var showSqueezed: Bool { UserDefaults.standard.object(forKey: showSqueezedKey) as? Bool ?? true }
}
