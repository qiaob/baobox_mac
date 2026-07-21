import AppKit
import SwiftUI

/// borderless 非激活面板，必须子类覆写 canBecomeKey。
final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 剪贴板历史浮层面板控制器。
@MainActor
final class ClipboardPanelController: NSObject {
    /// 当前展示中的面板（供 PasteService 关闭）。
    static weak var current: ClipboardPanelController?

    private let store: ClipboardStore
    private let monitor: ClipboardMonitor
    private let viewModel: ClipboardPanelViewModel

    private var panel: ClipboardPanel?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?

    /// 唤起面板时的前台 App —— 也就是粘贴目标。
    ///
    /// 面板拿到键盘焦点后，若不显式切回该 App，`PasteService` 合成的 ⌘V 会打给
    /// Baobox 自己（典型场景：设置窗开着时按 ⌘⇧V），粘贴静默失效且无任何提示。
    private(set) var previousApp: NSRunningApplication?

    init(store: ClipboardStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
        self.viewModel = ClipboardPanelViewModel(store: store)
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        // 必须在面板抢焦点之前记录，否则拿到的就是 Baobox 自己。
        previousApp = NSWorkspace.shared.frontmostApplication
        viewModel.resetForShow()

        let content = ClipboardPanelView(
            viewModel: viewModel,
            store: store,
            onPaste: { [weak self] item, plain in self?.paste(item, plainText: plain) },
            onTogglePin: { [weak self] item in self?.store.togglePin(item.id) },
            onClose: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: content)

        let panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
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

        // 居中于鼠标所在屏
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - 330, y: visible.midY - 210)
            panel.setFrameOrigin(origin)
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        ClipboardPanelController.current = self
        installMonitors()
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        if ClipboardPanelController.current === self {
            ClipboardPanelController.current = nil
        }
    }

    // MARK: - 事件监听

    private func installMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handleKey(event) ? nil : event
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

    /// 返回 true 表示已消费该按键（不再传给搜索框）。
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D: // ↓
            viewModel.moveSelection(1)
            return true
        case 0x7E: // ↑
            viewModel.moveSelection(-1)
            return true
        case 0x24, 0x4C: // Return / Enter
            if let item = viewModel.selectedItem {
                paste(item, plainText: event.modifierFlags.contains(.option))
            }
            return true
        case 0x23 where event.modifierFlags.contains(.command): // ⌘P（P=0x23）
            if let item = viewModel.selectedItem {
                store.togglePin(item.id)
            }
            return true
        case 0x35: // Esc
            hide()
            return true
        default:
            return false
        }
    }

    private func paste(_ item: ClipboardItem, plainText: Bool) {
        PasteService.paste(item, plainText: plainText, store: store, monitor: monitor)
    }
}
