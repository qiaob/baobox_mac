import AppKit
import CoreImage

/// 标注工具。
enum AnnotationTool: CaseIterable {
    case rect, ellipse, arrow, pen, highlighter, mosaic, text, eraser

    /// 该工具是否需要参数条（颜色 / 粗细）。
    var wantsStyleRow: Bool {
        switch self {
        case .eraser, .mosaic: return false
        default: return true
        }
    }
}

/// 标注样式。lineWidth 同时驱动字号（text 工具）与马赛克笔刷宽度的倍率。
struct AnnotationStyle {
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var fontSize: CGFloat = 18
}

/// 一条已提交的标注。几何均为「选区本地坐标」：原点 = 选区左下角，y 向上，单位 pt。
/// 预览（视图内平移后绘制）与导出（按像素倍率缩放后绘制）共用同一坐标系与绘制代码，
/// 保证"看到什么就导出什么"。
struct AnnotationOp {
    enum Shape {
        case rect(NSRect)
        case ellipse(NSRect)
        case arrow(from: NSPoint, to: NSPoint)
        case stroke([NSPoint])          // pen / highlighter / mosaic 共用点列
        case text(String, at: NSPoint)  // at = 文字框左下角
    }

    let tool: AnnotationTool
    let shape: Shape
    let style: AnnotationStyle
}

/// 标注绘制与命中检测。所有绘制走 NSBezierPath / NSAttributedString，
/// 依赖调用方已把 NSGraphicsContext 对齐到选区本地坐标。
enum AnnotationRenderer {

    static func textFont(size: CGFloat) -> NSFont {
        .boldSystemFont(ofSize: size)
    }

    static func textAttributes(_ style: AnnotationStyle) -> [NSAttributedString.Key: Any] {
        [.font: textFont(size: style.fontSize), .foregroundColor: style.color]
    }

    // MARK: - 绘制

    /// 把 ops 依次绘制到当前图形上下文。`mosaicImage` 为与选区等大的马赛克化底图。
    static func draw(_ ops: [AnnotationOp], bounds: NSRect, mosaicImage: CGImage?) {
        for op in ops {
            draw(op, bounds: bounds, mosaicImage: mosaicImage)
        }
    }

    static func draw(_ op: AnnotationOp, bounds: NSRect, mosaicImage: CGImage?) {
        let style = op.style
        switch op.shape {
        case .rect(let r):
            let path = NSBezierPath(rect: r)
            path.lineWidth = style.lineWidth
            path.lineJoinStyle = .round
            style.color.setStroke()
            path.stroke()

        case .ellipse(let r):
            let path = NSBezierPath(ovalIn: r)
            path.lineWidth = style.lineWidth
            style.color.setStroke()
            path.stroke()

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, style: style)

        case .stroke(let points):
            guard points.count > 1 else { break }
            switch op.tool {
            case .mosaic:
                drawMosaicStroke(points, style: style, bounds: bounds, mosaicImage: mosaicImage)
            case .highlighter:
                let path = strokePath(points)
                path.lineWidth = style.lineWidth * 4
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                // 单条 path 一次 stroke，自交叠处不会出现深色斑块。
                style.color.withAlphaComponent(0.35).setStroke()
                path.stroke()
            default:
                let path = strokePath(points)
                path.lineWidth = style.lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                style.color.setStroke()
                path.stroke()
            }

        case .text(let string, let at):
            NSAttributedString(string: string, attributes: textAttributes(style))
                .draw(at: at)
        }
    }

    private static func strokePath(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        return path
    }

    private static func drawArrow(from: NSPoint, to: NSPoint, style: AnnotationStyle) {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let headLen = max(10, style.lineWidth * 3.5)
        let headHalf = headLen * 0.45

        // 箭杆止于箭头根部，避免粗线穿出三角。
        let shaftEnd = NSPoint(x: to.x - ux * headLen, y: to.y - uy * headLen)
        let shaft = NSBezierPath()
        shaft.move(to: from)
        shaft.line(to: shaftEnd)
        shaft.lineWidth = style.lineWidth
        shaft.lineCapStyle = .round
        style.color.setStroke()
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: NSPoint(x: shaftEnd.x - uy * headHalf, y: shaftEnd.y + ux * headHalf))
        head.line(to: NSPoint(x: shaftEnd.x + uy * headHalf, y: shaftEnd.y - ux * headHalf))
        head.close()
        style.color.setFill()
        head.fill()
    }

    private static func drawMosaicStroke(_ points: [NSPoint], style: AnnotationStyle,
                                         bounds: NSRect, mosaicImage: CGImage?) {
        guard let mosaicImage, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let brushWidth = max(16, style.lineWidth * 7)

        let cgPath = CGMutablePath()
        cgPath.move(to: points[0])
        for p in points.dropFirst() { cgPath.addLine(to: p) }
        let stroked = cgPath.copy(strokingWithWidth: brushWidth, lineCap: .round,
                                  lineJoin: .round, miterLimit: 10)

        ctx.saveGState()
        ctx.addPath(stroked)
        ctx.clip()
        ctx.draw(mosaicImage, in: bounds)
        ctx.restoreGState()
    }

    // MARK: - 命中检测（橡皮擦整笔删除）

    /// 点距该标注绘制痕迹 ≤ 容差时命中。
    static func hitTest(_ op: AnnotationOp, at p: NSPoint) -> Bool {
        let tolerance: CGFloat = 8
        switch op.shape {
        case .rect(let r):
            let inner = r.insetBy(dx: tolerance, dy: tolerance)
            let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
            if inner.width <= 0 || inner.height <= 0 { return outer.contains(p) }
            return outer.contains(p) && !inner.contains(p)

        case .ellipse(let r):
            guard r.width > 1, r.height > 1 else { return false }
            let dx = (p.x - r.midX) / (r.width / 2)
            let dy = (p.y - r.midY) / (r.height / 2)
            let d = sqrt(dx * dx + dy * dy)
            let radialTolerance = tolerance / min(r.width / 2, r.height / 2)
            return abs(d - 1) <= radialTolerance

        case .arrow(let from, let to):
            return distanceToSegment(p, from, to) <= tolerance + op.style.lineWidth / 2

        case .stroke(let points):
            let extra = (op.tool == .mosaic) ? max(16, op.style.lineWidth * 7) / 2
                : (op.tool == .highlighter) ? op.style.lineWidth * 2
                : op.style.lineWidth / 2
            for i in 0..<(points.count - 1) {
                if distanceToSegment(p, points[i], points[i + 1]) <= tolerance + extra {
                    return true
                }
            }
            return false

        case .text(let string, let at):
            let size = NSAttributedString(string: string, attributes: textAttributes(op.style)).size()
            return NSRect(origin: at, size: size).insetBy(dx: -4, dy: -4).contains(p)
        }
    }

    private static func distanceToSegment(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lenSq = abx * abx + aby * aby
        guard lenSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq))
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    // MARK: - 马赛克底图 / 导出合成

    /// 生成整张马赛克化底图（绘制时按笔刷路径剪裁使用）。
    static func pixellated(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(8, min(image.width, image.height) / 45), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage else { return nil }
        // CIPixellate 的输出范围是无限延展的，必须按原图尺寸裁剪。
        return CIContext().createCGImage(output, from: CGRect(x: 0, y: 0,
                                                              width: image.width,
                                                              height: image.height))
    }

    /// 把标注按像素倍率合成到冻结底图上，产出最终导出图。
    static func composite(base: CGImage, ops: [AnnotationOp],
                          mosaicImage: CGImage?, selectionSizePoints: NSSize) -> CGImage? {
        guard !ops.isEmpty, selectionSizePoints.width > 0, selectionSizePoints.height > 0 else {
            return base
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return base
        }
        let fullPixels = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        ctx.draw(base, in: fullPixels)

        // 缩放到 pt 坐标系后复用预览绘制代码，线宽、字号随之等比放大。
        ctx.scaleBy(x: CGFloat(base.width) / selectionSizePoints.width,
                    y: CGFloat(base.height) / selectionSizePoints.height)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        draw(ops, bounds: NSRect(origin: .zero, size: selectionSizePoints), mosaicImage: mosaicImage)
        NSGraphicsContext.current = previous

        return ctx.makeImage()
    }
}
