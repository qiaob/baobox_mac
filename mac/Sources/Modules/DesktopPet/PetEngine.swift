import AppKit
import Foundation

/// 宠物某一帧的姿态：渲染层只读它，不关心状态机（设计 §7 的解耦点）。
struct PetPose {
    var state: PetEngine.State = .idle
    var facingLeft = false
    var walkPhase: Double = 0
    var time: Double = 0
    var bob: CGFloat = 0
    var bounce: CGFloat = 0
    var eyesClosed = false
    var lying = false
    /// 有气泡 / 菜单 / 互动时站住面向用户。
    var attentive = false
    /// 赶路：挡住正在用的窗口要让开时走得快一些（3D 走路片段跟着加速，脚不打滑）。
    var hurry = false
}

/// 宠物行为状态机（设计 §6；活动范围与窗口互动见 docs/desktop-pet/ROAM.md）。只产出窗口位置与姿态，不管 2D / 3D 怎么画。
///
/// 宠物总是「站在」某个台面上：
/// - 随意放（`.screen`，原来的行为）：停在被放下的高度，没有重力；
/// - 地面：屏幕可见区底边，或自定义区域的底边；
/// - 窗口顶边（`.windows`）：别的 App 窗口没被挡住的那段顶边。窗口挪了跟着挪，没了就掉下来。
/// 在空中时（跳上窗口、被拖到半空松手、窗口没了）沿抛物线 / 重力落到下面的台面。
@MainActor
final class PetEngine {
    enum State {
        case idle, wander, sleep, notify, dragged
        /// 跳向某个台面（跳上窗口、跳下窗口、跳回自定义区域）。
        case jump
        /// 往下掉（拖到半空松手、脚下的窗口没了）。
        case fall
        /// 趴在窗口顶边上休息。
        case rest
        /// 出场 / 退场动画进行中（#54，docs/desktop-pet/ENTRANCE.md）：位置与外观由控制器给的脚本逐帧决定，
        /// 不溜达、不睡、不跳窗口。渲染层看到的是脚本给的「外观状态」（跳 / 落 / 站 / 提醒），不会是这两个。
        case entering, leaving
        /// 踩着脚下冒出来的台阶上下（docs/desktop-pet/SETTLE.md §4.4）：随意放时去别的高度、窗口模式沿窗口侧边上窗口顶。
        case climb
        /// 在地上歇会儿：蹲着或坐在地上（docs/desktop-pet/SETTLE.md §5.5）。
        case lounge
    }

    /// 出场 / 退场脚本的一帧。
    struct ScriptFrame {
        var origin: NSPoint
        /// 这一帧渲染层按哪个状态画（jump / fall / idle / notify / wander）。
        var look: State
        var attentive: Bool
        var bounce: CGFloat = 0
        var facingLeft: Bool?
    }

    private(set) var state: State = .idle
    private(set) var pose = PetPose()
    private(set) var origin = NSPoint.zero

    /// 每帧回调：（姿态， 窗口左下角屏幕坐标）。
    var onPose: ((PetPose, NSPoint) -> Void)?

    /// 宠物窗边长（方窗）。
    var petSize: CGFloat = 104
    /// 走路时宠物窗每秒挪多少点（3D 形象按步幅算，脚不打滑）。
    var walkSpeed: CGFloat = 34
    /// 脚底离宠物窗底边多少点（站在台面上时窗口底边 = 台面高度 − 它）。
    var footInset: CGFloat = 0
    /// 活动范围与自定义区域（屏幕坐标）。
    var range: PetRange = .bottom
    var customRect: NSRect?
    /// 窗口顶边从哪儿来（`.windows` 时由控制器接上窗口观察器）。
    var ledges: (() -> [PetLedge])?

    /// 走动方式（docs/desktop-pet/SETTLE.md §2）。「活泼」= 原来的随机溜达、自己跳窗口；
    /// 「安静 / 适中」只在家附近挪一两步，去哪儿由控制器找空地决定（`walk(toX:)` / `hop(to:)`）。
    var activity: PetActivity = .calm {
        didSet {
            guard activity != oldValue else { return }
            nextStrollAt = Date().addingTimeInterval(strollInterval)
            if activity == .still, state == .wander, walkTarget == nil { state = .idle }
        }
    }
    /// 落脚点：散步围着它挪一两步。落地、走到控制器给的地方、被拖到哪，就是哪。
    private(set) var homeX: CGFloat?
    /// 随意放时家的高度（上下散步围着它，不会越踩越高）。
    private var homeY: CGFloat?
    /// 当前这条路线是散步（上下踩几级），走完不算搬家。
    private var routeIsStroll = false
    /// 要走到的 x（控制器找好的空地，或散步挪的几步）；nil = 没有。
    private var walkTarget: CGFloat?
    /// 当前这趟是散步（走到了不算搬家）。
    private var walkIsStroll = false
    private var hurry = false
    private var nextStrollAt = Date().addingTimeInterval(30)
    /// 走到了控制器给的地方。
    var onArrive: (() -> Void)?
    /// 散步前问一声这个位置（宠物窗左下角）碍不碍事：碍事的不去（不然刚挪过去又被「让开」拉回来，两头打架）。
    var strollFilter: ((NSPoint) -> Bool)?
    /// 形象会不会蹲 / 坐地（有这些片段的 VRM），控制器设。
    var canLounge = false
    /// 站起来要多久（渲染层播起身片段的时长），这期间引擎不动。
    var loungeExitDuration: TimeInterval = 1.2
    private var nextLoungeAt = Date().addingTimeInterval(Double.random(in: 120...240))
    /// 隔多久歇一回：安静 3–7 分钟，适中 5–10 分钟。
    private var loungeInterval: TimeInterval {
        activity == .normal ? Double.random(in: 300...600) : Double.random(in: 180...420)
    }
    /// 用户拖着松手了（控制器据此让它在那儿先待着，不急着挪走）。
    var onDropped: (() -> Void)?

    /// 系统睡眠 / 熄屏期间停掉每帧定时器（docs/desktop-pet/WAKE.md）：DarkWake 时进程也会被唤起来跑一会儿，
    /// 没必要对着黑屏换动作、攒一堆没渲染的片段切换。
    private(set) var isSuspended = false

    private var timer: Timer?
    private var stateUntil: Date?
    private var nextWanderAt = Date().addingTimeInterval(6)
    private var blinkStart = Date().addingTimeInterval(2.5)
    private var walkDirection: CGFloat = 1
    private var notifyStartedAt: Date?
    private var notifyUntil: Date?
    private var notifyDuration: TimeInterval = 1
    /// 有气泡或环形菜单开着：站住不溜达、面向用户。
    private var held = false
    /// 互动动作（摸摸 / 喂食…）播放中：同样不溜达、不进入睡觉。
    private var busyUntil = Date.distantPast

    // MARK: 台面与飞行

    private enum Surface: Equatable {
        /// 随意放：没有台面，不受重力。
        case free
        /// 地面（屏幕底边 / 自定义区域底边）。
        case floor
        /// 某个窗口的顶边。
        case ledge(CGWindowID)
    }

    private struct Flight {
        let from: NSPoint
        let to: NSPoint
        let start: Date
        let duration: TimeInterval
        /// 抛物线在起止连线之上再高出多少点（0 = 直线）。
        let apex: CGFloat
        let landing: Surface
    }

    private var surface: Surface = .free
    private var flight: Flight?
    /// 自由落体（没有目标台面时用重力，每帧找脚下的台面）。
    private var fallVelocity: CGFloat?
    /// 站在窗口上时上一帧那个窗口的左下角（窗口被拖动时宠物跟着挪）。
    private var ledgeAnchor: NSPoint?
    private var nextClimbAt = Date().addingTimeInterval(Double.random(in: 120...300))
    private var leaveLedgeAt = Date.distantFuture
    private var nextRestAt = Date.distantFuture

    private static let gravity: CGFloat = 2600

    // MARK: 出场 / 退场脚本（#54）

    /// 返回 nil = 脚本结束（之后不再调用）。
    private var script: ((Date) -> ScriptFrame?)?
    private var scriptState: State = .entering
    /// 换脚本时递增：旧脚本在 tick 里返回 nil 时，不能把刚换上的新脚本清掉。
    private var scriptGeneration = 0

    var isScripted: Bool { script != nil }

    /// 接管位置与外观，直到脚本返回 nil。正在跳 / 掉的打断（出场从屏幕外开始，不接着原来的抛物线）。
    func runScript(as state: State, _ frame: @escaping (Date) -> ScriptFrame?) {
        flight = nil
        fallVelocity = nil
        stateUntil = nil
        script = frame
        scriptState = state
        scriptGeneration += 1
        self.state = state
    }

    /// 脚本结束后宠物站在哪儿（退场完把位置放回原处，下次出场从这里开始、位置也照常记住）。
    func endScript(at point: NSPoint?) {
        script = nil
        scriptGeneration += 1
        if let point { origin = point }
        if state == .entering || state == .leaving { state = .idle }
        nextWanderAt = max(nextWanderAt, Date().addingTimeInterval(4))
    }

    func start(at origin: NSPoint) {
        self.origin = origin
        settle(animated: false)
        homeX = self.origin.x
        homeY = self.origin.y
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 系统要睡了 / 屏幕熄了：停掉每帧定时器（位置、状态原样留着）。
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        timer?.invalidate()
        timer = nil
    }

    /// 醒了：接着跑。勿扰 / 空闲马上重新判断（睡前的结果早就过期了）。
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        sleepCheckedAt = .distantPast
        startTimer()
    }

    // MARK: - 挪窝（控制器找好空地后调用，docs/desktop-pet/SETTLE.md §4）

    /// 现在能不能挪：站着 / 走着 / 趴着 / 坐着蹲着，没被拖、不在空中、没在出场退场、没睡、没被气泡菜单拴住、没在做互动。
    var canRelocate: Bool {
        guard script == nil, !isSuspended, !held, Date() >= busyUntil, flight == nil, fallVelocity == nil else {
            return false
        }
        return state == .idle || state == .wander || state == .rest || state == .lounge
    }

    /// 正在赶往控制器给的地方（散步不算）：这期间控制器不再重新挑地方。
    var isHeadingSomewhere: Bool { !route.isEmpty || state == .climb || (walkTarget != nil && !walkIsStroll) }

    /// 沿脚下的台面走到 `x`（宠物窗左下角）。趴着 / 坐着的先起来。
    func walk(toX x: CGFloat, hurry: Bool) {
        route = []
        walkTarget = x
        walkIsStroll = false
        self.hurry = hurry
        if state == .rest || state == .lounge { state = .idle }
        stateUntil = nil
    }

    /// 跳到另一个台面上（地面 ↔ 窗口顶边）的这个位置：`ledgeID` 为 nil 是地面。
    func hop(to destination: NSPoint, ledgeID: CGWindowID?) {
        route = []
        walkTarget = nil
        let landing: Surface = ledgeID.map { .ledge($0) } ?? .floor
        jump(to: destination, landing: landing, apex: max(60, abs(destination.y - origin.y) * 0.25 + 60))
    }

    /// 直接放到这里（远处的空地由黑洞送过去之后）：找脚下的台面站稳，这里就是新家。
    func place(at point: NSPoint) {
        endClimb()
        route = []
        origin = point
        flight = nil
        fallVelocity = nil
        walkTarget = nil
        settle(animated: false)
        homeX = origin.x
        homeY = origin.y
        nextStrollAt = Date().addingTimeInterval(strollInterval)
    }

    // MARK: 路线：走 / 踩台阶 / 迈上窗口顶 / 从窗口顶跳下（docs/desktop-pet/SETTLE.md §4.4）

    private enum Leg {
        /// 沿脚下的台面走到这个 x（宠物窗左下角）。
        case walk(CGFloat)
        /// 踩着脚下冒出来的台阶上 / 下到这个 y（宠物窗左下角）。
        case climb(CGFloat)
        /// 小跳一下迈到这里、站上这个台面（爬到窗口顶以后迈上去）。nil = 地面。
        case step(NSPoint, CGWindowID?)
        /// 从窗口顶边的一头蹦出去，落空以后重力接着往下掉；参数是起跳落点的 x。
        case drop(CGFloat)
    }

    private var route: [Leg] = []
    private var climbTargetY: CGFloat?
    private var lastStepFeetY: CGFloat = 0
    /// 每踩一级台阶身子抬高多少点、走两级要多久（3D 按踏台阶片段，控制器设）。
    var climbStepRise: CGFloat = 16
    var climbCycle: TimeInterval = 1.0
    private var climbSpeed: CGFloat { climbStepRise * 2 / CGFloat(max(climbCycle, 0.2)) }
    /// 台阶：脚下要冒一级（脚底中点的屏幕坐标、往上还是往下）/ 爬完了（控制器据此画台阶、收台阶）。
    var onClimbStep: ((NSPoint, Bool) -> Void)?
    var onClimbEnd: (() -> Void)?

    /// 去这个落脚点（宠物窗左下角）：
    /// - 随意放：先踩台阶到那个高度，再走过去；
    /// - 同一个台面：直接走；
    /// - 地面 → 窗口顶：走到那个窗口的侧边，踩台阶上去，迈上顶边，再走到位；
    /// - 窗口顶 → 地面：走到这段顶边离目标近的那一头跳下去，落地后走过去。
    /// 排不出路线（窗口顶 → 别的窗口顶、窗口两侧都在屏幕外）返回 false，由控制器钻黑洞过去。
    func travel(to point: NSPoint, ledgeID: CGWindowID?, hurry: Bool) -> Bool {
        var legs: [Leg] = []
        if range == .screen {
            if abs(point.y - origin.y) > 1 { legs.append(.climb(point.y)) }
            if abs(point.x - origin.x) > 1 { legs.append(.walk(point.x)) }
        } else if ledgeID == currentLedgeID {
            legs = [.walk(point.x)]
        } else if currentLedgeID == nil, let id = ledgeID, let ledge = ledges?().first(where: { $0.id == id }) {
            guard let plan = climbLegs(onto: ledge, target: point) else { return false }
            legs = plan
        } else if let id = currentLedgeID, ledgeID == nil, let ledge = ledges?().first(where: { $0.id == id }),
                  let segment = ledge.segment(containing: feet.x) {
            let center = point.x + petSize / 2
            let toLeft = abs(segment.lowerBound - center) <= abs(segment.upperBound - center)
            let span = walkSpan()
            let edge = toLeft ? segment.lowerBound - petSize * 0.2 : segment.upperBound + petSize * 0.2
            legs = [.walk(toLeft ? span.lowerBound : span.upperBound), .drop(edge - petSize / 2), .walk(point.x)]
        } else {
            return false
        }
        route = legs
        walkTarget = nil
        walkIsStroll = false
        self.hurry = hurry
        routeIsStroll = false
        if state == .rest || state == .lounge { state = .idle }
        stateUntil = nil
        return true
    }

    /// 地面 → 窗口顶：在窗口左侧或右侧（离现在和目标近、且在屏幕内的那一侧）贴着窗口边踩台阶上去，
    /// 到顶后迈到顶边上离这一侧最近、站得稳的位置，再走到目标。
    private func climbLegs(onto ledge: PetLedge, target: NSPoint) -> [Leg]? {
        let floor = floorLine()
        let half = petSize * 0.2
        let left = ledge.frame.minX - half - petSize / 2
        let right = ledge.frame.maxX + half - petSize / 2
        let options = [left, right].filter { floor.span.contains($0) }
        guard let climbX = options.min(by: {
            abs($0 - origin.x) + abs($0 - target.x) < abs($1 - origin.x) + abs($1 - target.x)
        }) else { return nil }
        let topY = ledge.frame.maxY - footInset
        let side = climbX == left ? ledge.frame.minX : ledge.frame.maxX
        let centers = ledge.segments.map { clampedSpan($0.lowerBound + petSize * 0.35, $0.upperBound - petSize * 0.35) }
        guard let landing = centers.map({ $0.clamp(side) }).min(by: { abs($0 - side) < abs($1 - side) }) else { return nil }
        return [.walk(climbX), .climb(topY), .step(NSPoint(x: landing - petSize / 2, y: topY), ledge.id), .walk(target.x)]
    }

    /// 下一段路。
    private func startNextLeg(now: Date) {
        guard !route.isEmpty else {
            finishRoute(now: now)
            return
        }
        let leg = route.removeFirst()
        switch leg {
        case .walk(let x):
            walkTarget = x
            walkIsStroll = false
            state = .wander
            stateUntil = nil
        case .climb(let y):
            climbTargetY = y
            surface = .free
            ledgeAnchor = nil
            state = .climb
            stateUntil = nil
            // 朝着爬完要去的方向（窗口模式朝着窗口）。
            switch route.first {
            case .step(let point, _)?: if point.x != origin.x { walkDirection = point.x < origin.x ? -1 : 1 }
            case .walk(let x)?: if x != origin.x { walkDirection = x < origin.x ? -1 : 1 }
            default: break
            }
            lastStepFeetY = feet.y
            onClimbStep?(feet, y > origin.y)
        case .step(let point, let id):
            let landing: Surface = id.map { .ledge($0) } ?? (range == .screen ? .free : .floor)
            jump(to: point, landing: landing, apex: 24)
        case .drop(let x):
            jump(to: NSPoint(x: x, y: origin.y), landing: .free, apex: 30)
        }
    }

    /// 一段路走完：接着下一段，没有了就到家。
    private func legFinished(now: Date) {
        if route.isEmpty {
            finishRoute(now: now)
        } else {
            startNextLeg(now: now)
        }
    }

    private func finishRoute(now: Date) {
        state = .idle
        stateUntil = nil
        walkTarget = nil
        hurry = false
        nextStrollAt = now.addingTimeInterval(strollInterval)
        nextWanderAt = now.addingTimeInterval(Double.random(in: 8...20))
        // 散步上下踩的几级不算搬家（家不会越踩越高）。
        if !routeIsStroll {
            homeX = origin.x
            homeY = origin.y
            onArrive?()
        }
        routeIsStroll = false
    }

    /// 随意放时上下溜达去哪（宠物窗左下角）：上下半个到两个身位、左右三个身位以内、不碍事的地方；挑几次都不行返回 nil。
    private func randomFreeTarget() -> NSPoint? {
        let visible = visibleFrame()
        for _ in 0..<6 {
            let dy = CGFloat.random(in: petSize * 0.5...petSize * 1.8) * (Bool.random() ? 1 : -1)
            let dx = CGFloat.random(in: -petSize * 3...petSize * 3)
            let target = NSPoint(x: min(max(origin.x + dx, visible.minX), visible.maxX - petSize),
                                 y: min(max(origin.y + dy, visible.minY), visible.maxY - petSize))
            guard abs(target.y - origin.y) >= climbStepRise * 2 else { continue }
            if strollFilter?(target) ?? true { return target }
        }
        return nil
    }

    /// 随意放时「安静 / 适中」的散步也会上下踩一两级台阶：离家高度一个身位以上就往回踩。成了返回 true。
    private func strollVertically() -> Bool {
        let visible = visibleFrame()
        let home = homeY ?? origin.y
        var direction: CGFloat = Bool.random() ? 1 : -1
        if origin.y - home > petSize * 0.8 { direction = -1 } else if home - origin.y > petSize * 0.8 { direction = 1 }
        let steps = CGFloat(Int.random(in: 1...3))
        let y = min(max(origin.y + direction * steps * climbStepRise, visible.minY), visible.maxY - petSize)
        guard abs(y - origin.y) > 1, strollFilter?(NSPoint(x: origin.x, y: y)) ?? true else { return false }
        route = [.climb(y)]
        routeIsStroll = true
        hurry = false
        return true
    }

    /// 台阶收起（爬完 / 被拖走 / 被送走）。
    private func endClimb() {
        guard climbTargetY != nil || state == .climb else { return }
        climbTargetY = nil
        onClimbEnd?()
    }

    /// 找空地用：脚下那条线（地面 / 随意放的高度）的可走范围，与站上去时宠物窗的 y。
    func floorLine() -> (span: ClosedRange<CGFloat>, y: CGFloat) {
        if range == .screen {
            let visible = visibleFrame()
            return (clampedSpan(visible.minX, visible.maxX - petSize), origin.y)
        }
        let floor = floorRect()
        return (clampedSpan(floor.minX, floor.maxX - petSize), floor.minY - footInset)
    }

    /// 站在哪个窗口的顶边上；nil = 地面 / 随意放。
    var currentLedgeID: CGWindowID? {
        if case .ledge(let id) = surface { return id }
        return nil
    }

    /// 宠物所在屏的可见区（找空地只在这块屏上找）。
    var screenVisibleFrame: NSRect { visibleFrame() }

    /// 宠物所在的屏。
    var screen: NSScreen? {
        let probe = NSPoint(x: origin.x + petSize / 2, y: origin.y + petSize / 2)
        return NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main
    }

    /// 散步的间隔：安静一两分钟挪一次，适中半分钟左右。
    private var strollInterval: TimeInterval {
        switch activity {
        case .calm: return Double.random(in: 45...100)
        case .normal: return Double.random(in: 18...40)
        case .still, .lively: return 3600
        }
    }

    func setOrigin(_ point: NSPoint) {
        origin = point
    }

    func setDragged(_ dragging: Bool) {
        if dragging {
            endClimb()
            route = []
            walkTarget = nil
            flight = nil
            fallVelocity = nil
            state = .dragged
        } else if state == .dragged {
            state = .idle
            nextWanderAt = Date().addingTimeInterval(6)
            walkTarget = nil
            settle(animated: true)
            // 放在哪就在哪安家（跳 / 掉下去的话落地时再更新一次）。
            homeX = origin.x
            homeY = origin.y
            nextStrollAt = Date().addingTimeInterval(strollInterval)
            onDropped?()
        }
    }

    /// 活动范围改了（设置页）：重新找脚下的台面。
    func rangeChanged() {
        if state == .dragged || script != nil { return }
        settle(animated: true)
    }

    /// 收到通知时的提醒动作：从睡眠中醒来并跳一下（alert 跳得更高、更久）。
    /// 拖拽中 / 在空中不改状态；落地或松手后 tick 按 notifyUntil 补上提醒动作。
    func notify(level: PetNotification.Level) {
        if script != nil {
            // 出场 / 退场中：记下时间就好，落地后 tick 按 notifyUntil 补上提醒动作。
            notifyStartedAt = Date()
            notifyDuration = level == .alert ? 1.5 : 0.9
            notifyUntil = Date().addingTimeInterval(notifyDuration)
            return
        }
        if state == .sleep || state == .rest { state = .idle }
        notifyStartedAt = Date()
        notifyDuration = level == .alert ? 1.5 : 0.9
        notifyUntil = Date().addingTimeInterval(notifyDuration)
        if state != .dragged, !isAirborne { state = .notify }
    }

    /// 有气泡 / 菜单时站住（正在走 / 趴着就起来站好）。
    func setHeld(_ on: Bool) {
        held = on
        if on, state == .wander || state == .rest {
            state = .idle
            stateUntil = nil
        }
        if !on { nextWanderAt = max(nextWanderAt, Date().addingTimeInterval(4)) }
    }

    /// 互动动作要占用宠物 `seconds` 秒：期间不溜达、睡着的先醒。
    func occupy(for seconds: TimeInterval) {
        busyUntil = max(busyUntil, Date().addingTimeInterval(seconds))
        if state == .sleep || state == .wander || state == .rest || state == .lounge {
            state = .idle
            stateUntil = nil
        }
        sleepCheckedAt = Date()
        sleepCached = false
        nextWanderAt = max(nextWanderAt, busyUntil.addingTimeInterval(4))
    }

    private var isAirborne: Bool { flight != nil || fallVelocity != nil }

    /// 站在窗口顶边上（窗口观察器据此刷得勤一些，跟得上窗口拖动）。
    var isOnLedge: Bool {
        if case .ledge = surface { return true }
        return false
    }

    private var sleepCheckedAt = Date.distantPast
    private var sleepCached = false

    /// 勿扰 / 长空闲判定。查窗口列表（全屏检测）和 HID 空闲时间都要跨进程，
    /// tick 是 30fps，每秒算一次就够（实测每帧都查时空闲 CPU 约 10%）。
    private func shouldSleep(_ now: Date) -> Bool {
        if now.timeIntervalSince(sleepCheckedAt) >= 1 {
            sleepCheckedAt = now
            sleepCached = NotifyDND.shared.isSuppressed || UserActivity.secondsSinceInput() > 300
        }
        return sleepCached
    }

    // MARK: - 每帧

    private func tick() {
        let now = Date()
        let dt = 1.0 / 30.0

        if let script {
            let generation = scriptGeneration
            if let frame = script(now) {
                origin = frame.origin
                state = scriptState
                if let left = frame.facingLeft { walkDirection = left ? -1 : 1 }
                if frame.look == .wander { pose.walkPhase += dt * 9 }
                finishScriptFrame(frame, now: now)
                return
            }
            // 脚本自己结束了（且期间没换成别的脚本）：回到正常状态机。
            if generation == scriptGeneration { endScript(at: nil) }
            // 脚本里换了新脚本（退场接出场）：下一拍由新脚本接手。
            if self.script != nil { return }
        }

        if state != .dragged {
            if advanceFlight(now: now, dt: dt) {
                finishFrame(now: now)
                return
            }
            followSurface(now: now)
            if isAirborne {
                finishFrame(now: now)
                return
            }
            if let until = notifyUntil, now < until {
                state = .notify
            } else if state == .notify {
                state = .idle
                notifyUntil = nil
                nextWanderAt = now.addingTimeInterval(Double.random(in: 6...14))
            }
            let busy = now < busyUntil
            if state != .notify {
                // 踩着台阶走到一半不睡（不然停在半空）。
                if !busy, state != .climb, route.isEmpty, shouldSleep(now) {
                    state = .sleep
                } else if state == .sleep {
                    state = .idle
                }
                if state == .wander || state == .rest, held || busy {
                    state = .idle
                    stateUntil = nil
                } else if state == .rest, let until = stateUntil, now >= until {
                    state = .idle
                    stateUntil = nil
                    nextWanderAt = now.addingTimeInterval(Double.random(in: 4...10))
                } else if state == .idle, !held, !busy, walkTarget != nil {
                    // 控制器找好了空地 / 散步挪一两步：走过去（被气泡 / 互动打断的接着走）。
                    state = .wander
                    stateUntil = nil
                } else if state == .idle, !held, !busy, !route.isEmpty {
                    // 路线的下一段（爬台阶、迈上窗口顶、跳下去…）。
                    startNextLeg(now: now)
                } else if state == .lounge, let until = stateUntil, now >= until {
                    // 歇够了：站起来（站起的那一下由渲染层播，引擎等它播完再动）。
                    state = .idle
                    stateUntil = nil
                    busyUntil = max(busyUntil, now.addingTimeInterval(loungeExitDuration))
                    nextStrollAt = max(nextStrollAt, now.addingTimeInterval(10))
                } else if state == .idle, canLounge, activity == .calm || activity == .normal, !held, !busy,
                          now >= nextLoungeAt {
                    // 待久了蹲一会儿 / 坐地上歇会儿。
                    state = .lounge
                    stateUntil = now.addingTimeInterval(Double.random(in: 40...110))
                    nextLoungeAt = now.addingTimeInterval(loungeInterval)
                } else if state == .idle, activity == .lively, !held, !busy, startWindowMove(now: now) {
                    // 跳上 / 跳下窗口已经开始（只有「活泼」自己跳；其余由控制器挑好窗口再跳）。
                } else if state == .idle, case .ledge = surface, !held, !busy, now >= nextRestAt {
                    state = .rest
                    stateUntil = now.addingTimeInterval(Double.random(in: 20...60))
                    nextRestAt = now.addingTimeInterval(Double.random(in: 40...90))
                } else if state == .idle, activity == .lively, !held, !busy, now >= nextWanderAt {
                    // 随意放时一半的溜达是上下左右去别处（先踩台阶到那个高度再走过去），另一半照旧左右走。
                    if range == .screen, Bool.random(), let target = randomFreeTarget(),
                       travel(to: target, ledgeID: nil, hurry: false) {
                        routeIsStroll = false
                    } else {
                        state = .wander
                        stateUntil = now.addingTimeInterval(Double.random(in: 3...7))
                        walkDirection = Bool.random() ? 1 : -1
                    }
                    nextWanderAt = now.addingTimeInterval(Double.random(in: 8...20))
                } else if state == .idle, activity == .calm || activity == .normal, !held, !busy, now >= nextStrollAt {
                    if range == .screen, Double.random(in: 0..<1) < 0.35, strollVertically() {
                        nextStrollAt = now.addingTimeInterval(strollInterval)
                    } else {
                        stroll(now: now)
                    }
                } else if state == .wander, walkTarget == nil, let until = stateUntil, now >= until {
                    state = .idle
                    stateUntil = nil
                    nextWanderAt = now.addingTimeInterval(Double.random(in: 8...20))
                }
            }
        }

        if state == .wander {
            let span = walkSpan()
            let speed = walkSpeed * (hurry ? hurryFactor : 1)
            if let target = walkTarget {
                let goal = span.clamp(target)
                let dx = goal - origin.x
                if abs(dx) <= speed * dt {
                    origin.x = goal
                    arrive(now: now)
                } else {
                    walkDirection = dx < 0 ? -1 : 1
                    origin.x += walkDirection * speed * dt
                }
            } else {
                var x = origin.x + walkDirection * speed * dt
                if x < span.lowerBound {
                    x = span.lowerBound
                    walkDirection = 1
                }
                if x > span.upperBound {
                    x = span.upperBound
                    walkDirection = -1
                }
                origin.x = x
            }
            pose.walkPhase += dt * 9 * Double(hurry ? hurryFactor : 1)
        }
        if state == .climb, let target = climbTargetY {
            let speed = climbSpeed * (hurry ? Self.climbHurryFactor : 1)
            let dy = target - origin.y
            if abs(dy) <= speed * dt {
                origin.y = target
                endClimb()
                legFinished(now: now)
            } else {
                origin.y += (dy > 0 ? 1 : -1) * speed * dt
                // 每抬高 / 降低一级，脚下冒一级台阶。
                if abs(feet.y - lastStepFeetY) >= climbStepRise {
                    lastStepFeetY = feet.y
                    onClimbStep?(feet, dy > 0)
                }
            }
            pose.walkPhase += dt * 9
        }
        finishFrame(now: now)
    }

    /// 赶路时爬台阶快多少（踏台阶片段同样加速）。
    static let climbHurryFactor: CGFloat = 1.5

    /// 没有跑步片段时赶路走快多少（走路片段同样加速，见 PetModelView）。
    static let walkHurryFactor: CGFloat = 1.8
    /// 赶路时比走路快多少：有跑步片段的形象按跑步步幅算（控制器设），没有的用 `walkHurryFactor`。
    var hurryFactor: CGFloat = PetEngine.walkHurryFactor

    /// 走到了：站住。控制器给的地方就是新家；散步挪的几步不算（不然家会越散越远）。路线没走完就接着下一段。
    private func arrive(now: Date) {
        if !route.isEmpty, !walkIsStroll {
            walkTarget = nil
            startNextLeg(now: now)
            return
        }
        state = .idle
        stateUntil = nil
        walkTarget = nil
        hurry = false
        nextStrollAt = now.addingTimeInterval(strollInterval)
        nextWanderAt = now.addingTimeInterval(Double.random(in: 8...20))
        if !walkIsStroll {
            homeX = origin.x
            homeY = origin.y
            onArrive?()
        }
        walkIsStroll = false
    }

    /// 「安静 / 适中」的散步：在家附近挪一两步（安静 0.3 个身位以内、适中 0.8 个），只去不碍事的位置；
    /// 挑几次都不行或挪不了几步，就原地转个身。
    private func stroll(now: Date) {
        nextStrollAt = now.addingTimeInterval(strollInterval)
        let reach = petSize * (activity == .calm ? 0.3 : 0.8)
        let span = walkSpan()
        var picked: CGFloat?
        for _ in 0..<4 {
            let x = span.clamp((homeX ?? origin.x) + CGFloat.random(in: -reach...reach))
            guard abs(x - origin.x) >= petSize * 0.06 else { continue }
            if strollFilter?(NSPoint(x: x, y: origin.y)) ?? true {
                picked = x
                break
            }
        }
        guard let target = picked else {
            walkDirection = -walkDirection
            return
        }
        walkTarget = target
        walkIsStroll = true
        hurry = false
        state = .wander
        stateUntil = nil
    }

    private func finishScriptFrame(_ frame: ScriptFrame, now: Date) {
        pose.state = frame.look
        pose.attentive = frame.attentive
        pose.facingLeft = walkDirection < 0
        pose.time = now.timeIntervalSinceReferenceDate
        pose.lying = false
        pose.bob = 0
        pose.bounce = frame.bounce
        updateBlink(now: now)
        onPose?(pose, origin)
    }

    private func finishFrame(now: Date) {
        pose.state = state
        pose.attentive = held || now < busyUntil
        pose.facingLeft = walkDirection < 0
        pose.time = now.timeIntervalSinceReferenceDate
        pose.lying = state == .sleep || state == .rest
        pose.hurry = (state == .wander || state == .climb) && hurry
        pose.bob = state == .idle ? CGFloat(sin(pose.time * 1.7)) * 1.4 : 0
        updateBlink(now: now)
        if state == .notify, let start = notifyStartedAt {
            let p = now.timeIntervalSince(start) / max(notifyDuration, 0.01)
            pose.bounce = p < 1 ? CGFloat(sin(min(p, 1) * .pi)) * 13 : 0
        } else {
            pose.bounce = 0
        }
        onPose?(pose, origin)
    }

    private func updateBlink(now: Date) {
        if state == .sleep {
            pose.eyesClosed = true
        } else if now < blinkStart {
            pose.eyesClosed = false
        } else if now < blinkStart.addingTimeInterval(0.13) {
            pose.eyesClosed = true
        } else {
            pose.eyesClosed = false
            blinkStart = now.addingTimeInterval(Double.random(in: 2.2...4.5))
        }
    }

    // MARK: - 台面

    /// 宠物所在屏的可见区。
    private func visibleFrame() -> NSRect {
        let probe = NSPoint(x: origin.x + petSize / 2, y: origin.y + petSize / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? .zero
    }

    /// 地面：自定义区域的底边，否则屏幕可见区底边（Dock 上沿）。
    private func floorRect() -> NSRect {
        let visible = visibleFrame()
        if range == .custom, let rect = customRect, rect.intersects(visible) {
            return rect.intersection(visible)
        }
        return visible
    }

    /// 宠物窗左下角 x 的可走范围（站在窗口上时是那段没被挡住的顶边）。
    private func walkSpan() -> ClosedRange<CGFloat> {
        if case .ledge(let id) = surface, let ledge = ledges?().first(where: { $0.id == id }),
           let segment = ledge.segment(containing: origin.x + petSize / 2) {
            return clampedSpan(segment.lowerBound - petSize * 0.35, segment.upperBound - petSize * 0.65)
        }
        let frame = surface == .free ? visibleFrame() : floorRect()
        return clampedSpan(frame.minX, frame.maxX - petSize)
    }

    private func clampedSpan(_ low: CGFloat, _ high: CGFloat) -> ClosedRange<CGFloat> {
        low <= high ? low...high : low...low
    }

    /// 脚下的台面高度（屏幕坐标）。
    private func surfaceTop(_ surface: Surface) -> CGFloat? {
        switch surface {
        case .free: return nil
        case .floor: return floorRect().minY
        case .ledge(let id): return ledges?().first(where: { $0.id == id })?.frame.maxY
        }
    }

    /// 宠物的脚现在在多高、中心 x 在哪儿（屏幕坐标）。
    private var feet: NSPoint { NSPoint(x: origin.x + petSize / 2, y: origin.y + footInset) }

    /// 落到脚下最近的台面：先找脚下的窗口顶边，没有就是地面。
    /// `snap`：比脚高这么多以内的顶边也算（拖到窗口边上松手时「吸」上去）；往下掉的途中是 0，免得刚跳下的那条边又把它吸回去。
    private func landingSurface(below point: NSPoint, snap: CGFloat = 0) -> (Surface, CGFloat) {
        if range == .windows, let ledges = ledges?() {
            let candidates = ledges.compactMap { ledge -> (CGWindowID, CGFloat)? in
                guard ledge.frame.maxY <= point.y + snap, ledge.frame.maxY > floorRect().minY + 20,
                      ledge.segment(containing: point.x) != nil else { return nil }
                return (ledge.id, ledge.frame.maxY)
            }
            if let best = candidates.max(by: { $0.1 < $1.1 }) { return (.ledge(best.0), best.1) }
        }
        return (.floor, floorRect().minY)
    }

    /// 松手 / 改了范围 / 启动时：找台面落下去（随意放模式不动）。
    private func settle(animated: Bool) {
        guard range != .screen else {
            surface = .free
            return
        }
        let floor = floorRect()
        // 自定义区域：被拖出区域左右两边就跳回来。
        let span = clampedSpan(floor.minX, floor.maxX - petSize)
        let clampedX = min(max(origin.x, span.lowerBound), span.upperBound)
        let (target, top) = landingSurface(below: NSPoint(x: clampedX + petSize / 2, y: max(feet.y, floor.minY)), snap: 24)
        let destination = NSPoint(x: clampedX, y: top - footInset)
        if !animated {
            origin = destination
            surface = target
            ledgeAnchor = anchor(of: target)
            return
        }
        if abs(clampedX - origin.x) > 1 || feet.y < top - 1 {
            // 横向要挪（跳回区域）或在台面下面（Dock 变高了）：跳过去。
            jump(to: destination, landing: target, apex: 50)
        } else if feet.y > top + 1 {
            surface = .free
            fallVelocity = 0
            state = .fall
        } else {
            origin.y = destination.y
            surface = target
            ledgeAnchor = anchor(of: target)
        }
    }

    private func anchor(of surface: Surface) -> NSPoint? {
        guard case .ledge(let id) = surface, let ledge = ledges?().first(where: { $0.id == id }) else { return nil }
        return ledge.frame.origin
    }

    /// 站在窗口上：窗口挪了跟着挪；窗口没了 / 脚下那段被挡住了就掉下来。地面：Dock 变了高度就贴上去。
    private func followSurface(now: Date) {
        switch surface {
        case .free:
            return
        case .floor:
            guard !isAirborne, state != .dragged else { return }
            let top = floorRect().minY
            if abs(feet.y - top) > 1 {
                if feet.y > top {
                    startFalling()
                } else {
                    origin.y = top - footInset
                }
            }
        case .ledge(let id):
            guard !isAirborne else { return }
            guard let ledge = ledges?().first(where: { $0.id == id }) else {
                startFalling()
                return
            }
            if let anchor = ledgeAnchor {
                let dx = ledge.frame.minX - anchor.x
                origin.x += dx
                // 窗口被拖走：家和要去的地方跟着一起挪。
                if dx != 0 {
                    homeX = homeX.map { $0 + dx }
                    walkTarget = walkTarget.map { $0 + dx }
                }
            }
            ledgeAnchor = ledge.frame.origin
            origin.y = ledge.frame.maxY - footInset
            if ledge.segment(containing: feet.x) == nil {
                startFalling()
            }
        }
    }

    private func startFalling() {
        surface = .free
        ledgeAnchor = nil
        flight = nil
        fallVelocity = 0
        state = .fall
        stateUntil = nil
        walkTarget = nil
    }

    private func jump(to destination: NSPoint, landing: Surface, apex: CGFloat) {
        walkTarget = nil
        let distance = hypot(destination.x - origin.x, destination.y - origin.y)
        flight = Flight(from: origin, to: destination, start: Date(),
                        duration: min(0.45 + Double(distance) * 0.0007, 1.1), apex: apex, landing: landing)
        fallVelocity = nil
        surface = .free
        ledgeAnchor = nil
        state = .jump
        stateUntil = nil
        if destination.x != origin.x { walkDirection = destination.x < origin.x ? -1 : 1 }
    }

    /// 在空中：沿抛物线飞 / 按重力往下掉。返回 true = 这一帧还在空中。
    private func advanceFlight(now: Date, dt: Double) -> Bool {
        if let flight {
            let t = min(now.timeIntervalSince(flight.start) / flight.duration, 1)
            origin.x = flight.from.x + (flight.to.x - flight.from.x) * t
            origin.y = flight.from.y + (flight.to.y - flight.from.y) * t + flight.apex * 4 * t * (1 - t)
            if t >= 1 {
                self.flight = nil
                land(on: flight.landing, now: now)
                return false
            }
            return true
        }
        if let velocity = fallVelocity {
            let newVelocity = velocity - Self.gravity * dt
            let (target, top) = landingSurface(below: feet)
            let nextFeet = feet.y + newVelocity * dt
            if nextFeet <= top {
                origin.y = top - footInset
                fallVelocity = nil
                land(on: target, now: now)
                return false
            }
            origin.y += newVelocity * dt
            fallVelocity = newVelocity
            return true
        }
        return false
    }

    private func land(on target: Surface, now: Date) {
        // 蹦出窗口边（落点没有台面）：接着往下掉。
        if target == .free, range != .screen {
            startFalling()
            return
        }
        surface = target
        ledgeAnchor = anchor(of: target)
        state = notifyUntil.map { now < $0 } == true ? .notify : .idle
        nextWanderAt = now.addingTimeInterval(Double.random(in: 3...8))
        // 路线没走完（迈上窗口顶、跳下来以后还要走过去）：接着下一段。
        if !route.isEmpty {
            startNextLeg(now: now)
            return
        }
        // 落在哪就在哪安家（跳上窗口、被拖到半空掉下来、窗口没了掉下来都算）。
        homeX = origin.x
        homeY = origin.y
        nextStrollAt = now.addingTimeInterval(strollInterval)
        onArrive?()
        if case .ledge = target {
            leaveLedgeAt = now.addingTimeInterval(Double.random(in: 60...180))
            nextRestAt = now.addingTimeInterval(Double.random(in: 8...25))
        } else {
            leaveLedgeAt = .distantFuture
            nextRestAt = .distantFuture
            nextClimbAt = max(nextClimbAt, now.addingTimeInterval(Double.random(in: 120...300)))
        }
    }

    /// 窗口模式下，隔几分钟跳上某个窗口；在窗口上待够了跳下来。返回 true = 起跳了。
    private func startWindowMove(now: Date) -> Bool {
        guard range == .windows, PetSettings.roam else { return false }
        if case .ledge(let id) = surface {
            guard now >= leaveLedgeAt else { return false }
            leaveLedgeAt = .distantFuture
            // 从近的那一头蹦出这段顶边，落空以后重力会找到下面的窗口或地面。
            guard let segment = ledges?().first(where: { $0.id == id })?.segment(containing: feet.x) else {
                startFalling()
                return true
            }
            let toLeft = feet.x - segment.lowerBound < segment.upperBound - feet.x
            let edge = toLeft ? segment.lowerBound - petSize * 0.2 : segment.upperBound + petSize * 0.2
            jump(to: NSPoint(x: edge - petSize / 2, y: origin.y), landing: .free, apex: 40)
            return true
        }
        guard now >= nextClimbAt else { return false }
        nextClimbAt = now.addingTimeInterval(Double.random(in: 120...300))
        let visible = visibleFrame()
        let candidates = (ledges?() ?? []).compactMap { ledge -> (PetLedge, ClosedRange<CGFloat>)? in
            // 窗口顶边上方要放得下宠物，且明显高于地面。
            guard ledge.frame.maxY - footInset + petSize <= visible.maxY, ledge.frame.maxY > floorRect().minY + 60,
                  ledge.frame.intersects(visible) else { return nil }
            let usable = ledge.segments.filter { $0.upperBound - $0.lowerBound >= petSize * 0.6 }
            let nearest = usable.min { abs($0.clamp(feet.x) - feet.x) < abs($1.clamp(feet.x) - feet.x) }
            return nearest.map { (ledge, $0) }
        }
        guard !candidates.isEmpty else { return false }
        // 近的窗口更容易被选中。
        let weights: [Double] = candidates.map { 1 / (1 + Double(abs($0.1.clamp(feet.x) - feet.x)) / 300) }
        var pick = Double.random(in: 0..<weights.reduce(0, +))
        var chosen = candidates[0]
        for (candidate, weight) in zip(candidates, weights) {
            if pick < weight {
                chosen = candidate
                break
            }
            pick -= weight
        }
        let (ledge, segment) = chosen
        let inner = clampedSpan(segment.lowerBound + petSize * 0.35, segment.upperBound - petSize * 0.35)
        let centerX = inner.clamp(feet.x)
        let destination = NSPoint(x: centerX - petSize / 2, y: ledge.frame.maxY - footInset)
        jump(to: destination, landing: .ledge(ledge.id), apex: max(60, abs(destination.y - origin.y) * 0.25 + 60))
        return true
    }
}

extension ClosedRange where Bound == CGFloat {
    func clamp(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
