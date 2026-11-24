import Foundation

// 别的启动器也用 ⌘Space（docs/launcher/TECH_DESIGN.md §9）：两个 App 注册同一个组合时系统两边都通知，
// `RegisterEventHotKey` 照样成功，`HotkeyCenter` 测不出来。只能按「快速入口的快捷键是 ⌘Space + 某个默认也用 ⌘Space
// 的启动器正在运行」提示 —— 它实际绑的是什么读不到，所以文案说「默认也用」。只依赖 Foundation，进 BaoboxTests；
// 读正在运行的 App、此刻的快捷键在 `Core/LauncherHotkeyConflictCheck.swift`。

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

    /// 默认也用 ⌘Space 的已知启动器：bundle id 前缀 + 显示名。
    /// - Raycast：`com.raycast.macos`。
    /// - Alfred：4 起是 `com.runningwithcrayons.Alfred`（官方说以后的版本都用它），2、3 带版本号后缀（`Alfred-2`、`Alfred-3`）。
    static let knownLaunchers: [(bundleIDPrefix: String, name: String)] = [
        ("com.raycast.macos", "Raycast"),
        ("com.runningwithcrayons.Alfred", "Alfred"),
    ]

    /// bundle id 是不是表里的启动器 → 显示名；nil = 不是。按前缀匹配：等于前缀，或前缀后面是「-版本号」。
    /// 同一家的别的 App 不算 —— Alfred 的偏好设置是另一个 App（`Alfred-Preferences`、`Alfred-Preferences-3`），
    /// 它开着不说明 Alfred 在响应 ⌘Space。
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

    /// 要不要提示冲突：快速入口的快捷键是 ⌘Space（nil = 没绑），且正在运行的 App 里有已知启动器 → 第一个的名字。
    static func conflictingLauncher(keyCode: UInt32?, carbonModifiers: UInt32?, runningBundleIDs: [String?]) -> String? {
        guard let keyCode, let carbonModifiers, isCommandSpace(keyCode: keyCode, carbonModifiers: carbonModifiers) else {
            return nil
        }
        for bundleID in runningBundleIDs {
            if let name = knownLauncherName(bundleID: bundleID) { return name }
        }
        return nil
    }

    /// 键盘被第三个 App 占着、没粘贴时的回执说哪一句。
    enum BlockedReceipt: Equatable {
        /// 「<名字> 也在用 ⌘Space，两个会同时响应。请在其中一个里换个快捷键」：快速入口是 ⌘Space、占着键盘的是已知启动器。
        case hotkeyConflict(name: String)
        /// 「键盘正被 <名字> 占着，没有粘贴；内容已复制，按 ⌘V 粘贴」。
        case keyboardHeld
    }

    static func blockedReceipt(holderBundleID: String?, launcherHotkeyIsCommandSpace: Bool) -> BlockedReceipt {
        if launcherHotkeyIsCommandSpace, let name = knownLauncherName(bundleID: holderBundleID) {
            return .hotkeyConflict(name: name)
        }
        return .keyboardHeld
    }
}
