import AppKit

/// 一个标签在某屏 overlay 内的绘制信息（view 本地 AppKit 坐标）。
struct HintTarget {
    let label: String
    let rectAK: NSRect
}

/// 覆盖单屏的透明键盘点击标签窗口。
///
/// `.nonactivatingPanel` + 全程鼠标穿透：会话期间**不抢激活、不吃鼠标** ——
/// 焦点始终留在目标 App（点完 hint 前台不变，别的 App 拉开的菜单也不会被
/// `NSApp.activate` 收起），合成点击也永远不会打在自己的 overlay 上。
/// 键盘输入不靠 key window，由 `KeyboardNavController` 的 CGEventTap 捕获。
@MainActor
final class KeyboardNavOverlayWindow: NSPanel {
    private let navView: KeyboardNavOverlayView

    init(screen: NSScreen, content: KeyboardNavOverlayView.Content) {
        self.navView = KeyboardNavOverlayView(content: content)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // level 先于 setFrame：普通级别会被菜单栏约束下移，标签坐标随之偏移（同截图 overlay 的坑）。
        level = .screenSaver
        setFrame(screen.frame, display: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        // NSPanel 默认 App 失活即隐藏 —— 本 App 全程不激活，不关掉这个标签根本显示不出来。
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = navView
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func updateInput(_ input: String) { navView.updateInput(input) }
}
