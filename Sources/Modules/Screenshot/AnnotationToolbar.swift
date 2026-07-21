import AppKit

@MainActor
protocol AnnotationToolbarDelegate: AnyObject {
    func toolbarDidSelectTool(_ tool: AnnotationTool)
    func toolbarDidChangeStyle(_ style: AnnotationStyle)
    func toolbarUndo()
    func toolbarRedo()
    func toolbarCancel()
    func toolbarPin()
    func toolbarSave()
    func toolbarCopy()
}

/// App 未激活时第一击即生效的无边框按钮（工具条挂在截图 overlay 上，不能要求二次点击）。
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 截图标注工具条：挂在 overlay 窗口下方的子窗口。
///
/// 之所以做成独立子窗口而不是 overlay 的子视图：overlay 视图拦截全部 mouseDown 用于
/// 框选/调整，子视图按钮的点击会被它吞掉（这正是旧版"提示条点不动"的根源）；
/// 子窗口的事件由 AppKit 按窗口直接分发，与 overlay 的手势互不干扰。
@MainActor
final class AnnotationToolbar: NSObject {

    let panel: NSPanel
    weak var delegate: AnnotationToolbarDelegate?

    private(set) var style = AnnotationStyle()
    private(set) var selectedTool: AnnotationTool?

    private var toolButtons: [FirstMouseButton] = []
    private var toolForButton: [ObjectIdentifier: AnnotationTool] = [:]
    private var undoButton: FirstMouseButton!
    private var redoButton: FirstMouseButton!
    private var sizeButtons: [FirstMouseButton] = []
    private var colorButtons: [FirstMouseButton] = []
    private var paramsRow: NSStackView!
    private var rootStack: NSStackView!

    private let accent = NSColor(srgbRed: 0x2B / 255.0, green: 0xC4 / 255.0, blue: 0xB8 / 255.0, alpha: 1)
    private let idleTint = NSColor(white: 0.92, alpha: 1)

    /// 线宽三档；text 工具下映射为字号三档。
    private let widthSteps: [CGFloat] = [2, 3, 5]
    private let fontSteps: [CGFloat] = [14, 18, 24]
    private var sizeStepIndex = 1

    private let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .black, .white
    ]
    private var colorIndex = 0

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        super.init()
        buildContent()
    }

    // MARK: - 构建

    private func buildContent() {
        let toolsRow = NSStackView()
        toolsRow.orientation = .horizontal
        toolsRow.spacing = 2

        let toolDefs: [(AnnotationTool, String, String)] = [
            (.rect, "rectangle", L("annotation.tool.rect")),
            (.ellipse, "circle", L("annotation.tool.ellipse")),
            (.arrow, "arrow.up.right", L("annotation.tool.arrow")),
            (.pen, "pencil", L("annotation.tool.pen")),
            (.highlighter, "highlighter", L("annotation.tool.highlighter")),
            (.mosaic, "checkerboard.rectangle", L("annotation.tool.mosaic")),
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
        undoButton = makeIconButton(symbol: "arrow.uturn.backward", tip: L("annotation.undo"),
                                    action: #selector(undoTapped))
        redoButton = makeIconButton(symbol: "arrow.uturn.forward", tip: L("annotation.redo"),
                                    action: #selector(redoTapped))
        undoButton.isEnabled = false
        redoButton.isEnabled = false
        toolsRow.addArrangedSubview(undoButton)
        toolsRow.addArrangedSubview(redoButton)

        toolsRow.addArrangedSubview(separator())
        toolsRow.addArrangedSubview(makeIconButton(symbol: "xmark", tip: L("annotation.cancel"),
                                                   action: #selector(cancelTapped)))
        toolsRow.addArrangedSubview(makeIconButton(symbol: "pin", tip: L("annotation.pin"),
                                                   action: #selector(pinTapped)))
        toolsRow.addArrangedSubview(makeIconButton(symbol: "square.and.arrow.down", tip: L("annotation.save"),
                                                   action: #selector(saveTapped)))
        toolsRow.addArrangedSubview(makeIconButton(symbol: "doc.on.doc", tip: L("annotation.copy"),
                                                   action: #selector(copyTapped)))

        paramsRow = NSStackView()
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
            let button = FirstMouseButton()
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
        paramsRow.isHidden = true

        rootStack = NSStackView(views: [toolsRow, paramsRow])
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
        refreshSelectionVisuals()
        sizeToFit()
    }

    private func makeIconButton(symbol: String, tip: String, action: Selector,
                                pointSize: CGFloat = 13) -> FirstMouseButton {
        let button = FirstMouseButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
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

    // MARK: - 展示 / 定位

    func show(attachedTo parent: NSWindow) {
        guard panel.parent == nil else { return }
        parent.addChildWindow(panel, ordered: .above)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func setHidden(_ hidden: Bool) {
        panel.alphaValue = hidden ? 0 : 1
        panel.ignoresMouseEvents = hidden
    }

    /// 依据选区（AK 全局坐标）放置：优先选区下方右对齐，放不下翻上方，再放不下收进选区内部。
    func position(near selectionAK: NSRect, on screen: NSScreen) {
        sizeToFit()
        let size = panel.frame.size
        let gap: CGFloat = 8
        let margin: CGFloat = 8
        let screenFrame = screen.frame

        var x = selectionAK.maxX - size.width
        x = min(max(x, screenFrame.minX + margin), screenFrame.maxX - margin - size.width)

        var y = selectionAK.minY - gap - size.height
        if y < screenFrame.minY + margin {
            y = selectionAK.maxY + gap
            if y + size.height > screenFrame.maxY - margin {
                y = max(selectionAK.minY + margin, screenFrame.minY + margin)
            }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func sizeToFit() {
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        panel.setContentSize(size)
    }

    // MARK: - 状态同步

    func setUndoEnabled(_ undo: Bool, redo: Bool) {
        undoButton.isEnabled = undo
        redoButton.isEnabled = redo
    }

    private func refreshSelectionVisuals() {
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
        delegate?.toolbarDidChangeStyle(style)
    }

    // MARK: - 动作

    @objc private func toolTapped(_ sender: NSButton) {
        guard let tool = toolForButton[ObjectIdentifier(sender)] else { return }
        selectedTool = tool
        paramsRow.isHidden = !tool.wantsStyleRow
        refreshSelectionVisuals()
        pushStyle()
        delegate?.toolbarDidSelectTool(tool)
    }

    @objc private func sizeTapped(_ sender: NSButton) {
        sizeStepIndex = sender.tag
        refreshSelectionVisuals()
        pushStyle()
    }

    @objc private func colorTapped(_ sender: NSButton) {
        colorIndex = sender.tag
        refreshSelectionVisuals()
        pushStyle()
    }

    @objc private func undoTapped() { delegate?.toolbarUndo() }
    @objc private func redoTapped() { delegate?.toolbarRedo() }
    @objc private func cancelTapped() { delegate?.toolbarCancel() }
    @objc private func pinTapped() { delegate?.toolbarPin() }
    @objc private func saveTapped() { delegate?.toolbarSave() }
    @objc private func copyTapped() { delegate?.toolbarCopy() }
}
