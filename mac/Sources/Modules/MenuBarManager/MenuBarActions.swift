import AppKit
import os

/// 挪图标（设置里的显示 / 隐藏）与点图标（Baobox 菜单顶部那一行）。docs/menubar-manager/TECH_DESIGN.md §5、§8c、§8d。
///
/// 都只**单独挪**那一个图标（MenuBarItemMover：屏外的也能挪，菜单栏上别的图标不动）；挪不动先重新扫一遍再挪一次，还不行就提示。
/// 以前还有一条老办法：缩短占位项让一串隐藏图标回到屏上，在看得见那段的最左边点；位置不够时临时把 Baobox 切到前台腾地方。
/// 它会带出别的隐藏图标、鼠标从右边跳到最左边，切到 Baobox 也腾不出地方（Baobox 没有窗口，切到前台后菜单栏仍是原来 App 的，
/// 2026-11-08 实测）。用户：「还是都出来了」「没有刘海，也不应该展示在最左边，鼠标跳的太大了」—— 老办法删掉。
@MainActor
final class MenuBarActions: ObservableObject {
    static let shared = MenuBarActions()
    private static let log = Logger(subsystem: "com.baobox.app", category: "menubar")

    /// 正在挪 / 点：设置页据此禁用选择，顶部图标行的点击在这期间忽略。
    @Published private(set) var busy = false

    private let source = CGEventSource(stateID: .hidSystemState)
    private var scanner: MenuBarItemScanner { .shared }
    private var spacer: MenuBarSpacer { MenuBarManager.shared.spacer }

    private init() {}

    // MARK: - 显示 / 隐藏

    /// 把图标挪到占位项左边（隐藏）或右边（显示）。返回挪没挪成。
    @discardableResult
    func setHidden(_ hidden: Bool, itemID: String) async -> Bool {
        guard !busy, spacer.isInstalled else { return false }
        guard Permissions.hasAccessibility else {
            Self.toast(L("menubar.toast.needAccessibility"))
            return false
        }
        busy = true
        defer { busy = false }

        for attempt in 1...2 {
            // 第二次先重新扫一遍拿新的窗口（换活跃屏时图标窗口会在两块屏之间搬家）。
            if attempt == 2 { await scanner.refreshNow() }
            guard let item = scanner.items.first(where: { $0.id == itemID }), let gap = spacerWindow() else { break }
            if await MenuBarItemMover.shared.move(window(of: item), hidden ? .leftOf : .rightOf, of: gap) {
                await scanner.refreshNow()
                Self.log.notice("\(hidden ? "hide" : "show", privacy: .public) \(itemID, privacy: .public): ok (try \(attempt))")
                return true
            }
        }
        await scanner.refreshNow()
        Self.log.notice("\(hidden ? "hide" : "show", privacy: .public) \(itemID, privacy: .public): failed")
        Self.toast(L("menubar.toast.moveFailed"))
        return false
    }

    // MARK: - 点开

    private enum OpenOutcome {
        case opened
        /// 挪到了 Baobox 左边，可那儿也被挤掉了（前台 App 的菜单一直排到了 Baobox 跟前）。
        case noRoom
        case notMoved
    }

    /// 顶部图标行里点了一个隐藏 / 被挤掉的图标：把它一个单独挪到 Baobox 图标左边（最右侧，不会被挤），点开它的菜单，
    /// 菜单关掉后挪回原处 —— 别的隐藏图标都不动。在用户点 Baobox 的那块屏上点（多显示器），鼠标指针不跳。
    func open(itemID: String) async {
        guard !busy else { return }
        guard Permissions.hasAccessibility else {
            Self.toast(L("menubar.toast.needAccessibility"))
            return
        }
        guard let first = scanner.items.first(where: { $0.id == itemID }) else { return }
        // 用户是在哪块屏的菜单栏上点的（多显示器）：就在那块屏上点开 —— 菜单开在眼前。
        let screen = MenuBarItemScanner.screenUnderMouse()
        busy = true
        defer { busy = false }

        var outcome = await openByMovingAlone(first, on: screen)
        if outcome == .notMoved {
            // 再试一次：重新扫一遍拿新的窗口（换活跃屏时图标窗口会在两块屏之间搬家）。
            await scanner.refreshNow()
            if let fresh = scanner.items.first(where: { $0.id == itemID }), fresh.state == first.state {
                outcome = await openByMovingAlone(fresh, on: screen)
            }
        }
        switch outcome {
        case .opened: break
        case .noRoom: Self.toast(L("menubar.toast.noRoom"))
        case .notMoved: Self.toast(L("menubar.toast.noResponse \(first.displayName)"))
        }
    }

    /// 单独挪过去点开，用完挪回原处：隐藏的回到它原来右邻（隐藏图标或占位项）的左边，被挤掉的回到它原来左邻的右边
    /// —— 顶部那一行的顺序不变。
    private func openByMovingAlone(_ current: MenuBarItem, on screen: CGRect?) async -> OpenOutcome {
        guard let anchor = baoboxWindow(), let gap = spacerWindow() else {
            Self.log.notice("open \(current.id, privacy: .public): no Baobox / spacer window")
            return .notMoved
        }
        Self.log.notice("open \(current.id, privacy: .public): state \(String(describing: current.state), privacy: .public), window \(current.windowID) at \(NSStringFromRect(current.frame), privacy: .public)")
        let mover = MenuBarItemMover.shared
        let item = window(of: current)
        let back: (MenuBarItemMover.Window, MenuBarItemMover.Side)
        if current.state == .hidden {
            let rightNeighbor = scanner.items
                .filter { $0.id != current.id && $0.state == .hidden && $0.frame.minX >= current.frame.maxX - 1 }
                .min { $0.frame.minX < $1.frame.minX }
            back = rightNeighbor.map { (window(of: $0), .leftOf) } ?? (gap, .leftOf)
        } else {
            let leftNeighbor = scanner.items
                .filter { $0.id != current.id && $0.state != .hidden && $0.frame.maxX <= current.frame.minX + 1 }
                .max { $0.frame.maxX < $1.frame.maxX }
            back = leftNeighbor.map { (window(of: $0), .rightOf) } ?? (gap, .rightOf)
        }
        let moved = await mover.move(item, .leftOf, of: anchor)
        let movedAt = Date()
        await scanner.refreshNow()
        let now = scanner.items.first { $0.id == current.id }
        // 点得着：活跃屏上那份看得见，或者用户那块屏上那份看得见（活跃屏上开着全屏 App、菜单栏收着时，只有别的屏上的看得见）。
        let clickable = now.flatMap { item -> MenuBarItem? in
            if item.onScreen { return item }
            guard let screen, MenuBarItemScanner.replicaFrame(pid: item.pid, of: item.frame, onScreen: screen) != nil else { return nil }
            return item
        }
        guard let shown = clickable else {
            // 不在屏上（没挪动，或挪过去了那儿也被挤掉）。挪了一半的话它可能已经不在原来那一侧：先放回去。
            if now?.state != current.state {
                _ = await mover.move(item, back.1, of: back.0)
                await scanner.refreshNow()
            }
            Self.log.notice("open \(current.id, privacy: .public): \(moved ? "moved but not on screen" : "move failed", privacy: .public)")
            return moved ? .noRoom : .notMoved
        }
        // 落在 Baobox 左边，或者没完全挪对、但已经在屏上看得见了：都直接点，点完照样挪回去。
        // 挪完至少等 0.6 秒再点：有的 App 要过一会儿才处理「图标被挪走了」，这之前开的菜单会被它自己收掉
        // （2026-11-08 自测：Electron 做的 1Password，挪完 0.2 秒点，菜单一闪就没；等 0.5 秒、1 秒都正常）。
        let settle = 0.6 - Date().timeIntervalSince(movedAt)
        if settle > 0 { try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
        await clickAndWait(shown, on: screen, path: moved ? "single move" : "single move, landed elsewhere")
        if !(await mover.move(item, back.1, of: back.0)) {
            Self.log.notice("open \(current.id, privacy: .public): could not move it back")
        }
        await scanner.refreshNow()
        return .opened
    }

    /// 像用户一样点它一下；第一下没弹出东西就按住久一点再点一次；弹出了就等它关掉。
    /// 扫描、挪动用的是活跃屏上那份图标；用户在别的屏上（screen），点那块屏上的那份。那块屏上找不到（比如屏窄、它在那儿被挤掉了）仍点活跃屏上的。
    private func clickAndWait(_ item: MenuBarItem, on screen: CGRect?, path: String) async {
        let before = Set(appWindows(pid: item.pid).keys)
        await waitForMouseIdle()
        let replica = screen.flatMap { MenuBarItemScanner.replicaFrame(pid: item.pid, of: item.frame, onScreen: $0) }
        let frame = replica ?? item.frame
        var opened: [CGWindowID: Int] = [:]
        var attempts = 0
        var how = "click"
        if replica == nil {
            // 先用辅助功能「按一下」：不动鼠标。Electron 做的 1Password 对合成的鼠标点击时灵时不灵（菜单一闪就没、或者不弹），
            // 2026-11-08 自测。用户在别的屏上（要点那块屏上的那份）时不用它 —— 它总在活跃屏上的那份下面开菜单。
            let pid = item.pid, target = item.frame
            Task.detached { _ = MenuBarItemScanner.axPress(pid: pid, at: target) }
            opened = await waitForNewWindows(pid: item.pid, before: before, within: 1.5)
            if !opened.isEmpty { how = "AXPress" }
        }
        if opened.isEmpty {
            (opened, attempts) = await clickAndCollect(at: CGPoint(x: frame.midX, y: frame.midY), pid: item.pid, before: before)
        }
        Self.log.notice("open \(item.id, privacy: .public) at \(NSStringFromRect(frame), privacy: .public) via \(path, privacy: .public), \(how, privacy: .public), clicks \(attempts) → \(opened.isEmpty ? "nothing appeared" : "windows \(opened.values.sorted())", privacy: .public)")
        if opened.isEmpty {
            Self.toast(L("menubar.toast.noResponse \(item.displayName)"))
        } else {
            await waitForInterfaceToClose(pid: item.pid, opened: opened, before: before)
        }
    }

    private func window(of item: MenuBarItem) -> MenuBarItemMover.Window {
        MenuBarItemMover.Window(pid: item.pid, windowID: item.windowID)
    }

    private func baoboxWindow() -> MenuBarItemMover.Window? {
        AppDelegate.shared?.statusItemController?.mainWindowID.map { MenuBarItemMover.Window(pid: getpid(), windowID: $0) }
    }

    private func spacerWindow() -> MenuBarItemMover.Window? {
        spacer.windowID.map { MenuBarItemMover.Window(pid: getpid(), windowID: $0) }
    }

    // MARK: - 等它的菜单关掉

    /// 那个进程此刻在屏上的窗口（窗口号 → 窗口层），不算它的菜单栏图标。
    private func appWindows(pid: pid_t) -> [CGWindowID: Int] {
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var windows: [CGWindowID: Int] = [:]
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer != statusLevel,
                  let number = info[kCGWindowNumber as String] as? Int else { continue }
            windows[CGWindowID(number)] = layer
        }
        return windows
    }

    /// 点完后等它弹出东西：菜单、面板，或者直接打开的主窗口。返回新出现的窗口（窗口号 → 层），没有就是空的。
    private func waitForNewWindows(pid: pid_t, before: Set<CGWindowID>, within seconds: TimeInterval) async -> [CGWindowID: Int] {
        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            try? await Task.sleep(nanoseconds: 120_000_000)
            let fresh = appWindows(pid: pid).filter { !before.contains($0.key) }
            if !fresh.isEmpty { return fresh }
        }
        return [:]
    }

    /// 等弹出来的菜单 / 面板关掉（最长 2 分钟）再把图标挪回去：菜单开着时图标被挪走，菜单会跟着收掉。
    /// 弹出的是普通窗口（层 0，比如点了直接打开主窗口）就不等。
    /// 「关掉」= 那个进程连着 0.5 秒没有点之后新冒出来的浮层窗口；不只盯第一次看到的那个窗口号 —— 菜单开着时换一个窗口
    /// 也还算开着（2026-11-08 自测：1Password 的菜单开了半秒就被当成关了，图标被挪回去、菜单跟着收掉）。
    private func waitForInterfaceToClose(pid: pid_t, opened: [CGWindowID: Int], before: Set<CGWindowID>) async {
        guard opened.values.contains(where: { $0 != 0 }) else { return }
        let started = Date()
        var quietPolls = 0
        while Date().timeIntervalSince(started) < 120 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let floating = appWindows(pid: pid).filter { !before.contains($0.key) && $0.value != 0 }
            quietPolls = floating.isEmpty ? quietPolls + 1 : 0
            if quietPolls >= 2 { return }
        }
    }

    // MARK: - 合成鼠标事件

    /// 用户正在动鼠标时先等它静止 0.1 秒（最多等 1.5 秒），免得点歪。
    private func waitForMouseIdle() async {
        var last = NSEvent.mouseLocation
        let started = Date()
        while Date().timeIntervalSince(started) < 1.5 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let now = NSEvent.mouseLocation
            if now == last, NSEvent.pressedMouseButtons == 0 { return }
            last = now
        }
    }

    private func postMouse(_ type: CGEventType, _ point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
        // 单击次数要标成 1：合成事件默认是 0，Electron 做的菜单栏图标（Slack）只认 clickCount == 1，
        // 点了没反应（2026-11-08 日志：Slack 在屏上的 941 处点了两下，什么都没弹出来）。原生 App 不看这一项。
        if type == .leftMouseDown || type == .leftMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }

    /// 点一下（第一下没弹出东西就按住久一点再点一次），返回新弹出的窗口和点了几下。
    ///
    /// 鼠标指针留在图标上，跟用户自己点的一样：菜单开在图标下面，指针正好在菜单上方。图标就挪在 Baobox 旁边（用户刚点的地方），
    /// 指针只挪一小段（以前老办法在最左边点，指针横跨整块屏，2026-11-08 用户：「鼠标跳的太大了」）。
    /// 试过藏起指针、点完放回原处（Ice 的做法）：App 处理松手时、或菜单开着时指针一离开图标，菜单就收掉；放回早了什么都不弹，
    /// 晚了菜单一闪就没（2026-11-08 自测：1Password、Tailscale），原生 App 和 Electron 做的 App 时机还不一样，不可靠。
    private func clickAndCollect(at point: CGPoint, pid: pid_t,
                                 before: Set<CGWindowID>) async -> (opened: [CGWindowID: Int], attempts: Int) {
        // 等得宽一点：在后台被系统节能挂起的 App（Electron 做的 1Password 等）第一下要先醒过来。
        await click(at: point, hold: 0.05)
        var opened = await waitForNewWindows(pid: pid, before: before, within: 1.5)
        var attempts = 1
        if opened.isEmpty {
            attempts = 2
            await click(at: point, hold: 0.2)
            opened = await waitForNewWindows(pid: pid, before: before, within: 2.0)
        }
        return (opened, attempts)
    }

    private func click(at point: CGPoint, hold: TimeInterval) async {
        postMouse(.mouseMoved, point)
        try? await Task.sleep(nanoseconds: 60_000_000)
        postMouse(.leftMouseDown, point)
        try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        postMouse(.leftMouseUp, point)
    }

    static func toast(_ text: String) {
        NotifyCenter.shared.post(PetNotification(source: "menubar", level: .ambient, title: text,
                                                 icon: "menubar.rectangle", isUserFeedback: true))
    }
}
