import AppKit

/// 菜单栏实时网速（docs/netcheck/SPEED.md §2.2）：紧挨 Baobox 主图标的一个状态项，文字照 `↓1.2M/s`，每秒一变。
///
/// **宽度跟着文字走**：文字画进一张模板图（右对齐、等宽数字），变宽立刻跟上，变窄要等 10 秒（`NetSpeedWidthHold`），
/// 平时不留空白，数字每秒跳也不会每秒伸缩。模板图跟着菜单栏明暗自动着色。
/// 开关关着时状态项和采样定时器都不存在。点它出一个只读内存的小菜单。
@MainActor
final class NetSpeedStatusItem: NSObject, NSMenuDelegate {
    static let shared = NetSpeedStatusItem()

    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var mode: NetSpeedDisplayMode = .down
    private var shownText: String?
    private var shownWidth: CGFloat = 0
    private var widthHold = NetSpeedWidthHold()

    private override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = true
    }

    // MARK: - 开关

    /// 按设置把状态项和采样器打开或关掉：打开后立刻出现，关掉后立刻消失、定时器停掉。
    func apply() {
        guard NetCheckSettings.liveSpeedEnabled else {
            NetTrafficSampler.shared.stop()
            NetTrafficSampler.shared.onUpdate = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shownText = nil
            widthHold.reset()
            return
        }
        let newMode = NetCheckSettings.liveSpeedMode
        if newMode != mode {
            mode = newMode
            shownText = nil
            widthHold.reset()
        }
        if item == nil {
            // 排在 Baobox 主图标右边（专注倒计时 1、会议录音指示 2 之后）。
            let created = StatusItemController.makeCompanionItem(autosaveName: "baobox.netcheck.speed", offset: 3,
                                                                 length: NSStatusItem.variableLength)
            created.menu = menu
            item = created
        }
        let sampler = NetTrafficSampler.shared
        sampler.onUpdate = { [weak self] rate in self?.show(rate) }
        if let rate = sampler.latest {
            show(rate)
        } else if shownText == nil {
            show(nil)
        }
        sampler.start()
    }

    /// 开关（二级菜单、快速入口、这个状态项自己的菜单）。
    func setEnabled(_ enabled: Bool) {
        NetCheckSettings.liveSpeedEnabled = enabled
        apply()
    }

    /// 退出 App 时停掉采样定时器。
    func shutdown() {
        NetTrafficSampler.shared.stop()
    }

    // MARK: - 画

    private func show(_ rate: NetTrafficRate?) {
        let text = NetSpeedFormat.menuBarText(down: rate?.down ?? 0, up: rate?.up ?? 0, mode: mode)
        let string = NSAttributedString(string: text, attributes: Self.attributes())
        let needed = Double(ceil(string.size().width))
        let width = CGFloat(widthHold.width(needed: needed, at: ProcessInfo.processInfo.systemUptime))
        guard text != shownText || width != shownWidth, let button = item?.button else { return }
        shownText = text
        shownWidth = width
        button.image = Self.image(string, width: width)
        button.imagePosition = .imageOnly
        button.title = ""
        button.setAccessibilityLabel(text)
    }

    /// 菜单栏上的字体：同专注倒计时（等宽数字的系统字体，菜单栏字号）。
    static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    private static func attributes(alignment: NSTextAlignment = .right) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byClipping
        return [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
    }

    /// 给定宽度、右对齐的模板图（每次画都按当前屏幕的倍率重画，不糊）。
    static func image(_ string: NSAttributedString, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: ceil(string.size().height))
        let image = NSImage(size: size, flipped: false) { rect in
            string.draw(with: rect, options: [.usesLineFragmentOrigin])
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = string.string
        return image
    }

    // MARK: - 小菜单（只读内存）

    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let rate = NetTrafficSampler.shared.latest {
            items.append(NSMenuItem(title: L("netcheck.live.now \(NetSpeedFormat.rate(rate.down)) \(NetSpeedFormat.rate(rate.up))"),
                                    action: nil, keyEquivalent: ""))
            // 只有 32 位计数时累计不可信（每 4 GiB 回绕），这一行不显示
            if let down = rate.totalDown, let up = rate.totalUp {
                items.append(NSMenuItem(title: L("netcheck.live.total \(NetSpeedFormat.amount(Double(down))) \(NetSpeedFormat.amount(Double(up)))"),
                                        action: nil, keyEquivalent: ""))
            }
        } else {
            items.append(NSMenuItem(title: L("netcheck.live.waiting"), action: nil, keyEquivalent: ""))
        }
        items.append(.separator())
        items.append(NetCheckTool.speedTestMenuItem())
        items.append(ClosureMenuItem(title: L("netcheck.live.open")) {
            NetCheckWindowController.shared.show()
        })
        items.append(ClosureMenuItem(title: L("netcheck.live.hide")) {
            NetSpeedStatusItem.shared.setEnabled(false)
        })
        return items
    }

    // 照 FocusStatusItem / StatusItemController：AX 巡检会在后台线程「模拟打开」菜单，非主线程一律跳过。
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            menu.removeAllItems()
            for entry in menuItems() { menu.addItem(entry) }
        }
    }
}
