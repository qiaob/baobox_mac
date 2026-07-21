import AppKit

/// 覆盖单个屏幕的透明截图 overlay 窗口。
@MainActor
final class CaptureOverlayWindow: NSWindow {
    let targetScreen: NSScreen
    private let overlayView: CaptureOverlayView

    init(screen: NSScreen, controller: CaptureController) {
        self.targetScreen = screen
        self.overlayView = CaptureOverlayView(screen: screen, controller: controller)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)

        // level 必须先于 setFrame 设置：普通级别的窗口会被 AppKit 的
        // constrainFrameRect(_:to:) 施加菜单栏约束，导致 overlay 整体下移、
        // 盖不住顶部菜单栏，选区坐标也会跟着偏移。
        level = .screenSaver
        setFrame(screen.frame, display: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        contentView = overlayView
        initialFirstResponder = overlayView
    }

    // borderless 窗口默认不能成为 key/main，必须覆写。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 彻底关闭菜单栏约束，保证 overlay 精确覆盖整屏（零成本保险）。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func focusOverlayView() {
        makeFirstResponder(overlayView)
    }

    /// 会话结束前的收尾：关闭标注工具条、文字编辑器等附属 UI。
    func teardown() {
        overlayView.teardown()
    }
}
