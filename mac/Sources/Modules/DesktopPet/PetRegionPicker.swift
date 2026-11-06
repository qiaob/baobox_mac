import AppKit

/// 框选宠物的活动区域（docs/desktop-pet/ROAM.md §1）：鼠标所在屏盖一层半透明，拖出一个矩形；Esc / 右键取消。
/// 不截屏，不需要屏幕录制权限。
@MainActor
final class PetRegionPicker {
    static let shared = PetRegionPicker()

    private var window: NSWindow?
    private var completion: ((NSRect?) -> Void)?

    /// completion 收到屏幕坐标（左下角原点）的矩形；取消为 nil。
    func pick(completion: @escaping (NSRect?) -> Void) {
        finish(nil)
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            completion(nil)
            return
        }
        self.completion = completion
        let window = PetRegionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = PetRegionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let origin = screen.frame.origin
        view.onFinish = { [weak self] rect in
            self?.finish(rect.map { $0.offsetBy(dx: origin.x, dy: origin.y) })
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func finish(_ rect: NSRect?) {
        let completion = self.completion
        self.completion = nil
        window?.orderOut(nil)
        window = nil
        completion?(rect)
    }
}

private final class PetRegionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class PetRegionView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.35).setFill()
        bounds.fill()
        if let rect = selection {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            let accent = NSColor(srgbRed: 0x17 / 255.0, green: 0xA3 / 255.0, blue: 0x98 / 255.0, alpha: 1)
            accent.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
        let hint = L("pet.region.hint") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attributes)
        hint.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 90), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let rect = selection, rect.width >= 80, rect.height >= 40 {
            onFinish?(rect)
        } else {
            start = nil
            current = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
