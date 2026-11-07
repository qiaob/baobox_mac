import CoreGraphics
import Foundation

/// 锁屏（docs/focus-health/TECH_DESIGN.md §5.6）：休息结束 30 秒没人用 Touch ID 确认时，交给系统锁屏。
///
/// 只用公开 API：替用户按系统「锁定屏幕」快捷键 ⌃⌘Q（CGEvent 发到 HID 层，需要辅助功能权限 —— Baobox 本来就要）。
/// 2026-11-08 探针：macOS 14 没有了 `CGSession -suspend`；用户的「熄屏后多久要密码」是 4 小时，靠熄屏不安全；
/// 私有的 `SACLockScreenImmediate` 不用（项目只用公开 API）。
enum ScreenLock {
    /// 按 ⌃⌘Q。
    static func lockNow() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyQ: CGKeyCode = 12
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyQ, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyQ, keyDown: false)
        down?.flags = [.maskControl, .maskCommand]
        up?.flags = [.maskControl, .maskCommand]
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 屏幕现在锁着没有（登录会话信息里的 `CGSSessionScreenIsLocked`）。
    static var isLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let flag = info["CGSSessionScreenIsLocked"] as? Bool { return flag }
        return (info["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}
