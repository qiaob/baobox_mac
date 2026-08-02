import AppKit

@MainActor
protocol ScreenDrawToolbarDelegate: AnyObject {
    func drawToolbarDidSelect(_ tool: AnnotationTool)
    func drawToolbarDidChangeStyle(_ style: AnnotationStyle)
    func drawToolbarUndo()
    func drawToolbarRedo()
    func drawToolbarClear()
    func drawToolbarTogglePassThrough()
    func drawToolbarExit()
}

/// 非激活面板里的按钮需要第一击就响应。
private final class DrawToolButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

    private let accent = NSColor(srgbRed: 0x2B / 255.0, green: 0xC4 / 255.0, blue: 0xB8 / 255.0, alpha: 1)
    private let idleTint = NSColor(white: 0.92, alpha: 1)

    private let widthSteps: [CGFloat] = [2, 4, 7]
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
        style.color = colors[colorIndex]
    }

    // MARK: - 构建

    private func buildContent() {
        let toolsRow = NSStackView()
        toolsRow.orientation = .horizontal
        toolsRow.spacing = 2

        // 不提供马赛克（没有底图可打码）与文字（输入需要 key 窗口，与「尽量不打扰前台 App」冲突）。
        let toolDefs: [(AnnotationTool, String, String)] = [
            (.pen, "pencil", L("annotation.tool.pen")),
            (.highlighter, "highlighter", L("annotation.tool.highlighter")),
            (.arrow, "arrow.up.right", L("annotation.tool.arrow")),
            (.rect, "rectangle", L("annotation.tool.rect")),
            (.ellipse, "circle", L("annotation.tool.ellipse")),
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
        button.toolTip = tip
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
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// 穿透态下按钮换成"划掉的手"，并染成 accent —— 用户必须一眼看出现在点得动下面。
    func setPassThrough(_ on: Bool) {
        let tip = on ? L("screendraw.toolbar.resumeDrawing") : L("screendraw.toolbar.passThrough")
        passThroughButton.image = NSImage(systemSymbolName: on ? "hand.raised.slash" : "hand.raised",
                                          accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        passThroughButton.toolTip = tip
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
    @objc private func passThroughTapped() { delegate?.drawToolbarTogglePassThrough() }
    @objc private func exitTapped() { delegate?.drawToolbarExit() }
}
