import AppKit

/// 宠物窗：无边框透明 NSPanel（设计 §8)。拖拽搬家、单击 / 双击 / 右键都回调给控制器。
/// M1 的命中区是整个窗口矩形；按像素 alpha 的精确命中等素材到位后补。
final class PetPanel: NSPanel {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onDragState: ((Bool) -> Void)?

    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var moved = false

    /// 鼠标按着（可能正在拖）：这期间不切换点击穿透，免得拖到一半窗口不接鼠标了。
    var isTracking: Bool { dragStart != nil }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowStart = frame.origin
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let windowStart else { return }
        let now = NSEvent.mouseLocation
        if !moved, abs(now.x - dragStart.x) + abs(now.y - dragStart.y) > 4 {
            moved = true
            onDragState?(true)
        }
        if moved {
            setFrameOrigin(NSPoint(x: windowStart.x + now.x - dragStart.x,
                                   y: windowStart.y + now.y - dragStart.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if moved {
            // 先报新位置再报「松手」：引擎松手时按新位置找落脚的台面（反过来会按拖之前的位置算）。
            onMove?(frame.origin)
            onDragState?(false)
        } else if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
        dragStart = nil
        windowStart = nil
        moved = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

/// 宠物窗的内容容器：里面放当前渲染视图（2D / 3D），自己负责「抚摸」识别 ——
/// 鼠标在宠物身上左右来回蹭（1.5 秒内换向 4 次以上）就算摸摸头。
final class PetStageView: NSView {
    var onPetting: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var lastX: CGFloat?
    private var lastDirection: CGFloat = 0
    private var reversals: [Date] = []
    private var cooldownUntil = Date.distantPast

    /// 换上新的渲染视图（铺满）。
    func show(_ view: NSView) {
        guard view.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        lastX = nil
        lastDirection = 0
        reversals.removeAll()
    }

    override func mouseMoved(with event: NSEvent) {
        let x = event.locationInWindow.x
        defer { if abs(x - (lastX ?? x)) >= 3 || lastX == nil { lastX = x } }
        guard let lastX else { return }
        let dx = x - lastX
        guard abs(dx) >= 3 else { return }
        let direction: CGFloat = dx > 0 ? 1 : -1
        let now = Date()
        if lastDirection != 0, direction != lastDirection { reversals.append(now) }
        lastDirection = direction
        reversals.removeAll { now.timeIntervalSince($0) > 1.5 }
        if reversals.count >= 4, now >= cooldownUntil {
            reversals.removeAll()
            cooldownUntil = now.addingTimeInterval(4)
            onPetting?()
        }
    }
}
