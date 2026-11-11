import AppKit
import SwiftUI

// 快速切换面板的窗口外壳（#109，docs/codex-assistant/DEDUPE.md §4.3）。Claude Code 助手与 Codex 助手的面板共用，
// 交互对齐剪贴板面板（ClipboardPanelController）：非激活 borderless NSPanel + 本地键盘监听；
// 搜索框始终持焦，裸字符留给它输入，所以「复制」类动作用 ⌘ 组合而不用裸字符。

/// borderless 非激活面板，必须子类覆写 canBecomeKey 才能接收键盘输入。
final class QuickSwitchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Spotlight 式面板的窗口外壳：640×420 borderless + nonactivatingPanel、浮动层级、透明、居中于鼠标所在屏略偏上；
/// 本地 keyDown 监听只拦本面板的事件，全局左键监听 = 点面板外收起。内容与按键含义由调用方给。
@MainActor
final class QuickSwitchPanelHost {
    static let size = NSSize(width: 640, height: 420)

    private var panel: QuickSwitchWindow?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var onKey: ((NSEvent) -> Bool)?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 建面板并显示到前面（不激活本 App）。onKey 返回 true = 已消费（不再传给搜索框）；裸字符一律放行给搜索框。
    func show<Content: View>(_ content: Content, onKey: @escaping (NSEvent) -> Bool) {
        let hosting = NSHostingView(rootView: content)

        let panel = QuickSwitchWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting

        // 居中于鼠标所在屏，略高于正中（Spotlight 习惯位）。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - Self.size.width / 2, y: visible.midY - 140)
            panel.setFrameOrigin(origin)
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.onKey = onKey
        installMonitors()
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: 事件监听

    private func installMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.onKey?(event) == true ? nil : event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeMonitors() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localKeyMonitor = nil
        globalClickMonitor = nil
    }
}

extension QuickSwitchKey {
    /// 从 keyDown 事件解码（只看 ⌘）。
    init?(_ event: NSEvent) {
        self.init(keyCode: event.keyCode, command: event.modifierFlags.contains(.command))
    }
}
