import AppKit

/// 截图 overlay 的核心交互视图（非翻转坐标：原点左下、y 向上）。
/// 所有几何都以「视图本地坐标」处理，仅在回调 controller 时转换到 AK 全局坐标。
@MainActor
final class CaptureOverlayView: NSView {

    private enum Phase {
        case hovering(DetectedWindow?)
        case dragging(anchor: NSPoint, current: NSPoint)
        case adjusting(rect: NSRect)
        /// 已选定标注工具：选区锁定，鼠标用于绘制。
        case annotating(rect: NSRect)
    }

    private enum ResizeHandle {
        case tl, tr, bl, br, t, b, l, r
    }

    private let screenRef: NSScreen
    private weak var controller: CaptureController?

    /// 录制模式：选区交互不变，但不出标注工具条，⏎/双击 = 开始录制。
    private let recordMode: Bool

    private var phase: Phase = .hovering(nil)

    // hovering → dragging 的按下点与命中窗口
    private var mouseDownLocal: NSPoint?

    // adjusting 拖拽状态
    private var activeHandle: ResizeHandle?
    private var movingSelection = false
    private var dragOrigin: NSPoint = .zero
    private var dragStartRect: NSRect = .zero

    private let dragThreshold: CGFloat = 4
    private let handleHitRadius: CGFloat = 8
    private let handleSize: CGFloat = 6

    private let accent = NSColor(srgbRed: 0x2B / 255.0, green: 0xC4 / 255.0, blue: 0xB8 / 255.0, alpha: 1)

    /// 录制模式的选区确认工具条（声音开关 / 取消 / 开始录制）。
    private var recordBar: RecordStartBar?

    // MARK: 像素放大镜

    /// 放大镜底图：overlay 打开时异步冻结的整屏画面（已排除自身窗口）。
    /// 就绪前放大镜不显示；选区期间屏幕内容基本静止，冻结底图与实况一致。
    private var loupeImage: CGImage?
    private var loupeTask: Task<CGImage, Error>?
    private var lastMouseLocal: NSPoint?

    // MARK: 标注状态

    private var toolbar: AnnotationToolbar?
    private var currentTool: AnnotationTool?
    private var annotationStyle = AnnotationStyle()

    /// 已提交标注（选区本地坐标）。撤销/重做用整表快照，天然覆盖"橡皮删除"的恢复。
    private var ops: [AnnotationOp] = []
    private var undoSnapshots: [[AnnotationOp]] = []
    private var redoSnapshots: [[AnnotationOp]] = []

    /// 冻结的选区底图（进入标注即捕获一次，之后所见与导出都基于它）。
    private var frozenImage: CGImage?
    private var mosaicImage: CGImage?
    private var freezeTask: Task<CGImage, Error>?

    /// 菜单场景的「含菜单整屏」冻结底图。非 nil 即冻结模式：框选/标注基于它裁剪，渲染也铺它而非透实时屏。
    private let frozenBackground: CGImage?

    /// 进行中的一笔（选区本地坐标）。
    private var draftAnchorLocal: NSPoint = .zero
    private var draftShape: AnnotationOp.Shape?
    private var strokePoints: [NSPoint] = []

    private var textEditor: NSTextField?
    private var finishing = false

    init(screen: NSScreen, controller: CaptureController, recordMode: Bool = false,
         frozenBackground: CGImage? = nil) {
        self.screenRef = screen
        self.controller = controller
        self.recordMode = recordMode
        self.frozenBackground = frozenBackground
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        // 不使用 layer-backing：draw(_:) 里以 .clear 混合模式在非透明 backing 上"挖洞"，
        // 需要窗口 backing 直接透明，layer-backed 会改变透明合成行为。
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.makeFirstResponder(self)
        beginLoupeCapture()
        // overlay 弹出时鼠标已经在 tracking area 内部，而 tracking area 未带
        // .assumeInside，AppKit 不会补发 mouseEntered。命中检测只在 mouseMoved 里做的话，
        // phase 会一直停在 .hovering(nil)：屏幕只是变暗、光标还是箭头，此刻直接单击会被
        // mouseUp 的 nil 分支吞掉 —— 用户必须先晃一下鼠标才能用，第一次用会以为截图坏了。
        refreshHoverAtCurrentMouse()
    }

    /// 按鼠标当前物理位置补一次窗口命中检测。
    private func refreshHoverAtCurrentMouse() {
        guard case .hovering = phase else { return }
        let mouseAK = NSEvent.mouseLocation
        // 只有鼠标所在的那块屏需要高亮，其余屏保持 nil 是正确的。
        guard NSMouseInRect(mouseAK, screenRef.frame, false) else { return }
        let local = NSPoint(x: mouseAK.x - screenRef.frame.minX,
                            y: mouseAK.y - screenRef.frame.minY)
        phase = .hovering(WindowDetector.window(atCG: globalCG(local)))
        needsDisplay = true
    }

    /// 用 cursor rect 保证整个 overlay 范围内都是十字光标，
    /// 不依赖 mouseMoved/mouseEntered 才设置。
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 坐标转换

    private func localPoint(_ event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    /// 视图本地点 → CG 全局点（用于窗口命中检测）。
    private func globalCG(_ localPoint: NSPoint) -> CGPoint {
        let globalAK = NSPoint(x: screenRef.frame.minX + localPoint.x,
                               y: screenRef.frame.minY + localPoint.y)
        return Geometry.cgPoint(fromAppKit: globalAK)
    }

    /// 视图本地 rect → AK 全局 rect（用于回调 controller.finishRect）。
    private func globalAKRect(fromLocal rect: NSRect) -> NSRect {
        NSRect(x: screenRef.frame.minX + rect.minX,
               y: screenRef.frame.minY + rect.minY,
               width: rect.width, height: rect.height)
    }

    /// CG 全局窗口 rect → 视图本地 rect（用于高亮绘制）。
    private func localRect(fromGlobalCG rectCG: CGRect) -> NSRect {
        let globalAK = Geometry.appKitRect(fromCG: rectCG)
        return NSRect(x: globalAK.minX - screenRef.frame.minX,
                      y: globalAK.minY - screenRef.frame.minY,
                      width: globalAK.width, height: globalAK.height)
    }

    // MARK: - 光标 / 追踪区域

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        // 指针进入本屏 overlay 时使其成为 key，从而接管键盘与后续 mouseMoved。
        if window?.isKeyWindow == false {
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(self)
        }
        if !mouseOverToolbar { NSCursor.crosshair.set() }
    }

    /// 工具条是独立子窗口但几何上叠在 overlay 之内，mouseMoved 仍会派发到这里；
    /// 指针悬在工具条（标注条或录制确认条）上时不能把光标改成十字。
    private var mouseOverToolbar: Bool {
        if let toolbar, toolbar.panel.isVisible, toolbar.panel.alphaValue > 0,
           toolbar.panel.frame.contains(NSEvent.mouseLocation) {
            return true
        }
        if let recordBar, recordBar.panel.isVisible, recordBar.panel.alphaValue > 0,
           recordBar.panel.frame.contains(NSEvent.mouseLocation) {
            return true
        }
        return false
    }

    // MARK: - 鼠标事件

    override func mouseMoved(with event: NSEvent) {
        if mouseOverToolbar {
            NSCursor.arrow.set()
        } else if case .annotating(let rect) = phase, currentTool == .text,
                  rect.contains(localPoint(event)) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.crosshair.set()
        }
        if window?.isKeyWindow == false {
            window?.makeKey()
            window?.makeFirstResponder(self)
        }
        lastMouseLocal = localPoint(event)
        if case .hovering = phase {
            let detected = WindowDetector.window(atCG: globalCG(localPoint(event)))
            phase = .hovering(detected)
            needsDisplay = true
        } else {
            needsDisplay = true // 放大镜跟随光标
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = localPoint(event)
        switch phase {
        case .hovering:
            window?.makeFirstResponder(self)
            mouseDownLocal = p
        case .adjusting(let rect):
            window?.makeFirstResponder(self)
            if event.clickCount == 2 && rect.contains(p) {
                // 双击选区 = 复制并完成（对齐 Snipaste）。
                finishSelection(.copy)
                return
            }
            if let handle = handleHit(at: p, rect: rect) {
                activeHandle = handle
                movingSelection = false
                dragOrigin = p
                dragStartRect = rect
            } else if rect.contains(p) {
                activeHandle = nil
                movingSelection = true
                dragOrigin = p
                dragStartRect = rect
            } else {
                // 选区外按下 → 重新开始框选
                phase = .dragging(anchor: p, current: p)
                toolbar?.setHidden(true)
                recordBar?.setHidden(true)
                needsDisplay = true
            }
        case .annotating(let rect):
            // 有未提交的文字时，点击任意处 = 提交该文字（本次点击不再另起对象）。
            if textEditor != nil {
                commitTextEditor(cancel: false)
                return
            }
            window?.makeFirstResponder(self)
            guard let tool = currentTool else { return }
            let cp = clampPoint(p, into: rect)
            let lp = NSPoint(x: cp.x - rect.minX, y: cp.y - rect.minY)
            switch tool {
            case .text:
                beginTextEditor(atViewPoint: cp)
            case .eraser:
                eraseAt(localPoint: lp)
            case .rect:
                draftAnchorLocal = lp
                draftShape = .rect(NSRect(origin: lp, size: .zero))
            case .ellipse:
                draftAnchorLocal = lp
                draftShape = .ellipse(NSRect(origin: lp, size: .zero))
            case .arrow:
                draftAnchorLocal = lp
                draftShape = .arrow(from: lp, to: lp)
            case .pen, .highlighter, .mosaic:
                strokePoints = [lp]
                draftShape = .stroke(strokePoints)
            }
            needsDisplay = true
        case .dragging:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = localPoint(event)
        lastMouseLocal = p
        switch phase {
        case .hovering:
            if let down = mouseDownLocal, hypot(p.x - down.x, p.y - down.y) > dragThreshold {
                phase = .dragging(anchor: down, current: p)
                needsDisplay = true
            }
        case .dragging(let anchor, _):
            phase = .dragging(anchor: anchor, current: p)
            needsDisplay = true
        case .adjusting:
            if let handle = activeHandle {
                let resized = resize(rect: dragStartRect, handle: handle, to: p)
                phase = .adjusting(rect: clampToBounds(resized))
            } else if movingSelection {
                let moved = dragStartRect.offsetBy(dx: p.x - dragOrigin.x, dy: p.y - dragOrigin.y)
                phase = .adjusting(rect: clampInside(moved))
            }
            if case .adjusting(let rect) = phase {
                toolbar?.position(near: globalAKRect(fromLocal: rect), on: screenRef)
                recordBar?.position(near: globalAKRect(fromLocal: rect), on: screenRef)
            }
            needsDisplay = true
        case .annotating(let rect):
            guard let tool = currentTool else { break }
            let cp = clampPoint(p, into: rect)
            let lp = NSPoint(x: cp.x - rect.minX, y: cp.y - rect.minY)
            switch tool {
            case .rect:
                draftShape = .rect(normalizedRect(anchor: draftAnchorLocal, current: lp))
            case .ellipse:
                draftShape = .ellipse(normalizedRect(anchor: draftAnchorLocal, current: lp))
            case .arrow:
                draftShape = .arrow(from: draftAnchorLocal, to: lp)
            case .pen, .highlighter, .mosaic:
                guard !strokePoints.isEmpty else { break }
                strokePoints.append(lp)
                draftShape = .stroke(strokePoints)
            case .eraser:
                eraseAt(localPoint: lp)
            case .text:
                break
            }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = localPoint(event)
        switch phase {
        case .hovering(let detected):
            // 未超阈值 = 单击：有命中窗口则截取，否则忽略。
            mouseDownLocal = nil
            if let detected {
                if recordMode {
                    // 录制模式：点窗口不直接开录，把窗口区域转成选区让用户确认。
                    let local = localRect(fromGlobalCG: detected.frameCG).intersection(bounds)
                    if local.width >= 3, local.height >= 3 {
                        phase = .adjusting(rect: local)
                        showRecordBar(for: local)
                        needsDisplay = true
                    }
                } else {
                    controller?.finishWindow(detected)
                }
            }
        case .dragging(let anchor, _):
            let rect = normalizedRect(anchor: anchor, current: p)
            if rect.width < 3 || rect.height < 3 {
                phase = .hovering(nil)
            } else {
                phase = .adjusting(rect: rect)
                if recordMode {
                    showRecordBar(for: rect)
                } else {
                    showToolbar(for: rect)
                }
            }
            needsDisplay = true
        case .adjusting:
            activeHandle = nil
            movingSelection = false
        case .annotating:
            commitDraftIfMeaningful()
        }
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 0x35: // Esc
            controller?.cancel()
        case 0x24, 0x4C: // Return / Enter
            handleReturn(saveOnly: event.modifierFlags.contains(.option))
        case 0x7B, 0x7C, 0x7D, 0x7E: // ← → ↓ ↑
            handleArrow(keyCode: event.keyCode, large: event.modifierFlags.contains(.shift))
        default:
            super.keyDown(with: event)
        }
    }

    /// ⌘Z / ⇧⌘Z 撤销重做（command 组合不会进 keyDown，只能在这里拦）。
    /// 文字编辑中不拦截，让字段编辑器自己的撤销生效。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if case .annotating = phase, textEditor == nil,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                redoAnnotation()
            } else {
                undoAnnotation()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleReturn(saveOnly: Bool) {
        switch phase {
        case .adjusting, .annotating:
            finishSelection(saveOnly ? .save : .copy)
        case .dragging(let anchor, let current):
            let rect = normalizedRect(anchor: anchor, current: current)
            controller?.finishRect(globalAKRect(fromLocal: rect), on: screenRef,
                                   mode: saveOnly ? .saveOnly : .standard)
        case .hovering:
            if recordMode {
                // 录制模式：⏎ 先把整屏变成选区，让用户在工具条上确认/调声音。
                phase = .adjusting(rect: bounds)
                showRecordBar(for: bounds)
                needsDisplay = true
            } else {
                controller?.finishFullScreen(on: screenRef)
            }
        }
    }

    private func handleArrow(keyCode: UInt16, large: Bool) {
        guard case .adjusting(let rect) = phase else { return }
        let step: CGFloat = large ? 10 : 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch keyCode {
        case 0x7B: dx = -step   // ←
        case 0x7C: dx = step    // →
        case 0x7D: dy = -step    // ↓（y 向上，向下为负）
        case 0x7E: dy = step    // ↑
        default: break
        }
        let moved = clampInside(rect.offsetBy(dx: dx, dy: dy))
        phase = .adjusting(rect: moved)
        toolbar?.position(near: globalAKRect(fromLocal: moved), on: screenRef)
        recordBar?.position(near: globalAKRect(fromLocal: moved), on: screenRef)
        needsDisplay = true
    }

    // MARK: - 几何辅助

    private func normalizedRect(anchor: NSPoint, current: NSPoint) -> NSRect {
        NSRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
               width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
    }

    private func handlePoints(for rect: NSRect) -> [(ResizeHandle, NSPoint)] {
        [
            (.tl, NSPoint(x: rect.minX, y: rect.maxY)),
            (.tr, NSPoint(x: rect.maxX, y: rect.maxY)),
            (.bl, NSPoint(x: rect.minX, y: rect.minY)),
            (.br, NSPoint(x: rect.maxX, y: rect.minY)),
            (.t, NSPoint(x: rect.midX, y: rect.maxY)),
            (.b, NSPoint(x: rect.midX, y: rect.minY)),
            (.l, NSPoint(x: rect.minX, y: rect.midY)),
            (.r, NSPoint(x: rect.maxX, y: rect.midY))
        ]
    }

    private func handleHit(at p: NSPoint, rect: NSRect) -> ResizeHandle? {
        for (handle, point) in handlePoints(for: rect) {
            if abs(p.x - point.x) <= handleHitRadius && abs(p.y - point.y) <= handleHitRadius {
                return handle
            }
        }
        return nil
    }

    private func resize(rect: NSRect, handle: ResizeHandle, to p: NSPoint) -> NSRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch handle {
        case .tl: minX = p.x; maxY = p.y
        case .tr: maxX = p.x; maxY = p.y
        case .bl: minX = p.x; minY = p.y
        case .br: maxX = p.x; minY = p.y
        case .t: maxY = p.y
        case .b: minY = p.y
        case .l: minX = p.x
        case .r: maxX = p.x
        }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    private func clampToBounds(_ r: NSRect) -> NSRect {
        let b = bounds
        let x = max(b.minX, r.minX)
        let y = max(b.minY, r.minY)
        let mx = min(b.maxX, r.maxX)
        let my = min(b.maxY, r.maxY)
        return NSRect(x: x, y: y, width: max(0, mx - x), height: max(0, my - y))
    }

    private func clampInside(_ r: NSRect) -> NSRect {
        let b = bounds
        let x = min(max(b.minX, r.minX), b.maxX - r.width)
        let y = min(max(b.minY, r.minY), b.maxY - r.height)
        return NSRect(x: x, y: y, width: r.width, height: r.height)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 冻结模式（菜单场景）：先铺满「含菜单整屏」底图，后续 dim/挖洞都基于它，而非透出实时屏。
        if let frozenBackground {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.draw(frozenBackground, in: bounds)
            ctx.restoreGState()
        }

        switch phase {
        case .hovering(let detected):
            drawDim(ctx)
            if let detected {
                let local = localRect(fromGlobalCG: detected.frameCG).intersection(bounds)
                punchHole(ctx, rect: local)
                accent.withAlphaComponent(0.16).setFill()
                local.fill()
                let border = NSBezierPath(rect: local)
                border.lineWidth = 3
                accent.setStroke()
                border.stroke()
                let sizeText = "\(Int(detected.frameCG.width)) × \(Int(detected.frameCG.height))"
                let label = "\(detected.appName)\(detected.title.map { " · \($0)" } ?? "") — \(sizeText)"
                drawBadge(label, origin: NSPoint(x: local.minX, y: local.minY - 26), anchorRight: false)
            }
            if recordMode {
                drawHintPill([L("screenshot.record.hint.click"),
                              L("screenshot.record.hint.drag"),
                              L("screenshot.record.hint.enter"),
                              L("screenshot.overlay.hint.esc")])
            } else {
                drawHintPill([L("screenshot.overlay.hint.click"),
                              L("screenshot.overlay.hint.drag"),
                              L("screenshot.overlay.hint.enter"),
                              L("screenshot.overlay.hint.esc")])
            }

        case .dragging(let anchor, let current):
            let rect = normalizedRect(anchor: anchor, current: current)
            drawDim(ctx)
            punchHole(ctx, rect: rect)
            drawSelectionBorder(rect)
            drawSizeBadge(rect)

        case .adjusting(let rect):
            // 操作入口全部在工具条上（真按钮）；不再画"长得像工具条"的键盘提示，
            // 旧版用户会去点它 —— 那只是文字，点击会落到选区外触发重新框选。
            drawDim(ctx)
            punchHole(ctx, rect: rect)
            drawSelectionBorder(rect)
            drawHandles(rect)
            drawSizeBadge(rect)

        case .annotating(let rect):
            drawDim(ctx)
            if let frozenImage {
                ctx.saveGState()
                ctx.interpolationQuality = .high
                ctx.draw(frozenImage, in: rect)
                ctx.restoreGState()
            } else {
                // 冻结帧未就绪前先挖洞显示实况（捕获排除了自身窗口，两者内容一致）。
                punchHole(ctx, rect: rect)
            }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.translateBy(x: rect.minX, y: rect.minY)
            let localBounds = NSRect(origin: .zero, size: rect.size)
            AnnotationRenderer.draw(ops, bounds: localBounds, mosaicImage: mosaicImage)
            if let draftShape, let currentTool {
                AnnotationRenderer.draw(AnnotationOp(tool: currentTool, shape: draftShape,
                                                     style: annotationStyle),
                                        bounds: localBounds, mosaicImage: mosaicImage)
            }
            ctx.restoreGState()
            drawSelectionBorder(rect)
            drawSizeBadge(rect)
        }

        drawLoupeIfNeeded(ctx)
    }

    // MARK: - 像素放大镜

    private func beginLoupeCapture() {
        guard loupeTask == nil, let controller else { return }
        let task = Task { try await controller.freezeRegion(self.screenRef.frame, on: self.screenRef,
                                                            alsoExcluding: []) }
        loupeTask = task
        Task { @MainActor [weak self] in
            guard let self, let image = try? await task.value else { return }
            self.loupeImage = image
            self.needsDisplay = true
        }
    }

    /// 悬停 / 框选 / 拉手柄时显示；标注相和指针悬在工具条上时不显示。
    private func drawLoupeIfNeeded(_ ctx: CGContext) {
        guard let loupeImage, let p = lastMouseLocal, !mouseOverToolbar else { return }
        switch phase {
        case .hovering, .dragging:
            break
        case .adjusting:
            guard activeHandle != nil || movingSelection else { return }
        case .annotating:
            return
        }
        drawLoupe(ctx, image: loupeImage, at: p)
    }

    /// 以光标处像素为中心：17×17 物理像素放大到 8pt/px，附坐标与颜色读数。
    private func drawLoupe(_ ctx: CGContext, image: CGImage, at p: NSPoint) {
        let scale = screenRef.backingScaleFactor
        let px = floor(p.x * scale)
        let py = floor((bounds.height - p.y) * scale) // 图像空间：原点左上、y 向下
        guard px >= 0, py >= 0, px < CGFloat(image.width), py < CGFloat(image.height) else { return }

        let unit: CGFloat = 8            // 每物理像素放大后的 pt
        let cells: CGFloat = 17          // 视野边长（像素数，奇数保证有正中心）
        let body = unit * cells          // 136pt
        let infoH: CGFloat = 22
        let total = NSSize(width: body + 8, height: body + infoH + 12)

        // 摆位：光标右下，越界翻转。
        var origin = NSPoint(x: p.x + 18, y: p.y - 18 - total.height)
        if origin.x + total.width > bounds.maxX { origin.x = p.x - 18 - total.width }
        if origin.y < bounds.minY { origin.y = p.y + 18 }
        let box = NSRect(origin: origin, size: total)

        // 背板
        let bg = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        NSColor(white: 0.11, alpha: 0.95).setFill()
        bg.fill()

        // 放大区域：直接整幅底图按倍率绘制 + 裁剪，屏幕边缘自然留黑，无需特判。
        let bodyRect = NSRect(x: box.minX + 4, y: box.maxY - 4 - body, width: body, height: body)
        ctx.saveGState()
        NSBezierPath(rect: bodyRect).addClip()
        ctx.interpolationQuality = .none
        let drawW = CGFloat(image.width) * unit
        let drawH = CGFloat(image.height) * unit
        // 非翻转上下文里图像顶行画在 rect 顶部；把 (px,py) 的像素中心对到视野中心。
        let originX = bodyRect.midX - (px + 0.5) * unit
        let originY = bodyRect.midY - (drawH - (py + 0.5) * unit)
        ctx.draw(image, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))
        ctx.restoreGState()

        // 十字线 + 中心像素格
        NSColor(white: 1, alpha: 0.35).setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 1
        cross.move(to: NSPoint(x: bodyRect.midX, y: bodyRect.minY))
        cross.line(to: NSPoint(x: bodyRect.midX, y: bodyRect.maxY))
        cross.move(to: NSPoint(x: bodyRect.minX, y: bodyRect.midY))
        cross.line(to: NSPoint(x: bodyRect.maxX, y: bodyRect.midY))
        cross.stroke()
        let centerCell = NSRect(x: bodyRect.midX - unit / 2, y: bodyRect.midY - unit / 2,
                                width: unit, height: unit)
        accent.setStroke()
        let cellPath = NSBezierPath(rect: centerCell)
        cellPath.lineWidth = 1.5
        cellPath.stroke()

        // 信息行：CG 全局坐标 + 中心像素颜色
        let gcg = Geometry.cgPoint(fromAppKit: NSPoint(x: screenRef.frame.minX + p.x,
                                                       y: screenRef.frame.minY + p.y))
        let hex = Self.pixelHex(in: image, x: Int(px), y: Int(py)) ?? "—"
        let info = "\(Int(gcg.x)), \(Int(gcg.y))   \(hex)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.92, alpha: 1)
        ]
        let str = NSAttributedString(string: info, attributes: attrs)
        str.draw(at: NSPoint(x: bodyRect.minX + 2, y: box.minY + 6))
    }

    /// 读取单个像素颜色（画进 1×1 RGBA 上下文）。
    private static func pixelHex(in image: CGImage, x: Int, y: Int) -> String? {
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }

    private func drawDim(_ ctx: CGContext) {
        NSColor(white: 0, alpha: 0.45).setFill()
        bounds.fill()
    }

    private func punchHole(_ ctx: CGContext, rect: NSRect) {
        if let frozenBackground {
            // 冻结模式：选区露出「含菜单底图」的亮部（而非清透明透出实时屏）。
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.interpolationQuality = .high
            ctx.draw(frozenBackground, in: bounds)
            ctx.restoreGState()
            return
        }
        ctx.setBlendMode(.clear)
        NSColor.black.setFill()
        rect.fill()
        ctx.setBlendMode(.normal)
    }

    private func drawSelectionBorder(_ rect: NSRect) {
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()
    }

    private func drawHandles(_ rect: NSRect) {
        NSColor.white.setFill()
        for (_, point) in handlePoints(for: rect) {
            let handleRect = NSRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2,
                                    width: handleSize, height: handleSize)
            handleRect.fill()
        }
    }

    private func drawSizeBadge(_ rect: NSRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        drawBadge(text, origin: NSPoint(x: rect.maxX, y: rect.minY - 26), anchorRight: true)
    }

    private func drawBadge(_ text: String, origin: NSPoint, anchorRight: Bool) {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let padX: CGFloat = 8, padY: CGFloat = 4
        var x = origin.x
        if anchorRight { x -= (size.width + padX * 2) }
        var y = origin.y
        if y < 4 { y = 4 } // 贴底时抬起
        let bgRect = NSRect(x: x, y: y, width: size.width + padX * 2, height: size.height + padY * 2)
        let bg = NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6)
        NSColor(white: 0.11, alpha: 0.92).setFill()
        bg.fill()
        str.draw(at: NSPoint(x: bgRect.minX + padX, y: bgRect.minY + padY))
    }

    private func drawHintPill(_ segments: [String]) {
        let text = segments.joined(separator: "    ")
        let font = NSFont.systemFont(ofSize: 12)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.92, alpha: 1)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let padX: CGFloat = 18, padY: CGFloat = 8
        let w = size.width + padX * 2
        let h = size.height + padY * 2
        let x = bounds.midX - w / 2
        let y: CGFloat = 24
        let bgRect = NSRect(x: x, y: y, width: w, height: h)
        let bg = NSBezierPath(roundedRect: bgRect, xRadius: h / 2, yRadius: h / 2)
        NSColor(white: 0.13, alpha: 0.92).setFill()
        bg.fill()
        str.draw(at: NSPoint(x: bgRect.minX + padX, y: bgRect.minY + padY))
    }

    // MARK: - 标注：工具条与生命周期

    private func showToolbar(for rect: NSRect) {
        if toolbar == nil {
            let created = AnnotationToolbar()
            created.delegate = self
            annotationStyle = created.style
            toolbar = created
            if let window { created.show(attachedTo: window) }
        }
        toolbar?.setHidden(false)
        toolbar?.position(near: globalAKRect(fromLocal: rect), on: screenRef)
    }

    /// 录制模式的选区确认工具条：开始 = 走 ⏎ 同一条完成链路；取消 = 结束整个会话。
    private func showRecordBar(for rect: NSRect) {
        if recordBar == nil {
            let created = RecordStartBar(
                onStart: { [weak self] in self?.handleReturn(saveOnly: false) },
                onCancel: { [weak self] in self?.controller?.cancel() }
            )
            recordBar = created
            if let window { created.show(attachedTo: window) }
        }
        recordBar?.setHidden(false)
        recordBar?.position(near: globalAKRect(fromLocal: rect), on: screenRef)
    }

    /// 会话结束（完成 / 取消 / 整体消隐）时的收尾。
    func teardown() {
        commitTextEditor(cancel: true)
        toolbar?.close()
        toolbar = nil
        recordBar?.close()
        recordBar = nil
        freezeTask?.cancel()
        loupeTask?.cancel()
    }

    // MARK: - 标注：冻结底图

    /// 首次选定工具时捕获选区画面（排除自身蒙层与工具条，overlay 无需消隐）。
    private func beginFreezeIfNeeded(rect: NSRect) {
        guard freezeTask == nil else { return }
        // 冻结模式：标注底图直接从「含菜单整屏」裁剪（同步），不用实时 freezeRegion（那会丢失菜单）。
        if frozenBackground != nil {
            guard let cropped = cropFrozenBackground(localRect: rect) else { return }
            frozenImage = cropped
            needsDisplay = true
            Task { @MainActor [weak self] in
                let mosaic = await Task.detached { AnnotationRenderer.pixellated(cropped) }.value
                self?.mosaicImage = mosaic
                self?.needsDisplay = true
            }
            return
        }
        guard let controller else { return }
        let globalRect = globalAKRect(fromLocal: rect)
        let extra: Set<CGWindowID> = toolbar.map { [$0.windowID] } ?? []
        let task = Task { try await controller.freezeRegion(globalRect, on: self.screenRef,
                                                            alsoExcluding: extra) }
        freezeTask = task
        Task { @MainActor [weak self] in
            guard let self, let image = try? await task.value else { return }
            self.frozenImage = image
            self.needsDisplay = true
            // 马赛克底图生成较重，放后台；就绪前马赛克笔画暂不显示。
            let mosaic = await Task.detached { AnnotationRenderer.pixellated(image) }.value
            self.mosaicImage = mosaic
            self.needsDisplay = true
        }
    }

    /// 从「含菜单整屏」底图裁剪 view 本地 rect 对应的像素（标注底图 / 最终裁剪用）。原点左上、Retina 换算。
    private func cropFrozenBackground(localRect: NSRect) -> CGImage? {
        guard let frozenBackground else { return nil }
        let scale = screenRef.backingScaleFactor
        let x = localRect.minX * scale
        let y = (bounds.height - localRect.maxY) * scale
        let w = localRect.width * scale
        let h = localRect.height * scale
        let pixelRect = CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
        return frozenBackground.cropping(to: pixelRect)
    }

    // MARK: - 标注：绘制提交 / 橡皮 / 撤销

    private func clampPoint(_ p: NSPoint, into rect: NSRect) -> NSPoint {
        NSPoint(x: min(max(p.x, rect.minX), rect.maxX),
                y: min(max(p.y, rect.minY), rect.maxY))
    }

    private func commitDraftIfMeaningful() {
        defer {
            draftShape = nil
            strokePoints = []
            needsDisplay = true
        }
        guard let shape = draftShape, let tool = currentTool else { return }

        let meaningful: Bool
        switch shape {
        case .rect(let r), .ellipse(let r):
            meaningful = r.width >= 3 && r.height >= 3
        case .arrow(let from, let to):
            meaningful = hypot(to.x - from.x, to.y - from.y) >= 6
        case .stroke(let points):
            meaningful = points.count >= 2
        case .text:
            meaningful = false
        }
        guard meaningful else { return }

        pushUndoSnapshot()
        ops.append(AnnotationOp(tool: tool, shape: shape, style: annotationStyle))
        redoSnapshots.removeAll()
        syncToolbarUndoState()
    }

    private func eraseAt(localPoint lp: NSPoint) {
        // 后画的在上层，从后往前找第一笔命中的删除。
        guard let index = ops.lastIndex(where: { AnnotationRenderer.hitTest($0, at: lp) }) else { return }
        pushUndoSnapshot()
        ops.remove(at: index)
        redoSnapshots.removeAll()
        syncToolbarUndoState()
        needsDisplay = true
    }

    private func pushUndoSnapshot() {
        undoSnapshots.append(ops)
    }

    private func undoAnnotation() {
        guard let previous = undoSnapshots.popLast() else { return }
        redoSnapshots.append(ops)
        ops = previous
        syncToolbarUndoState()
        needsDisplay = true
    }

    private func redoAnnotation() {
        guard let next = redoSnapshots.popLast() else { return }
        undoSnapshots.append(ops)
        ops = next
        syncToolbarUndoState()
        needsDisplay = true
    }

    private func syncToolbarUndoState() {
        toolbar?.setUndoEnabled(!undoSnapshots.isEmpty, redo: !redoSnapshots.isEmpty)
    }

    // MARK: - 标注：文字编辑器

    private func beginTextEditor(atViewPoint p: NSPoint) {
        commitTextEditor(cancel: false)

        let height = annotationStyle.fontSize + 8
        let editor = NSTextField(frame: NSRect(x: p.x, y: p.y - height / 2, width: 60, height: height))
        editor.isBezeled = false
        editor.isBordered = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = AnnotationRenderer.textFont(size: annotationStyle.fontSize)
        editor.textColor = annotationStyle.color
        editor.cell?.wraps = false
        editor.cell?.isScrollable = true
        editor.delegate = self
        editor.wantsLayer = true
        editor.layer?.borderWidth = 1
        editor.layer?.borderColor = NSColor(white: 1, alpha: 0.45).cgColor
        addSubview(editor)
        textEditor = editor
        window?.makeFirstResponder(editor)
    }

    private func resizeTextEditorToFit() {
        guard let editor = textEditor else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: editor.font ?? AnnotationRenderer.textFont(size: annotationStyle.fontSize)
        ]
        let size = (editor.stringValue as NSString).size(withAttributes: attrs)
        editor.frame.size = NSSize(width: max(60, size.width + 16),
                                   height: max(annotationStyle.fontSize + 8, size.height + 6))
    }

    private func commitTextEditor(cancel: Bool) {
        guard let editor = textEditor else { return }
        let string = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = editor.frame
        // 先置空再移除：removeFromSuperview 会触发 controlTextDidEndEditing 重入本方法。
        textEditor = nil
        editor.removeFromSuperview()
        window?.makeFirstResponder(self)

        guard !cancel, !string.isEmpty, case .annotating(let rect) = phase else {
            needsDisplay = true
            return
        }
        // 换算成选区本地坐标；x+2 抵消 NSTextField cell 的内边距，让提交后的字不跳位。
        let attr = NSAttributedString(string: string,
                                      attributes: AnnotationRenderer.textAttributes(annotationStyle))
        let textSize = attr.size()
        let origin = NSPoint(x: frame.minX + 2 - rect.minX,
                             y: frame.minY + (frame.height - textSize.height) / 2 - rect.minY)
        pushUndoSnapshot()
        ops.append(AnnotationOp(tool: .text, shape: .text(string, at: origin), style: annotationStyle))
        redoSnapshots.removeAll()
        syncToolbarUndoState()
        needsDisplay = true
    }

    // MARK: - 标注：完成

    private enum FinishAction { case copy, save, pin }

    private func finishSelection(_ action: FinishAction) {
        guard !finishing else { return }
        let rect: NSRect
        switch phase {
        case .adjusting(let r), .annotating(let r):
            rect = r
        default:
            return
        }
        commitTextEditor(cancel: false)
        let globalRect = globalAKRect(fromLocal: rect)

        // 从未进入标注：复制 / 保存走原有实时捕获链路（overlay 消隐后再拍）。
        if ops.isEmpty && freezeTask == nil {
            switch action {
            case .copy:
                controller?.finishRect(globalRect, on: screenRef, mode: .standard)
                return
            case .save:
                controller?.finishRect(globalRect, on: screenRef, mode: .saveOnly)
                return
            case .pin:
                break // 贴图需要拿到图像本身，统一走下方冻结路径。
            }
        }

        finishing = true
        let extra: Set<CGWindowID> = toolbar.map { [$0.windowID] } ?? []
        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }

            var base = self.frozenImage
            if base == nil, let task = self.freezeTask {
                base = try? await task.value
            }
            if base == nil, self.frozenBackground != nil {
                base = self.cropFrozenBackground(localRect: rect)
            }
            if base == nil {
                base = try? await controller.freezeRegion(globalRect, on: self.screenRef,
                                                          alsoExcluding: extra)
            }
            guard let baseImage = base else {
                controller.cancel()
                return
            }

            var final = baseImage
            if !self.ops.isEmpty {
                // 马赛克底图若还没在后台生成完，这里同步补齐，保证导出不缺笔画。
                var mosaic = self.mosaicImage
                if mosaic == nil, self.ops.contains(where: { $0.tool == .mosaic }) {
                    mosaic = AnnotationRenderer.pixellated(baseImage)
                }
                final = AnnotationRenderer.composite(base: baseImage, ops: self.ops,
                                                     mosaicImage: mosaic,
                                                     selectionSizePoints: rect.size) ?? baseImage
            }

            switch action {
            case .copy: controller.finishComposited(final, mode: .standard)
            case .save: controller.finishComposited(final, mode: .saveOnly)
            case .pin: controller.finishPin(final, at: globalRect)
            }
        }
    }
}

// MARK: - 工具条回调

extension CaptureOverlayView: AnnotationToolbarDelegate {
    func toolbarDidSelectTool(_ tool: AnnotationTool) {
        switch phase {
        case .adjusting(let rect):
            // 首次选定工具：锁定选区、冻结画面，进入标注相。
            phase = .annotating(rect: rect)
            beginFreezeIfNeeded(rect: rect)
        case .annotating(let rect):
            commitTextEditor(cancel: false)
            beginFreezeIfNeeded(rect: rect)
        default:
            return
        }
        currentTool = tool
        if case .annotating(let rect) = phase {
            // 参数条出现 / 隐藏会改变面板尺寸，重摆一次。
            toolbar?.position(near: globalAKRect(fromLocal: rect), on: screenRef)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func toolbarDidChangeStyle(_ style: AnnotationStyle) {
        annotationStyle = style
        if let editor = textEditor {
            editor.font = AnnotationRenderer.textFont(size: style.fontSize)
            editor.textColor = style.color
            resizeTextEditorToFit()
        }
    }

    func toolbarUndo() { undoAnnotation() }
    func toolbarRedo() { redoAnnotation() }
    func toolbarCancel() { controller?.cancel() }
    func toolbarPin() { finishSelection(.pin) }
    func toolbarSave() { finishSelection(.save) }
    func toolbarCopy() { finishSelection(.copy) }
}

// MARK: - 文字编辑器回调

extension CaptureOverlayView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        resizeTextEditorToFit()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEditor(cancel: false)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditor(cancel: true)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextEditor(cancel: false)
            return true
        }
        return false
    }
}
