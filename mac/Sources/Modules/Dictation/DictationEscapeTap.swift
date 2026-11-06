import AppKit
import CoreGraphics

/// 听写中临时开的 Esc 拦截（docs/dictation/TECH_DESIGN.md §6）：只吞不带 ⌘⌥⌃ 的 Esc（keyCode 53）并通知取消，
/// 其余按键原样放行（⌘⌥Esc 强制退出照常可用）。系统因超时停用 tap 时重新启用；听写结束即关。
/// 要辅助功能权限，没有就开不起来（只能点录音条上的 ✕）。
///
/// C 回调不能捕获上下文：经静态的 `active` 找到当前实例（同 `HotkeyCenter` / `SnippetExpander` 的做法）。
/// tap source 挂在主 run loop，回调就在主线程。
@MainActor
final class DictationEscapeTap {
    private static weak var active: DictationEscapeTap?

    /// 按了 Esc（下一拍在主线程调，不在 tap 回调栈里改 tap）。
    var onEscape: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// 开启；没有辅助功能权限等原因开不起来返回 false。
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard Permissions.hasAccessibility else { return false }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let callback: CGEventTapCallBack = { _, type, event, _ in
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let swallow = MainActor.assumeIsolated {
                DictationEscapeTap.handle(type: type, keyCode: keyCode, flags: flags)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .defaultTap,
                                              eventsOfInterest: mask,
                                              callback: callback,
                                              userInfo: nil) else {
            return false
        }
        tap = created
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        Self.active = self
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        if Self.active === self { Self.active = nil }
    }

    /// 返回 true = 吞掉这次按键。
    private static func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard let owner = active else { return false }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .keyDown:
            break
        default:
            return false
        }
        guard keyCode == 53,
              !flags.contains(.maskCommand), !flags.contains(.maskAlternate), !flags.contains(.maskControl) else {
            return false
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DictationEscapeTap.active?.onEscape?()
            }
        }
        return true
    }
}
