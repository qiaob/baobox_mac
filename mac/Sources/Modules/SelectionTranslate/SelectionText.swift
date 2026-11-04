import AppKit
import ApplicationServices
import NaturalLanguage

/// 一次取词的结果。见 docs/selection-translate/DESIGN.md §2。
struct SelectionTextResult {
    let text: String
    /// 选区在 AppKit 屏幕坐标（左下原点）里的位置；nil = 没拿到，浮层退回鼠标位置。
    let anchorRect: CGRect?
    /// 哪条路径取到的。
    let route: Route

    enum Route {
        case accessibility
        case copyFallback
        case ocr
    }
}

/// 本功能只做英⇄中：判定原文是中文还是英文，译文自动取另一种。
enum SelectionLanguage {
    case chinese
    case english

    var other: SelectionLanguage { self == .chinese ? .english : .chinese }

    /// Translation 框架用的语言代码。
    var translationCode: String {
        switch self {
        case .chinese: return "zh-Hans"
        case .english: return "en"
        }
    }

    /// 朗读用的嗓音语言。
    var voiceLanguage: String {
        switch self {
        case .chinese: return "zh-CN"
        case .english: return "en-US"
        }
    }

    /// 语言名按惯例用各自语言书写，不随界面语言翻译。
    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
}

/// 取词：AX 读选中文字为主，模拟 ⌘C 兜底（仅手动触发时用）。
enum SelectionText {

    /// 语种判定（本地 NLLanguageRecognizer）。认不出就按内容兜底：
    /// 含中日韩表意字 → 中文，否则英文。
    static func detectLanguage(of text: String) -> SelectionLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese, .english]
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .simplifiedChinese, .traditionalChinese:
            return .chinese
        case .english:
            return .english
        default:
            let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            return hasCJK ? .chinese : .english
        }
    }

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
        return SelectionTextResult(text: text, anchorRect: selectionBounds(of: element), route: .accessibility)
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

    // MARK: - ⌘C 兜底

    /// 模拟一次 ⌘C 读剪贴板再**恢复原内容**。会短暂改动剪贴板，
    /// 剪贴板监听可能把这一条记进历史 —— 已知代价，见设计文档 §2。
    @MainActor
    static func fetchViaCopyFallback() async -> SelectionTextResult? {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotItems(of: pasteboard)
        let changeBefore = pasteboard.changeCount

        postCommandC()
        var copied: String?
        // 等前台 App 把选区写进剪贴板，最多 ~0.35 秒。
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if pasteboard.changeCount != changeBefore {
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        restore(snapshot, to: pasteboard)

        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let mouse = NSEvent.mouseLocation
        return SelectionTextResult(text: copied,
                                   anchorRect: CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1),
                                   route: .copyFallback)
    }

    private static func snapshotItems(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
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
