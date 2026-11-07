import AppKit
import QuartzCore

/// 爬高爬低时脚下冒出来的台阶（docs/desktop-pet/SETTLE.md §4.4，用户提议「像黑洞一样给脚底下渲染一个台阶，爬上去后就消失」）。
/// 和出场的黑洞一个画风：一块块发光的紫 / 青色小台面。宠物每踩高（低）一级，脚下冒出一块；
/// 走过的那块慢慢淡掉、往下沉一点；爬完，剩下的也淡掉。
/// 独立的透明窗口铺满宠物所在的屏，排在宠物窗下面，不接鼠标。只用 Core Animation，没有逐帧绘制。
@MainActor
final class PetStairs {
    private var window: NSWindow?
    private var steps: [CALayer] = []
    private var hideWork: DispatchWorkItem?

    /// 脚下冒一级台阶：`feet` 是脚底中点（屏幕坐标），台面顶边就在这儿；`width` 台面宽。
    func addStep(at feet: NSPoint, width: CGFloat, below petWindow: NSWindow) {
        hideWork?.cancel()
        hideWork = nil
        let screen = NSScreen.screens.first(where: { $0.frame.contains(feet) }) ?? petWindow.screen ?? NSScreen.main
        guard let screen else { return }
        let window = self.window ?? makeWindow()
        self.window = window
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        // 排在宠物窗下面（orderedIndex 越小越靠前）。
        if !window.isVisible || window.orderedIndex < petWindow.orderedIndex {
            window.order(.below, relativeTo: petWindow.windowNumber)
        }
        guard let root = window.contentView?.layer else { return }

        // 走过的台阶（除了刚才脚下那一块）淡掉。
        if steps.count >= 2 {
            for old in steps.dropLast() { fade(old, after: 0) }
            steps = Array(steps.suffix(1))
        }
        let height = max(width * 0.16, 6)
        let step = makeStep(width: width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        step.frame = CGRect(x: feet.x - screen.frame.minX - width / 2, y: feet.y - screen.frame.minY - height,
                            width: width, height: height)
        root.addSublayer(step)
        CATransaction.commit()
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.55
        pop.toValue = 1
        pop.duration = 0.16
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        step.add(pop, forKey: "pet.stairs.pop")
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.16
        step.add(appear, forKey: "pet.stairs.appear")
        steps.append(step)
    }

    /// 爬完了：剩下的台阶淡掉，再收起窗口。
    func finish() {
        for step in steps { fade(step, after: 0.25) }
        steps = []
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.steps.isEmpty else { return }
                self.window?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// 淡掉、往下沉一点，然后拿掉。
    private func fade(_ step: CALayer, after delay: CFTimeInterval) {
        let group = CAAnimationGroup()
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        let sink = CABasicAnimation(keyPath: "position.y")
        sink.fromValue = step.position.y
        sink.toValue = step.position.y - step.bounds.height * 0.8
        group.animations = [fadeOut, sink]
        group.duration = 0.6
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        step.add(group, forKey: "pet.stairs.fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.65) {
            step.removeFromSuperlayer()
        }
    }

    /// 一块台面：黑色（用户 2026-11-07：「颜色太艳丽了，黑色的就行」），上面略浅一点看得出台面，
    /// 顶上一道很淡的高光，深色背景上也分得清；底下一点软阴影。
    private func makeStep(width: CGFloat, height: CGFloat) -> CALayer {
        let slab = CAGradientLayer()
        slab.colors = [NSColor(white: 0.16, alpha: 0.95).cgColor, NSColor(white: 0.02, alpha: 0.95).cgColor]
        slab.locations = [0, 1]
        // 图层坐标 y 朝上：startPoint 在顶上。
        slab.startPoint = CGPoint(x: 0.5, y: 1)
        slab.endPoint = CGPoint(x: 0.5, y: 0)
        slab.cornerRadius = min(height * 0.2, 3)
        slab.shadowColor = NSColor.black.cgColor
        slab.shadowOpacity = 0.35
        slab.shadowRadius = max(height * 0.3, 2)
        slab.shadowOffset = CGSize(width: 0, height: -1)
        let highlight = CALayer()
        highlight.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        highlight.frame = CGRect(x: width * 0.12, y: height - max(height * 0.18, 1.5), width: width * 0.76,
                                 height: max(height * 0.12, 1))
        highlight.cornerRadius = highlight.frame.height / 2
        slab.addSublayer(highlight)
        return slab
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
