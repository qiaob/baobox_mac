import AppKit
import UniformTypeIdentifiers

/// 贴图浮窗：把截图钉在屏幕最上层。可拖动；双击关闭；右键菜单提供复制 / 另存 / 关闭。
@MainActor
final class PinnedImageWindow: NSPanel {

    /// 强引用池 —— borderless panel 无人持有会被立刻释放。
    private static var pins: [PinnedImageWindow] = []

    static func pin(image: CGImage, at rectAK: NSRect) {
        let window = PinnedImageWindow(image: image, frameAK: rectAK)
        pins.append(window)
        window.orderFrontRegardless()
    }

    private let image: CGImage

    private init(image: CGImage, frameAK: NSRect) {
        self.image = image
        super.init(contentRect: frameAK,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let view = PinContentView(image: image, owner: self)
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x35 { // Esc
            closePin()
        } else {
            super.keyDown(with: event)
        }
    }

    func closePin() {
        orderOut(nil)
        PinnedImageWindow.pins.removeAll { $0 === self }
    }

    func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = NSImage(cgImage: image, size: .zero).tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    func saveImage() {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = ScreenshotSettings.saveDirectoryURL
        panel.nameFieldStringValue = L("pin.defaultName")
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }
}

/// 贴图内容视图：承载图片、细边框，处理双击与右键菜单。
private final class PinContentView: NSImageView {
    private weak var owner: PinnedImageWindow?

    init(image: CGImage, owner: PinnedImageWindow) {
        self.owner = owner
        super.init(frame: .zero)
        self.image = NSImage(cgImage: image, size: .zero)
        imageScaling = .scaleAxesIndependently
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.45).cgColor
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            owner?.closePin()
        } else {
            // 不能走 super/isMovableByWindowBackground：NSImageView 自带
            // "把图片拖出去"的 mouseDown 行为，会拦截窗口背景拖动，
            // 表现为贴图钉住后拖不动。直接手动驱动窗口拖拽。
            window?.performDrag(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L("pin.menu.copy")) { [weak self] in self?.owner?.copyImage() })
        menu.addItem(ClosureMenuItem(title: L("pin.menu.save")) { [weak self] in self?.owner?.saveImage() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("pin.menu.close")) { [weak self] in self?.owner?.closePin() })
        return menu
    }
}
