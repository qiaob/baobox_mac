import AppKit

/// 通用图片预览窗：滚动/缩放看大图 + 底部动作按钮条。
/// 长截屏结果与剪贴板图片条目共用，故与 `QRCodeGenerator` 同理下沉到 Core；
/// 按钮语义由调用方以闭包注入，本窗不依赖任何模块。
/// 结构与用法对齐 `ClipboardEditorWindow` / `OCRResultWindow`（标准窗口 + 强引用池 + `windowWillClose` 摘除）。
@MainActor
final class ImagePreviewWindow: NSWindow, NSWindowDelegate {

    struct Action {
        let title: String
        /// 默认动作绑 ⏎（放最右）。
        var isDefault = false
        /// 动作完成后是否顺带关窗（复制/贴图这类"拿走结果"的动作）。
        var closesWindow = false
        let handler: () -> Void
    }

    /// 强引用池：isReleasedWhenClosed = false，生命周期由这里管理。
    private static var windows: [ImagePreviewWindow] = []

    static func present(image: CGImage, title: String, actions: [Action]) {
        let window = ImagePreviewWindow(image: image, title: title, actions: actions)
        windows.append(window)
        // 无 Dock 图标的 accessory App：不先激活，窗口拿不到键盘焦点。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private let actions: [Action]

    private init(image: CGImage, title windowTitle: String, actions: [Action]) {
        self.actions = actions

        // 像素按屏幕倍率换算成点；窗口最大占可视区 80%，超出部分滚动/缩放看。
        let screen = NSScreen.main
        let scale = max(screen?.backingScaleFactor ?? 2, 1)
        let imageSize = NSSize(width: max(CGFloat(image.width) / scale, 1),
                               height: max(CGFloat(image.height) / scale, 1))
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let barHeight: CGFloat = 44
        let contentSize = NSSize(
            width: min(max(imageSize.width, 360), visible.width * 0.8),
            height: min(max(imageSize.height, 200), visible.height * 0.8 - barHeight) + barHeight)
        let contentRect = NSRect(origin: .zero, size: contentSize)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: barHeight,
                                                    width: contentSize.width,
                                                    height: contentSize.height - barHeight))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 5
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: imageSize))
        imageView.image = NSImage(cgImage: image, size: imageSize)
        imageView.imageScaling = .scaleAxesIndependently
        scrollView.documentView = imageView

        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = windowTitle
        minSize = NSSize(width: 320, height: 240)
        isReleasedWhenClosed = false
        delegate = self

        let container = NSView(frame: contentRect)
        container.addSubview(scrollView)

        let bar = NSView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: barHeight))
        bar.autoresizingMask = [.width]

        // 按传入顺序从左到右排列，末尾的动作最靠右 —— 调用方按 macOS 惯例把默认动作放最后。
        var x = bar.frame.width - 14
        for (index, action) in actions.enumerated().reversed() {
            let button = NSButton(title: action.title, target: self, action: #selector(actionPressed(_:)))
            button.bezelStyle = .rounded
            if action.isDefault { button.keyEquivalent = "\r" }
            button.sizeToFit()
            button.setFrameOrigin(NSPoint(x: x - button.frame.width,
                                          y: (barHeight - button.frame.height) / 2))
            button.autoresizingMask = [.minXMargin]
            button.tag = index
            bar.addSubview(button)
            x = button.frame.minX - 8
        }

        // 左下角尺寸标签：像素尺寸对判断长图是否完整很有用。
        let sizeLabel = NSTextField(labelWithString: "\(image.width) × \(image.height) px")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.frame = NSRect(x: 14, y: (barHeight - 16) / 2, width: max(x - 24, 60), height: 16)
        bar.addSubview(sizeLabel)

        container.addSubview(bar)
        contentView = container
        center()

        // 宽于视口的图先缩到适配宽度（长截屏常见）；再滚到顶部 —— 非翻转坐标默认露出的是底部。
        let clipSize = scrollView.contentView.bounds.size
        if imageSize.width > clipSize.width {
            scrollView.magnification = clipSize.width / imageSize.width
        }
        let visibleHeight = scrollView.contentView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, imageSize.height - visibleHeight)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func actionPressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        let action = actions[sender.tag]
        action.handler()
        if action.closesWindow { close() }
    }

    /// Esc 关窗（预览窗的肌肉记忆）。
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x35 { // Esc
            close()
            return
        }
        super.keyDown(with: event)
    }

    func windowWillClose(_ notification: Notification) {
        ImagePreviewWindow.windows.removeAll { $0 === self }
    }
}
