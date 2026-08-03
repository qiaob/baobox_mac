import AppKit

/// 文字卡片浮窗（2026-08-02 增补）：把剪贴板条目（或其转换结果）钉在屏幕最上层。
/// 交互对齐贴图 `PinnedImageWindow`：背景任意拖动、双击 / Esc 关闭、
/// 右键菜单（复制内容 / 关闭）、⌥+滚轮调透明度。
@MainActor
final class PinnedTextCard: NSPanel {

    /// 强引用池 —— borderless panel 无人持有会被立刻释放。
    private static var pins: [PinnedTextCard] = []

    static func pin(_ text: String) {
        guard !text.isEmpty else { return }
        let card = PinnedTextCard(text: text)
        pins.append(card)
        card.orderFrontRegardless()
    }

    private let text: String

    private init(text: String) {
        self.text = text
        let size = Self.cardSize(for: text)

        // 鼠标所在屏中央起，逐张级联偏移，避免连钉几张完全叠死。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let offset = CGFloat(Self.pins.count % 8) * 26
        let origin = NSPoint(
            x: min(max(visible.minX, visible.midX - size.width / 2 + offset), visible.maxX - size.width),
            y: min(max(visible.minY, visible.midY - size.height / 2 - offset), visible.maxY - size.height)
        )

        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = CardContentView(text: text, owner: self)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x35 { // Esc
            closePin()
        } else {
            super.keyDown(with: event)
        }
    }

    func closePin() {
        orderOut(nil)
        PinnedTextCard.pins.removeAll { $0 === self }
    }

    func copyText() {
        // 不抑制监听：这是用户显式的「复制」，回到历史顶部是正常剪贴板语义。
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// ⌥+滚轮调透明度（20%–100%），与贴图一致；文字卡片不做缩放。
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else { return }
        alphaValue = min(1, max(0.2, alphaValue + event.scrollingDeltaY * 0.01))
    }

    // MARK: - 尺寸

    /// 超过可视行数的部分截断（完整内容用右键复制拿）——卡片不做内部滚动，
    /// 滚动视图会拦截背景拖拽，「任意拖动」是这个功能的底线。
    static let maxLines = 40

    private static func cardSize(for text: String) -> NSSize {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let maxContent = NSSize(width: 420, height: 560)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maxContent.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        )
        let width = min(maxContent.width, max(140, ceil(bounds.width))) + 28
        let height = min(maxContent.height, max(24, ceil(bounds.height))) + 24
        return NSSize(width: width, height: height)
    }
}

/// 卡片内容视图：毛玻璃底 + 圆角细边框 + 只读文本；处理拖动、双击与右键菜单。
private final class CardContentView: NSVisualEffectView {
    private weak var owner: PinnedTextCard?

    init(text: String, owner: PinnedTextCard) {
        self.owner = owner
        super.init(frame: .zero)
        material = .hudWindow
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor

        // 不可选中的 label：可选中文本会吃掉 mouseDown，卡片就拖不动了。
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .labelColor
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = PinnedTextCard.maxLines
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            owner?.closePin()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L("clipboard.pin.copy")) { [weak self] in self?.owner?.copyText() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("clipboard.pin.close")) { [weak self] in self?.owner?.closePin() })
        return menu
    }
}
