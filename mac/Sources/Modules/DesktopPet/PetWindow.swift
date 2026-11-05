import AppKit

/// 宠物窗：无边框透明 NSPanel（设计 §8)。拖拽搬家、点击/右键弹菜单都回调给控制器。
/// M1 的命中区是整个窗口矩形；按像素 alpha 的精确命中等素材到位后补。
final class PetPanel: NSPanel {
    var onClick: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onDragState: ((Bool) -> Void)?

    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var moved = false

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
            onDragState?(false)
            onMove?(frame.origin)
        } else {
            onClick?()
        }
        dragStart = nil
        windowStart = nil
        moved = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }
}
