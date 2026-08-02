import AppKit

/// 覆盖单个屏幕的透明画布窗口。
///
/// 与截图 overlay 的区别：不压暗屏幕（要看清底下的实时内容）、可切换为鼠标穿透、
/// 生命周期由 `ScreenDrawController` 管理而不是一次性会话。
@MainActor
final class ScreenDrawOverlayWindow: NSPanel {
    let targetScreen: NSScreen
    let drawView: ScreenDrawView

    init(screen: NSScreen, controller: ScreenDrawController) {
        self.targetScreen = screen
        self.drawView = ScreenDrawView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        // level 必须先于 setFrame 设置：普通级别的窗口会被 AppKit 的 constrainFrameRect
        // 施加菜单栏约束，画布整体下移就盖不住顶部菜单栏，坐标也跟着偏。
        level = .screenSaver
        setFrame(screen.frame, display: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        drawView.controller = controller
        contentView = drawView
        initialFirstResponder = drawView
    }

    // borderless 窗口默认不能成为 key，而 Esc / ⌘Z / ⌫ 都要靠键盘。
    override var canBecomeKey: Bool { true }

    /// 彻底关掉菜单栏约束，保证画布精确覆盖整屏。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func focusDrawView() {
        makeFirstResponder(drawView)
    }

    /// 穿透态：整扇窗口放行鼠标事件（笔迹仍然可见）。
    func setPassThrough(_ on: Bool) {
        ignoresMouseEvents = on
    }
}
