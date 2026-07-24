import AppKit

/// 菜单栏状态项与菜单。菜单结构完全由 ToolRegistry 里的模块驱动。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let registry: ToolRegistry
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(registry: ToolRegistry) {
        self.registry = registry
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            // 菜单栏用模板符号（跟随系统明暗），箱子造型与 App 图标呼应。
            // 必须显式指定字号：不带配置的符号图默认 ~13pt，会明显小于相邻状态栏图标。
            let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            let image = NSImage(systemSymbolName: "shippingbox.fill",
                                accessibilityDescription: "Baobox")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
        }

        menu.delegate = self
        menu.autoenablesItems = true
        statusItem.menu = menu
        rebuild()
    }

    // MARK: - NSMenuDelegate

    /// 每次打开菜单前重建，保证快捷键改动即时反映。
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    /// 菜单打开期间启用 CGEventTap 补捉全局热键：NSMenu tracking 独占事件循环，Carbon 全局热键
    /// 此时收不到（「菜单开着按快捷键无反应」）。tap 在 HID 层捕获，命中即收起菜单并触发。
    func menuWillOpen(_ menu: NSMenu) {
        HotkeyCenter.shared.beginMenuTrackingCapture()
    }

    func menuDidClose(_ menu: NSMenu) {
        HotkeyCenter.shared.endMenuTrackingCapture()
    }

    /// 收起可能正打开的状态栏菜单。供全局热键触发前调用（见 `HotkeyCenter.onWillFireAction`），
    /// 避免菜单与动作弹出的窗口（如截图选区浮层）同时在场。未在 tracking 时为 no-op。
    func dismissMenu() {
        menu.cancelTrackingWithoutAnimation()
    }

    // MARK: - 构建

    private func rebuild() {
        menu.removeAllItems()

        for tool in registry.tools {
            let item = NSMenuItem(title: tool.name, action: nil, keyEquivalent: "")
            item.image = symbolImage(tool.symbolName)

            let submenu = NSMenu()
            submenu.autoenablesItems = true
            for sub in tool.submenuItems() {
                Self.showHotkeyIfTagged(sub)
                submenu.addItem(sub)
            }
            submenu.addItem(.separator())
            submenu.addItem(ClosureMenuItem(title: L("app.menu.toolSettings \(tool.name)")) { [weak self] in
                self?.openSettings(tab: tool.id)
            })
            item.submenu = submenu
            menu.addItem(item)
        }

        // 占位提示行（自动置灰）
        let more = NSMenuItem(title: L("app.menu.morePlaceholder"), action: nil, keyEquivalent: "")
        menu.addItem(more)

        menu.addItem(.separator())

        let settings = ClosureMenuItem(title: L("app.menu.settings"), keyEquivalent: ",") { [weak self] in
            self?.openSettings(tab: nil)
        }
        menu.addItem(settings)

        // 检查更新：M2 接入 Sparkle，现阶段占位置灰（action 为 nil 即自动置灰）。
        let update = NSMenuItem(title: L("app.menu.checkUpdates"), action: nil, keyEquivalent: "")
        menu.addItem(update)

        let quit = ClosureMenuItem(title: L("app.menu.quit"), keyEquivalent: "q") {
            NSApp.terminate(nil)
        }
        menu.addItem(quit)
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    /// 把 ClosureMenuItem 声明的快捷键渲染到该项右侧。
    ///
    /// 这里刻意只做「展示」而不设置真正的 keyEquivalent：菜单打开时 AppKit 会响应
    /// key equivalent，与常驻的 Carbon 全局热键叠加会导致同一动作触发两次
    /// （剪贴板面板这类 toggle 动作会开了又立刻关）。
    private static func showHotkeyIfTagged(_ item: NSMenuItem) {
        guard let closure = item as? ClosureMenuItem,
              let hkID = closure.hotkeyID,
              let combo = HotkeyCenter.shared.combo(for: hkID) else { return }
        item.attributedTitle = titleWithShortcut(item.title, shortcut: combo.display)
    }

    /// 快捷键列的右对齐位置（pt），需大于最长菜单项文案的宽度。
    private static let shortcutColumn: CGFloat = 190

    /// 「名称 …… 快捷键」两端对齐的标题。
    private static func titleWithShortcut(_ name: String, shortcut: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: shortcutColumn)]

        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(
            string: name,
            attributes: [.paragraphStyle: style, .font: font]
        )
        title.append(NSAttributedString(
            string: "\t" + shortcut,
            attributes: [.paragraphStyle: style,
                         .font: font,
                         .foregroundColor: NSColor.secondaryLabelColor]
        ))
        return title
    }

    private func openSettings(tab: String?) {
        SettingsWindowController.shared.show(registry: registry, tab: tab)
    }
}
