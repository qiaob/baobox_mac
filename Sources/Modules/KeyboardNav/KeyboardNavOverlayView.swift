import AppKit

/// 键盘点击标签层：hint 态画字母标签，滚动态画选中区边框 + 按键提示。
/// 透明、非翻转（AppKit 左下原点）。纯展示 —— 键盘输入由
/// `KeyboardNavController` 的 CGEventTap 捕获，不经过本视图。
@MainActor
final class KeyboardNavOverlayView: NSView {
    enum Content {
        case hints([HintTarget])
        /// 滚动态：圈出选中的滚动区（view 本地 AppKit 坐标）。
        case scrollFrame(NSRect)
    }

    private let content: Content
    private var input = ""

    init(content: Content) {
        self.content = content
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    func updateInput(_ s: String) { input = s; needsDisplay = true }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current != nil else { return }
        let accent = NSColor(calibratedRed: 0.09, green: 0.64, blue: 0.60, alpha: 1) // ≈ #17A398
        switch content {
        case .hints(let targets):
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            for t in targets {
                if !input.isEmpty && !t.label.hasPrefix(input) { continue } // 隐藏不匹配
                drawBadge(t.label, at: t.rectAK, accent: accent, font: font)
            }
        case .scrollFrame(let rect):
            drawScrollFrame(rect, accent: accent)
        }
    }

    /// 滚动态：accent 边框圈住滚动区，框内底部一条按键提示 pill。
    private func drawScrollFrame(_ rect: NSRect, accent: NSColor) {
        let path = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        accent.withAlphaComponent(0.95).setStroke()
        path.stroke()

        let text = L("keyboardnav.scroll.keysHint")
        let font = NSFont.systemFont(ofSize: 12)
        let attrs: [NSAttributedString.Key: Any] = [.font: font,
                                                    .foregroundColor: NSColor(white: 0.92, alpha: 1)]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let padX: CGFloat = 14, padY: CGFloat = 6
        let w = size.width + padX * 2
        let h = size.height + padY * 2
        var x = rect.midX - w / 2
        var y = rect.minY + 16
        x = max(4, min(x, bounds.width - w - 4))
        y = max(4, min(y, bounds.height - h - 4))
        let bg = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                              xRadius: h / 2, yRadius: h / 2)
        NSColor(white: 0.13, alpha: 0.92).setFill()
        bg.fill()
        str.draw(at: NSPoint(x: x + padX, y: y + padY))
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
}
