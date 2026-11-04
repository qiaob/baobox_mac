import AppKit
import CoreGraphics

/// 框选 OCR：把鼠标所在屏冻结成底图，用户拖出矩形后裁剪 + 本地识别。
///
/// 给「根本不能选中」的文字用（图片、扫描版 PDF、视频、游戏）。
/// 冻结与裁剪的像素口径：倍率一律从冻结图自身反推（图宽 ÷ 屏点宽），
/// 不假设 backingScaleFactor —— 混合 DPI 下的教训见 PR #32。
@MainActor
final class RegionTextPicker {
    typealias Completion = @MainActor (String?, CGRect?) -> Void

    private var window: RegionPickerWindow?
    private var completion: Completion?

    /// 开始框选。调用方需先确认屏幕录制权限。
    func pick(completion: @escaping Completion) {
        cancel()
        guard let screen = Self.mouseScreen(),
              let frozen = Self.freeze(screen: screen) else {
            completion(nil, nil)
            return
        }
        self.completion = completion

        let view = RegionPickerView(frame: NSRect(origin: .zero, size: screen.frame.size), image: frozen)
        view.onFinish = { [weak self] rectPoints in
            self?.finish(rectPoints: rectPoints, screen: screen, image: frozen)
        }
        view.onCancel = { [weak self] in
            self?.finishCancelled()
        }

        let window = RegionPickerWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        window?.orderOut(nil)
        window = nil
        completion = nil
    }

    private func finish(rectPoints: CGRect?, screen: NSScreen, image: CGImage) {
        let done = completion
        cancel()
        guard let rectPoints, rectPoints.width >= 8, rectPoints.height >= 8 else {
            done?(nil, nil)
            return
        }
        // 视图坐标（屏内左下原点）→ 全局 AppKit 坐标（浮层锚点用）。
        let anchor = CGRect(x: screen.frame.minX + rectPoints.minX,
                            y: screen.frame.minY + rectPoints.minY,
                            width: rectPoints.width,
                            height: rectPoints.height)
        // 屏内点坐标 → 冻结图像素坐标：y 轴翻转，倍率从图像自身反推。
        let scaleX = CGFloat(image.width) / screen.frame.width
        let scaleY = CGFloat(image.height) / screen.frame.height
        let pixelRect = CGRect(
            x: rectPoints.minX * scaleX,
            y: (screen.frame.height - rectPoints.maxY) * scaleY,
            width: rectPoints.width * scaleX,
            height: rectPoints.height * scaleY
        ).integral
        guard let cropped = image.cropping(to: pixelRect) else {
            done?(nil, nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = TextRecognizer.recognize(cropped, languages: ["zh-Hans", "en-US"])
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    done?(text.isEmpty ? nil : text, anchor)
                }
            }
        }
    }

    private func finishCancelled() {
        let done = completion
        cancel()
        done?(nil, nil)
    }

    private static func mouseScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
    }

    /// 冻结一整屏（与截图覆盖层菜单场景同款取图方式）。
    private static func freeze(screen: NSScreen) -> CGImage? {
        // CGWindowListCreateImage 要 Quartz 坐标（主屏左上原点）。
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let quartz = CGRect(x: screen.frame.minX,
                            y: primaryHeight - screen.frame.minY - screen.frame.height,
                            width: screen.frame.width,
                            height: screen.frame.height)
        return CGWindowListCreateImage(quartz, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
    }
}

/// borderless 窗口默认不能成为 key，框选要收 Esc，重写放行。
private final class RegionPickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// 冻结底图 + 拖拽选区。坐标系：视图内左下原点（AppKit 默认）。
private final class RegionPickerView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    var onCancel: (() -> Void)?

    private let image: CGImage
    private var dragStart: CGPoint?
    private var dragRect: CGRect?

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(image, in: bounds)
        // 压暗整屏，选区内恢复原亮度（把冻结图按选区再贴一次）。
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        if let rect = dragRect {
            context.saveGState()
            context.clip(to: rect)
            context.draw(image, in: bounds)
            context.restoreGState()
            NSColor.controlAccentColor.setStroke()
            let border = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            border.stroke()
            let label = "\(Int(rect.width)) × \(Int(rect.height))"
            (label as NSString).draw(at: NSPoint(x: rect.minX, y: rect.maxY + 4),
                                     withAttributes: [.foregroundColor: NSColor.white,
                                                      .font: NSFont.systemFont(ofSize: 11)])
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.type == .rightMouseDown {
            onCancel?()
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
        dragRect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        dragRect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        onFinish?(dragRect)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}
