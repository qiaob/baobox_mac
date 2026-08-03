import AppKit

/// 屏幕取字的结果窗：可编辑的识别文本 + 复制；识别到二维码时底部多一条内容。
///
/// 识别难免有错，所以给的是**可编辑文本框**而不是只读展示 —— 就地改完再复制，比重识别快。
/// 结构与用法对齐 `ClipboardEditorWindow`（标准窗口 + 强引用池 + `windowWillClose` 摘除）。
@MainActor
final class OCRResultWindow: NSWindow, NSWindowDelegate {

    /// 强引用池：isReleasedWhenClosed = false，生命周期由这里管理。
    private static var windows: [OCRResultWindow] = []

    /// 识别并展示。设置里勾了「识别后直接复制」就不开窗，静默进剪贴板。
    ///
    /// 识别放后台队列（大图可能几百毫秒到秒级），窗口先以「识别中…」占位，避免点了没反应。
    static func present(image: CGImage) {
        let languages = ScreenshotSettings.ocrLanguageOption.visionLanguages
        let window: OCRResultWindow? = ScreenshotSettings.ocrAutoCopyOnly ? nil : makeWindow()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = TextRecognizer.recognize(image, languages: languages)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let window else {
                        // 直接复制模式：有内容进剪贴板，没有就提示一声，不留窗口。
                        if result.isEmpty {
                            reportEmpty()
                        } else {
                            copyToPasteboard(joined(result))
                        }
                        return
                    }
                    window.fill(with: result)
                }
            }
        }
    }

    private static func makeWindow() -> OCRResultWindow {
        let window = OCRResultWindow()
        windows.append(window)
        // 无 Dock 图标的 accessory App：不先激活，窗口拿不到键盘焦点，没法编辑。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    // MARK: - 构建

    private let textView: NSTextView
    private let statusLabel: NSTextField
    private var barcodes: [String] = []

    private init() {
        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 380)
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
        editor.font = .systemFont(ofSize: 13)
        // 识别结果常是代码 / 路径 / 命令，智能替换会把引号连字符改坏。
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
        editor.string = L("screenshot.ocr.result.recognizing")
        editor.isEditable = false
        self.textView = editor
        scrollView.documentView = editor

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        self.statusLabel = label

        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = L("screenshot.ocr.result.title")
        minSize = NSSize(width: 360, height: 240)
        isReleasedWhenClosed = false
        delegate = self

        let container = NSView(frame: contentRect)
        container.addSubview(scrollView)

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight))
        bar.autoresizingMask = [.width]

        let copyButton = NSButton(title: L("screenshot.ocr.result.copy"),
                                  target: self, action: #selector(copyAll(_:)))
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.sizeToFit()
        copyButton.setFrameOrigin(NSPoint(x: bar.frame.width - copyButton.frame.width - 14,
                                          y: (barHeight - copyButton.frame.height) / 2))
        copyButton.autoresizingMask = [.minXMargin]
        bar.addSubview(copyButton)

        label.frame = NSRect(x: 14, y: (barHeight - 16) / 2,
                             width: copyButton.frame.minX - 24, height: 16)
        label.autoresizingMask = [.width]
        bar.addSubview(label)

        container.addSubview(bar)
        contentView = container
        center()
    }

    // MARK: - 结果填充

    private func fill(with result: TextRecognizer.Result) {
        barcodes = result.barcodes
        textView.isEditable = true
        textView.string = result.text
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        if result.isEmpty {
            statusLabel.stringValue = L("screenshot.ocr.result.empty")
        } else if result.barcodes.isEmpty {
            statusLabel.stringValue = ""
        } else {
            // 二维码内容不塞进文本框（用户多半只要文字），单独一行展示，复制时一并带上。
            let all = result.barcodes.joined(separator: " · ")
            statusLabel.stringValue = L("screenshot.ocr.result.barcode \(all)")
            statusLabel.toolTip = result.barcodes.joined(separator: "\n")
        }
    }

    /// 文本 + 二维码内容拼成最终要复制的字符串。
    private static func joined(_ result: TextRecognizer.Result) -> String {
        var parts: [String] = []
        if !result.text.isEmpty { parts.append(result.text) }
        parts.append(contentsOf: result.barcodes)
        return parts.joined(separator: "\n")
    }

    private static func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func reportEmpty() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("screenshot.ocr.error.title")
        alert.informativeText = L("screenshot.ocr.error.message")
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - 动作

    /// 复制编辑后的全文（连同二维码内容）并关窗 —— 取字的终点就是粘贴到别处。
    @objc private func copyAll(_ sender: Any?) {
        var parts: [String] = []
        let edited = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !edited.isEmpty { parts.append(edited) }
        parts.append(contentsOf: barcodes)
        Self.copyToPasteboard(parts.joined(separator: "\n"))
        close()
    }

    func windowWillClose(_ notification: Notification) {
        OCRResultWindow.windows.removeAll { $0 === self }
    }
}
