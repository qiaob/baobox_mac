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

    // MARK: - 尺寸记忆

    /// 出厂尺寸即最小尺寸；用户拉大后的尺寸跨启动记住。
    static let minSize = NSSize(width: 660, height: 420)
    private static let sizeKey = "clipboard.panelSize"

    private static func restoredSize() -> NSSize {
        guard let dict = UserDefaults.standard.dictionary(forKey: sizeKey),
              let width = dict["w"] as? Double, let height = dict["h"] as? Double else { return minSize }
        return NSSize(width: max(width, minSize.width), height: max(height, minSize.height))
    }

    private static func saveSize(_ size: NSSize) {
        UserDefaults.standard.set(["w": size.width, "h": size.height], forKey: sizeKey)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        // 必须在面板抢焦点之前记录，否则拿到的就是 Baobox 自己。
        previousApp = NSWorkspace.shared.frontmostApplication
        store.pruneExpired()
        viewModel.resetForShow()

        let content = ClipboardPanelView(
            viewModel: viewModel,
            store: store,
            onPaste: { [weak self] item, plain in self?.paste(item, plainText: plain) },
            onTogglePin: { [weak self] item in self?.store.togglePin(item.id) },
            onDelete: { [weak self] item in self?.delete(item) },
            onClose: { [weak self] in self?.hide() },
            onCopyText: { [weak self] text in self?.copyOnly(text) },
            onPreviewImage: { [weak self] item in self?.previewImage(item) },
            onEditSnippet: { [weak self] item in self?.editSnippet(item) }
        )
        let hosting = NSHostingView(rootView: content)

        // .resizable 让无边框窗口的边缘出现不可见的拖拽区（光标会变），
        // 这是「大 JSON 看不下」的解法：拉大一次，尺寸记住。
        let panel = ClipboardPanel(
            contentRect: NSRect(origin: .zero, size: Self.restoredSize()),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentMinSize = Self.minSize
        panel.contentView = hosting

        // 居中于鼠标所在屏；记忆尺寸超过当前屏可视区时压回去（换了小屏的情况）。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            var frame = panel.frame
            frame.size.width = min(frame.size.width, visible.width)
            frame.size.height = min(frame.size.height, visible.height)
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
            panel.setFrame(frame, display: false)
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        ClipboardPanelController.current = self
        installMonitors()
    }

    func hide() {
        removeMonitors()
        if let size = panel?.frame.size { Self.saveSize(size) }
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
        case 0x7B: // ← 切换类型筛选。搜索框有内容时不拦 —— 留给光标移动。
            guard viewModel.query.isEmpty else { return false }
            viewModel.cycleFilter(-1)
            return true
        case 0x7C: // → 同上
            guard viewModel.query.isEmpty else { return false }
            viewModel.cycleFilter(1)
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
        case 0x33 where event.modifierFlags.contains(.command): // ⌘⌫ 删除选中条目
            // 用 ⌘⌫ 而非裸 ⌫：搜索框始终持有焦点，裸 ⌫ 要留给它删字。
            if let item = viewModel.selectedItem {
                delete(item)
            }
            return true
        case 0x30: // Tab 切换预览区最大化
            viewModel.isPreviewMaximized.toggle()
            return true
        case 0x35: // Esc：最大化时先收起（渐进撤销），否则才关面板
            if viewModel.isPreviewMaximized {
                viewModel.isPreviewMaximized = false
            } else {
                hide()
            }
            return true
        // 复制整个预览内容用 ⌘⇧C 而不是 ⌘C —— 主菜单的「编辑」里 ⌘C 绑的是
        // NSText.copy(_:)，劫持它会让搜索框和预览区（textSelection 开着）里
        // 选中一段文字后的复制失效。
        case 0x08 where event.modifierFlags.contains([.command, .shift]):
            copyOnly(viewModel.previewText)
            return true
        case 0x1D where event.modifierFlags.contains(.command): // ⌘0 还原转换
            viewModel.transformed = nil
            return true
        default:
            // ⌘1…⌘9 触发动作栏第 n 个动作（下拉展开后的顺序，容器不占号）
            if event.modifierFlags.contains(.command),
               let slot = Self.actionKeyCodes.firstIndex(of: event.keyCode) {
                let actions = viewModel.keyboardActions
                if actions.indices.contains(slot) { viewModel.run(actions[slot]) }
                return true
            }
            return false
        }
    }

    /// ⌘1…⌘9 的 keyCode。注意 5 和 6 是反直觉的 0x17 / 0x16。
    private static let actionKeyCodes: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]

    private func paste(_ item: ClipboardItem, plainText: Bool) {
        PasteService.paste(item, plainText: plainText,
                           overrideText: viewModel.pasteOverride,
                           store: store, monitor: monitor)
    }

    /// 只写剪贴板，不粘贴、不关面板（⌘C 与表格行的复制按钮）。
    ///
    /// `ignoreNextChange` 不能省：不抑制的话，格式化一次 JSON 就会被监听器当成
    /// 一次新的复制记进历史 —— 这正是「转换不污染历史」的实现。
    private func copyOnly(_ text: String) {
        guard !text.isEmpty else { return }
        monitor.ignoreNextChange = true
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func delete(_ item: ClipboardItem) {
        store.delete(item.id)
        viewModel.clampSelection()
    }

    /// 收藏条目开片段编辑窗（名称/关键字/内容）。面板 floating 层级会挡住标准窗口，先收面板。
    private func editSnippet(_ item: ClipboardItem) {
        SnippetEditorWindow.open(store: store, id: item.id)
        hide()
    }

    /// 图片条目开独立预览窗看原图。面板是 floating 层级会挡在标准窗口前面，
    /// 与「大窗编辑」同款处理 —— 开窗后收面板。
    private func previewImage(_ item: ClipboardItem) {
        guard let image = ClipboardStore.image(for: item) else { return }
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let data = ClipboardStore.imageData(for: item)
        ImagePreviewWindow.present(
            image: cg,
            title: L("clipboard.preview.open"),
            actions: [
                ImagePreviewWindow.Action(title: L("clipboard.preview.copyImage"),
                                          isDefault: true, closesWindow: true) { [weak self] in
                    // 复制的就是历史里这张图，抑制监听避免同图再记一条。
                    self?.monitor.ignoreNextChange = true
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([image])
                    if let data { pasteboard.setData(data, forType: .png) }
                }
            ])
        hide()
    }
}
