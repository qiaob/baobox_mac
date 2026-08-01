import AppKit

/// 大窗编辑器（2026-08-02 增补）：面板预览区放不下的大 JSON / 长文本，开成
/// 独立的标准窗口（可拉伸、绿灯全屏），内容**可编辑**（NSTextView，大文本
/// 性能好、自带撤销与 ⌘F 查找条）；底部「复制」把编辑结果写回剪贴板。
@MainActor
final class ClipboardEditorWindow: NSWindow, NSWindowDelegate {

    /// 强引用池：isReleasedWhenClosed = false，生命周期由这里管理。
    private static var editors: [ClipboardEditorWindow] = []

    static func open(text: String) {
        let window = ClipboardEditorWindow(text: text)
        editors.append(window)
        // 无 Dock 图标的 accessory App：不先激活，窗口拿不到键盘焦点，没法编辑。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private let textView: NSTextView

    private init(text: String) {
        let contentRect = NSRect(x: 0, y: 0, width: 900, height: 640)
        let barHeight: CGFloat = 44

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: barHeight,
                                                    width: contentRect.width,
                                                    height: contentRect.height - barHeight))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]

        let editor = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        // 关掉所有智能替换 —— 对着 JSON/代码把引号换成弯引号是灾难。
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.string = text
        self.textView = editor
        scrollView.documentView = editor

        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = L("clipboard.editor.title")
        minSize = NSSize(width: 480, height: 360)
        collectionBehavior = [.fullScreenPrimary]
        isReleasedWhenClosed = false
        delegate = self

        let container = NSView(frame: contentRect)
        container.addSubview(scrollView)

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight))
        bar.autoresizingMask = [.width]

        let copyButton = NSButton(title: L("clipboard.editor.copy"),
                                  target: self, action: #selector(copyAll(_:)))
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.sizeToFit()
        copyButton.setFrameOrigin(NSPoint(x: bar.frame.width - copyButton.frame.width - 14,
                                          y: (barHeight - copyButton.frame.height) / 2))
        copyButton.autoresizingMask = [.minXMargin]
        bar.addSubview(copyButton)
        container.addSubview(bar)

        contentView = container
        center()
    }

    /// 把编辑后的全文写回剪贴板。不抑制监听：这是显式复制，进历史是正常语义。
    @objc private func copyAll(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)
    }

    func windowWillClose(_ notification: Notification) {
        ClipboardEditorWindow.editors.removeAll { $0 === self }
    }
}
