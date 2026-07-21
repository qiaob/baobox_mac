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

    static func closeAll() {
        for pin in pins { pin.orderOut(nil) }
        pins.removeAll()
    }

    private let image: CGImage
    /// 初始尺寸，作为缩放上下限的基准与"恢复原始大小"的目标。
    private let originalSize: NSSize

    private init(image: CGImage, frameAK: NSRect) {
        self.image = image
        self.originalSize = frameAK.size
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

    // MARK: - 缩放 / 透明度

    /// 滚轮等比缩放（0.2×–5×，锚定鼠标位置）；⌥+滚轮调透明度（20%–100%）。
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            let delta = event.scrollingDeltaY * 0.01
            alphaValue = min(1, max(0.2, alphaValue + delta))
            return
        }

        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let factor = 1 + delta * 0.01
        let currentScale = frame.width / originalSize.width
        let newScale = min(5, max(0.2, currentScale * factor))
        guard abs(newScale - currentScale) > 0.0001 else { return }

        let newSize = NSSize(width: originalSize.width * newScale,
                             height: originalSize.height * newScale)
        // 锚定鼠标：缩放前后鼠标指向的图像点保持不动。
        let mouse = NSEvent.mouseLocation
        let fx = frame.width > 0 ? (mouse.x - frame.minX) / frame.width : 0.5
        let fy = frame.height > 0 ? (mouse.y - frame.minY) / frame.height : 0.5
        let origin = NSPoint(x: mouse.x - fx * newSize.width,
                             y: mouse.y - fy * newSize.height)
        setFrame(NSRect(origin: origin, size: newSize), display: true)
    }

    func resetSize() {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let origin = NSPoint(x: center.x - originalSize.width / 2,
                             y: center.y - originalSize.height / 2)
        setFrame(NSRect(origin: origin, size: originalSize), display: true)
    }

    func setOpacity(_ value: CGFloat) {
        alphaValue = value
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
        menu.addItem(ClosureMenuItem(title: L("pin.menu.resetSize")) { [weak self] in self?.owner?.resetSize() })

        let opacityItem = NSMenuItem(title: L("pin.menu.opacity"), action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40] {
            let item = ClosureMenuItem(title: "\(percent)%") { [weak self] in
                self?.owner?.setOpacity(CGFloat(percent) / 100)
            }
            item.state = Int((self.owner?.alphaValue ?? 1) * 100) == percent ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("pin.menu.close")) { [weak self] in self?.owner?.closePin() })
        return menu
    }
}
