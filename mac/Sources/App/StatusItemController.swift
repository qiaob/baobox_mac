import AppKit

/// 菜单栏状态项与菜单。菜单结构完全由 ToolRegistry 里的模块驱动。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let registry: ToolRegistry
    /// 「放到最右边」时会移除重建（docs/menubar-manager/TECH_DESIGN.md §4），所以是 var。
    private var statusItem: NSStatusItem
    private let menu = NSMenu()
    /// 状态栏菜单开着（只在主线程读写）。连续听写据此推迟上屏：菜单 tracking 时合成的 ⌘V / 退格会被菜单吃掉。
    private(set) static var isMenuOpen = false
    /// 主状态项在偏好里的名字。从没设过 autosaveName，系统按创建顺序叫它 Item-0（2026-11-08 探针实测）。
    private static let autosaveName = "Item-0"
    private static weak var current: StatusItemController?

    init(registry: ToolRegistry) {
        self.registry = registry
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 名字写死：系统默认按创建顺序起名，菜单栏管理的占位项在各模块 activate 时先建出来，主图标就成了 Item-1、
        // 找不到记过的位置，被当成新图标排到最左 —— 正好落进隐藏区，Baobox 图标「没了」（2026-11-08 用户反馈）。
        self.statusItem.autosaveName = Self.autosaveName
        super.init()
        Self.current = self

        menu.delegate = self
        menu.autoenablesItems = true
        configure(statusItem)
        rebuild()
    }

    private func configure(_ item: NSStatusItem) {
        if let button = item.button {
            // 菜单栏用模板符号（跟随系统明暗），箱子造型与 App 图标呼应。
            // 必须显式指定字号：不带配置的符号图默认 ~13pt，会明显小于相邻状态栏图标。
            let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            let image = NSImage(systemSymbolName: "shippingbox.fill",
                                accessibilityDescription: "Baobox")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
        }
        item.menu = menu
    }

    // MARK: - 位置（菜单栏管理）

    /// 把 Baobox 图标挪到系统图标（电池 / 控制中心 / 时间）左边紧挨着，以后被挤掉的是别的图标。
    /// 状态项的位置是各 App 偏好里 `NSStatusItem Preferred Position <名字>` 的值，越大越靠左（探针实测）：
    /// 取控制中心「电池」（没有就取控制中心图标）的值再大一点。先移除旧状态项、再写值、再建新的 —— 移除时系统会把当前位置写回去。
    func placeNearSystemIcons() {
        let value = Self.farRightPosition()
        NSStatusBar.system.removeStatusItem(statusItem)
        UserDefaults.standard.set(value, forKey: "NSStatusItem Preferred Position \(Self.autosaveName)")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.autosaveName
        configure(item)
        statusItem = item
    }

    /// 「最右边」的位置值：控制中心「电池」（没有就取控制中心图标）的值再大一点 = 紧挨在它左边；
    /// 并且一定比菜单栏管理的占位项小（= 在占位项右边，看得见），哪怕用户把电池也隐藏了。
    static func farRightPosition() -> Double {
        var value = 230.0
        let domain = "com.apple.controlcenter" as CFString
        CFPreferencesAppSynchronize(domain)
        for module in ["Battery", "BentoBox"] {
            let key = "NSStatusItem Preferred Position \(module)" as CFString
            if let system = CFPreferencesCopyAppValue(key, domain) as? NSNumber {
                value = system.doubleValue + 3
                break
            }
        }
        let spacerKey = "NSStatusItem Preferred Position \(MenuBarSpacer.autosaveName)"
        if let spacer = UserDefaults.standard.object(forKey: spacerKey) as? NSNumber {
            value = min(value, spacer.doubleValue - 40)
        }
        return max(1, value)
    }

    // MARK: - Baobox 自己必须看得见（菜单栏管理用）

    /// 主图标的窗口号：菜单栏管理临时显示隐藏的图标时，把它挪到这个窗口左边（最右侧，不会被挤）。
    var mainWindowID: CGWindowID? {
        statusItem.button?.window.map { CGWindowID($0.windowNumber) }
    }

    /// 主图标此刻的窗口位置（AppKit 坐标）。
    var mainFrame: NSRect? { statusItem.button?.window?.frame }

    /// 主图标此刻看得见：在屏上、落在菜单栏看得见的那段（刘海右边）。
    var mainIsVisible: Bool {
        guard let window = statusItem.button?.window else { return false }
        return window.occlusionState.contains(.visible) && Self.isOnVisibleMenuBar(window.frame)
    }

    /// 已经在「最右边」了：再挪也不会更好（真放不下时就靠「打开 Baobox 菜单」快捷键）。
    var isAtFarRight: Bool {
        let key = "NSStatusItem Preferred Position \(Self.autosaveName)"
        guard let saved = UserDefaults.standard.object(forKey: key) as? NSNumber else { return false }
        return abs(saved.doubleValue - Self.farRightPosition()) < 1.5
    }

    /// Baobox 自己的临时状态项（专注倒计时、会议录音指示）：放在主图标右边紧挨着。不指定位置的话系统把新状态项排到最左，
    /// 开着菜单栏管理时那里是隐藏区（docs/menubar-manager/TECH_DESIGN.md §3）—— 录音指示被藏起来就白做了。
    /// 位置值越大越靠左，主图标的值减 offset 就在它右边。每次出现都按主图标**当前**的位置重写：主图标挪到最右以后，
    /// 旧位置可能已经在占位项左边了。
    static func makeCompanionItem(autosaveName: String, offset: Double, length: CGFloat) -> NSStatusItem {
        if let main = current?.mainPosition() {
            UserDefaults.standard.set(max(1, main - offset), forKey: "NSStatusItem Preferred Position \(autosaveName)")
        }
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = autosaveName
        return item
    }

    /// 主图标的位置值：偏好里记过就用；没记过就按它此刻离屏幕右边的距离算（这个值本来就是这么记的）。
    private func mainPosition() -> Double? {
        let key = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if let saved = UserDefaults.standard.object(forKey: key) as? NSNumber { return saved.doubleValue }
        guard let frame = statusItem.button?.window?.frame,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return nil }
        return Double(screen.frame.maxX - frame.maxX)
    }

    /// 「打开 Baobox 菜单」快捷键：图标看得见就像点了它；被挤掉、被刘海挡住、在全屏 App 里菜单栏收着时，在鼠标位置弹出。
    func showMenu() {
        // 多显示器：鼠标所在那块屏上有一份看得见的 Baobox 图标（每块屏各有一份；活跃屏上开着全屏 App、菜单栏收着时也一样），
        // 就开在它下面。
        if let window = statusItem.button?.window, let screen = MenuBarItemScanner.screenUnderMouse(),
           let replica = MenuBarItemScanner.replicaFrame(pid: getpid(), of: Geometry.cgRect(fromAppKit: window.frame),
                                                         onScreen: screen) {
            let below = Geometry.appKitRect(fromCG: replica)
            menu.popUp(positioning: nil, at: NSPoint(x: below.minX, y: below.minY), in: nil)
        } else if let button = statusItem.button, let window = button.window,
                  window.occlusionState.contains(.visible), Self.isOnVisibleMenuBar(window.frame) {
            button.performClick(nil)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private static func isOnVisibleMenuBar(_ frame: NSRect) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return false }
        if let right = screen.auxiliaryTopRightArea {
            return frame.minX >= right.minX - 1 && frame.maxX <= screen.frame.maxX + 1
        }
        return screen.frame.contains(frame)
    }

    // MARK: - NSMenuDelegate
    //
    // 三个回调都 nonisolated + 手动验线程：键盘点击类工具（含本 App 自己的 KeyboardNav）
    // 与读屏软件对本进程做 AX 枚举时，AppKit 会在**后台线程**「模拟打开」菜单
    // （_simulateOpening）并同步回调这里 —— rebuild 里创建 NSHostingView，SwiftUI 在
    // 非主线程直接断言崩溃（实测栈：NSMenu(Accessibility) → menuNeedsUpdate → rebuild）。
    // AX 巡检不需要新鲜菜单内容，非主线程一律跳过。

    /// 每次打开菜单前重建，保证快捷键改动即时反映。
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { rebuild() }
    }

    /// 菜单打开期间启用 CGEventTap 补捉全局热键：NSMenu tracking 独占事件循环，Carbon 全局热键
    /// 此时收不到（「菜单开着按快捷键无反应」）。tap 在 HID 层捕获，命中即收起菜单并触发。
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            StatusItemController.isMenuOpen = true
            HotkeyCenter.shared.beginMenuTrackingCapture()
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            StatusItemController.isMenuOpen = false
            HotkeyCenter.shared.endMenuTrackingCapture()
        }
    }

    /// 收起可能正打开的状态栏菜单。供全局热键触发前调用（见 `HotkeyCenter.onWillFireAction`），
    /// 避免菜单与动作弹出的窗口（如截图选区浮层）同时在场。未在 tracking 时为 no-op。
    func dismissMenu() {
        menu.cancelTrackingWithoutAnimation()
    }

    // MARK: - 构建

    private func rebuild() {
        menu.removeAllItems()

        // 模块放在最上面的行（菜单栏管理：被隐藏 / 被挤掉的图标），见 ToolModule.statusMenuHeaderItems。
        let headers = registry.tools.flatMap { $0.statusMenuHeaderItems() }
        if !headers.isEmpty {
            headers.forEach { menu.addItem($0) }
            menu.addItem(.separator())
        }

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

    /// 把 ClosureMenuItem 声明的快捷键渲染到该项右侧（模块自己的菜单栏项，如会议的录音指示，也用这个）。
    ///
    /// 这里刻意只做「展示」而不设置真正的 keyEquivalent：菜单打开时 AppKit 会响应
    /// key equivalent，与常驻的 Carbon 全局热键叠加会导致同一动作触发两次
    /// （剪贴板面板这类 toggle 动作会开了又立刻关）。
    static func showHotkeyIfTagged(_ item: NSMenuItem) {
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
