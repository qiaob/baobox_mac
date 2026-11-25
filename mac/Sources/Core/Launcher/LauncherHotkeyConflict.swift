import Foundation

// 别的启动器也用 ⌘Space（docs/launcher/TECH_DESIGN.md §9）：两个 App 注册同一个组合时系统两边都通知，
// `RegisterEventHotKey` 照样成功，`HotkeyCenter` 测不出来。所以只在**有证据**时提示：
// 快速入口的 ⌘Space 自己注册上了，Raycast 正在运行，且它的偏好里 `raycastGlobalHotkey` 读出来也是 ⌘Space。
// Raycast、Alfred 的出厂快捷键都是 ⌥Space，不能凭「装了 / 开着」就说撞了；Alfred 的绑定读不到，不提前提示，
// 只在粘贴那一刻键盘确实被它占着时出现在回执里。只依赖 Foundation，进 BaoboxTests；
// 读正在运行的 App、此刻的快捷键、Raycast 的那一个偏好键在 `Core/LauncherHotkeyConflictCheck.swift`。

enum LauncherHotkeyConflict {
    /// 快速入口呼出键的快捷键 id（= `LauncherTool.toggleHotkeyID`；Core 不认识模块，写一份）。
    static let launcherHotkeyID = "launcher.toggle"
    /// Space 的虚拟键码。
    static let spaceKeyCode: UInt32 = 0x31
    /// Carbon 的 ⌘（= `KeyCombo.cmd`）。
    static let commandModifier: UInt32 = 256

    static func isCommandSpace(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        keyCode == spaceKeyCode && carbonModifiers == commandModifier
    }

    /// 快速入口的快捷键此刻算不算注册上了：有键位、没在 `HotkeyCenter` 里标冲突、也不在系统保留表里
    /// （Spotlight 占着的组合 `RegisterEventHotKey` 照样「成功」，却永远收不到）。没注册上就谈不上和别人抢。
    static func isRegistered(hasCombo: Bool, markedConflicted: Bool, systemReserved: Bool) -> Bool {
        hasCombo && !markedConflicted && !systemReserved
    }

    // MARK: - 已知启动器（回执里说是谁占着键盘）

    /// 已知启动器：bundle id 前缀 + 显示名。
    /// - Raycast：`com.raycast.macos`。
    /// - Alfred：4 起是 `com.runningwithcrayons.Alfred`（官方说以后的版本都用它），2、3 带版本号后缀（`Alfred-2`、`Alfred-3`）。
    static let knownLaunchers: [(bundleIDPrefix: String, name: String)] = [
        ("com.raycast.macos", "Raycast"),
        ("com.runningwithcrayons.Alfred", "Alfred"),
    ]

    /// bundle id 是不是表里的启动器 → 显示名；nil = 不是。按前缀匹配：等于前缀，或前缀后面是「-版本号」。
    /// 同一家的别的 App 不算 —— Alfred 的偏好设置是另一个 App（`Alfred-Preferences`、`Alfred-Preferences-3`）。
    static func knownLauncherName(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        for launcher in knownLaunchers {
            let prefix = launcher.bundleIDPrefix
            if bundleID == prefix { return launcher.name }
            guard bundleID.hasPrefix(prefix + "-") else { continue }
            let suffix = bundleID.dropFirst(prefix.count + 1)
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) { return launcher.name }
        }
        return nil
    }

    // MARK: - Raycast 的快捷键

    static let raycastBundleID = "com.raycast.macos"
    static let raycastName = "Raycast"
    /// Raycast 存呼出键的偏好键（2026-11-24 用户机器上读出来是 `"Command-49"` = ⌘Space）。只读这一个。
    static let raycastHotkeyKey = "raycastGlobalHotkey"

    /// 别的 App 偏好里存的一个快捷键。
    struct ForeignHotkey: Equatable {
        var keyCode: UInt32
        var command = false
        var option = false
        var shift = false
        var control = false

        /// 修饰键只有 ⌘、键是 Space。
        var isCommandSpace: Bool {
            keyCode == LauncherHotkeyConflict.spaceKeyCode && command && !option && !shift && !control
        }
    }

    /// 解析 `raycastGlobalHotkey`：修饰键名用「-」连起来，最后是十进制键码（`Command-49`、`Command-Shift-49`）。
    /// 修饰键名认 Command / Option / Shift / Control（不分大小写）；空、没有键码、有认不出的名字一律 nil（= 当作没有冲突）。
    static func parseRaycastHotkey(_ value: String?) -> ForeignHotkey? {
        guard let value else { return nil }
        let parts = value.trimmingCharacters(in: .whitespaces).components(separatedBy: "-")
        guard let last = parts.last, !last.isEmpty, last.allSatisfy(\.isASCII), last.allSatisfy(\.isNumber),
              let keyCode = UInt32(last) else { return nil }
        var hotkey = ForeignHotkey(keyCode: keyCode)
        for name in parts.dropLast() {
            switch name.lowercased() {
            case "command": hotkey.command = true
            case "option": hotkey.option = true
            case "shift": hotkey.shift = true
            case "control": hotkey.control = true
            default: return nil
            }
        }
        return hotkey
    }

    /// 有证据的冲突 → 那个 App 的名字（现在只有 Raycast）；否则 nil。条件全都要满足：
    /// 快速入口的快捷键是 ⌘Space，而且它自己注册上了（被 Spotlight 占着、标了冲突时它根本收不到，谈不上和别人抢）；
    /// Raycast 正在运行；它的 `raycastGlobalHotkey` 读得出来、也是 ⌘Space。
    static func confirmedConflict(ourKeyCode: UInt32?, ourModifiers: UInt32?, ourRegistered: Bool,
                                  raycastRunning: Bool, raycastHotkey: String?) -> String? {
        guard let ourKeyCode, let ourModifiers, ourRegistered,
              isCommandSpace(keyCode: ourKeyCode, carbonModifiers: ourModifiers),
              raycastRunning, parseRaycastHotkey(raycastHotkey)?.isCommandSpace == true else { return nil }
        return raycastName
    }

    // MARK: - 回执

    /// 键盘被第三个 App 占着、没粘贴时的回执说哪一句。
    enum BlockedReceipt: Equatable {
        /// 「<名字> 也在用 ⌘Space，两个会同时响应。请在其中一个里换个快捷键」：占着键盘的正是确认了冲突的那个 App。
        case hotkeyConflict(name: String)
        /// 「键盘正被 <名字> 占着，没有粘贴；内容已复制，按 ⌘V 粘贴」。
        case keyboardHeld
    }

    /// - Parameter confirmedConflict: `confirmedConflict(…)` 此刻的结果。
    static func blockedReceipt(holderBundleID: String?, confirmedConflict: String?) -> BlockedReceipt {
        if let confirmedConflict, knownLauncherName(bundleID: holderBundleID) == confirmedConflict {
            return .hotkeyConflict(name: confirmedConflict)
        }
        return .keyboardHeld
    }
}
