import AppKit
import SwiftUI

// 快速入口面板的窗口外壳（docs/launcher/TECH_DESIGN.md §4）。窗口类直接用快速切换面板的 `QuickSwitchWindow`
// （borderless + nonactivatingPanel、能成为 key、不激活 Baobox，收起后焦点自然回到原来的 App）；
// 键盘监听和「点外面收起」照 `QuickSwitchPanelHost` 的两个监听。和它不同的是高度跟内容变：窗口顶边固定、向下长，不做动画。
// 每次呼出新建窗口、收起时销毁。

@MainActor
final class LauncherPanel {
    private var window: QuickSwitchWindow?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var onKey: ((NSEvent) -> Bool)?
    private var onClickOutside: (() -> Void)?
    /// 窗口顶边（屏幕坐标），高度变化时保持不动。
    private var top: CGFloat = 0

    var isVisible: Bool { window?.isVisible ?? false }

    /// 建窗口并显示到前面（不激活本 App）。显示前先排一次版，让输入框（NSViewRepresentable）在返回前就建好，
    /// 调用方紧接着就能给它焦点 —— 呼出后立刻打的字不会丢。
    /// - Parameters:
    ///   - onKey: 本面板的 keyDown，返回 true = 已处理（不再交给输入框）。
    ///   - onClickOutside: 点了别的 App 的窗口。
    func show<Content: View>(_ content: Content, height: CGFloat,
                             onKey: @escaping (NSEvent) -> Bool, onClickOutside: @escaping () -> Void) {
        hide()
        let hosting = NSHostingView(rootView: content)
        // 窗口大小由这里定（顶边固定），不让 SwiftUI 的尺寸约束反过来改窗口（同会议控制条、字幕条）。
        hosting.sizingOptions = []

        let frame = Self.initialFrame(height: height)
        top = frame.maxY
        let window = QuickSwitchWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
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

    func hide() {
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
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClickOutside?() }
        }
    }

    private func removeMonitors() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localKeyMonitor = nil
        globalClickMonitor = nil
    }
}
