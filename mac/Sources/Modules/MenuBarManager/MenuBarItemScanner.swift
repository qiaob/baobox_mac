import AppKit
import ApplicationServices
import ImageIO
import os

/// 菜单栏上别的 App 的一个图标（docs/menubar-manager/TECH_DESIGN.md §2）。
struct MenuBarItem: Identifiable, Equatable {
    enum State: Equatable {
        /// 在占位项右边，看得见。
        case visible
        /// 在占位项左边，被推出屏外。
        case hidden
        /// 在占位项右边，但位置不够：被刘海挡住、被前台 App 的菜单挤掉。
        case squeezed
    }

    /// bundle id +「|」+ 这一项的标识：一个 App 只有一项时是 item0，多项时用辅助功能标识 / 标题 / 序号。
    let id: String
    let bundleID: String
    let pid: pid_t
    let displayName: String
    /// 图标窗口在 CG 坐标（左上原点）里的位置。
    let frame: CGRect
    let windowID: CGWindowID
    let state: State
    /// 此刻在屏上、落在菜单栏看得见的那一段里（能直接点、能拖）。和 state 分开记：占位项缩短时隐藏的也会在屏上。
    let onScreen: Bool

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// 找别的 App 的菜单栏图标、判断显示 / 隐藏 / 被挤掉、抓图标图像。
///
/// 2026-11-08 探针定下的做法（TECH_DESIGN.md §8）：
/// - 以辅助功能的 `kAXExtrasMenuBarAttribute` 为准（位置准、系统项带标识）；窗口列表里每项有一对同位置窗口，
///   控制中心还有几个隐藏模块的窗口叠在别的图标上，只按位置对上屏上那个。
/// - 图标图像只能在看得见时抓（菜单栏收着、被推到屏外都抓不到），按项缓存，隐藏后沿用。
@MainActor
final class MenuBarItemScanner: ObservableObject {
    static let shared = MenuBarItemScanner()

    @Published private(set) var items: [MenuBarItem] = []
    /// 菜单栏此刻露着的那些屏（CG 坐标；全屏 App 所在那块屏的菜单栏是收着的）。每块屏分开算：多显示器时活跃屏上开着
    /// 全屏 App，那块屏的菜单栏收着、别的屏照样露着（2026-11-08 外接屏自测）。收着的那块屏上不算「被挤掉」。
    private(set) var shownScreens: [CGRect] = []
    private var scannedOnce = false

    /// 这个位置（CG）所在那块屏的菜单栏露着没有。还没扫过时当作露着。
    func menuBarShown(at frame: CGRect) -> Bool {
        guard scannedOnce else { return true }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return shownScreens.contains { $0.contains(center) }
    }
    /// 图标图像缓存（看得见时抓的，已裁掉透明边），同时存在硬盘上。
    ///
    /// **每个图标只抓一次**：抓屏幕画面会让 macOS 在菜单栏亮起紫色的「正在捕捉你的屏幕」指示，
    /// 第一版每 3 秒抓一遍，指示一直亮着（2026-11-08 用户截图问「为什么多了一个这个」）。
    /// 现在只在某个图标第一次露面时抓，存进 ~/Library/Application Support/Baobox/MenuBar/Icons/，重启也不再抓。
    private(set) var images: [String: CGImage] = [:]

    private let queue = DispatchQueue(label: "com.baobox.menubar.scan", qos: .utility)
    private var running = false
    private var again = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var diskLoaded = false

    nonisolated static let iconsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Baobox/MenuBar/Icons", isDirectory: true)

    private init() {}

    func clear() {
        items = []
    }

    /// 后台扫一遍（菜单构建零 IO：菜单只读扫好的缓存）。
    func refresh() {
        Task { await refreshNow() }
    }

    /// 扫完才返回：挪图标、点图标前后要最新的位置。正在扫的话，等它扫完再扫一遍。
    func refreshNow() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
            if running {
                again = true
            } else {
                start()
            }
        }
    }

    private func start() {
        running = true
        let needsDisk = !diskLoaded
        diskLoaded = true
        let spacerWindowID = MenuBarManager.shared.spacer.windowID
        let known = Set(images.keys)
        queue.async {
            // 第一次扫之前先读硬盘上的图标：读到的就不用再抓了。
            let fromDisk = needsDisk ? Self.loadIcons() : [:]
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let scanner = MenuBarItemScanner.shared
                    for (key, image) in fromDisk where scanner.images[key] == nil { scanner.images[key] = image }
                    let input = ScanInput.current(spacerWindowID: spacerWindowID,
                                                  knownImageKeys: known.union(fromDisk.keys))
                    scanner.queue.async {
                        let result = Self.scan(input)
                        Self.saveIcons(result.images)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { MenuBarItemScanner.shared.finish(result) }
                        }
                    }
                }
            }
        }
    }

    /// 刚从「显示着」被判成「被挤掉」、还没确认的项：id → 第一次这么判的时间。
    private var pendingSqueezes: [String: Date] = [:]
    /// 连着丢掉了几次扫描结果。
    private var discardedInARow = 0
    private static let log = Logger(subsystem: "com.baobox.app", category: "menubar")

    private func finish(_ result: ScanResult) {
        for (key, image) in result.images { images[key] = image }
        // 换活跃屏的那一下扫到的不作数：图标窗口正在两块屏之间搬家，占位项和图标不在同一条菜单栏上，或者一些图标对不上窗口
        // （2026-11-09 用户截图：偶尔 Baobox 菜单最上面那一行整个没了；日志里换屏那一下的扫描把隐藏的图标全丢了）。
        // 沿用上一次的，0.3 秒后再扫，等着结果的也接着等；连着丢 4 次（约 1.6 秒）就照收，免得真有图标没了也一直不认。
        let lost = lostItems(result.items)
        if !items.isEmpty, discardedInARow < 4, !result.consistent || !lost.isEmpty {
            discardedInARow += 1
            again = false
            Self.log.notice("scan discarded (display switching?): consistent \(result.consistent), lost \(lost, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { MenuBarItemScanner.shared.start() }
            }
            return
        }
        discardedInARow = 0
        let settled = settleSqueezes(result.items)
        let hiddenBefore = items.filter { $0.state == .hidden }.count
        let hiddenNow = settled.filter { $0.state == .hidden }.count
        if hiddenNow != hiddenBefore {
            Self.log.notice("hidden icons \(hiddenBefore) → \(hiddenNow) (of \(settled.count))")
        }
        if items != settled { items = settled }
        shownScreens = result.shownScreens
        scannedOnce = true
        // 每次扫完都看一眼 Baobox 自己还在不在（落进隐藏区 / 被挤掉就挪回最右边）。
        MenuBarManager.shared.ensureBaoboxVisible()
        if again {
            again = false
            start()
            return
        }
        running = false
        let done = waiters
        waiters = []
        done.forEach { $0.resume() }
    }

    /// 上一次还在、这一次没扫到、App 也还在跑的图标。
    private func lostItems(_ fresh: [MenuBarItem]) -> [String] {
        let ids = Set(fresh.map(\.id))
        return items.filter { !ids.contains($0.id) && NSRunningApplication(processIdentifier: $0.pid) != nil }.map(\.id)
    }

    /// 从「显示着」变成「被挤掉」要连着几次扫描、隔 2 秒以上都这么判才算：换活跃屏时图标窗口在两块屏之间搬家，
    /// 那一下会把明明看得见的图标判成被挤掉（2026-11-08 外接屏自测：Wi-Fi 跑进了 Baobox 菜单顶部那一行）。
    private func settleSqueezes(_ fresh: [MenuBarItem]) -> [MenuBarItem] {
        let previous = Dictionary(items.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        var pending: [String: Date] = [:]
        let settled = fresh.map { item -> MenuBarItem in
            guard item.state == .squeezed, previous[item.id] == .visible else { return item }
            let since = pendingSqueezes[item.id] ?? now
            guard now.timeIntervalSince(since) < 2 else { return item }
            pending[item.id] = since
            return MenuBarItem(id: item.id, bundleID: item.bundleID, pid: item.pid, displayName: item.displayName,
                               frame: item.frame, windowID: item.windowID, state: .visible, onScreen: item.onScreen)
        }
        pendingSqueezes = pending
        return settled
    }

    // MARK: - 后台扫描

    struct ScreenInfo {
        /// CG 坐标。
        let frame: CGRect
        /// 菜单栏图标能显示的最左边：有刘海的屏是刘海右边那块的左边，没刘海的是屏幕左边。
        let visibleMinX: CGFloat
    }

    struct ScanInput {
        let myPID: pid_t
        let apps: [pid_t: (bundleID: String, name: String)]
        let screens: [ScreenInfo]
        /// 占位项的窗口号：它的位置从同一份窗口列表里取，和图标的位置是同一刻的。
        let spacerWindowID: CGWindowID?
        /// 已经有图像的项：不再抓（每抓一次菜单栏就亮一下录屏指示）。
        let knownImageKeys: Set<String>

        @MainActor
        static func current(spacerWindowID: CGWindowID?, knownImageKeys: Set<String>) -> ScanInput {
            var apps: [pid_t: (bundleID: String, name: String)] = [:]
            for app in NSWorkspace.shared.runningApplications {
                let bundle = app.bundleIdentifier ?? "pid\(app.processIdentifier)"
                apps[app.processIdentifier] = (bundle, app.localizedName ?? bundle)
            }
            let screens = NSScreen.screens.map { screen -> ScreenInfo in
                let frame = Geometry.cgRect(fromAppKit: screen.frame)
                // 水平方向 AppKit 与 CG 同一套 x，刘海右边那块的 minX 直接用。
                return ScreenInfo(frame: frame, visibleMinX: screen.auxiliaryTopRightArea?.minX ?? frame.minX)
            }
            return ScanInput(myPID: getpid(), apps: apps, screens: screens, spacerWindowID: spacerWindowID,
                             knownImageKeys: knownImageKeys)
        }
    }

    struct ScanResult {
        let items: [MenuBarItem]
        let images: [String: CGImage]
        let shownScreens: [CGRect]
        /// 占位项和各图标在同一条菜单栏上（换活跃屏的那一下，图标窗口正在两块屏之间搬家，会对不上）。
        let consistent: Bool
    }

    private struct Window {
        let id: CGWindowID
        let frame: CGRect
        let onScreen: Bool
    }

    private struct AXItem {
        let frame: CGRect
        let identifier: String?
        let title: String?
        let description: String?
    }

    /// 时间、控制中心图标和麦克风 / 摄像头的录音指示（隐私提示，用着才出现）系统不让挪，不列出来。
    /// 录音指示以前列着：它的窗口和别的图标不在同一条线上，录音期间每次扫描都判成「正在换屏」丢掉
    /// （每 3 秒连扫 5 次，会议多长就扫多久），停止录音它一消失又判成「图标丢了」再丢一轮。
    nonisolated private static let unmovable: Set<String> = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter",
                                                             "com.apple.menuextra.audiovideo"]

    nonisolated static func scan(_ input: ScanInput) -> ScanResult {
        let level = Int(CGWindowLevelForKey(.statusWindow))
        let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreenList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreenIDs = Set(onScreenList.compactMap { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } })

        var windowsByPID: [pid_t: [Window]] = [:]
        var spacerFrame: CGRect?
        for info in all {
            guard (info[kCGWindowLayer as String] as? Int) == level,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 0, frame.height > 0 else { continue }
            let id = CGWindowID(number)
            if id == input.spacerWindowID { spacerFrame = frame }
            guard pid != input.myPID else { continue }
            windowsByPID[pid, default: []].append(Window(id: id, frame: frame, onScreen: onScreenIDs.contains(id)))
        }
        var consistent = true
        // 每块屏的菜单栏露没露：那块屏顶上有没有在屏上的状态栏窗口（谁的都算）。收着的屏（全屏 App）上谁都不在屏上，
        // 那里的图标不算「被挤掉」，免得把它们都塞进顶部那一行。
        let statusOnScreen: [CGPoint] = onScreenList.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == level,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        let shownScreens = input.screens.map(\.frame).filter { screen in statusOnScreen.contains { screen.contains($0) } }

        var items: [MenuBarItem] = []
        var images: [String: CGImage] = [:]
        for (pid, windows) in windowsByPID {
            guard let app = input.apps[pid] else { continue }
            let axItems = axMenuBarItems(pid: pid).sorted { $0.frame.minX < $1.frame.minX }
            let single = axItems.count == 1
            for (index, ax) in axItems.enumerated() {
                if let identifier = ax.identifier, unmovable.contains(identifier) { continue }
                let center = CGPoint(x: ax.frame.midX, y: ax.frame.midY)
                // 同一处可能叠着两个窗口：外接屏上真正的图标窗口（24 高）和一个屏外的「替身」（37 高，同一个 x）。
                // 只有真的那个挪得动（2026-11-08：选成了替身，挪了没动，退回老办法，所有隐藏图标都露了出来）。
                // 图标按钮在自己的窗口里竖直居中：先挑在屏上的，再挑竖直中心离辅助功能给的中心最近的。
                let candidates = windows.filter { $0.frame.contains(center) }
                    .sorted { abs($0.frame.midY - center.y) < abs($1.frame.midY - center.y) }
                guard let window = candidates.first(where: \.onScreen) ?? candidates.first else { continue }

                let identity = single ? "item0" : (ax.identifier ?? nonEmpty(ax.title) ?? "item\(index)")
                let name = firstSegment(ax.description) ?? nonEmpty(ax.title) ?? app.name
                let screen = input.screens.first { $0.frame.intersects(window.frame) } ?? input.screens.first
                let inVisibleBand = screen.map {
                    window.frame.minX >= $0.visibleMinX - 1 && window.frame.maxX <= $0.frame.maxX + 1
                } ?? false
                let onScreen = window.onScreen && inVisibleBand
                let barShown = screen.map { shownScreens.contains($0.frame) } ?? false

                if let spacerFrame, abs(window.frame.minY - spacerFrame.minY) > 1 { consistent = false }
                let state: MenuBarItem.State
                if let spacerFrame, window.frame.maxX <= spacerFrame.minX + 2 {
                    state = .hidden
                } else if onScreen || !barShown {
                    state = .visible
                } else {
                    state = .squeezed
                }
                let key = app.bundleID + "|" + identity
                items.append(MenuBarItem(id: key, bundleID: app.bundleID, pid: pid, displayName: name,
                                         frame: window.frame, windowID: window.id, state: state, onScreen: onScreen))
                if onScreen, !input.knownImageKeys.contains(key), let image = captureIcon(window) {
                    images[key] = image
                }
            }
        }
        items.sort { $0.frame.minX < $1.frame.minX }
        return ScanResult(items: items, images: images, shownScreens: shownScreens, consistent: consistent)
    }

    // MARK: - 图标存盘（每个图标只抓一次，重启也不再抓）

    nonisolated private static func iconURL(_ key: String) -> URL {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return iconsDirectory.appendingPathComponent(safe + ".png")
    }

    nonisolated private static func saveIcons(_ icons: [String: CGImage]) {
        guard !icons.isEmpty else { return }
        try? FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        for (key, image) in icons {
            guard let destination = CGImageDestinationCreateWithURL(iconURL(key) as CFURL, "public.png" as CFString,
                                                                    1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        // 键名里的「|」写进文件名时换成了「_」，读回来时按这份清单对上。
        var index = (NSDictionary(contentsOf: iconsDirectory.appendingPathComponent("index.plist")) as? [String: String]) ?? [:]
        for key in icons.keys { index[iconURL(key).lastPathComponent] = key }
        (index as NSDictionary).write(to: iconsDirectory.appendingPathComponent("index.plist"), atomically: true)
    }

    nonisolated private static func loadIcons() -> [String: CGImage] {
        guard let index = NSDictionary(contentsOf: iconsDirectory.appendingPathComponent("index.plist")) as? [String: String] else {
            return [:]
        }
        var icons: [String: CGImage] = [:]
        for (file, key) in index {
            let url = iconsDirectory.appendingPathComponent(file)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            icons[key] = image
        }
        return icons
    }

    // MARK: - 抓图

    /// 单抓这一个图标窗口（透明底），再裁掉四周的透明边；全透明（没画东西）返回 nil。
    nonisolated private static func captureIcon(_ window: Window) -> CGImage? {
        guard let image = CGWindowListCreateImage(window.frame, .optionIncludingWindow, window.id,
                                                  [.boundsIgnoreFraming, .bestResolution]) else { return nil }
        return trimmed(image)
    }

    nonisolated private static func trimmed(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 12 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // 位图行序自上而下，和 CGImage 裁剪的坐标一致；四周留 1 像素。
        let rect = CGRect(x: max(0, minX - 1), y: max(0, minY - 1),
                          width: min(w, maxX + 2) - max(0, minX - 1), height: min(h, maxY + 2) - max(0, minY - 1))
        return image.cropping(to: rect)
    }

    // MARK: - 辅助功能

    /// 菜单栏属主 App 的菜单（文件 / 编辑…）的右端（CG 坐标，最右那个菜单的右边缘、竖直居中）：菜单越过刘海时，图标只能露在它后面。
    /// 给的是一个点而不只是 x：多显示器上下摆放时各屏的 x 范围会重叠，要按点判断在哪块屏上。
    nonisolated static func appMenusEnd(pid: pid_t) -> CGPoint? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar = element(app, kAXMenuBarAttribute), let children = elements(bar, kAXChildrenAttribute) else {
            return nil
        }
        return children.compactMap { child -> CGPoint? in
            guard let position = point(child, kAXPositionAttribute), let size = size(child, kAXSizeAttribute),
                  size.width > 0 else { return nil }
            return CGPoint(x: position.x + size.width, y: position.y + size.height / 2)
        }.max { $0.x < $1.x }
    }

    // MARK: - 多显示器

    /// 鼠标所在的那块屏（CG 坐标）。
    static func screenUnderMouse() -> CGRect? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }.map { Geometry.cgRect(fromAppKit: $0.frame) }
    }

    /// 每块屏的菜单栏上都有一份同样的图标（同一进程，各屏各一个窗口）。辅助功能、`statusItem.button.window` 给的
    /// （扫描、挪动用的）是**当前活跃那块屏**上的那份 —— 前台 App 的窗口所在、菜单栏不变暗的那块；活跃屏一换，这个窗口
    /// 连同窗口号一起搬到新的那块屏上（2026-11-08 外接屏自测）。
    /// 这里找同一个图标在 target 那块屏上的那份：各屏都从右边排起，同一个图标离屏幕右边的距离几乎一样
    /// （2026-11-08 实测外接屏比内建屏多 2px），按这个估位置；还要同宽、离估计位置不超过半个图标 —— 宁可找不到也不点错别的 App。
    /// target 就是它自己那块屏，或那块屏上它被挤掉了（不在屏上），返回 nil。
    static func replicaFrame(pid: pid_t, of mainFrame: CGRect, onScreen target: CGRect) -> CGRect? {
        let screens = NSScreen.screens.map { Geometry.cgRect(fromAppKit: $0.frame) }
        guard let home = screens.first(where: { $0.contains(CGPoint(x: mainFrame.midX, y: mainFrame.midY)) }),
              home != target else { return nil }
        let estimate = target.maxX - (home.maxX - mainFrame.minX)
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var best: (frame: CGRect, distance: CGFloat)?
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == statusLevel,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(frame.minY - target.minY) < 1, frame.height <= 40,
                  frame.minX >= target.minX - 1, frame.maxX <= target.maxX + 1,
                  abs(frame.width - mainFrame.width) <= 1 else { continue }
            let distance = abs(frame.minX - estimate)
            if distance < (best?.distance ?? .greatestFiniteMagnitude) { best = (frame, distance) }
        }
        guard let best, best.distance <= mainFrame.width / 2 else { return nil }
        return best.frame
    }

    nonisolated private static func axMenuBarItems(pid: pid_t) -> [AXItem] {
        let app = AXUIElementCreateApplication(pid)
        // 对方卡住时别把扫描拖住（默认要等好几秒）。
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = element(app, kAXExtrasMenuBarAttribute),
              let children = elements(bar, kAXChildrenAttribute) else { return [] }
        return children.compactMap { child -> AXItem? in
            guard let position = point(child, kAXPositionAttribute),
                  let size = size(child, kAXSizeAttribute), size.width > 0, size.height > 0 else { return nil }
            return AXItem(frame: CGRect(origin: position, size: size),
                          identifier: string(child, kAXIdentifierAttribute),
                          title: string(child, kAXTitleAttribute),
                          description: string(child, kAXDescriptionAttribute))
        }
    }

    nonisolated private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// 用辅助功能「按一下」frame 处的那个菜单栏图标（读屏软件打开菜单栏图标的方式）：不动鼠标、不看指针在哪。
    /// 返回动作发出去了没有；App 可能在处理动作时进入菜单的事件循环，调用会等到超时才返回，所以放在后台调。
    nonisolated static func axPress(pid: pid_t, at frame: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = element(app, kAXExtrasMenuBarAttribute), let children = elements(bar, kAXChildrenAttribute) else {
            return false
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for child in children {
            guard let position = point(child, kAXPositionAttribute), let size = size(child, kAXSizeAttribute),
                  CGRect(origin: position, size: size).insetBy(dx: -2, dy: -8).contains(center) else { continue }
            let result = AXUIElementPerformAction(child, kAXPressAction as CFString)
            return result == .success || result == .cannotComplete
        }
        return false
    }

    nonisolated private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    nonisolated private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        value(element, attribute) as? [AXUIElement]
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    nonisolated private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) else { return nil }
        return point
    }

    nonisolated private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else { return nil }
        return size
    }

    nonisolated private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    /// 系统项的描述带状态（「Wi‑Fi，已接入，3格」），名字取第一段。
    nonisolated private static func firstSegment(_ text: String?) -> String? {
        guard let text = nonEmpty(text) else { return nil }
        let first = text.split(whereSeparator: { $0 == "，" || $0 == "," }).first.map(String.init) ?? text
        return nonEmpty(first)
    }
}
