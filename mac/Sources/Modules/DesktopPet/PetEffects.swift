import AppKit
import QuartzCore

/// 跳 / 飞时脚下的小特效（docs/desktop-pet/SETTLE.md §4.4）：起跳、落地扬一小团土，火箭起飞、落地喷一团烟，
/// 二段跳空中再蹬时脚下一圈气浪。特效留在原地、不跟着宠物窗走，所以画在单独一层：
/// 透明窗口铺满宠物所在的屏，排在宠物窗下面，不接鼠标；只用 Core Animation，播完就拿掉。
@MainActor
final class PetEffects {
    private var window: NSWindow?
    private var hideWork: DispatchWorkItem?

    /// 脚下扬一小团土 / 喷一团烟：`feet` 脚底中点（屏幕坐标），`width` 大致多宽（按宠物身形）。
    func puff(at feet: NSPoint, width: CGFloat, smoke: Bool, below petWindow: NSWindow) {
        guard let root = layer(at: feet, below: petWindow) else { return }
        let local = convert(feet)
        let count = smoke ? 7 : 5
        let life: CFTimeInterval = smoke ? 0.7 : 0.45
        for i in 0..<count {
            let side: CGFloat = i % 2 == 0 ? -1 : 1
            let spread = CGFloat(i / 2 + 1) / CGFloat(count / 2 + 1)
            let radius = width * (smoke ? 0.11 : 0.07) * CGFloat.random(in: 0.8...1.2)
            let blob = CALayer()
            blob.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            blob.cornerRadius = radius
            blob.backgroundColor = (smoke ? NSColor(white: 0.93, alpha: 0.82) : NSColor(calibratedRed: 0.86, green: 0.82, blue: 0.76, alpha: 0.8)).cgColor
            blob.borderColor = NSColor(white: smoke ? 0.6 : 0.5, alpha: 0.45).cgColor
            blob.borderWidth = 1
            blob.position = CGPoint(x: local.x + side * width * 0.06 * spread, y: local.y + radius * 0.6)
            root.addSublayer(blob)
            let drift = CABasicAnimation(keyPath: "position")
            drift.toValue = NSValue(point: CGPoint(x: blob.position.x + side * width * (smoke ? 0.45 : 0.32) * spread,
                                                   y: blob.position.y + width * (smoke ? 0.12 : 0.07) * CGFloat.random(in: 0.5...1)))
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.4
            grow.toValue = smoke ? 1.6 : 1.3
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [drift, grow, fade]
            group.duration = life * Double.random(in: 0.85...1.15)
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            blob.add(group, forKey: "pet.effects.puff")
            remove(blob, after: group.duration + 0.05)
        }
        scheduleHide(after: life + 0.4)
    }

    /// 二段跳空中再蹬：脚下一圈白色气浪，往外扩、变淡。
    func ring(at feet: NSPoint, width: CGFloat, below petWindow: NSWindow) {
        guard let root = layer(at: feet, below: petWindow) else { return }
        let local = convert(feet)
        let ring = CAShapeLayer()
        let w = width * 0.5, h = width * 0.14
        ring.path = CGPath(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
        ring.lineWidth = max(width * 0.025, 1.5)
        ring.shadowColor = NSColor(white: 0, alpha: 1).cgColor
        ring.shadowOpacity = 0.25
        ring.shadowRadius = 1.5
        ring.shadowOffset = .zero
        ring.position = local
        root.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.5
        grow.toValue = 1.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.4
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "pet.effects.ring")
        remove(ring, after: 0.45)
        scheduleHide(after: 0.8)
    }

    // MARK: - 窗口

    /// 铺好特效窗（宠物所在的屏、排在宠物窗下面），返回画特效的图层。
    private func layer(at point: NSPoint, below petWindow: NSWindow) -> CALayer? {
        hideWork?.cancel()
        hideWork = nil
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? petWindow.screen ?? NSScreen.main
        guard let screen else { return nil }
        let window = self.window ?? makeWindow()
        self.window = window
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        if !window.isVisible || window.orderedIndex < petWindow.orderedIndex {
            window.order(.below, relativeTo: petWindow.windowNumber)
        }
        return window.contentView?.layer
    }

    /// 屏幕坐标 → 特效窗里的坐标。
    private func convert(_ point: NSPoint) -> CGPoint {
        guard let frame = window?.frame else { return point }
        return CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    private func remove(_ layer: CALayer, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { layer.removeFromSuperlayer() }
    }

    /// 特效都播完了再收起窗口（又来了新的就取消）。
    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window?.contentView?.layer?.sublayers?.isEmpty ?? true else { return }
                self.window?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makeWindow() -> NSWindow {
        let window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        let view = NSView()
        view.wantsLayer = true
        window.contentView = view
        return window
    }
}
