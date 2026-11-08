import AppKit
import os

/// 挪图标（设置里的显示 / 隐藏）与点图标（Baobox 菜单顶部那一行）。docs/menubar-manager/TECH_DESIGN.md §3、§5、§8b。
///
/// 只在屏上发普通的合成鼠标事件（`.cghidEventTap`），等同用户自己 ⌘ 拖、点一下：
/// 2026-11-08 探针里给屏外的图标发事件（postToPid、会话事件流加窗口字段）点、拖都不起作用，
/// 所以要碰隐藏的图标时，先把占位项缩短让它回到屏上。位置不够时临时把 Baobox 切到前台腾地方。
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
    ///
    /// 先**单独挪**这一个（MenuBarItemMover：屏外的也能挪，菜单栏只动它一个）；不灵再退回老办法
    /// （缩短占位项让它回到屏上、⌘ 拖，会带出别的隐藏图标）。
    @discardableResult
    func setHidden(_ hidden: Bool, itemID: String) async -> Bool {
        guard !busy, spacer.isInstalled else { return false }
        guard Permissions.hasAccessibility else {
            Self.toast(L("menubar.toast.needAccessibility"))
            return false
        }
        busy = true
        defer { busy = false }

        if let item = scanner.items.first(where: { $0.id == itemID }), let gap = spacerWindow() {
            let window = MenuBarItemMover.Window(pid: item.pid, windowID: item.windowID)
            if await MenuBarItemMover.shared.move(window, hidden ? .leftOf : .rightOf, of: gap) {
                await scanner.refreshNow()
                Self.log.notice("\(hidden ? "hide" : "show", privacy: .public) \(itemID, privacy: .public): ok (single move)")
                return true
            }
            Self.log.notice("\(hidden ? "hide" : "show", privacy: .public) \(itemID, privacy: .public): single move failed, falling back")
        }

        var previous: NSRunningApplication?
        var ready = await prepareMove(hidden: hidden, itemID: itemID)
        if ready == nil {
            // 前台 App 菜单太长、位置不够：临时把 Baobox 切到前台（菜单栏换成 Baobox 自己很短的菜单）再试。
            previous = activateBaoboxForRoom()
            try? await Task.sleep(nanoseconds: 350_000_000)
            ready = await prepareMove(hidden: hidden, itemID: itemID)
        }
        var moved = false
        if let item = ready, let gap = spacer.frameX {
            await waitForMouseIdle()
            let target = hidden ? CGPoint(x: gap.minX - 3, y: item.center.y) : CGPoint(x: gap.maxX + 3, y: item.center.y)
            await commandDrag(from: item.center, to: target)
            try? await Task.sleep(nanoseconds: 350_000_000)
            await scanner.refreshNow()
            if let after = scanner.items.first(where: { $0.id == itemID }), let gapNow = spacer.frameX {
                moved = hidden ? after.frame.maxX <= gapNow.minX + 2 : after.frame.minX >= gapNow.maxX - 2
            }
        }
        spacer.collapse()
        restoreFrontmost(previous)
        try? await Task.sleep(nanoseconds: 250_000_000)
        await scanner.refreshNow()
        Self.log.notice("\(hidden ? "hide" : "show", privacy: .public) \(itemID, privacy: .public): \(moved ? "ok" : (ready == nil ? "no room" : "failed"), privacy: .public)")
        if !moved { Self.toast(ready == nil ? L("menubar.toast.noRoom") : L("menubar.toast.moveFailed")) }
        return moved
    }

    // MARK: - 点开

    /// 顶部图标行里点了一个隐藏 / 被挤掉的图标：先把它一个单独挪到 Baobox 图标左边（最右侧，不会被挤），点开它的菜单，
    /// 菜单关掉后挪回原处 —— 别的隐藏图标都不动（2026-11-08 用户：「还是都出来了」）。不灵再退回老办法。
    func open(itemID: String) async {
        guard !busy else { return }
        guard Permissions.hasAccessibility else {
            Self.toast(L("menubar.toast.needAccessibility"))
            return
        }
        guard let current = scanner.items.first(where: { $0.id == itemID }) else { return }
        busy = true
        defer { busy = false }

        if await openByMovingAlone(current) { return }

        let wasHidden = current.state == .hidden
        var previous: NSRunningApplication?
        var ready = await prepareOpen(wasHidden: wasHidden, itemID: itemID)
        if ready == nil {
            previous = activateBaoboxForRoom()
            try? await Task.sleep(nanoseconds: 350_000_000)
            ready = await prepareOpen(wasHidden: wasHidden, itemID: itemID)
        }
        guard let item = ready else {
            spacer.collapse()
            restoreFrontmost(previous)
            await scanner.refreshNow()
            Self.log.notice("open \(itemID, privacy: .public): no room")
            Self.toast(L("menubar.toast.noRoom"))
            return
        }
        await clickAndWait(item, path: "reveal, roomByActivating \(previous != nil)")
        spacer.collapse()
        restoreFrontmost(previous)
        try? await Task.sleep(nanoseconds: 250_000_000)
        scanner.refresh()
    }

    /// 单独挪过去点开，用完挪回：隐藏的回到占位项左边，被挤掉的回到它原来左邻的右边。返回 false = 没挪成，交给老办法。
    private func openByMovingAlone(_ current: MenuBarItem) async -> Bool {
        guard let anchor = baoboxWindow(), let gap = spacerWindow() else {
            Self.log.notice("open \(current.id, privacy: .public): no Baobox / spacer window")
            return false
        }
        Self.log.notice("open \(current.id, privacy: .public): state \(String(describing: current.state), privacy: .public), window \(current.windowID) at \(NSStringFromRect(current.frame), privacy: .public)")
        let mover = MenuBarItemMover.shared
        let window = MenuBarItemMover.Window(pid: current.pid, windowID: current.windowID)
        let back: (MenuBarItemMover.Window, MenuBarItemMover.Side)
        if current.state == .hidden {
            back = (gap, .leftOf)
        } else {
            let leftNeighbor = scanner.items
                .filter { $0.id != current.id && $0.state != .hidden && $0.frame.maxX <= current.frame.minX + 1 }
                .max { $0.frame.maxX < $1.frame.maxX }
            back = leftNeighbor.map { (MenuBarItemMover.Window(pid: $0.pid, windowID: $0.windowID), .rightOf) } ?? (gap, .rightOf)
        }
        guard await mover.move(window, .leftOf, of: anchor) else {
            Self.log.notice("open \(current.id, privacy: .public): single move failed, falling back")
            return false
        }
        await scanner.refreshNow()
        guard let shown = scanner.items.first(where: { $0.id == current.id }), shown.onScreen else {
            // 挪过去了却仍不在屏上（右边也满了）：放回去，交给老办法。
            _ = await mover.move(window, back.1, of: back.0)
            await scanner.refreshNow()
            return false
        }
        await clickAndWait(shown, path: "single move")
        if !(await mover.move(window, back.1, of: back.0)) {
            Self.log.notice("open \(current.id, privacy: .public): could not move it back")
        }
        await scanner.refreshNow()
        return true
    }

    /// 像用户一样点它一下；第一下没弹出东西就按住久一点再点一次；弹出了就等它关掉。
    private func clickAndWait(_ item: MenuBarItem, path: String) async {
        let before = Set(appWindows(pid: item.pid).keys)
        await waitForMouseIdle()
        await click(at: item.center, hold: 0.05)
        var opened = await waitForNewWindows(pid: item.pid, before: before, within: 1.0)
        var attempts = 1
        if opened.isEmpty {
            attempts = 2
            await click(at: item.center, hold: 0.2)
            opened = await waitForNewWindows(pid: item.pid, before: before, within: 1.5)
        }
        Self.log.notice("open \(item.id, privacy: .public) at \(NSStringFromRect(item.frame), privacy: .public) via \(path, privacy: .public), clicks \(attempts) → \(opened.isEmpty ? "nothing appeared" : "windows \(opened.values.sorted())", privacy: .public)")
        if opened.isEmpty {
            Self.toast(L("menubar.toast.noResponse \(item.displayName)"))
        } else {
            await waitForInterfaceToClose(pid: item.pid, windows: opened)
        }
    }

    private func baoboxWindow() -> MenuBarItemMover.Window? {
        AppDelegate.shared?.statusItemController?.mainWindowID.map { MenuBarItemMover.Window(pid: getpid(), windowID: $0) }
    }

    private func spacerWindow() -> MenuBarItemMover.Window? {
        spacer.windowID.map { MenuBarItemMover.Window(pid: getpid(), windowID: $0) }
    }

    // MARK: - 只让一个图标回到屏上

    /// 菜单栏上图标能露出来的最左边（CG x）：刘海右边；菜单栏属主 App 的菜单越过刘海时，在它的菜单后面。
    private func visibleBandMinX(nearX x: CGFloat) -> CGFloat {
        let screen = NSScreen.screens.first { screen in
            let frame = Geometry.cgRect(fromAppKit: screen.frame)
            return x >= frame.minX && x <= frame.maxX
        } ?? NSScreen.main
        guard let screen else { return 0 }
        let frame = Geometry.cgRect(fromAppKit: screen.frame)
        var minX = screen.auxiliaryTopRightArea?.minX ?? frame.minX
        if let owner = NSWorkspace.shared.menuBarOwningApplication,
           let menusMaxX = MenuBarItemScanner.appMenusMaxX(pid: owner.processIdentifier),
           menusMaxX >= frame.minX, menusMaxX <= frame.maxX {
            minX = max(minX, menusMaxX + 6)
        }
        return minX
    }

    /// 把占位项的左边放到 x：右边钉在原位，按需要的宽度设长度；窗口比长度多一截留白，第一次按 16 估，再按实际偏差修一次。
    private func moveSpacerLeftEdge(to x: CGFloat) async {
        guard let gap = spacer.frameX else { return }
        var length = max(2, gap.maxX - x - 16)
        spacer.setLength(length)
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let now = spacer.frameX, abs(now.minX - x) > 1.5 {
            length = max(2, length + (now.minX - x))
            spacer.setLength(length)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// 隐藏的图标挨个排在占位项左边，缩放占位项时它们一起平移、彼此距离不变：
    /// 按这个图标离占位项左边的距离，把占位项的左边放到「它刚好落在看得见那段最左边」的位置。
    /// 夹在它和占位项之间的隐藏图标会一起露出来，更左边的仍在屏外。放不下（夹在中间的太多 / 看得见那段太窄）返回 nil。
    private func revealOnly(_ itemID: String) async -> MenuBarItem? {
        spacer.collapse()
        try? await Task.sleep(nanoseconds: 150_000_000)
        await scanner.refreshNow()
        guard let item = scanner.items.first(where: { $0.id == itemID }), item.state == .hidden,
              let gap = spacer.frameX else { return nil }
        let band = visibleBandMinX(nearX: gap.maxX - 1)
        let offset = gap.minX - item.frame.minX
        let left = band + 3 + offset
        guard left <= gap.maxX - 4 else { return nil }
        await moveSpacerLeftEdge(to: left)
        await scanner.refreshNow()
        if let now = scanner.items.first(where: { $0.id == itemID }), now.onScreen { return now }
        return nil
    }

    /// 隐藏前：只把占位项的左边露进看得见那段（离左边 40），好把显示着的图标拖到它左边。
    private func exposeSpacerEdge(for itemID: String) async -> MenuBarItem? {
        spacer.collapse()
        try? await Task.sleep(nanoseconds: 150_000_000)
        await scanner.refreshNow()
        guard let gap = spacer.frameX,
              scanner.items.contains(where: { $0.id == itemID && $0.onScreen && $0.state != .hidden }) else { return nil }
        let band = visibleBandMinX(nearX: gap.maxX - 1)
        let left = min(band + 40, gap.maxX - 10)
        guard left >= band + 4 else { return nil }
        await moveSpacerLeftEdge(to: left)
        await scanner.refreshNow()
        return scanner.items.first { $0.id == itemID && $0.onScreen && $0.state != .hidden }
    }

    private func prepareMove(hidden: Bool, itemID: String) async -> MenuBarItem? {
        if hidden { return await exposeSpacerEdge(for: itemID) }
        return await revealOnly(itemID)
    }

    private func prepareOpen(wasHidden: Bool, itemID: String) async -> MenuBarItem? {
        if wasHidden { return await revealOnly(itemID) }
        return await onScreenNow(itemID)
    }

    /// 被挤掉 / 显示着的图标此刻在不在屏上。
    private func onScreenNow(_ itemID: String) async -> MenuBarItem? {
        await scanner.refreshNow()
        return scanner.items.first { $0.id == itemID && $0.onScreen }
    }

    private func activateBaoboxForRoom() -> NSRunningApplication? {
        let previous = NSWorkspace.shared.frontmostApplication
        guard previous?.processIdentifier != getpid() else { return nil }
        NSApp.activate(ignoringOtherApps: true)
        return previous
    }

    /// 切回原来的前台 App —— 只在 Baobox 还在前台时：点开的图标可能自己弹出了窗口、成了前台，那就别抢回来。
    private func restoreFrontmost(_ previous: NSRunningApplication?) {
        guard let previous, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { return }
        previous.activate(options: [])
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

    /// 等弹出来的菜单 / 面板关掉（最长 2 分钟）再把占位项撑回去：菜单开着时图标被推走，有的 App 会把菜单一起收掉。
    /// 弹出的是普通窗口（层 0，比如点了直接打开主窗口）就不等。
    private func waitForInterfaceToClose(pid: pid_t, windows: [CGWindowID: Int]) async {
        let floating = Set(windows.filter { $0.value != 0 }.keys)
        guard !floating.isEmpty else { return }
        let started = Date()
        while Date().timeIntervalSince(started) < 120 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if appWindows(pid: pid).keys.allSatisfy({ !floating.contains($0) }) { return }
        }
    }

    // MARK: - 合成鼠标事件

    /// 用户正在动鼠标时开拖会拖歪：等它静止 0.1 秒（最多等 1.5 秒）。
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

    private func postMouse(_ type: CGEventType, _ point: CGPoint, flags: CGEventFlags = []) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
        event.flags = flags
        // 单击次数要标成 1：合成事件默认是 0，Electron 做的菜单栏图标（Slack）只认 clickCount == 1，
        // 点了没反应（2026-11-08 日志：Slack 在屏上的 941 处点了两下，什么都没弹出来）。原生 App 不看这一项。
        if type == .leftMouseDown || type == .leftMouseUp {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
    }

    private func postCommandKey(down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: down) else { return }
        event.flags = down ? .maskCommand : []
        event.post(tap: .cghidEventTap)
    }

    /// 按住 ⌘ 从 start 拖到 end（CG 坐标），做完把鼠标放回原处。
    private func commandDrag(from start: CGPoint, to end: CGPoint) async {
        let saved = CGEvent(source: nil)?.location
        postMouse(.mouseMoved, start)
        try? await Task.sleep(nanoseconds: 80_000_000)
        postCommandKey(down: true)
        try? await Task.sleep(nanoseconds: 60_000_000)
        postMouse(.leftMouseDown, start, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 180_000_000)
        for step in 1...12 {
            let t = CGFloat(step) / 12
            postMouse(.leftMouseDragged,
                      CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                      flags: .maskCommand)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        try? await Task.sleep(nanoseconds: 180_000_000)
        postMouse(.leftMouseUp, end, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 60_000_000)
        postCommandKey(down: false)
        if let saved {
            CGWarpMouseCursorPosition(saved)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    /// 普通点一下。鼠标留在图标上：菜单就开在它下面，跟用户自己点的一样。
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
