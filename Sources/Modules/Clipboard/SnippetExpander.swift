import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// 关键字展开：在任意输入框里打 `;mail`，就地换成对应片段的内容。
///
/// ## 隐私边界（先看这段）
///
/// 这个功能要监听全局键盘输入，是本 App 里权限最敏感的一处，所以边界写死在这里：
///
/// - **默认关**，用户必须在设置里显式打开；
/// - 只在内存里维护一个 ≤32 字符的滚动缓冲做前缀匹配，**绝不落盘、绝不进剪贴板历史、
///   不做任何统计**；
/// - 遇到 ⏎ / ⇥ / 空格 / esc / 方向键 / 任何带 ⌘⌃⌥ 的组合键立刻清空缓冲；
/// - 命中忽略名单里的 App 直接不展开（复用剪贴板的按 App 忽略名单）；
/// - 密码框等开启了 secure input 的场景，系统根本不会把按键投递给 event tap，
///   天然拿不到 —— 这是系统给的保护，不是靠我们自觉。
///
/// 需要辅助功能权限（与剪贴板回填粘贴同一个）。没授权时静默不启用，不弹窗打扰。
///
/// 并发：类本身**不**标 `@MainActor` —— CGEventTap 的 C 回调不能捕获隔离上下文，
/// 必须能从非隔离上下文取到单例（与 `HotkeyCenter` 同一处理）。tap source 挂在主 run loop，
/// 回调实际就在主线程，内部用 `MainActor.assumeIsolated` 过渡。
final class SnippetExpander {
    static let shared = SnippetExpander()

    // MARK: - 设置

    static let enabledKey = "clipboard.snippetExpandEnabled"
    static let prefixKey = "clipboard.snippetPrefix"
    static let restoreClipboardKey = "clipboard.snippetRestoreClipboard"

    /// 默认**关**：这个开关背后是全局键盘监听，不该有默认打开的余地。
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var prefix: String {
        let raw = UserDefaults.standard.string(forKey: prefixKey) ?? ";"
        return raw.isEmpty ? ";" : raw
    }

    static var restoresClipboard: Bool {
        UserDefaults.standard.object(forKey: restoreClipboardKey) as? Bool ?? true
    }

    /// 缓冲上限。够长到装下「前缀 + 关键字」，又短到没有留存价值。
    private static let maxBuffer = 32

    // MARK: - 状态

    private weak var store: ClipboardStore?
    private weak var monitor: ClipboardMonitor?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// 仅内存，随时可丢。
    private var buffer = ""
    /// 正在展开：自己合成的退格与 ⌘V 会再次流经本 tap，不能递归处理。
    private var isExpanding = false

    private init() {}

    /// 由 `ClipboardTool.activate()` 装配。
    @MainActor
    func configure(store: ClipboardStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
        refresh()
    }

    /// 设置变更后按开关重新决定启停。
    @MainActor
    func refresh() {
        if Self.isEnabled { start() } else { stop() }
    }

    // MARK: - 监听

    @MainActor
    private func start() {
        guard tap == nil, store != nil else { return }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        // C 函数指针：不能捕获任何上下文，只引用全局单例。
        let callback: CGEventTapCallBack = { _, _, event, _ in
            if SnippetExpander.shared.handleKeyDown(event) {
                return nil // 命中：吞掉触发词的最后一个字符，后续由展开流程接管
            }
            return Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .defaultTap,
                                              eventsOfInterest: mask,
                                              callback: callback,
                                              userInfo: nil) else {
            return // 无辅助功能权限等 → 静默不启用，不影响其它功能
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(nil, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    @MainActor
    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        buffer.removeAll()
    }

    // MARK: - 按键处理

    /// tap 回调入口（非隔离）。返回 true = 吞掉这次按键。
    fileprivate func handleKeyDown(_ event: CGEvent) -> Bool {
        MainActor.assumeIsolated {
            self.processKeyDown(event)
        }
    }

    @MainActor
    private func processKeyDown(_ event: CGEvent) -> Bool {
        guard !isExpanding, let store else { return false }

        let flags = event.flags
        // 带 ⌘⌃⌥ 的是命令而不是输入，清缓冲。
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            buffer.removeAll()
            return false
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case Int(kVK_Return), Int(kVK_ANSI_KeypadEnter), Int(kVK_Tab), Int(kVK_Escape), Int(kVK_Space),
             Int(kVK_LeftArrow), Int(kVK_RightArrow), Int(kVK_UpArrow), Int(kVK_DownArrow):
            buffer.removeAll()
            return false
        case Int(kVK_Delete), Int(kVK_ForwardDelete):
            if !buffer.isEmpty { buffer.removeLast() }
            return false
        default:
            break
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else {
            buffer.removeAll()
            return false
        }
        let typed = String(utf16CodeUnits: chars, count: length)
        guard !typed.isEmpty, !typed.contains(where: { $0.isNewline }) else {
            buffer.removeAll()
            return false
        }

        buffer.append(typed)
        if buffer.count > Self.maxBuffer {
            buffer.removeFirst(buffer.count - Self.maxBuffer)
        }

        // 匹配「前缀 + 关键字」结尾：取最后一个前缀之后的部分当关键字。
        let prefix = Self.prefix
        guard let range = buffer.range(of: prefix, options: .backwards) else { return false }
        let keyword = String(buffer[range.upperBound...])
        guard !keyword.isEmpty,
              let item = store.snippet(forKeyword: keyword),
              let text = item.text, !text.isEmpty else { return false }
        guard !isIgnoredApp() else {
            buffer.removeAll()
            return false
        }

        // 触发词整体长度 = 前缀 + 关键字。最后一个字符被这次吞掉了，所以只需退 n-1 次。
        let triggerLength = prefix.count + keyword.count
        buffer.removeAll()
        expand(text: text, backspaces: max(triggerLength - 1, 0))
        return true
    }

    /// 前台 App 在剪贴板忽略名单里 → 不展开（终端、密码管理器之类由用户自己列）。
    @MainActor
    private func isIgnoredApp() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return ClipboardStore.ignoredBundleIDs.contains(bundleID)
    }

    // MARK: - 展开

    /// 删触发词 → 内容进剪贴板 → 合成 ⌘V → 还原剪贴板。
    ///
    /// 每一步之间都要留一拍：退格与粘贴挨太近，部分 App 会把两者顺序颠倒；
    /// 剪贴板还原太早，目标 App 还没读完就被改回去，粘出来的是旧内容。
    @MainActor
    private func expand(text: String, backspaces: Int) {
        isExpanding = true
        let previous = Self.restoresClipboard ? NSPasteboard.general.string(forType: .string) : nil

        // 退格必须推到下一拍再发：此刻还在 tap 回调栈里，回调尚未返回、当前这一击也还没被
        // 丢弃，在这里同步 post 事件等于往自己正在处理的队列里插队，顺序不可控。
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Self.sendBackspaces(backspaces)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            MainActor.assumeIsolated {
                self.monitor?.ignoreNextChange = true
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                Self.simulateCommandV()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    MainActor.assumeIsolated {
                        self.isExpanding = false
                        guard let previous else { return }
                        self.monitor?.ignoreNextChange = true
                        let board = NSPasteboard.general
                        board.clearContents()
                        board.setString(previous, forType: .string)
                    }
                }
            }
        }
    }

    private static func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_Delete)
        for _ in 0..<count {
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    private static func simulateCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
