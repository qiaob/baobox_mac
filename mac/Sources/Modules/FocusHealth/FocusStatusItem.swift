import AppKit

/// 专注 / 休息时的菜单栏倒计时（技术设计 §7）。只在专注、暂停、休息时存在，空闲时不占菜单栏。
@MainActor
final class FocusStatusItem: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var shownSymbol: String?
    private var shownText: String?
    /// 打开菜单时现建（只读内存，零磁盘 IO）。
    var menuItems: () -> [NSMenuItem] = { [] }

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = true
    }

    /// symbol / text 为 nil = 收起。
    func update(symbol: String?, text: String?) {
        guard let symbol, let text else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shownSymbol = nil
            shownText = nil
            return
        }
        if item == nil {
            // 排在 Baobox 主图标右边：系统默认的最左边可能是菜单栏管理的隐藏区。
            let created = StatusItemController.makeCompanionItem(autosaveName: "baobox.focus.countdown", offset: 1,
                                                                 length: NSStatusItem.variableLength)
            created.menu = menu
            item = created
        }
        guard let button = item?.button else { return }
        if shownSymbol != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            shownSymbol = symbol
        }
        if shownText != text {
            button.attributedTitle = NSAttributedString(
                string: " " + text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
            )
            shownText = text
        }
    }

    // 照 StatusItemController：AX 巡检会在后台线程「模拟打开」菜单，非主线程一律跳过。
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            menu.removeAllItems()
            for entry in menuItems() { menu.addItem(entry) }
        }
    }
}
