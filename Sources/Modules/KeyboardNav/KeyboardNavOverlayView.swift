import AppKit

/// 键盘点击标签层：画每个可点击元素的字母标签，捕获键盘输入。透明、非翻转（AppKit 左下原点）。
@MainActor
final class KeyboardNavOverlayView: NSView {
    private let targets: [HintTarget]
    private weak var controller: KeyboardNavController?
    private var input = ""

    init(targets: [HintTarget], controller: KeyboardNavController) {
        self.targets = targets
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func updateInput(_ s: String) { input = s; needsDisplay = true }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current != nil else { return }
        let accent = NSColor(calibratedRed: 0.09, green: 0.64, blue: 0.60, alpha: 1) // ≈ #17A398
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        for t in targets {
            if !input.isEmpty && !t.label.hasPrefix(input) { continue } // 隐藏不匹配
            drawBadge(t.label, at: t.rectAK, accent: accent, font: font)
        }
    }

    private func drawBadge(_ label: String, at rect: NSRect, accent: NSColor, font: NSFont) {
        let text = label.uppercased()
        let padX: CGFloat = 4, padY: CGFloat = 2
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let badgeW = textSize.width + padX * 2
        let badgeH = textSize.height + padY * 2
        // 放元素左上角（AppKit 里"上"= maxY），并夹进屏内。
        var bx = rect.minX
        var by = rect.maxY - badgeH
        bx = max(0, min(bx, bounds.width - badgeW))
        by = max(0, min(by, bounds.height - badgeH))
        let badge = NSRect(x: bx, y: by, width: badgeW, height: badgeH)

        let path = NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4)
        accent.setFill()
        path.fill()

        // 已输入的前缀淡化，剩余白色高亮。
        let full = NSMutableAttributedString(string: text, attributes: attrs)
        let matchedLen = min(input.count, text.count)
        if matchedLen > 0 {
            full.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.4),
                              range: NSRange(location: 0, length: matchedLen))
        }
        full.draw(at: NSPoint(x: badge.minX + padX, y: badge.minY + padY))
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 0x35: // Esc
            controller?.cancel()
        case 0x33: // Delete
            controller?.backspace()
        default:
            if let ch = event.charactersIgnoringModifiers?.first, ch.isLetter {
                controller?.appendInput(String(ch).lowercased())
            }
        }
    }
}
