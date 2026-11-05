import AppKit

/// M1 内置形象：代码绘制的橘猫。
///
/// 设计 §7 的渲染层解耦点在本文件：引擎只产出 PetPose，本视图负责把它画出来。
/// 后续放入 `Resources/Pets/<id>/` 的帧序列（2D)或 USDZ 模型（3D)时，
/// 换掉本视图即可，引擎、窗口、通知内核都不动。
final class CodeDrawnPetView: NSView {
    var pose = PetPose() {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }

        let b = bounds
        let s = min(b.width, b.height)
        let cx = b.midX
        // 朝向：绘制一律朝右，需要时整体镜像。
        if pose.facingLeft {
            context.cgContext.translateBy(x: cx, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            context.cgContext.translateBy(x: -cx, y: 0)
        }
        context.cgContext.translateBy(x: 0, y: pose.bob + pose.bounce)

        let ground = b.minY + s * 0.05
        if pose.lying {
            drawLying(cx: cx, ground: ground, s: s)
        } else {
            drawStanding(cx: cx, ground: ground, s: s)
        }
    }

    // MARK: - 颜色

    private var bodyColor: NSColor { NSColor(calibratedRed: 0.93, green: 0.58, blue: 0.25, alpha: 1) }
    private var darkColor: NSColor { NSColor(calibratedRed: 0.60, green: 0.35, blue: 0.14, alpha: 1) }
    private var creamColor: NSColor { NSColor(calibratedRed: 0.99, green: 0.91, blue: 0.78, alpha: 1) }
    private var pinkColor: NSColor { NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.55, alpha: 1) }

    // MARK: - 站姿（待机 / 行走共用，腿部相位不同）

    private func drawStanding(cx: CGFloat, ground: CGFloat, s: CGFloat) {
        let wandering = pose.state == .wander
        let wag = sin(wandering ? pose.walkPhase * 0.8 : pose.time * 2) * s * 0.03

        // 尾巴
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx - s * 0.24, y: ground + s * 0.34))
        tail.curve(to: NSPoint(x: cx - s * 0.45, y: ground + s * 0.56 + wag),
                   controlPoint1: NSPoint(x: cx - s * 0.40, y: ground + s * 0.30),
                   controlPoint2: NSPoint(x: cx - s * 0.50, y: ground + s * 0.44))
        tail.lineWidth = s * 0.05
        tail.lineCapStyle = .round
        darkColor.setStroke()
        tail.stroke()

        // 腿：行走时交替抬起，待机时是两只前爪
        if wandering {
            let liftA = max(0, sin(pose.walkPhase)) * s * 0.035
            let liftB = max(0, -sin(pose.walkPhase)) * s * 0.035
            bodyColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: cx + s * 0.08, y: ground + liftA, width: s * 0.07, height: s * 0.13),
                         xRadius: s * 0.03, yRadius: s * 0.03).fill()
            NSBezierPath(roundedRect: NSRect(x: cx - s * 0.16, y: ground + liftB, width: s * 0.07, height: s * 0.13),
                         xRadius: s * 0.03, yRadius: s * 0.03).fill()
        } else {
            bodyColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx + s * 0.02, y: ground, width: s * 0.12, height: s * 0.05)).fill()
            NSBezierPath(ovalIn: NSRect(x: cx - s * 0.18, y: ground, width: s * 0.12, height: s * 0.05)).fill()
        }

        // 身体与肚子
        bodyColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - s * 0.29, y: ground + s * 0.12, width: s * 0.58, height: s * 0.40)).fill()
        creamColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - s * 0.14, y: ground + s * 0.14, width: s * 0.36, height: s * 0.24)).fill()
        // 背部条纹
        darkColor.setStroke()
        for i in 0..<3 {
            let stripe = NSBezierPath()
            let x = cx - s * 0.10 + CGFloat(i) * s * 0.09
            stripe.move(to: NSPoint(x: x, y: ground + s * 0.50))
            stripe.line(to: NSPoint(x: x + s * 0.02, y: ground + s * 0.42))
            stripe.lineWidth = s * 0.018
            stripe.lineCapStyle = .round
            stripe.stroke()
        }

        drawHead(hx: cx + s * 0.22, hy: ground + s * 0.60, s: s)
    }

    // MARK: - 躺姿（睡觉）

    private func drawLying(cx: CGFloat, ground: CGFloat, s: CGFloat) {
        // 身体：扁长椭圆贴地
        bodyColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - s * 0.35, y: ground, width: s * 0.70, height: s * 0.27)).fill()
        // 尾巴环在身后
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: cx - s * 0.33, y: ground + s * 0.06))
        tail.curve(to: NSPoint(x: cx - s * 0.10, y: ground + s * 0.015),
                   controlPoint1: NSPoint(x: cx - s * 0.38, y: ground + s * 0.02),
                   controlPoint2: NSPoint(x: cx - s * 0.24, y: ground - s * 0.01))
        tail.lineWidth = s * 0.045
        tail.lineCapStyle = .round
        darkColor.setStroke()
        tail.stroke()

        // 头枕在身体前端
        let hx = cx + s * 0.28
        let hy = ground + s * 0.13
        bodyColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: hx - s * 0.16, y: hy - s * 0.16, width: s * 0.32, height: s * 0.32)).fill()
        let ear = NSBezierPath()
        ear.move(to: NSPoint(x: hx - s * 0.12, y: hy + s * 0.10))
        ear.line(to: NSPoint(x: hx - s * 0.11, y: hy + s * 0.24))
        ear.line(to: NSPoint(x: hx + s * 0.01, y: hy + s * 0.14))
        ear.close()
        bodyColor.setFill()
        ear.fill()
        // 闭眼 + 鼻子
        darkColor.setStroke()
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: hx + s * 0.03, y: hy + s * 0.01))
        eye.line(to: NSPoint(x: hx + s * 0.10, y: hy + s * 0.01))
        eye.lineWidth = s * 0.016
        eye.lineCapStyle = .round
        eye.stroke()
        pinkColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: hx + s * 0.135, y: hy - s * 0.045, width: s * 0.04, height: s * 0.028)).fill()

        // Zzz
        let drift = CGFloat(sin(pose.time * 1.2)) * s * 0.012
        drawLetter("Z", at: NSPoint(x: hx + s * 0.10, y: hy + s * 0.24 + drift), size: s * 0.17, alpha: 0.75)
        drawLetter("z", at: NSPoint(x: hx + s * 0.02, y: hy + s * 0.38 + drift), size: s * 0.12, alpha: 0.5)
    }

    // MARK: - 头（站姿）

    private func drawHead(hx: CGFloat, hy: CGFloat, s: CGFloat) {
        // 耳朵
        for dx in [CGFloat(-0.15), CGFloat(0.03)] {
            let ear = NSBezierPath()
            ear.move(to: NSPoint(x: hx + dx * s, y: hy + s * 0.12))
            ear.line(to: NSPoint(x: hx + (dx + 0.015) * s, y: hy + s * 0.30))
            ear.line(to: NSPoint(x: hx + (dx + 0.14) * s, y: hy + s * 0.155))
            ear.close()
            bodyColor.setFill()
            ear.fill()
            let inner = NSBezierPath()
            inner.move(to: NSPoint(x: hx + (dx + 0.035) * s, y: hy + s * 0.145))
            inner.line(to: NSPoint(x: hx + (dx + 0.045) * s, y: hy + s * 0.235))
            inner.line(to: NSPoint(x: hx + (dx + 0.115) * s, y: hy + s * 0.16))
            inner.close()
            pinkColor.setFill()
            inner.fill()
        }
        // 脸
        bodyColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: hx - s * 0.205, y: hy - s * 0.205, width: s * 0.41, height: s * 0.41)).fill()
        // 口鼻
        creamColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: hx - s * 0.02, y: hy - s * 0.125, width: s * 0.20, height: s * 0.13)).fill()
        pinkColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: hx + s * 0.135, y: hy - s * 0.05, width: s * 0.045, height: s * 0.03)).fill()
        // 眼睛
        if pose.eyesClosed {
            darkColor.setStroke()
            for dx in [CGFloat(0.03), CGFloat(0.14)] {
                let eye = NSBezierPath()
                eye.move(to: NSPoint(x: hx + dx * s - s * 0.02, y: hy + s * 0.04))
                eye.line(to: NSPoint(x: hx + dx * s + s * 0.02, y: hy + s * 0.04))
                eye.lineWidth = s * 0.016
                eye.lineCapStyle = .round
                eye.stroke()
            }
        } else {
            darkColor.setFill()
            for dx in [CGFloat(0.03), CGFloat(0.14)] {
                NSBezierPath(ovalIn: NSRect(x: hx + dx * s - s * 0.016, y: hy + s * 0.024, width: s * 0.032, height: s * 0.032)).fill()
            }
        }
        // 胡须
        darkColor.setStroke()
        for dy in [CGFloat(0.0), CGFloat(-0.045)] {
            let whisker = NSBezierPath()
            whisker.move(to: NSPoint(x: hx + s * 0.15, y: hy + dy * s - s * 0.03))
            whisker.line(to: NSPoint(x: hx + s * 0.27, y: hy + dy * s - s * 0.015))
            whisker.lineWidth = s * 0.008
            whisker.stroke()
        }
    }

    private func drawLetter(_ letter: String, at point: NSPoint, size: CGFloat, alpha: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: size),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(alpha),
        ]
        (letter as NSString).draw(at: point, withAttributes: attrs)
    }
}
