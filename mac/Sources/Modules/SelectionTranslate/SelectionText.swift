import AppKit
import ApplicationServices
import os

enum SelectionTranslateLog {
    static let selection = Logger(subsystem: "com.baobox.app", category: "selectiontranslate")
}

/// 一次取词的结果。见 docs/selection-translate/DESIGN.md §2。
struct SelectionTextResult {
    let text: String
    /// 选区在 AppKit 屏幕坐标（左下原点）里的位置；nil = 没拿到，浮层退回鼠标位置。
    let anchorRect: CGRect?
    /// 哪条路径取到的。
    let route: Route
    /// 选区在一个可写的输入框里（AX 确认 `kAXSelectedText` 可设）：改写类结果可以替换回去。
    /// 借剪贴板 / 框选取到的一律为 nil（docs/selection-translate/ASSISTANT.md §1.5）。
    var editTarget: SelectionEditTarget? = nil
    /// 选中的词所在的整句（AX 读得到全文时），学习的词典卡用。
    var context: String? = nil

    enum Route {
        case accessibility
        /// 借剪贴板：按前台 App 自己的「拷贝」菜单项。
        case menuCopy
        /// 借剪贴板：合成 ⌘C（仅手动触发、且菜单栏里找不到「拷贝」时）。
        case keystrokeCopy
        /// App 自己在选中时就拷进了剪贴板（终端的「选中即复制」、TUI 用 OSC 52 自己复制）。
        case appCopied
        case ocr
    }
}

/// 可以把结果替换回去的那个输入框：取词时的元素和当时选中的文字。替换前据此再核对一次。
struct SelectionEditTarget {
    let pid: pid_t
    let element: AXUIElement
    let originalText: String
}

/// 取词：AX 读选中文字为主；读不到时借剪贴板 —— 按前台 App 自己的「拷贝」菜单项，
/// 手动触发且找不到菜单项时才合成 ⌘C。
/// 语种判定在共享层 `LanguageDetector`（docs/translation-engine/DESIGN.md §3.1）。
enum SelectionText {

    // MARK: - AX 路径

    /// 读前台 App 当前焦点元素的选中文字。取不到（没选中 / App 不暴露）返回 nil。
    @MainActor
    static func fetchViaAccessibility() -> SelectionTextResult? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)

        guard let text = selectedText(of: element),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var result = SelectionTextResult(text: text, anchorRect: selectionBounds(of: element), route: .accessibility)
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            result.editTarget = SelectionEditTarget(pid: app.processIdentifier, element: element, originalText: text)
        }
        result.context = sentence(around: element)
        return result
    }

    /// 替换前再读一次那个输入框此刻选中的文字（docs/selection-translate/ASSISTANT.md §2.4）。
    @MainActor
    static func currentSelection(of target: SelectionEditTarget) -> String? {
        selectedText(of: target.element)
    }

    /// 选区所在的整句：读全文 + 选区范围，按句末标点往两边找，最多 300 字。读不到 / 就是选区本身时返回 nil。
    private static func sentence(around element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length > 0 else { return nil }
        return SelectionSentence.extract(from: value as NSString,
                                         selection: NSRange(location: range.location, length: range.length))
    }

    /// 先读 kAXSelectedText；没有就用「全文 + 选区范围」切（不少文本视图只给后者）。
    private static func selectedText(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &ref) == .success,
           let text = ref as? String, !text.isEmpty {
            return text
        }
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length > 0 else { return nil }
        // AX 的 CFRange 按 UTF-16 计，与 NSString 同口径。
        let ns = value as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: range.location, length: range.length))
    }

    /// 选区的屏幕位置（AppKit 坐标）。拿不到返回 nil。
    private static func selectionBounds(of element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsRef) == .success,
              let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var quartz = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &quartz), quartz.width > 0 || quartz.height > 0 else {
            return nil
        }
        // AX 给的是 Quartz 坐标（主屏左上原点），翻成 AppKit 坐标（主屏左下原点）。
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: quartz.minX,
                      y: primaryHeight - quartz.minY - quartz.height,
                      width: quartz.width,
                      height: quartz.height)
    }

    // MARK: - 借剪贴板兜底

    enum CopyMethod {
        /// 用 AX 按了 App 自己的「拷贝」菜单项。
        case menu
        /// 合成了一次 ⌘C 按键。
        case keystroke
    }

    enum CopyOutcome {
        case copied(String, CopyMethod)
        /// 菜单栏里没有快捷键为 ⌘C 的项（或菜单栏读不到）。
        case noMenuItem
        /// 「拷贝」置灰：App 认为没有选区。
        case disabled
        /// 按了「拷贝」但剪贴板没变（或拷到的只有空白）。
        case nothingCopied
        /// 拷到的是文件 / 图片：不是在选文字。
        case notText

        /// 写日志用：不带选中的文字本身。
        var logDescription: String {
            switch self {
            case .copied(let text, let method): return "copied \(text.count) chars via \(method)"
            case .noMenuItem: return "no copy menu item"
            case .disabled: return "copy disabled"
            case .nothingCopied: return "nothing copied"
            case .notText: return "not text"
            }
        }
    }

    /// 本次运行里「按菜单项不拷、得真按 ⌘C 才拷」的 App。终端常见：拷贝选区走的是视图自己的
    /// 快捷键处理，菜单里的「拷贝」被按下也不动剪贴板（实测 Otty）。记住后直接按 ⌘C，省掉白等的那一拍。
    @MainActor private static var keystrokeCopyApps: Set<pid_t> = []

    /// 借剪贴板取词，见设计文档 §2.1。要求前台 App 菜单栏里有快捷键 ⌘C 的「拷贝」且没置灰（置灰 = 没有选区，
    /// 这时不碰剪贴板、不响提示音）。先用 AX 按这一项；剪贴板没动静再合成一次 ⌘C。
    @MainActor
    static func copyViaMenu(pid: pid_t, allowImages: Bool) async -> CopyOutcome {
        guard let item = copyMenuItem(pid: pid) else { return .noMenuItem }
        guard isEnabled(item) else { return .disabled }
        var pressResult = AXError.success
        let pressMenu: PasteboardBorrow.Trigger = {
            pressResult = AXUIElementPerformAction(item, kAXPressAction as CFString)
            return pressResult == .success
        }
        let pressKeys: PasteboardBorrow.Trigger = {
            postCommandC()
            return true
        }
        let knownKeystroke = keystrokeCopyApps.contains(pid)
        let triggers = knownKeystroke ? [pressKeys] : [pressMenu, pressKeys]
        let (result, used) = await PasteboardBorrow.copy(allowImages: allowImages, triggers: triggers)
        let method: CopyMethod = knownKeystroke || used == 1 ? .keystroke : .menu
        // 诊断：按的是哪一项、AXPress 返回什么、有没有走到合成 ⌘C（不记选中的文字本身）。
        let title = stringAttribute(item, kAXTitleAttribute) ?? "?"
        SelectionTranslateLog.selection.notice(
            "menu item \"\(title, privacy: .public)\": press \(knownKeystroke ? "skipped" : String(pressResult.rawValue), privacy: .public), keystroke \(method == .keystroke ? "sent" : "not needed", privacy: .public)")
        if case .text = result, method == .keystroke { keystrokeCopyApps.insert(pid) }
        return outcome(of: result, method: method)
    }

    /// 合成一次 ⌘C 借剪贴板取词。只给手动触发、且菜单栏里找不到「拷贝」的 App 用。
    @MainActor
    static func copyViaKeystroke() async -> CopyOutcome {
        let (result, _) = await PasteboardBorrow.copy(allowImages: true, triggers: [{
            postCommandC()
            return true
        }])
        return outcome(of: result, method: .keystroke)
    }

    private static func outcome(of result: PasteboardBorrow.Result, method: CopyMethod) -> CopyOutcome {
        switch result {
        case .text(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothingCopied : .copied(text, method)
        case .unchanged:
            return .nothingCopied
        case .notText:
            return .notText
        }
    }

    /// 按 pid 缓存「拷贝」所在的菜单；菜单项每次现找（App 可能重建菜单项）。
    @MainActor private static var copyMenuCache: (pid: pid_t, menu: AXUIElement)?

    /// 前台 App 菜单栏里快捷键为 ⌘C 的菜单项。按快捷键认而不按标题认：标题随系统语言变（Copy / 拷贝 / 复制）。
    @MainActor
    private static func copyMenuItem(pid: pid_t) -> AXUIElement? {
        if let cache = copyMenuCache, cache.pid == pid, let item = copyItem(in: cache.menu) {
            return item
        }
        copyMenuCache = nil
        guard let menuBar = elementAttribute(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else {
            return nil
        }
        // 跳过第一个（苹果菜单）；「编辑」通常是第 3～4 个，按顺序找很快就到。
        for barItem in childElements(of: menuBar).dropFirst() {
            for menu in childElements(of: barItem) {
                if let item = copyItem(in: menu) {
                    copyMenuCache = (pid, menu)
                    return item
                }
            }
        }
        return nil
    }

    private static func copyItem(in menu: AXUIElement) -> AXUIElement? {
        childElements(of: menu).first(where: isCopyShortcut)
    }

    private static func isCopyShortcut(_ item: AXUIElement) -> Bool {
        var charRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &charRef) == .success,
              let char = charRef as? String, char.lowercased() == "c" else { return false }
        var modifiersRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString,
                                            &modifiersRef) == .success,
              let modifiers = modifiersRef as? Int else { return false }
        // kAXMenuItemModifierNone（0）= 只按 ⌘；带 ⇧ / ⌥ / ⌃ 的不是「拷贝」。
        return modifiers == 0
    }

    private static func isEnabled(_ item: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &ref) == .success else {
            return false
        }
        return (ref as? Bool) ?? false
    }

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

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let objects = ref as? [AnyObject] else { return [] }
        return objects.compactMap { object in
            CFGetTypeID(object) == AXUIElementGetTypeID() ? unsafeBitCast(object, to: AXUIElement.self) : nil
        }
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        // 0x08 = kVK_ANSI_C（Carbon 虚拟键码，避免为一个常量引整个 Carbon 头）。
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// 从全文里切出选区所在的句子（纯逻辑）。
enum SelectionSentence {
    private static let terminators: Set<unichar> = Set("。！？!?\n".utf16)
    private static let maxLength = 300

    static func extract(from text: NSString, selection: NSRange) -> String? {
        guard selection.location >= 0, selection.location + selection.length <= text.length else { return nil }
        var start = selection.location
        var steps = 0
        while start > 0, steps < maxLength {
            let previous = text.character(at: start - 1)
            if terminators.contains(previous) || isPeriodEnd(text, at: start - 1) { break }
            start -= 1
            steps += 1
        }
        var end = selection.location + selection.length
        steps = 0
        while end < text.length, steps < maxLength {
            let current = text.character(at: end)
            end += 1
            steps += 1
            if terminators.contains(current) || isPeriodEnd(text, at: end - 1) { break }
        }
        let sentence = text.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = text.substring(with: selection).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentence.count > selected.count, sentence.count <= maxLength else { return nil }
        return sentence
    }

    /// 英文句点后面跟空白（或在末尾）才算句末，避免把 e.g. / 3.14 当句末。
    private static func isPeriodEnd(_ text: NSString, at index: Int) -> Bool {
        guard text.character(at: index) == 0x2E else { return false }
        guard index + 1 < text.length else { return true }
        let next = text.character(at: index + 1)
        return next == 0x20 || next == 0x0A || next == 0x09
    }
}
