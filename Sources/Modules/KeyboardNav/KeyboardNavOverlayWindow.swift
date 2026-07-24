import AppKit

/// 一个标签在某屏 overlay 内的绘制信息（view 本地 AppKit 坐标）。
struct HintTarget {
    let label: String
    let rectAK: NSRect
}

/// 覆盖单屏的透明键盘点击标签窗口（仿截图 `CaptureOverlayWindow`）。
@MainActor
final class KeyboardNavOverlayWindow: NSWindow {
    private let navView: KeyboardNavOverlayView

    init(screen: NSScreen, targets: [HintTarget], controller: KeyboardNavController) {
        self.navView = KeyboardNavOverlayView(targets: targets, controller: controller)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // level 先于 setFrame：普通级别会被菜单栏约束下移，标签坐标随之偏移（同截图 overlay 的坑）。
        level = .screenSaver
        setFrame(screen.frame, display: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = navView
        initialFirstResponder = navView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func focusView() { makeFirstResponder(navView) }
    func updateInput(_ input: String) { navView.updateInput(input) }
}
