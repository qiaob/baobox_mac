import AppKit

/// Baobox 主菜单最上面那一行：隐藏的图标，一道细竖线后是此刻被挤掉的（docs/menubar-manager/REQUIREMENTS.md §3.1，
/// 位置是用户截图里框出来的「截图」上面那一行）。点一下 = 点了菜单栏上的它。
@MainActor
enum MenuBarIconRow {
    static func menuItems(hidden: [MenuBarItem], squeezed: [MenuBarItem], images: [String: CGImage]) -> [NSMenuItem] {
        guard !hidden.isEmpty || !squeezed.isEmpty else { return [] }
        let item = NSMenuItem()
        item.view = MenuBarIconRowView(hidden: hidden, squeezed: squeezed, images: images)
        return [item]
    }

    /// 图标画在一块小圆角底上：菜单栏图标按菜单栏的明暗画（深色菜单栏上是白的），菜单本身可能是浅色 ——
    /// 白图标配深底、黑图标配浅底，哪种外观都看得清。没抓到过图像（一直没露过面）时用 App 图标。
    static func chipImage(_ image: CGImage?, pid: pid_t, size: NSSize) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let light = image.map(isLight) ?? true
        let appIcon = image == nil ? NSRunningApplication(processIdentifier: pid)?.icon : nil
        return NSImage(size: size, flipped: false) { rect in
            if let image {
                let chip = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                (light ? NSColor(white: 0.14, alpha: 0.92) : NSColor(white: 0.93, alpha: 0.92)).setFill()
                chip.fill()
                var width = CGFloat(image.width) / scale
                var height = CGFloat(image.height) / scale
                let fit = min(1, (rect.width - 6) / max(width, 1), (rect.height - 6) / max(height, 1))
                width *= fit
                height *= fit
                let target = NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
                NSGraphicsContext.current?.cgContext.draw(image, in: target)
            } else if let appIcon {
                let side = rect.height - 2
                appIcon.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
            }
            return true
        }
    }

    /// 不透明像素的平均亮度 > 0.5 算浅色图标（缩到 16×16 算，够用）。
    private static func isLight(_ image: CGImage) -> Bool {
        let side = 16
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return true }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var sum = 0.0
        var weight = 0.0
        for i in 0..<(side * side) {
            let alpha = Double(pixels[i * 4 + 3]) / 255
            guard alpha > 0.3 else { continue }
            // 预乘过 alpha：亮度先除回去。
            let r = Double(pixels[i * 4]) / 255 / alpha
            let g = Double(pixels[i * 4 + 1]) / 255 / alpha
            let b = Double(pixels[i * 4 + 2]) / 255 / alpha
            sum += (0.299 * r + 0.587 * g + 0.114 * b) * alpha
            weight += alpha
        }
        return weight == 0 || sum / weight > 0.5
    }
}

/// 图标行的视图：从左到右排，放不下就换行。
final class MenuBarIconRowView: NSView {
    private static let buttonSize = NSSize(width: 32, height: 26)
    private static let chipSize = NSSize(width: 30, height: 22)
    private static let gap: CGFloat = 4
    private static let separatorWidth: CGFloat = 9
    private static let inset: CGFloat = 12
    private static let width: CGFloat = 268

    private enum Entry {
        case icon(MenuBarItem, squeezed: Bool)
        case separator
    }

    override var isFlipped: Bool { true }

    @MainActor
    init(hidden: [MenuBarItem], squeezed: [MenuBarItem], images: [String: CGImage]) {
        var entries: [Entry] = hidden.map { .icon($0, squeezed: false) }
        if !hidden.isEmpty, !squeezed.isEmpty { entries.append(.separator) }
        entries += squeezed.map { .icon($0, squeezed: true) }

        var placements: [(Entry, NSRect)] = []
        var x = Self.inset
        var y: CGFloat = 5
        for entry in entries {
            let width: CGFloat
            if case .separator = entry { width = Self.separatorWidth } else { width = Self.buttonSize.width }
            if x + width > Self.width - Self.inset, x > Self.inset {
                x = Self.inset
                y += Self.buttonSize.height + Self.gap
            }
            placements.append((entry, NSRect(x: x, y: y, width: width, height: Self.buttonSize.height)))
            x += width + Self.gap
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: y + Self.buttonSize.height + 5))

        for (entry, rect) in placements {
            switch entry {
            case .separator:
                let line = NSView(frame: NSRect(x: rect.midX - 0.5, y: rect.minY + 5, width: 1, height: rect.height - 10))
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.separatorColor.cgColor
                addSubview(line)
            case let .icon(item, squeezed):
                let button = MenuBarIconButton(frame: rect)
                button.itemID = item.id
                button.image = MenuBarIconRow.chipImage(images[item.id], pid: item.pid, size: Self.chipSize)
                let name = squeezed ? L("menubar.row.squeezed \(item.displayName)") : item.displayName
                button.toolTip = name
                button.setAccessibilityLabel(name)
                button.target = self
                button.action = #selector(pick(_:))
                addSubview(button)
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// 先收起 Baobox 菜单，再去点那个图标：菜单跟踪期间主线程的任务要等菜单关掉才执行，正好排在后面。
    @objc private func pick(_ sender: MenuBarIconButton) {
        let id = sender.itemID
        enclosingMenuItem?.menu?.cancelTracking()
        Task { @MainActor in
            await MenuBarActions.shared.open(itemID: id)
        }
    }
}

/// 无边框的图标按钮，鼠标移上去有一块浅色底。
final class MenuBarIconButton: NSButton {
    var itemID = ""
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}
