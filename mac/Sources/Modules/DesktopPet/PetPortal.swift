import AppKit
import QuartzCore

/// 出场 / 退场的黑洞（#54，docs/desktop-pet/ENTRANCE.md §2）：宠物脚下一个透视压扁的旋涡 ——
/// 黑色洞心、外圈一道旋转的紫 / 青色吸积环，边缘渐隐。独立的透明窗口，排在宠物窗下面（宠物「站在」洞口上）。
/// 不接鼠标。只用 Core Animation 图层，没有逐帧绘制。
@MainActor
final class PetPortal {
    private var window: NSWindow?
    private let container = CALayer()
    private let glow = CAGradientLayer()
    private let swirl = CAGradientLayer()
    private let swirlMask = CAShapeLayer()
    private let core = CAShapeLayer()
    private var diameter: CGFloat = 0
    /// 椭圆的扁度（高 / 宽）：从略俯视的角度看地上的洞。
    private static let squash: CGFloat = 0.34

    /// 放到 `center`（屏幕坐标，洞的中心）、宽 `width`，排在 `petWindow` 下面。开口从 0 开始。
    func show(center: NSPoint, width: CGFloat, below petWindow: NSWindow) {
        let window = self.window ?? makeWindow()
        self.window = window
        let size = NSSize(width: width * 1.2, height: width * 1.2 * Self.squash + 8)
        window.setFrame(NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                               width: size.width, height: size.height), display: false)
        layout(width: width, in: size)
        setOpen(0)
        window.order(.below, relativeTo: petWindow.windowNumber)
    }

    /// 张开的程度 0–1（逐帧调用，关掉隐式动画）。
    func setOpen(_ amount: CGFloat) {
        let k = max(0, min(amount, 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.transform = CATransform3DMakeScale(max(k, 0.001), max(k, 0.001) * Self.squash, 1)
        container.opacity = Float(min(1, k * 1.6))
        CATransaction.commit()
    }

    func hide() {
        window?.orderOut(nil)
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
        view.layer?.addSublayer(container)

        // 外圈光晕：中间黑、往外紫、最外透明。
        glow.type = .radial
        glow.colors = [NSColor.black.cgColor, NSColor.black.cgColor,
                       NSColor(red: 0.42, green: 0.18, blue: 0.85, alpha: 0.75).cgColor,
                       NSColor(red: 0.17, green: 0.77, blue: 0.72, alpha: 0.25).cgColor,
                       NSColor.clear.cgColor]
        glow.locations = [0, 0.38, 0.62, 0.82, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        container.addSublayer(glow)

        // 吸积环：圆锥渐变 + 环形遮罩，一直转。
        swirl.type = .conic
        swirl.colors = [NSColor(red: 0.55, green: 0.3, blue: 1, alpha: 0.9).cgColor,
                        NSColor.clear.cgColor,
                        NSColor(red: 0.17, green: 0.77, blue: 0.72, alpha: 0.8).cgColor,
                        NSColor.clear.cgColor,
                        NSColor(red: 0.55, green: 0.3, blue: 1, alpha: 0.9).cgColor]
        swirl.startPoint = CGPoint(x: 0.5, y: 0.5)
        swirl.endPoint = CGPoint(x: 0.5, y: 0)
        swirlMask.fillRule = .evenOdd
        swirl.mask = swirlMask
        container.addSublayer(swirl)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1.1
        spin.repeatCount = .infinity
        swirl.add(spin, forKey: "pet.portal.spin")

        core.fillColor = NSColor.black.cgColor
        container.addSublayer(core)
        return window
    }

    /// 图层按正圆排（直径 = 宽），整体再按 `squash` 压扁成椭圆。
    private func layout(width: CGFloat, in size: NSSize) {
        guard width != diameter else { return }
        diameter = width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let square = CGRect(x: 0, y: 0, width: width, height: width)
        container.bounds = square
        container.position = CGPoint(x: size.width / 2, y: size.height / 2)
        glow.frame = square
        swirl.frame = square
        let ring = CGMutablePath()
        ring.addEllipse(in: square.insetBy(dx: width * 0.12, dy: width * 0.12))
        ring.addEllipse(in: square.insetBy(dx: width * 0.3, dy: width * 0.3))
        swirlMask.frame = square
        swirlMask.path = ring
        core.frame = square
        core.path = CGPath(ellipseIn: square.insetBy(dx: width * 0.3, dy: width * 0.3), transform: nil)
        CATransaction.commit()
    }
}
