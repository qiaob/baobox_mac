import AppKit

/// 屏幕标注画笔的画布：覆盖整屏的透明视图，直接在屏幕上画。
///
/// 与截图标注共用同一套绘制引擎（`AnnotationTool` / `AnnotationOp` / `AnnotationRenderer`），
/// 区别只是画布——截图画在冻结的选区图上，这里画在一层什么都没有的透明浮层上。
/// 坐标系同样是「视图本地、原点左下、y 向上」，`AnnotationRenderer` 直接可用。
@MainActor
final class ScreenDrawView: NSView {

    weak var controller: ScreenDrawController?

    var currentTool: AnnotationTool = .pen
    var style = AnnotationStyle()

    private var ops: [AnnotationOp] = []
    private var undoSnapshots: [[AnnotationOp]] = []
    private var redoSnapshots: [[AnnotationOp]] = []

    /// 进行中的一笔。
    private var draftAnchor: NSPoint = .zero
    private var draftShape: AnnotationOp.Shape?
    private var strokePoints: [NSPoint] = []

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    /// App 未激活时第一击就要落笔，不能要求先点一下激活。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isEmpty: Bool { ops.isEmpty && draftShape == nil }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 屏幕标注没有底图，马赛克无从谈起 —— mosaicImage 恒为 nil，工具条里也不提供该工具。
        AnnotationRenderer.draw(ops, bounds: bounds, mosaicImage: nil)
        if let draftShape {
            AnnotationRenderer.draw(AnnotationOp(tool: currentTool, shape: draftShape, style: style),
                                    bounds: bounds, mosaicImage: nil)
        }
    }

    // MARK: - 鼠标

    private func localPoint(_ event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = localPoint(event)
        controller?.viewBecameActive(self)

        switch currentTool {
        case .eraser:
            eraseAt(point)
        case .rect:
            draftAnchor = point
            draftShape = .rect(NSRect(origin: point, size: .zero))
        case .ellipse:
            draftAnchor = point
            draftShape = .ellipse(NSRect(origin: point, size: .zero))
        case .arrow:
            draftAnchor = point
            draftShape = .arrow(from: point, to: point)
        case .pen, .highlighter:
            strokePoints = [point]
            draftShape = .stroke(strokePoints)
        case .mosaic, .text:
            break // 屏幕标注不提供这两个工具
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = localPoint(event)
        switch currentTool {
        case .eraser:
            eraseAt(point)
        case .rect:
            draftShape = .rect(normalizedRect(anchor: draftAnchor, current: point))
        case .ellipse:
            draftShape = .ellipse(normalizedRect(anchor: draftAnchor, current: point))
        case .arrow:
            draftShape = .arrow(from: draftAnchor, to: point)
        case .pen, .highlighter:
            guard !strokePoints.isEmpty else { break }
            strokePoints.append(point)
            draftShape = .stroke(strokePoints)
        case .mosaic, .text:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        commitDraftIfMeaningful()
    }

    private func normalizedRect(anchor: NSPoint, current: NSPoint) -> NSRect {
        NSRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
               width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 0x35: // Esc —— 退出并清除全部笔迹
            controller?.stop()
        case 0x33: // ⌫ —— 只清笔迹，人还在标注模式里
            controller?.clearAll()
        default:
            let flags = event.modifierFlags
            if flags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "z" {
                if flags.contains(.shift) { redo() } else { undo() }
                return
            }
            super.keyDown(with: event)
        }
    }

    // MARK: - 编辑

    private func commitDraftIfMeaningful() {
        defer {
            draftShape = nil
            strokePoints = []
            needsDisplay = true
        }
        guard let shape = draftShape else { return }

        // 与截图标注同一套「太小的一笔算手抖，丢掉」判定。
        let meaningful: Bool
        switch shape {
        case .rect(let rect), .ellipse(let rect):
            meaningful = rect.width >= 3 && rect.height >= 3
        case .arrow(let from, let to):
            meaningful = hypot(to.x - from.x, to.y - from.y) >= 6
        case .stroke(let points):
            meaningful = points.count >= 2
        case .text:
            meaningful = false
        }
        guard meaningful else { return }

        pushUndoSnapshot()
        ops.append(AnnotationOp(tool: currentTool, shape: shape, style: style))
        redoSnapshots.removeAll()
    }

    private func eraseAt(_ point: NSPoint) {
        // 后画的在上层，从后往前找第一笔命中的删除。
        guard let index = ops.lastIndex(where: { AnnotationRenderer.hitTest($0, at: point) }) else { return }
        pushUndoSnapshot()
        ops.remove(at: index)
        redoSnapshots.removeAll()
        needsDisplay = true
    }

    private func pushUndoSnapshot() {
        undoSnapshots.append(ops)
    }

    func undo() {
        guard let previous = undoSnapshots.popLast() else { return }
        redoSnapshots.append(ops)
        ops = previous
        needsDisplay = true
    }

    func redo() {
        guard let next = redoSnapshots.popLast() else { return }
        undoSnapshots.append(ops)
        ops = next
        needsDisplay = true
    }

    func clear() {
        guard !ops.isEmpty else { return }
        pushUndoSnapshot()
        ops.removeAll()
        redoSnapshots.removeAll()
        needsDisplay = true
    }
}
