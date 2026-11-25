import AppKit
import SwiftUI

// 快速入口面板的窗口外壳（docs/launcher/TECH_DESIGN.md §4）。窗口同快速切换面板的 `QuickSwitchWindow`
// （borderless + nonactivatingPanel、能成为 key、不激活 Baobox，收起后焦点自然回到原来的 App），
// 另外给输入框配一个不接拖放的字段编辑器（`LauncherWindow`，§5.5）；
// 键盘监听和「点外面收起」照 `QuickSwitchPanelHost` 的两个监听。和它不同的是高度跟内容变：窗口顶边固定、向下长，不做动画。
// 拖放（§5.5）：内容视图接文件、图片、文字的拖放，交给控制器按「贴进来」的规则处理；点别的 App 时按住不放可能是在往这边拖，
// 等松开再决定收不收。每次呼出新建窗口、收起时销毁。

/// 快速入口的窗口：同 `QuickSwitchWindow`（borderless + nonactivatingPanel、能成为 key），另外给输入框一个不接拖放的字段编辑器 ——
/// 系统默认的字段编辑器会接下拖到输入框上的文件、图片（往框里插一段路径或网址），这里要它们落到面板上、按「贴进来」的规则处理。
final class LauncherWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    private lazy var launcherFieldEditor: LauncherFieldEditor = {
        let editor = LauncherFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if object is LauncherTextField { return launcherFieldEditor }
        return super.fieldEditor(createFlag, for: object)
    }
}

/// 输入框的字段编辑器：和系统默认的一样，只是不接任何拖放（拖进来的东西交给面板）。
final class LauncherFieldEditor: NSTextView {
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
}

/// 面板的内容视图：SwiftUI 的承载视图，外加接拖放（文件、图片、文字）。拖进来时显示「可以放」，放下交给 `onDrop`。
final class LauncherHostingView<Content: View>: NSHostingView<Content> {
    /// 接哪些类型的拖放：文件、常见位图、网址、文字。
    static var dropTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .png, .tiff, .string] + LauncherPasteboardReader.preferredImageTypes
    }

    /// 放下了：交给控制器（按「贴进来」的规则）；返回 false = 没接。
    var onDrop: ((NSPasteboard) -> Bool)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes(Self.dropTypes)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}

@MainActor
final class LauncherPanel {
    private var window: LauncherWindow?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var onKey: ((NSEvent) -> Bool)?
    private var onClickOutside: (() -> Void)?
    /// 点了别的 App、还按着没松开：每次收起 / 呼出 +1，作废还在轮询的那次。
    private var pressWatch = 0
    private var watchingPress = false
    /// 窗口顶边（屏幕坐标），高度变化时保持不动。
    private var top: CGFloat = 0

    var isVisible: Bool { window?.isVisible ?? false }

    /// 建窗口并显示到前面（不激活本 App）。显示前先排一次版，让输入框（NSViewRepresentable）在返回前就建好，
    /// 调用方紧接着就能给它焦点 —— 呼出后立刻打的字不会丢。
    /// - Parameters:
    ///   - onKey: 本面板的 keyDown，返回 true = 已处理（不再交给输入框）。
    ///   - onClickOutside: 点了别的 App 的窗口（左键：松开时鼠标不在面板上才算）。
    ///   - onDrop: 有东西拖到面板上放下了（拖进来的那块剪贴板），返回 true = 接了。
    func show<Content: View>(_ content: Content, height: CGFloat,
                             onKey: @escaping (NSEvent) -> Bool, onClickOutside: @escaping () -> Void,
                             onDrop: ((NSPasteboard) -> Bool)? = nil) {
        hide()
        let hosting = LauncherHostingView(rootView: content)
        hosting.onDrop = onDrop
        // 窗口大小由这里定（顶边固定），不让 SwiftUI 的尺寸约束反过来改窗口（同会议控制条、字幕条）。
        hosting.sizingOptions = []

        let frame = Self.initialFrame(height: height)
        top = frame.maxY
        let window = LauncherWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        window.level = .floating
        // 全屏 App 上也能盖住：跟着当前空间走、可以叠在全屏空间里。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 顶边要固定，不让拖背景挪窗口。
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = hosting
        window.setFrame(frame, display: false)
        hosting.layoutSubtreeIfNeeded()

        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.onKey = onKey
        self.onClickOutside = onClickOutside
        installMonitors()
    }

    /// 放下东西后让面板重新拿键盘焦点（在别的 App 里按下鼠标拖过来时，那个 App 的窗口成了 key）。不激活 Baobox。
    func makeKey() {
        window?.makeKey()
    }

    func hide() {
        pressWatch += 1
        watchingPress = false
        removeMonitors()
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        onKey = nil
        onClickOutside = nil
    }

    /// 内容高度变了：顶边不动，向下长 / 往上收。和 SwiftUI 的重绘在同一次刷新里提交，不立即重画。
    func setHeight(_ height: CGFloat) {
        guard let window else { return }
        let frame = NSRect(x: window.frame.minX, y: top - height, width: LauncherLayout.width, height: height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: false)
        // 透明窗口的阴影按内容的形状算：等新内容画好再重算一次。
        DispatchQueue.main.async { [weak window] in
            MainActor.assumeIsolated { window?.invalidateShadow() }
        }
    }

    /// 鼠标所在屏幕的中间偏上：顶边在可见区域从上往下 1/5 处；结果长到最多时底边也要在屏幕里（矮屏往上挪）。
    private static func initialFrame(height: CGFloat) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let width = LauncherLayout.width
        guard let visible = screen?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }
        let margin: CGFloat = 20
        var top = visible.maxY - visible.height * 0.2
        let lowest = visible.minY + margin + LauncherLayout.maxHeight
        if top < lowest { top = min(visible.maxY - margin, lowest) }
        return NSRect(x: visible.midX - width / 2, y: top - height, width: width, height: height)
    }

    // MARK: 事件监听

    private func installMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            return self.onKey?(event) == true ? nil : event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .leftMouseDown {
                    self?.watchOutsidePress()
                } else {
                    self?.onClickOutside?()
                }
            }
        }
    }

    /// 在别的 App 里按下了左键：等松开再决定收不收 —— 按住拖动可能是在把文件、图片拖到面板上来（§5.5）。
    /// 松开时鼠标在面板上（拖进来放下了，或者只是框选时扫过了面板）不收；否则照旧收起。普通的单击只是晚了按住的那一下（零点一秒左右）。
    private func watchOutsidePress() {
        guard !watchingPress else { return }
        watchingPress = true
        pollOutsidePress(pressWatch)
    }

    private func pollOutsidePress(_ token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.pressWatch else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    self.pollOutsidePress(token)
                    return
                }
                self.watchingPress = false
                if let window = self.window, NSMouseInRect(NSEvent.mouseLocation, window.frame, false) { return }
                self.onClickOutside?()
            }
        }
    }

    private func removeMonitors() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localKeyMonitor = nil
        globalClickMonitor = nil
    }
}
