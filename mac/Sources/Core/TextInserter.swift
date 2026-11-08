import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// 把一段文字送进当前输入焦点，按可靠性自动降级（docs/dictation/TECH_DESIGN.md §5）：
/// 1. 辅助功能直接写进焦点输入框，写完读回，**值变了才算成功**；
/// 2. 借剪贴板粘贴（`PasteboardBorrow.paste`，不进剪贴板历史）—— 终端、Electron、网页内容区直接走这条；
/// 3. 都不行（安全输入、没权限、没有可输入的焦点）→ 普通复制，调用方提示用户 ⌘V。
/// 选档规则在 `TextInsertionPolicy`（纯逻辑，可单测）。只在主线程使用。
@MainActor
enum TextInserter {
    enum Mode {
        /// 能直接写就写，写不进去再粘贴。
        case auto
        /// 一律借剪贴板粘贴（某些 App 直接写入表现不对时用）。
        case alwaysPaste
    }

    enum Result: Equatable {
        case ax
        case paste
        /// 已复制到剪贴板（会进剪贴板历史：这是给用户的复制）。`copyOnFailure: false` 时只表示没插进去、没复制。
        case copied(TextInsertionPolicy.CopyReason)

        var inserted: Bool {
            switch self {
            case .ax, .paste: return true
            case .copied: return false
            }
        }
    }

    private static let log = Logger(subsystem: "com.baobox.app", category: "textinserter")
    /// 辅助功能查询的超时（秒）：目标 App 卡住时别把我们一起拖住（系统默认要等好几秒）。
    private static let messagingTimeout: Float = 0.5

    /// `target` 为 nil = 此刻的前台 App。`copyOnFailure` 为 false 时插不进去只返回 `.copied(原因)`、不动剪贴板
    /// （连续听写攒到结束一次复制，docs/dictation/TECH_DESIGN.md §3.1）。
    static func insert(_ text: String, into target: NSRunningApplication? = nil, mode: Mode = .auto,
                       copyOnFailure: Bool = true) async -> Result {
        guard !text.isEmpty else { return .ax }
        func fail(_ reason: TextInsertionPolicy.CopyReason) -> Result {
            copyOnFailure ? copy(text, reason: reason) : .copied(reason)
        }
        // 密码框（安全输入）不粘贴：粘进去的东西用户看不见，也可能被当成密码提交。
        if IsSecureEventInputEnabled() {
            return fail(.secureInput)
        }
        guard Permissions.hasAccessibility else {
            return fail(.noAccessibility)
        }
        guard let app = target ?? NSWorkspace.shared.frontmostApplication else {
            return fail(.noTextFocus)
        }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // 焦点在 Baobox 自己的窗口里（设置页、剪贴板搜索框…）：直接交给第一响应者。
            return insertIntoOwnWindow(text) ? .ax : fail(.noTextFocus)
        }

        let pasteOnly = TextInsertionPolicy.isPasteOnly(bundleID: app.bundleIdentifier, appURL: app.bundleURL)
        let probe = pasteOnly ? nil : focusProbe(of: app)
        let route = TextInsertionPolicy.route(pasteOnly: pasteOnly,
                                              browser: TextInsertionPolicy.isBrowser(bundleID: app.bundleIdentifier),
                                              alwaysPaste: mode == .alwaysPaste, focus: probe?.focus)
        let bundle = app.bundleIdentifier ?? "?"
        log.notice("insert into \(bundle, privacy: .public): route \(String(describing: route), privacy: .public), role \(probe?.focus.role ?? "-", privacy: .public)")

        switch route {
        case .copy(let reason):
            return fail(reason)
        case .paste:
            return await paste(text, copyOnFailure: copyOnFailure)
        case .accessibility:
            if let element = probe?.element, await writeViaAccessibility(text, into: element) {
                return .ax
            }
            log.notice("accessibility write did not take in \(bundle, privacy: .public), pasting instead")
            return await paste(text, copyOnFailure: copyOnFailure)
        }
    }

    /// 往前台 App 发 `count` 次退格（连续听写的「删除上一句」：上一句已经输入进去了，docs/dictation/TECH_DESIGN.md §3.1）。
    /// 密码框（安全输入）里、没有辅助功能权限时不发，返回 false。合成按键走事件队列、AX 写入是同步的：
    /// 发完等一会儿让目标 App 先处理完，后面的写入才不会跑到退格前面。
    @discardableResult
    static func deleteBackward(_ count: Int) async -> Bool {
        guard count > 0, Permissions.hasAccessibility, !IsSecureEventInputEnabled() else { return false }
        // 同 `PasteboardBorrow.paste`：快捷键刚松开时修饰键可能还按着，叠上去就成了 ⌥⌫（删一个词）之类。
        let deadline = Date().addingTimeInterval(0.5)
        let held: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        while !NSEvent.modifierFlags.intersection(held).isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_Delete)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            down?.flags = []
            up?.flags = []
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        return true
    }

    /// 普通复制（进剪贴板历史）。
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func copy(_ text: String, reason: TextInsertionPolicy.CopyReason) -> Result {
        copyToClipboard(text)
        return .copied(reason)
    }

    private static func paste(_ text: String, copyOnFailure: Bool) async -> Result {
        // 划词翻译正借着剪贴板（一秒内就还原）：等它还完再粘。抢着写的话，它一还原就把我们的文字盖掉了。
        for _ in 0..<20 where PasteboardBorrow.isActive {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if await PasteboardBorrow.paste(text) { return .paste }
        return copyOnFailure ? copy(text, reason: .busy) : .copied(.busy)
    }

    // MARK: - 辅助功能写入

    private struct Probe {
        let element: AXUIElement?
        let focus: TextInsertionPolicy.Focus
    }

    /// 读前台 App 的焦点元素。nil = App 不回答（不支持辅助功能 / 超时）。
    private static func focusProbe(of app: NSRunningApplication) -> Probe? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if status == .noValue {
            // App 明确说「没有焦点元素」。
            return Probe(element: nil, focus: TextInsertionPolicy.Focus())
        }
        guard status == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var settable = DarwinBoolean(false)
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        let focus = TextInsertionPolicy.Focus(
            role: stringAttribute(element, kAXRoleAttribute) ?? "",
            subrole: stringAttribute(element, kAXSubroleAttribute),
            selectedTextSettable: settableStatus == .success && settable.boolValue,
            valueReadable: stringAttribute(element, kAXValueAttribute) != nil,
            inWebArea: isInWebArea(element)
        )
        return Probe(element: element, focus: focus)
    }

    /// 往焦点元素的选区写入（替换选中的文字 / 插在光标处），再读回值确认。值没变 = 没写进去。
    /// 不看写入调用的返回值：有的 App 报错却写进去了，按值判断才不会再粘一遍变成两份。
    private static func writeViaAccessibility(_ text: String, into element: AXUIElement) async -> Bool {
        guard let before = stringAttribute(element, kAXValueAttribute) else { return false }
        let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if let after = stringAttribute(element, kAXValueAttribute), after != before { return true }
        // 少数 App 晚一拍才更新值。
        try? await Task.sleep(nanoseconds: 80_000_000)
        if let after = stringAttribute(element, kAXValueAttribute), after != before { return true }
        log.notice("accessibility write status \(status.rawValue), value unchanged")
        return false
    }

    /// 某一级祖先是网页内容区（AXWebArea）。最多往上找 12 层。
    private static func isInWebArea(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let node = current else { return false }
            if stringAttribute(node, kAXRoleAttribute) == "AXWebArea" { return true }
            current = elementAttribute(node, kAXParentAttribute)
        }
        return false
    }

    /// 焦点在 Baobox 自己的窗口里：第一响应者是文字视图（含 SwiftUI 文本框的字段编辑器）就直接插入。
    private static func insertIntoOwnWindow(_ text: String) -> Bool {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable else { return false }
        textView.insertText(text, replacementRange: textView.selectedRange())
        return true
    }

    // MARK: - 插入点位置

    /// 前台 App 焦点输入框里插入点（或选区）的屏幕位置，AppKit 坐标（左下原点）。取不到返回 nil。
    /// 录音条据此贴在光标旁（docs/dictation/TECH_DESIGN.md §7）。
    static func caretRect(in target: NSRunningApplication? = nil) -> CGRect? {
        guard Permissions.hasAccessibility,
              let app = target ?? NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard let element = elementAttribute(appElement, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let range = rangeAttribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        if let rect = bounds(of: element, range: range) { return rect }
        // 空选区（只有光标）时不少 App 给不出位置：取光标前一个字，放在它右边。
        guard range.location > 0,
              let previous = bounds(of: element, range: CFRange(location: range.location - 1, length: 1)) else {
            return nil
        }
        return CGRect(x: previous.maxX, y: previous.minY, width: 1, height: previous.height)
    }

    private static func bounds(of element: AXUIElement, range: CFRange) -> CGRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef) == .success,
              let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var quartz = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(boundsRef, to: AXValue.self), .cgRect, &quartz),
              quartz.height > 0, quartz.height < 400, quartz.width < 4000 else { return nil }
        // AX 给的是 Quartz 坐标（主屏左上原点）。
        let rect = Geometry.appKitRect(fromCG: quartz)
        // 落在所有屏幕之外的（有的 App 对不可见的行给出 0,0）不要。
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect.insetBy(dx: -1, dy: -1)) }) else {
            return nil
        }
        return rect
    }

    // MARK: - AX 小工具

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    private static func rangeAttribute(_ element: AXUIElement, _ name: String) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(ref, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }
}
