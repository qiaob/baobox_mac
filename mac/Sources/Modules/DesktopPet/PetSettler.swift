import AppKit

/// 找个不碍事的地方待着（docs/desktop-pet/SETTLE.md §4）：
/// - 切换 App / 桌面 / 屏幕后、窗口挪过来以后发现自己挡住了正在用的窗口：让开（近的走过去，远的跳 / 钻黑洞过去）；
/// - 你在它旁边连着点：你在那儿干活，让开；
/// - 「安静 / 适中」隔一阵子换个同样不碍事的地方（换换风景）；
/// - 你亲手把它放到哪，就先在那儿待着：10 分钟内不自己挪（切了 App 后挡住了、在它旁边连着点除外）。
/// 只决定去哪、怎么去；走路、跳、散步一两步由引擎做，黑洞由控制器播。
@MainActor
final class PetSettler {
    struct Environment {
        /// 宠物开着、显示着、没借给休息画面、没在出场退场 / 换形象。
        var isAvailable: () -> Bool
        /// 宠物窗边长、脚离窗口底边多远、身子占窗口的宽 / 高比例。
        var metrics: () -> (side: CGFloat, footInset: CGFloat, bodyWidth: CGFloat, bodyHeight: CGFloat)
        var petFrame: () -> NSRect
        var windows: () -> [PetWindowInfo]
        var ledges: () -> [PetLedge]
        /// 远处的空地：钻进黑洞，从那儿冒出来。
        var transit: (NSPoint) -> Void
    }

    private let engine: PetEngine
    private let env: Environment
    private let blankness = PetBlankness()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?
    private var pending: DispatchWorkItem?
    private var recentClicks: [(point: NSPoint, at: Date)] = []
    /// 最近用过的 App 什么时候还在前台（切走的那一刻）。
    private var lastActive: [pid_t: Date] = [:]
    private var activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private var badChecks = 0
    /// 你亲手放的：这之前不自己挪。
    private var pinnedUntil = Date.distantPast
    /// 刚挪完 / 刚落地 / 刚看过没必要挪：这之前不再评估，免得来回折腾。
    private var calmUntil = Date.distantPast
    /// 上一次挪窝：之后 60 秒里每 2 秒的「挡着没有」不看（切换 App / 桌面、在旁边点照样看）。
    private var lastMoveAt = Date.distantPast
    private var nextVarietyAt = Date.distantFuture
    /// 事件触发的「让开」（切 App、旁边连点、睡醒）碰上宠物正忙（气泡开着、在做互动、在空中、还没醒）：记下来，
    /// 能挪了马上补做（20 秒内有效）。不然这次就丢了 —— 碍事分没到「该让开」的程度时，之后就一直挡着。
    private var pendingUrgent: (reason: String, until: Date)?

    /// 「挡着」：碍事分到这个数（身子一多半挡在正在用的窗口上）。2026-11-07 试用「挪得太勤」后从 0.45 调高。
    private static let badThreshold = 0.55
    /// 连续几次（每 2 秒一次）都挡着才挪：窗口拖过、鼠标点一下切过去都不算。
    private static let badChecksNeeded = 3
    /// 新地方至少要好这么多才挪。
    private static let gain = 0.15

    init(engine: PetEngine, environment: Environment) {
        self.engine = engine
        self.env = environment
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                               queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                self?.appActivated(pid)
                self?.contentChanged(reason: "app switch", delay: 0.8)
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.contentChanged(reason: "space switch", delay: 1.0) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.contentChanged(reason: "screens changed", delay: 1.5) }
        })
        // 点在别的 App 上的鼠标（点到宠物身上的归宠物窗自己处理，不在这里）：只看位置，不看点了什么。
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.noteClick(at: NSEvent.mouseLocation) }
            }
        }
        scheduleVariety()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// 走动方式 / 不挡我 / 识别屏幕内容改了。
    func settingsChanged() {
        badChecks = 0
        blankness.invalidate()
        scheduleVariety()
    }

    /// 你把它拖到这儿放下：先在这儿待着。
    func noteDropped() {
        pinnedUntil = Date().addingTimeInterval(600)
        calmUntil = Date().addingTimeInterval(3)
        badChecks = 0
    }

    /// 走到了 / 落地了 / 被黑洞送到了。
    func noteArrived() {
        calmUntil = max(calmUntil, Date().addingTimeInterval(5))
        badChecks = 0
    }

    /// 过一会儿看看是不是挡住了（系统唤醒后屏幕和窗口都可能变了）。
    func recheck(reason: String, after delay: TimeInterval) {
        contentChanged(reason: reason, delay: delay)
    }

    // MARK: - 什么时候看

    /// 切到了另一个 App：刚切走的那个记下时间（它的窗口十分钟内还算「在用」）。Baobox 自己（设置窗口）不算。
    private func appActivated(_ pid: pid_t?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let now = Date()
        if let previous = activePID, previous != pid { lastActive[previous] = now }
        activePID = pid
        lastActive = lastActive.filter { now.timeIntervalSince($0.value) < 600 }
    }

    /// 刚用过的 App 的窗口算几分：刚切走 0.9，十分钟内线性降回 0.35。
    private func recentWeights() -> [pid_t: Double] {
        let now = Date()
        var weights: [pid_t: Double] = [:]
        for (pid, at) in lastActive {
            let age = now.timeIntervalSince(at)
            if age < 600 { weights[pid] = 0.35 + 0.55 * (1 - age / 600) }
        }
        return weights
    }

    /// 画面换了：等窗口摆好再看是不是挡住了正在用的窗口。你亲手放的也看；要让就快点让（跑过去）。
    private func contentChanged(reason: String, delay: TimeInterval) {
        blankness.invalidate()
        schedule(after: delay) { [weak self] in
            self?.evaluate(reason: reason, variety: false, ignoringPin: true, urgent: true)
        }
    }

    /// 散步前问一声：这个位置不比现在更碍事、也不算「挡着」才去（不然刚挪过去又被拉回来）。
    func strollAcceptable(_ origin: NSPoint) -> Bool {
        guard PetSettings.avoidsActiveWindow else { return true }
        let scorer = makeScorer(withPixels: true)
        let there = scorer.cost(at: origin)
        return there < Self.badThreshold && there <= scorer.cost(at: engine.origin) + 0.05
    }

    /// 「活泼」上下左右溜达：只要不碍事（没到「该让开」的程度）就能去，不要求比现在更空 ——
    /// 落到那儿也不会被「让开」马上拉回来。
    func roamAcceptable(_ origin: NSPoint) -> Bool {
        guard PetSettings.avoidsActiveWindow else { return true }
        return makeScorer(withPixels: true).cost(at: origin) < Self.badThreshold
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 在宠物旁边点了一下（点击穿透到了下面的窗口）：8 秒内点了两下就是在那儿干活，让开。
    private func noteClick(at point: NSPoint) {
        guard PetSettings.avoidsActiveWindow, env.isAvailable() else { return }
        let side = env.metrics().side
        guard env.petFrame().insetBy(dx: -side * 0.25, dy: -side * 0.1).contains(point) else { return }
        let now = Date()
        recentClicks.removeAll { now.timeIntervalSince($0.at) > 8 }
        recentClicks.append((point, now))
        guard recentClicks.count >= 2 else { return }
        schedule(after: 0.4) { [weak self] in
            self?.evaluate(reason: "clicks next to it", variety: false, ignoringPin: true, urgent: true)
        }
    }

    /// 每 2 秒：挡着正在用的窗口连续三次（6 秒，窗口只是拖过去不算）就慢慢走开；刚挪过的 60 秒内不看。
    /// 到点了换换风景。
    private func tick() {
        let now = Date()
        recentClicks.removeAll { now.timeIntervalSince($0.at) > 8 }
        guard env.isAvailable(), engine.canRelocate, !engine.isHeadingSomewhere, now >= calmUntil else {
            badChecks = 0
            return
        }
        if let pending = pendingUrgent {
            pendingUrgent = nil
            if now < pending.until {
                evaluate(reason: pending.reason + " (retry)", variety: false, ignoringPin: true, urgent: true)
                return
            }
        }
        if PetSettings.avoidsActiveWindow, now >= pinnedUntil, now.timeIntervalSince(lastMoveAt) >= 60 {
            let scorer = makeScorer(withPixels: true)
            badChecks = scorer.cost(at: engine.origin) >= Self.badThreshold ? badChecks + 1 : 0
            if badChecks >= Self.badChecksNeeded {
                badChecks = 0
                evaluate(reason: "covering the active window", variety: false, ignoringPin: false, urgent: false)
                return
            }
        }
        if now >= nextVarietyAt {
            scheduleVariety()
            if now >= pinnedUntil {
                evaluate(reason: "change of scenery", variety: true, ignoringPin: false, urgent: false)
            }
        }
    }

    /// 换换风景的间隔：安静 12–25 分钟，适中 4–8 分钟；不走动 / 活泼不换（活泼本来就到处走）。
    private func scheduleVariety() {
        let now = Date()
        switch PetSettings.activity {
        case .calm: nextVarietyAt = now.addingTimeInterval(Double.random(in: 720...1500))
        case .normal: nextVarietyAt = now.addingTimeInterval(Double.random(in: 240...480))
        case .still, .lively: nextVarietyAt = .distantFuture
        }
    }

    // MARK: - 去哪

    private func makeScorer(withPixels: Bool) -> PetSpotScorer {
        let m = env.metrics()
        let pixels = withPixels && PetBlankness.isAvailable
        let blankness = self.blankness
        var scorer = PetSpotScorer(side: m.side, footInset: m.footInset, bodyWidth: m.bodyWidth,
                                   bodyHeight: m.bodyHeight, windows: env.windows(),
                                   activePID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                   recentClicks: recentClicks.map(\.point),
                                   busyness: pixels ? { blankness.busyness(of: $0) } : nil)
        scorer.recentWeights = recentWeights()
        return scorer
    }

    private func evaluate(reason: String, variety: Bool, ignoringPin: Bool, urgent: Bool, usePixels: Bool = true) {
        guard env.isAvailable(), engine.canRelocate, let screen = engine.screen else {
            if urgent { pendingUrgent = (reason, Date().addingTimeInterval(20)) }
            return
        }
        if urgent { pendingUrgent = nil }
        let now = Date()
        if !ignoringPin, now < pinnedUntil { return }
        if !variety, !PetSettings.avoidsActiveWindow { return }
        let m = env.metrics()
        let visible = engine.screenVisibleFrame
        // 随意放没有重力：整个屏幕上下左右都找；其余沿地面（和窗口顶边）找。
        var spots = engine.range == .screen
            ? PetSpotScorer.freeCandidates(visible: visible, side: m.side)
            : PetSpotScorer.candidates(line: engine.floorLine(), ledges: env.ledges(),
                                       includeLedges: engine.range == .windows, side: m.side,
                                       footInset: m.footInset, visible: visible)
        guard !spots.isEmpty else { return }
        let hasPixels = PetBlankness.isAvailable && blankness.isFresh(for: screen)
        let scorer = makeScorer(withPixels: hasPixels)
        for index in spots.indices { spots[index].cost = scorer.cost(at: spots[index].origin) }
        let current = scorer.cost(at: engine.origin)
        let bestCost = spots.map(\.cost).min() ?? 0
        // 按窗口位置找不到空桌面：看一眼屏幕内容再决定（截好了再评估一次）。
        if usePixels, !hasPixels, PetBlankness.isAvailable, bestCost > 0.25, variety || current >= 0.3 {
            blankness.refresh(screen: screen) { [weak self] in
                self?.evaluate(reason: reason, variety: variety, ignoringPin: ignoringPin, urgent: urgent,
                               usePixels: false)
            }
            return
        }

        let origin = engine.origin
        let ledge = engine.currentLedgeID
        let width = max(visible.width, 1), height = max(visible.height, 1)
        let mouse = NSEvent.mouseLocation
        // 排序时的小偏好：近的、不用换台面的、不在鼠标跟前的优先（鼠标只影响挑哪儿，不会因为鼠标靠近就跑）。
        func preference(_ spot: PetSpot) -> Double {
            var value = Double(abs(spot.origin.x - origin.x) / width) * 0.12
                + Double(abs(spot.origin.y - origin.y) / height) * 0.1
                + (spot.ledgeID == ledge ? 0 : 0.03)
            let body = scorer.body(at: spot.origin)
            let reach = max(body.height, 80)
            let toMouse = hypot(max(body.minX - mouse.x, 0, mouse.x - body.maxX), max(body.minY - mouse.y, 0, mouse.y - body.maxY))
            if toMouse < reach { value += 0.2 * Double(1 - toMouse / reach) }
            return value
        }

        if variety {
            // 换个同样不碍事的地方：离开至少一个半身位，近的机会大一些。
            let minimum = m.side * m.bodyWidth * 1.5
            let options = spots.filter {
                $0.cost <= bestCost + 0.05 && $0.cost <= current + 0.02 && abs($0.origin.x - origin.x) >= minimum
            }
            let weights = options.map { 1 / (1 + Double(abs($0.origin.x - origin.x)) / 400) }
            guard !options.isEmpty else { return }
            var pick = Double.random(in: 0..<weights.reduce(0, +))
            for (option, weight) in zip(options, weights) {
                if pick < weight {
                    move(to: option, hurry: false, reason: reason, from: current)
                    return
                }
                pick -= weight
            }
            if let last = options.last { move(to: last, hurry: false, reason: reason, from: current) }
            return
        }

        guard let best = spots.min(by: { $0.cost + preference($0) < $1.cost + preference($1) }) else { return }
        if current >= 0.3, current - best.cost >= Self.gain {
            move(to: best, hurry: urgent, reason: reason, from: current)
        } else {
            // 这儿就挺好 / 没有更好的：过一阵子再看（画面里找过空白的话多等一会儿，免得老截屏）。
            calmUntil = max(calmUntil, now.addingTimeInterval(hasPixels ? 20 : 8))
        }
    }

    /// 怎么去（SETTLE.md §4.3–4.4）：近的按路线过去 —— 同一个台面走过去；随意放、地面 ↔ 窗口顶，够得着的跳过去，
    /// 太高太低的背火箭飞过去。路太远、高低差大到火箭也要飞很久、排不出路线的钻黑洞过去。
    /// 让路（切换 App / 桌面、旁边连着点）时跑过去，其余慢慢走。
    private func move(to spot: PetSpot, hurry: Bool, reason: String, from current: Double) {
        let origin = engine.origin
        let side = env.metrics().side
        let dx = abs(spot.origin.x - origin.x), dy = abs(spot.origin.y - origin.y)
        // 换高度（随意放上下挪、地面 ↔ 窗口顶两个方向）都要在火箭飞得过去的范围里，太高太远钻黑洞。
        let changesLevel = engine.range == .screen ? dy > 2 : spot.ledgeID != engine.currentLedgeID
        let nearEnough = dx <= max(700, side * 4) && (!changesLevel || dy <= max(600, side * 4.5))
        PetLog.log.info("relocate (\(reason, privacy: .public)): cost \(current, format: .fixed(precision: 2)) → \(spot.cost, format: .fixed(precision: 2)), dx \(Int(dx)) dy \(Int(dy))")
        if !(nearEnough && engine.travel(to: spot.origin, ledgeID: spot.ledgeID, hurry: hurry)) {
            env.transit(spot.origin)
        }
        calmUntil = Date().addingTimeInterval(6)
        lastMoveAt = Date()
        badChecks = 0
        pinnedUntil = .distantPast
    }
}
