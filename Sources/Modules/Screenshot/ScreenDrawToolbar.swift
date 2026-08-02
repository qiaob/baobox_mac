import AppKit

@MainActor
protocol ScreenDrawToolbarDelegate: AnyObject {
    func drawToolbarDidSelect(_ tool: AnnotationTool)
    func drawToolbarDidChangeStyle(_ style: AnnotationStyle)
    func drawToolbarUndo()
    func drawToolbarRedo()
    func drawToolbarClear()
    func drawToolbarSave()
    func drawToolbarTogglePassThrough()
    func drawToolbarExit()
}

/// 非激活面板里的按钮需要第一击就响应；悬停回调给自绘 tooltip 用
/// （系统 tooltip 窗口层级低于 .screenSaver 的工具条，会被面板自己挡住）。
private final class DrawToolButton: NSButton {
    var onHover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// 屏幕标注的工具条：独立浮窗，工具 + 撤销/重做/清空 + 穿透 + 退出，外加颜色与粗细。
///
/// 没有复用截图的 `AnnotationToolbar`：那条工具条的动作是「取消 / 贴图 / 保存 / 复制」，
/// 与屏幕标注的「清空 / 穿透 / 退出」完全不是一组；硬塞成一个可配置工具条会把两边都拖累。
/// 真正该共用的是绘制引擎（`AnnotationRenderer`），那部分已经共用了。
@MainActor
final class ScreenDrawToolbar: NSObject {

    let panel: NSPanel
    weak var delegate: ScreenDrawToolbarDelegate?

    private(set) var style = AnnotationStyle()
    private(set) var selectedTool: AnnotationTool = .pen

    private var toolButtons: [DrawToolButton] = []
    private var toolForButton: [ObjectIdentifier: AnnotationTool] = [:]
    private var sizeButtons: [DrawToolButton] = []
    private var colorButtons: [DrawToolButton] = []
    private var passThroughButton: DrawToolButton!

    private var statusPanel: NSPanel?
    private var statusLabel: NSTextField?
    private var statusHideWork: DispatchWorkItem?
    private var tipPanel: NSPanel?
    private var tipLabel: NSTextField?
    /// 按钮 → tooltip 文案。悬停那一刻查表，穿透按钮的文案切换即时生效。
    private var tipForButton: [ObjectIdentifier: String] = [:]

    private let accent = NSColor(srgbRed: 0x2B / 255.0, green: 0xC4 / 255.0, blue: 0xB8 / 255.0, alpha: 1)
    private let idleTint = NSColor(white: 0.92, alpha: 1)

    private let widthSteps: [CGFloat] = [2, 4, 7]
    /// 同一排尺寸按钮：画笔类工具是线宽，文字工具是字号。
    private let fontSteps: [CGFloat] = [14, 18, 24]
    private var sizeStepIndex = 1

    private let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .black, .white
    ]
    private var colorIndex = 0

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // 必须与画布同级（.screenSaver）并作为画布的子窗口：`.popUpMenu`(101) 低于
        // `.screenSaver`(1000)，工具条会被自己的画布整个盖住、点击也落到画布上画出一笔。
        // 同级 + 子窗口关系才能保证它稳定压在画布之上（截图工具条同样的做法）。
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init()
        buildContent()
        style.lineWidth = widthSteps[sizeStepIndex]
        style.fontSize = fontSteps[sizeStepIndex]
        style.color = colors[colorIndex]
    }

    // MARK: - 构建

    private func buildContent() {
        let toolsRow = NSStackView()
        toolsRow.orientation = .horizontal
        toolsRow.spacing = 2

        // 不提供马赛克（没有底图可打码）。文字只在绘制态可用 —— 绘制态本来就持有键盘焦点。
        let toolDefs: [(AnnotationTool, String, String)] = [
            (.pen, "pencil", L("annotation.tool.pen")),
            (.highlighter, "highlighter", L("annotation.tool.highlighter")),
            (.arrow, "arrow.up.right", L("annotation.tool.arrow")),
            (.rect, "rectangle", L("annotation.tool.rect")),
            (.ellipse, "circle", L("annotation.tool.ellipse")),
            (.text, "textformat", L("annotation.tool.text")),
            (.eraser, "eraser", L("annotation.tool.eraser"))
        ]
        for (tool, symbol, tip) in toolDefs {
            let button = makeIconButton(symbol: symbol, tip: tip, action: #selector(toolTapped(_:)))
            toolForButton[ObjectIdentifier(button)] = tool
            toolButtons.append(button)
            toolsRow.addArrangedSubview(button)
        }

        toolsRow.addArrangedSubview(separator())
        toolsRow.addArrangedSubview(makeIconButton(symbol: "arrow.uturn.backward",
                                                   tip: L("annotation.undo"),
                                                   action: #selector(undoTapped)))
        toolsRow.addArrangedSubview(makeIconButton(symbol: "arrow.uturn.forward",
                                                   tip: L("annotation.redo"),
                                                   action: #selector(redoTapped)))
        toolsRow.addArrangedSubview(makeIconButton(symbol: "trash",
                                                   tip: L("screendraw.toolbar.clear"),
                                                   action: #selector(clearTapped)))

        toolsRow.addArrangedSubview(separator())
        toolsRow.addArrangedSubview(makeIconButton(symbol: "square.and.arrow.down",
                                                   tip: L("screendraw.toolbar.save"),
                                                   action: #selector(saveTapped)))
        passThroughButton = makeIconButton(symbol: "hand.raised",
                                           tip: L("screendraw.toolbar.passThrough"),
                                           action: #selector(passThroughTapped))
        toolsRow.addArrangedSubview(passThroughButton)
        toolsRow.addArrangedSubview(makeIconButton(symbol: "xmark",
                                                   tip: L("screendraw.toolbar.exit"),
                                                   action: #selector(exitTapped)))

        let paramsRow = NSStackView()
        paramsRow.orientation = .horizontal
        paramsRow.spacing = 5
        for (index, point) in [4.5, 6.5, 9].enumerated() {
            let button = makeIconButton(symbol: "circle.fill", tip: L("annotation.sizeTip"),
                                        action: #selector(sizeTapped(_:)), pointSize: CGFloat(point))
            button.tag = index
            sizeButtons.append(button)
            paramsRow.addArrangedSubview(button)
        }
        paramsRow.addArrangedSubview(separator())
        for (index, color) in colors.enumerated() {
            let button = DrawToolButton()
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(colorTapped(_:))
            button.tag = index
            button.image = swatchImage(color, selected: index == colorIndex)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            colorButtons.append(button)
            paramsRow.addArrangedSubview(button)
        }

        let rootStack = NSStackView(views: [toolsRow, paramsRow])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 4
        rootStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.96).cgColor
        background.layer?.cornerRadius = 9
        background.translatesAutoresizingMaskIntoConstraints = false
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: background.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        panel.contentView = background
        refreshVisuals()
        sizeToFit()
    }

    private func makeIconButton(symbol: String, tip: String, action: Selector,
                                pointSize: CGFloat = 13) -> DrawToolButton {
        let button = DrawToolButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.title = ""
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        button.contentTintColor = idleTint
        // 不设系统 toolTip：其窗口层级低于 .screenSaver 的工具条，会被面板自己挡住 —— 自绘。
        tipForButton[ObjectIdentifier(button)] = tip
        button.onHover = { [weak self, weak button] inside in
            guard let self, let button else { return }
            if inside, let text = self.tipForButton[ObjectIdentifier(button)] {
                self.showTip(text, for: button)
            } else {
                self.hideTip()
            }
        }
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return line
    }

    private func swatchImage(_ color: NSColor, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            color.setFill()
            circle.fill()
            NSColor(white: 1, alpha: 0.35).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            if selected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1.5
                NSColor.white.setStroke()
                ring.stroke()
            }
            return true
        }
    }

    private func sizeToFit() {
        guard let content = panel.contentView else { return }
        panel.setContentSize(content.fittingSize)
    }

    // MARK: - 展示

    /// 摆在屏幕底部居中偏上（避开 Dock），可拖动。
    /// `parent` 为该屏的画布窗口 —— 挂成子窗口才能稳定压在画布之上。
    func show(on screen: NSScreen, attachedTo parent: NSWindow) {
        sizeToFit()
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + 28)
        panel.setFrameOrigin(origin)
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
    }

    func close() {
        statusHideWork?.cancel()
        for bubble in [statusPanel, tipPanel].compactMap({ $0 }) {
            panel.removeChildWindow(bubble)
            bubble.orderOut(nil)
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: - 浮条（状态提示 + 自绘 tooltip 共用底座）

    /// 无边框小气泡：深底圆角 + 居中一行字，鼠标穿透。层级与工具条一致（.screenSaver），
    /// 挂成工具条子窗口后永远压在面板之上 —— 系统 tooltip 做不到这点。
    private func makeBubblePanel() -> (NSPanel, NSTextField) {
        let bubble = NSPanel(contentRect: .zero,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        bubble.level = .screenSaver
        bubble.backgroundColor = .clear
        bubble.isOpaque = false
        bubble.hasShadow = true
        bubble.hidesOnDeactivate = false
        bubble.ignoresMouseEvents = true
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.96).cgColor
        background.layer?.cornerRadius = 7

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11.5)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        bubble.contentView = background
        return (bubble, label)
    }

    /// 填文案、按内容定宽、摆到指定原点并作为工具条子窗口浮出。
    private func present(_ bubble: NSPanel, label: NSTextField, text: String,
                         color: NSColor, originFor: (NSSize) -> NSPoint) {
        label.stringValue = text
        label.textColor = color
        let textWidth = (text as NSString).size(withAttributes: [.font: label.font ?? .systemFont(ofSize: 11.5)]).width
        let size = NSSize(width: min(max(textWidth + 22, 60), 420), height: 26)
        bubble.setContentSize(size)
        bubble.setFrameOrigin(originFor(size))
        if bubble.parent == nil {
            panel.addChildWindow(bubble, ordered: .above)
        }
        bubble.orderFrontRegardless()
    }

    /// 在工具条正下方浮一条短暂提示（保存成功/失败）。
    /// 不用 NSAlert：画布吃掉全屏点击，模态弹窗点不到；演示场景里弹窗也太打断 ——
    /// 小浮条提示完自己消失。工具条可拖动，位置按显示那一刻的工具条位置算。
    func showStatus(_ text: String, isError: Bool = false) {
        statusHideWork?.cancel()
        if statusPanel == nil {
            let (bubble, label) = makeBubblePanel()
            statusPanel = bubble
            statusLabel = label
        }
        guard let statusPanel, let statusLabel else { return }
        let anchor = panel.frame
        present(statusPanel, label: statusLabel, text: text,
                color: isError ? .systemOrange : idleTint) { size in
            NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.statusPanel?.orderOut(nil)
            }
        }
        statusHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 4 : 1.8), execute: work)
    }

    /// 自绘 tooltip：悬停按钮时浮在工具条**上方**（与下方的状态提示错开），对准按钮居中。
    private func showTip(_ text: String, for button: NSView) {
        if tipPanel == nil {
            let (bubble, label) = makeBubblePanel()
            tipPanel = bubble
            tipLabel = label
        }
        guard let tipPanel, let tipLabel, let window = button.window else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let top = panel.frame.maxY
        present(tipPanel, label: tipLabel, text: text, color: idleTint) { size in
            NSPoint(x: buttonRect.midX - size.width / 2, y: top + 6)
        }
    }

    private func hideTip() {
        tipPanel?.orderOut(nil)
    }

    /// 穿透态下按钮换成"划掉的手"，并染成 accent —— 用户必须一眼看出现在点得动下面。
    func setPassThrough(_ on: Bool) {
        let tip = on ? L("screendraw.toolbar.resumeDrawing") : L("screendraw.toolbar.passThrough")
        passThroughButton.image = NSImage(systemSymbolName: on ? "hand.raised.slash" : "hand.raised",
                                          accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        tipForButton[ObjectIdentifier(passThroughButton)] = tip
        passThroughButton.contentTintColor = on ? accent : idleTint
    }

    // MARK: - 状态

    private func refreshVisuals() {
        for button in toolButtons {
            let tool = toolForButton[ObjectIdentifier(button)]
            button.contentTintColor = (tool == selectedTool) ? accent : idleTint
        }
        for (index, button) in sizeButtons.enumerated() {
            button.contentTintColor = (index == sizeStepIndex) ? accent : NSColor(white: 0.75, alpha: 1)
        }
        for (index, button) in colorButtons.enumerated() {
            button.image = swatchImage(colors[index], selected: index == colorIndex)
        }
    }

    private func pushStyle() {
        style.lineWidth = widthSteps[sizeStepIndex]
        style.fontSize = fontSteps[sizeStepIndex]
        style.color = colors[colorIndex]
        delegate?.drawToolbarDidChangeStyle(style)
    }

    // MARK: - 动作

    @objc private func toolTapped(_ sender: NSButton) {
        guard let tool = toolForButton[ObjectIdentifier(sender)] else { return }
        selectedTool = tool
        refreshVisuals()
        delegate?.drawToolbarDidSelect(tool)
    }

    @objc private func sizeTapped(_ sender: NSButton) {
        sizeStepIndex = sender.tag
        refreshVisuals()
        pushStyle()
    }

    @objc private func colorTapped(_ sender: NSButton) {
        colorIndex = sender.tag
        refreshVisuals()
        pushStyle()
    }

    @objc private func undoTapped() { delegate?.drawToolbarUndo() }
    @objc private func redoTapped() { delegate?.drawToolbarRedo() }
    @objc private func clearTapped() { delegate?.drawToolbarClear() }
    @objc private func saveTapped() { delegate?.drawToolbarSave() }
    @objc private func passThroughTapped() { delegate?.drawToolbarTogglePassThrough() }
    @objc private func exitTapped() { delegate?.drawToolbarExit() }
}
