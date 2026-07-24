import Foundation

/// 键盘点击（Click Mode）—— 常量与设置。
enum KeyboardNavEnv {
    /// 标签字符集（home-row 优先，Homerow 风格；两字符组合手指基本不离基准键位）。
    static let hintCharacters = "sadfjklewcmpgh"

    /// AX 遍历护栏：最大深度、最大元素数、整体超时（防大型 App 的 AX 树把主流程拖死）。
    static let maxDepth = 40
    static let maxElements = 500
    static let scanTimeout: TimeInterval = 0.35

    /// 标签显示范围："current"（仅当前屏，前台 App 焦点窗口所在屏）| "all"（所有屏）。
    /// 默认「当前屏」——多显示器时减少干扰。
    static let labelScopeKey = "keyboardnav.labelScope"
    static var labelScope: String {
        UserDefaults.standard.string(forKey: labelScopeKey) ?? "current"
    }
}
