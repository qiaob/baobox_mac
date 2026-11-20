import AppKit
import SwiftUI
import os

/// 菜单栏管理模块壳（docs/menubar-manager/）：在 Baobox 设置里给每个菜单栏图标选显示 / 隐藏，
/// 隐藏的与此刻被挤掉的放在 Baobox 主菜单最上面一行，点一下就打开它的菜单。
@MainActor
final class MenuBarManagerTool: ToolModule {
    let id = "menubar"
    let name = L("menubar.name")
    let symbolName = "menubar.rectangle"

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if MenuBarManager.shared.isUnsupported {
            items.append(NSMenuItem(title: L("menubar.menu.unsupported"), action: nil, keyEquivalent: ""))
        } else if MenuBarSettings.enabled {
            let hidden = MenuBarItemScanner.shared.items.filter { $0.state == .hidden }.count
            items.append(NSMenuItem(title: L("menubar.menu.status \(hidden)"), action: nil, keyEquivalent: ""))
        } else {
            items.append(NSMenuItem(title: L("menubar.menu.disabled"), action: nil, keyEquivalent: ""))
        }
        items.append(ClosureMenuItem(title: L("menubar.menu.moveBaoboxRight")) {
            AppDelegate.shared?.statusItemController?.placeNearSystemIcons()
        })
        return items
    }

    /// 出厂不绑（仓库惯例）：Baobox 图标被挤掉时，在鼠标位置弹出 Baobox 菜单。
    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "menubar.openMenu",
                title: L("menubar.hotkey.openMenu"),
                subtitle: L("menubar.hotkey.openMenuHelp"),
                defaultCombo: nil
            ) {
                AppDelegate.shared?.statusItemController?.showMenu()
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(MenuBarSettingsView())
    }

    func activate() {
        MenuBarManager.shared.apply(MenuBarSettings.enabled)
    }

    func statusMenuHeaderItems() -> [NSMenuItem] {
        MenuBarManager.shared.headerItems()
    }
}

/// 启停与刷新：占位项、定时扫描、App 切换 / 启动 / 退出时补扫。
@MainActor
final class MenuBarManager {
    static let shared = MenuBarManager()

    let spacer = MenuBarSpacer()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastRescue = Date.distantPast
    /// 这台 Mac 上能不能用；nil = 还看不出来。见 `resolveSupport()`。
    private var support: Bool?
    /// 看不出来时已经隔一会儿再看了几次（启动时各模块 activate 比主图标先跑）。
    private var supportRetries = 0
    /// 第一次看到 Baobox 图标「被挤掉」的时间；连着看到、隔 2 秒以上才挪。
    private var squeezedSince: Date?
    private static let log = Logger(subsystem: "com.baobox.app", category: "menubar")

    private init() {}

    /// 这台 Mac 的系统不支持菜单栏管理（docs/menubar-manager/TECH_DESIGN.md §11）。菜单、设置页据此置灰。
    var isUnsupported: Bool { resolveSupport() == false }

    /// 开着、并且这台 Mac 支持：只有这时才有占位项、才扫描。
    var isActive: Bool { MenuBarSettings.enabled && resolveSupport() == true }

    /// 运行时判断，不看系统版本号：Baobox 主图标的窗口号放得进 CGWindowID 才算能用。
    /// macOS 27.2.1 起状态栏图标改由系统进程 MenuBarAgent 绘制，各 App 的状态栏窗口号是合成值（1<<32、2<<32 …），
    /// 窗口列表里也没有各 App 的 layer 25 窗口 —— 占位项、扫描、挪图标都没了依据。
    /// 主图标还没建好、窗口号还没分配时返回 nil；看出来了就记住（运行中系统版本不会变）。只读内存，菜单构建里也能调。
    private func resolveSupport() -> Bool? {
        if support == nil, let number = AppDelegate.shared?.statusItemController?.mainWindowNumber, number > 0 {
            let fits = CGWindowID(exactly: number) != nil
            support = fits
            if !fits {
                Self.log.notice("Status item windows have synthetic numbers (\(number, privacy: .public)); menu bar management is unavailable on this macOS")
            }
        }
        return support
    }

    /// 设置页的开关、启动时都走这里（开关的值已由 @AppStorage 写好）。
    /// `userToggled`：用户刚在设置里打开 —— 顺手把 Baobox 图标挪到最右边（从左边开始挤，最右边最安全）。
    /// 系统不支持时什么都不装，用户存的开关值不动。
    func apply(_ enabled: Bool, userToggled: Bool = false) {
        let supported = resolveSupport()
        if enabled, supported == nil {
            // 启动时 activate() 比主图标先跑，还看不出来：先什么都不装，过一会儿再看。
            // 5 秒还看不出来（主图标一直没有窗口号）就照旧当能用 —— 窗口号已经是安全转换，不会再崩。
            supportRetries += 1
            if supportRetries > 20 {
                support = true
                apply(enabled, userToggled: userToggled)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated {
                    MenuBarManager.shared.apply(MenuBarSettings.enabled, userToggled: userToggled)
                }
            }
            return
        }
        if enabled, supported == true {
            spacer.install()
            startRefreshing()
            if userToggled, let controller = AppDelegate.shared?.statusItemController, !controller.isAtFarRight {
                controller.placeNearSystemIcons()
            }
            MenuBarItemScanner.shared.refresh()
        } else {
            spacer.remove()
            stopRefreshing()
            MenuBarItemScanner.shared.clear()
        }
    }

    /// Baobox 自己的图标必须一直看得见：它要是落进隐藏区（在占位项左边）或被挤掉，就再也打不开 Baobox 菜单，
    /// 而把别的图标藏起来的正是它自己（2026-11-08 用户：「一定要保证自身百分之百可见，不然……就死循环了」）。
    /// 每次扫描完检查；不对就挪回最右边 —— 改自己的位置值、重建状态项，不用模拟拖，菜单栏不闪。
    /// Baobox 菜单开着、正在挪图标时不动；10 秒内最多挪一次；已经在最右边还被挤掉就不再折腾（靠快捷键兜底）。
    func ensureBaoboxVisible() {
        guard isActive, !StatusItemController.isMenuOpen, !MenuBarActions.shared.busy,
              let controller = AppDelegate.shared?.statusItemController,
              let main = controller.mainFrame, let gap = spacer.frameX else { return }
        let hidden = main.maxX <= gap.minX + 2
        let squeezed = !hidden && MenuBarItemScanner.shared.menuBarShown(at: Geometry.cgRect(fromAppKit: main))
            && !controller.mainIsVisible
        // 「被挤掉」要连着几次扫描、隔 2 秒以上都是才算：换活跃屏时 Baobox 的图标窗口搬到另一块屏上，那一下读到的
        // 「看不见」是假的（2026-11-08 外接屏自测：图标明明在，却被当成挤掉、重建了一遍）。
        if squeezed { squeezedSince = squeezedSince ?? Date() } else { squeezedSince = nil }
        let stillSqueezed = squeezedSince.map { Date().timeIntervalSince($0) >= 2 } ?? false
        guard hidden || (stillSqueezed && !controller.isAtFarRight) else { return }
        guard Date().timeIntervalSince(lastRescue) > 10 else { return }
        lastRescue = Date()
        Self.log.notice("Baobox icon \(hidden ? "fell into the hidden area" : "was squeezed out", privacy: .public); moving it to the right end")
        controller.placeNearSystemIcons()
    }

    /// Baobox 菜单最上面那一行：只读扫描缓存（菜单构建零 IO）。
    func headerItems() -> [NSMenuItem] {
        guard isActive else { return [] }
        let items = MenuBarItemScanner.shared.items
        let hidden = items.filter { $0.state == .hidden }
        let squeezed = MenuBarSettings.showSqueezed ? items.filter { $0.state == .squeezed } : []
        return MenuBarIconRow.menuItems(hidden: hidden, squeezed: squeezed, images: MenuBarItemScanner.shared.images)
    }

    private func startRefreshing() {
        guard timer == nil else { return }
        // common 模式：Baobox 菜单开着（事件跟踪模式）时也照样扫。
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarItemScanner.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        // 前台 App 一换菜单宽度就变（谁被挤掉跟着变）；App 起来 / 退出时图标增减。
        let names: [Notification.Name] = [NSWorkspace.didActivateApplicationNotification,
                                          NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.didTerminateApplicationNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuBarItemScanner.shared.refresh() }
            })
        }
    }

    private func stopRefreshing() {
        timer?.invalidate()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers = []
    }
}
