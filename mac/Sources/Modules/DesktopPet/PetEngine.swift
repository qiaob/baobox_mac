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
    /// 这趟走路的样子（docs/desktop-pet/MOCAP.md §3）。
    var gait: PetGait = .calm
    /// 在跳 / 飞的哪一段（渲染层按它切片段）；不在跳 / 飞、或是老式的小跳 = nil。
    var flight: PetFlightPose?
}

/// 跳 / 飞的这一刻（docs/desktop-pet/SETTLE.md §4.4）：近的跳过去，远的、高的背上火箭飞过去。
struct PetFlightPose: Equatable {
    enum Style {
        /// 老式的小跳（只有一段抛物线，没有蓄力；渲染层按 jump / fall 片段播）。
        case plain
        /// 单跳 / 二段跳（往上，高过约一个身高时空中再蹬一下、转一圈）/ 往下轻轻一跳。
        case leap, doubleLeap, hop
        /// 背上火箭飞。
        case rocket
    }
    enum Phase {
        /// 原地蓄力 / 点火（窗口还没动）。
        case prepare
        /// 跳：往上 / 往下（按竖直速度），二段跳空中再蹬、转圈，落地前腿先伸。
        case rise, fall, kick, reach
        /// 火箭：飞行中、落地前刹车。
        case cruise, brake
    }
    var style: Style
    var phase: Phase
    /// 往上去（火箭往上全力飞，往下小火慢慢降）。
    var ascending: Bool
    /// 从开始蓄力起过了多久、离地后过了多久（蓄力时是负的）：渲染层按它排助推器弹出、点火、推力。
    var elapsed: TimeInterval = 0
    var air: TimeInterval = 0
}

/// 走路的样子，按场景换（docs/desktop-pet/MOCAP.md §3）：VRM 各对应一段动捕走路，各有各的步幅和速度。
enum PetGait: CaseIterable {
    /// 平时：闲逛、走去空地待着（女性化的走法）。
    case calm
    /// 心情好：刚互动过、来过通知、你回到电脑前，之后一阵子（开心的走法）。
    case happy
    /// 活泼：「活泼」档自己溜达，「适中」档偶尔（孩子气的走法）。
    case playful
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
        /// 跳 / 飞向某个台面（跳上窗口、跳下窗口、跳回自定义区域、随意放时去别的高度）：
        /// 近的跳过去，远的、高的背上火箭飞过去（docs/desktop-pet/SETTLE.md §4.4）。
        case jump
        /// 往下掉（拖到半空松手、脚下的窗口没了）。
        case fall
        /// 趴在窗口顶边上休息。
        case rest
        /// 出场 / 退场动画进行中（#54，docs/desktop-pet/ENTRANCE.md）：位置与外观由控制器给的脚本逐帧决定，
        /// 不溜达、不睡、不跳窗口。渲染层看到的是脚本给的「外观状态」（跳 / 落 / 站 / 提醒），不会是这两个。
        case entering, leaving
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
    /// 各种走法的速度（点 / 秒，按各自片段的步幅算，控制器设）；没有的走法用 `walkSpeed`。
    var gaitSpeeds: [PetGait: CGFloat] = [:]
    /// 跑步的速度（点 / 秒，有跑步片段的形象由控制器设）；nil = 赶路时把走路加快 `hurryFactor` 倍。
    var runSpeed: CGFloat?
    /// 这趟走路的样子：每次开始走时按场景挑（`pickGait`），走的途中不换。
    private var gait: PetGait = .calm
    /// 心情好到什么时候（互动、来通知、你回来）：这期间开始的走路用开心的走法。
    private var happyUntil = Date.distantPast
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
    /// 「活泼」上下左右溜达用的宽松版：只要不碍事就能去，不要求比现在待的地方更空
    /// （用 strollFilter 的话她本来就在最空的地方，几乎哪儿都去不了，就一直不跳，2026-11-08 试用反馈）。
    var roamFilter: ((NSPoint) -> Bool)?
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
        /// 起跳 / 点火前原地蓄力多久（窗口不动）。
        var prepare: TimeInterval = 0
        /// 腾空多久。
        let duration: TimeInterval
        /// 老式小跳：抛物线在起止连线之上再高出多少点（0 = 直线）。
        var apex: CGFloat = 0
        let landing: Surface
        var style: PetFlightPose.Style = .plain
        /// 跳：竖直方向一段或两段抛物线（二段跳在第一段最高点空中再蹬一下），横向匀速。
        var arcs: [Arc] = []
        /// 二段跳：腾空后第几秒空中再蹬。
        var kickAt: TimeInterval?
        /// 已经离地 / 已经空中再蹬过（回调只发一次）。
        var launched = false
        /// 原地蹦（落回原处）：落地不算搬家、不动计时器。
        var inPlace = false
        var kicked = false
    }

    /// 一段抛物线：从腾空计时 `start` 秒起，宠物窗 y = y0 + v0·τ − g·τ²/2（τ 从 start 算起）。
    private struct Arc {
        let start: TimeInterval
        let y0: CGFloat
        let v0: CGFloat
    }

    private var surface: Surface = .free
    private var flight: Flight?
    /// 自由落体（没有目标台面时用重力，每帧找脚下的台面）。
    private var fallVelocity: CGFloat?
    /// 站在窗口上时上一帧那个窗口的左下角（窗口被拖动时宠物跟着挪）。
    private var ledgeAnchor: NSPoint?
    private var nextLedgeJumpAt = Date().addingTimeInterval(Double.random(in: 120...300))
    private var leaveLedgeAt = Date.distantFuture
    private var nextRestAt = Date.distantFuture

    private static let gravity: CGFloat = 2600

    // MARK: 跳 / 飞（docs/desktop-pet/SETTLE.md §4.4）

    /// 人有多高（点，控制器按形象设）：跳多高、飞多快都按它算。
    var bodyHeight: CGFloat = 80
    /// 各段动作要多久（按形象的片段，控制器设）：跳 / 往下跳前的蓄力，火箭弹出 + 点火到离地（往上 / 往下），
    /// 落地前伸腿 / 刹车提前多少，二段跳空中转一圈。
    var leapPrepare: TimeInterval = 0.39
    var hopPrepare: TimeInterval = 0.27
    var rocketPrepare: TimeInterval = 0.77
    var rocketDescendPrepare: TimeInterval = 0.65
    var reachLead: TimeInterval = 0.26
    var brakeLead: TimeInterval = 0.37
    var spinDuration: TimeInterval = 0.7
    /// 离地 / 落地（脚底中点的屏幕坐标）、二段跳空中再蹬：控制器在那儿画一小团土 / 一圈气浪（留在原地，不跟着窗口走）。
    var onTakeoff: ((NSPoint, PetFlightPose.Style) -> Void)?
    var onTouchdown: ((NSPoint, PetFlightPose.Style) -> Void)?
    var onKick: ((NSPoint) -> Void)?
    /// 轨迹（身高为单位，和片段的设计一致，见 VRMMotion 的 jumpGravity 等）：重力 5.8 身高 / 秒²（比真的略小，空中停得久一点）；
    /// 单跳最高点比起点、落点里高的那个再高 0.22；二段跳第一段最高点比起点高 0.62，在那儿空中再蹬，第二段最高点比落点高 0.24；
    /// 往下跳先往上 0.13。
    static let leapGravity: CGFloat = 5.8
    static let leapApex: CGFloat = 0.22
    static let doubleLeapFirstApex: CGFloat = 0.62
    static let doubleLeapSecondApex: CGFloat = 0.24
    static let hopApex: CGFloat = 0.13
    /// 一跳够得着多高（身高）：单跳、二段跳往上，轻跳往下。再高 / 再低就背火箭飞。
    static let maxSingleLeap: CGFloat = 0.95
    static let maxDoubleLeap: CGFloat = 1.5
    static let maxHop: CGFloat = 1.8
    /// 跳 / 飞的时候人在宠物窗里抬高多少（窗口高度的比例），窗口同样往下挪、人在屏幕上不动：
    /// 空中绷脚尖时脚尖比脚底线低约 4.5%，宠物窗脚下只留了 2.4%，不抬会被窗口底边裁掉。
    static let flightLift: CGFloat = 0.03
    /// 此刻抬了多少点（渲染层按 `pose.bounce` 抬人，窗口同样往下挪）。
    private var liftPoints: CGFloat = 0

    // MARK: 出场 / 退场脚本（#54）

    /// 返回 nil = 脚本结束（之后不再调用）。
    private var script: ((Date) -> ScriptFrame?)?
    private var scriptState: State = .entering
    /// 换脚本时递增：旧脚本在 tick 里返回 nil 时，不能把刚换上的新脚本清掉。
    private var scriptGeneration = 0

    var isScripted: Bool { script != nil }
    /// 脚本期间改了活动范围 / 来了通知：脚本结束时补做（见 endScript）。
    private var pendingRangeChange = false
    private var pendingNotify: Notice.Level?
    /// 从打盹醒来那一下（起身 + 伸懒腰 / 打哈欠）要多久：这段时间里不溜达、不歇脚、不跳（控制器按形象的 wake 片段设）。
    var wakeDuration: TimeInterval = 0.5
    /// 跳 / 飞落地后路线还没走完时，先停一下让落地缓冲播出来再走下一段（控制器按 jump_land 设）。
    var landPause: TimeInterval = 0.4

    /// 接管位置与外观，直到脚本返回 nil。正在跳 / 掉的打断（出场从屏幕外开始，不接着原来的抛物线）。
    func runScript(as state: State, _ frame: @escaping (Date) -> ScriptFrame?) {
        flight = nil
        liftPoints = 0
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
        // 脚本打断了跳 / 掉（悬在半空）、或脚本期间改了活动范围：现在补上找台面，免得沿一条看不见的线在空中散步。
        if pendingRangeChange || (range != .screen && surface == .free && !isAirborne) {
            pendingRangeChange = false
            settle(animated: true)
        }
        // 脚本期间来的通知：现在补上提醒动作（按落地这一刻算时间，不会已经过期）。
        if let level = pendingNotify {
            pendingNotify = nil
            notify(level: level)
        }
    }

    func start(at origin: NSPoint) {
        self.origin = origin
        settle(animated: false)
        homeX = self.origin.x
        homeY = self.origin.y
        startTimer()
    }

    /// 形象换了 / 大小变了（脚离窗口底边的距离 footInset 跟着变）：按新的 footInset 重新站到台面上。
    /// 不然出场在「脚离地」的位置播完，下一拍才掉下去一截（还会打断招手）。在空中、在脚本里、被拖着时不动。
    func resettle() {
        guard script == nil, state != .dragged, !isAirborne else { return }
        settle(animated: false)
    }

    private func startTimer() {
        timer?.invalidate()
        // 挂在 common 模式：菜单栏菜单开着（事件追踪模式）、有模态框时宠物也照常动，不会定住再一下跳一截。
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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

    /// 醒了：接着跑。勿扰 / 空闲马上重新判断（睡前的结果早就过期了）。宠物关着的话不跑。
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        sleepCheckedAt = .distantPast
        if !isHidden { startTimer() }
    }

    /// 宠物关掉了：停掉每帧定时器（隐形的宠物不再散步、蹦、冒土）。和系统睡眠的 suspend 分开记 ——
    /// 系统醒来的 resume 不会把关掉的宠物跑起来；打开时先恢复再出场。
    private(set) var isHidden = false
    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        if hidden {
            timer?.invalidate()
            timer = nil
        } else if !isSuspended {
            sleepCheckedAt = .distantPast
            startTimer()
        }
    }

    // MARK: - 挪窝（控制器找好空地后调用，docs/desktop-pet/SETTLE.md §4）

    /// 现在能不能挪：站着 / 走着 / 趴着 / 坐着蹲着，没被拖、不在空中、没在出场退场、没睡、没被气泡菜单拴住、没在做互动、没关掉。
    var canRelocate: Bool {
        guard script == nil, !isSuspended, !isHidden, !held, Date() >= busyUntil, flight == nil, fallVelocity == nil else {
            return false
        }
        return state == .idle || state == .wander || state == .rest || state == .lounge
    }

    /// 正在赶往控制器给的地方（散步不算）：这期间控制器不再重新挑地方。
    var isHeadingSomewhere: Bool { !route.isEmpty || flight != nil || (walkTarget != nil && !walkIsStroll) }

    /// 心情好一阵（刚互动过、来了通知、你回到电脑前）：这期间开始的走路用开心的走法。
    func cheer(for seconds: TimeInterval = 40) {
        happyUntil = max(happyUntil, Date().addingTimeInterval(seconds))
    }

    /// 开始走之前挑走法：心情好就开心地走；否则 `playful` 的场景孩子气地走，其余平常地走。
    private func pickGait(playful: Bool) {
        gait = Date() < happyUntil ? .happy : (playful ? .playful : .calm)
    }

    /// 散步用哪种走法：「活泼」都是孩子气的，「适中」四次里约有一次，「安静」不会。
    private var strollIsPlayful: Bool {
        switch activity {
        case .lively: return true
        case .normal: return Double.random(in: 0..<1) < 0.25
        case .still, .calm: return false
        }
    }

    /// 要上路了：正坐着 / 蹲着的先站起来（起身片段播完再动，不然坐着滑出去），趴着的先爬起来（0.6 秒），
    /// 正在溜达的先站住（下一拍从第一段路开始）。
    private func standUpForRoute() {
        let now = Date()
        switch state {
        case .lounge: busyUntil = max(busyUntil, now.addingTimeInterval(loungeExitDuration))
        case .rest: busyUntil = max(busyUntil, now.addingTimeInterval(0.6))
        default: break
        }
        if state == .rest || state == .lounge || state == .wander { state = .idle }
        stateUntil = nil
    }

    /// 直接放到这里（远处的空地由黑洞送过去之后）：找脚下的台面站稳，这里就是新家。
    func place(at point: NSPoint) {
        route = []
        origin = point
        flight = nil
        liftPoints = 0
        fallVelocity = nil
        walkTarget = nil
        settle(animated: false)
        homeX = origin.x
        homeY = origin.y
        nextStrollAt = Date().addingTimeInterval(strollInterval)
    }

    // MARK: 路线：走 / 跳 / 飞（docs/desktop-pet/SETTLE.md §4.4）

    private enum Leg {
        /// 沿脚下的台面走到这个 x（宠物窗左下角）。
        case walk(CGFloat)
        /// 跳到这里、站上这个台面（够得着的：单跳 / 二段跳 / 往下轻跳）。
        case leap(NSPoint, Surface)
        /// 背上火箭飞到这里、站上这个台面（太高、太低、太远的）。
        case fly(NSPoint, Surface)
    }

    private var route: [Leg] = []

    /// 去这个落脚点（宠物窗左下角）：
    /// - 随意放：高低差不大就走；够得着的走到跟前再跳，太高 / 太低的背火箭飞；
    /// - 同一个台面：直接走；
    /// - 地面 → 窗口顶：走到那个窗口的侧边，跳上去（跳不到就飞上去），再走到位；
    /// - 窗口顶 → 地面：走到这段顶边离目标近的那一头，跳下去（太高就飞下去），落地后走过去。
    /// 排不出路线（窗口顶 → 别的窗口顶、窗口两侧都在屏幕外）返回 false，由控制器钻黑洞过去。
    func travel(to point: NSPoint, ledgeID: CGWindowID?, hurry: Bool) -> Bool {
        var legs: [Leg] = []
        if range == .screen {
            legs = freeLegs(to: point)
        } else if ledgeID == currentLedgeID {
            legs = [.walk(point.x)]
        } else if currentLedgeID == nil, let id = ledgeID, let ledge = ledges?().first(where: { $0.id == id }) {
            guard let plan = ledgeLegs(onto: ledge, target: point) else { return false }
            legs = plan
        } else if let id = currentLedgeID, ledgeID == nil, let ledge = ledges?().first(where: { $0.id == id }),
                  let segment = ledge.segment(containing: feet.x),
                  let exit = ledgeExit(segment, toward: point.x + petSize / 2) {
            let span = walkSpan()
            let down = NSPoint(x: exit.center - petSize / 2, y: floorRect().minY - footInset)
            legs = [.walk(exit.left ? span.lowerBound : span.upperBound), takeoffLeg(to: down, landing: .floor), .walk(point.x)]
        } else {
            return false
        }
        route = legs
        walkTarget = nil
        walkIsStroll = false
        self.hurry = hurry
        routeIsStroll = false
        pickGait(playful: false)
        // 正在溜达（「活泼」的随便走、散步挪几步）也先站住，下一拍从第一段路开始。不站住的话：walkTarget 清掉了、
        // stateUntil 也清掉了，随便走就停不下来，在可走范围两头来回走（2026-11-08 试用「走来走去，有三四个来回了」）。
        standUpForRoute()
        return true
    }

    /// 从这段窗口顶边的哪一头下去（落点身子中线的 x）：离 `targetCenter` 近的那头优先；
    /// 落点（顶边外 0.3 个窗宽）要在地面的可走范围里 —— 窗口贴着屏幕边时那一头会落到屏外或隔壁屏，换另一头；都不行返回 nil。
    private func ledgeExit(_ segment: ClosedRange<CGFloat>, toward targetCenter: CGFloat) -> (center: CGFloat, left: Bool)? {
        let floor = floorLine()
        let options: [(CGFloat, Bool)] = [(segment.lowerBound - petSize * 0.3, true), (segment.upperBound + petSize * 0.3, false)]
            .sorted { abs($0.0 - targetCenter) < abs($1.0 - targetCenter) }
        return options.first { floor.span.contains($0.0 - petSize / 2) }.map { (center: $0.0, left: $0.1) }
    }

    /// 地面 → 窗口顶：走到窗口左侧或右侧（离现在和目标近、且在屏幕内的那一侧），跳上去（跳不到就飞上去），
    /// 落在顶边上离这一侧最近、站得稳的位置，再走到目标。
    private func ledgeLegs(onto ledge: PetLedge, target: NSPoint) -> [Leg]? {
        let floor = floorLine()
        let half = petSize * 0.3
        let left = ledge.frame.minX - half - petSize / 2
        let right = ledge.frame.maxX + half - petSize / 2
        let options = [left, right].filter { floor.span.contains($0) }
        guard let takeoffX = options.min(by: {
            abs($0 - origin.x) + abs($0 - target.x) < abs($1 - origin.x) + abs($1 - target.x)
        }) else { return nil }
        let topY = ledge.frame.maxY - footInset
        let side = takeoffX == left ? ledge.frame.minX : ledge.frame.maxX
        let centers = ledge.segments.map { clampedSpan($0.lowerBound + petSize * 0.35, $0.upperBound - petSize * 0.35) }
        guard let landing = centers.map({ $0.clamp(side) }).min(by: { abs($0 - side) < abs($1 - side) }) else { return nil }
        let top = NSPoint(x: landing - petSize / 2, y: topY)
        return [.walk(takeoffX), takeoffLeg(to: top, landing: .ledge(ledge.id)), .walk(target.x)]
    }

    /// 随意放时去别的高度：几乎一样高就走；够得着的先走到离落点一个身位以内再跳（差一点点也轻轻蹦一下），
    /// 太高、太低的走近一些再背火箭飞。
    private func freeLegs(to point: NSPoint) -> [Leg] {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        if abs(dy) < bodyHeight * 0.05 { return abs(dx) > 1 ? [.walk(point.x)] : [] }
        let near = bodyHeight * (canLeap(dy) ? 0.9 : 2.0)
        var legs: [Leg] = []
        if abs(dx) > near { legs.append(.walk(point.x - (dx > 0 ? near : -near))) }
        legs.append(takeoffLeg(to: point, landing: .free))
        return legs
    }

    /// 这个高低差一跳够不够得着（往上二段跳到 `maxDoubleLeap` 个身高，往下轻跳到 `maxHop` 个）。
    private func canLeap(_ dy: CGFloat) -> Bool {
        dy > 0 ? dy <= bodyHeight * Self.maxDoubleLeap : -dy <= bodyHeight * Self.maxHop
    }

    /// 跳得到就跳，跳不到就飞（高低差按现在的高度算：前面的路段都是平着走）。
    private func takeoffLeg(to point: NSPoint, landing: Surface) -> Leg {
        canLeap(point.y - origin.y) ? .leap(point, landing) : .fly(point, landing)
    }

    /// 马上起跳 / 起飞。
    private func takeoff(to point: NSPoint, landing: Surface) {
        switch takeoffLeg(to: point, landing: landing) {
        case .leap(let target, let surface): leap(to: target, landing: surface)
        case .fly(let target, let surface): fly(to: target, landing: surface)
        case .walk: break
        }
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
        case .leap(let point, let landing):
            leap(to: point, landing: landing)
        case .fly(let point, let landing):
            fly(to: point, landing: landing)
        }
    }

    private func finishRoute(now: Date) {
        state = .idle
        stateUntil = nil
        walkTarget = nil
        hurry = false
        nextStrollAt = now.addingTimeInterval(strollInterval)
        nextWanderAt = now.addingTimeInterval(Double.random(in: 8...20))
        // 散步上下蹦的那一下不算搬家（家不会越蹦越高）。
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
        for _ in 0..<12 {
            let dy = CGFloat.random(in: petSize * 0.5...petSize * 1.8) * (Bool.random() ? 1 : -1)
            let dx = CGFloat.random(in: -petSize * 3...petSize * 3)
            let target = NSPoint(x: min(max(origin.x + dx, visible.minX), visible.maxX - petSize),
                                 y: min(max(origin.y + dy, visible.minY), visible.maxY - petSize))
            guard abs(target.y - origin.y) >= bodyHeight * 0.4 else { continue }
            if (roamFilter ?? strollFilter)?(target) ?? true { return target }
        }
        return nil
    }

    /// 随意放时「安静 / 适中」的散步也会上下蹦一下：往上或往下跳半个到快一个身高、横着挪半个身位以内；
    /// 离家高度一个身位以上就往回跳。成了返回 true。
    private func strollVertically() -> Bool {
        let visible = visibleFrame()
        let home = homeY ?? origin.y
        var direction: CGFloat = Bool.random() ? 1 : -1
        if origin.y - home > petSize * 0.8 { direction = -1 } else if home - origin.y > petSize * 0.8 { direction = 1 }
        let y = min(max(origin.y + direction * bodyHeight * CGFloat.random(in: 0.4...0.9), visible.minY), visible.maxY - petSize)
        let x = walkSpan().clamp(origin.x + bodyHeight * CGFloat.random(in: -0.5...0.5))
        guard abs(y - origin.y) > bodyHeight * 0.2, strollFilter?(NSPoint(x: x, y: y)) ?? true else { return false }
        route = [.leap(NSPoint(x: x, y: y), .free)]
        routeIsStroll = true
        hurry = false
        pickGait(playful: strollIsPlayful)
        return true
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
        Self.nearestScreen(to: NSPoint(x: origin.x + petSize / 2, y: origin.y + petSize / 2))
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
            route = []
            walkTarget = nil
            flight = nil
            liftPoints = 0
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

    /// 活动范围改了（设置页）：重新找脚下的台面。出场 / 退场中先记下，脚本结束再补。
    func rangeChanged() {
        if script != nil {
            pendingRangeChange = true
            return
        }
        if state == .dragged { return }
        route = []
        routeIsStroll = false
        settle(animated: true)
    }

    /// 收到通知时的提醒动作：从睡眠中醒来并跳一下（alert 跳得更高、更久）。
    /// 拖拽中 / 在空中不改状态；落地或松手后 tick 按 notifyUntil 补上提醒动作。
    /// 出场 / 退场中只记下级别，脚本结束时再补（按那时的时间算，不会还没落地就过期）。
    /// 蹲着 / 坐地时先站起来，提醒那一下小跳等起身片段播完再跳（不然半蹲着就飘起来）。
    func notify(level: Notice.Level) {
        if script != nil {
            if pendingNotify != .alert { pendingNotify = level }
            return
        }
        let standUp: TimeInterval = state == .lounge ? loungeExitDuration : 0
        if state == .sleep || state == .rest { state = .idle }
        notifyDuration = level == .alert ? 1.5 : 0.9
        notifyStartedAt = Date().addingTimeInterval(standUp)
        notifyUntil = Date().addingTimeInterval(standUp + notifyDuration)
        if state != .dragged, !isAirborne { state = .notify }
        cheer()
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
                if !busy, route.isEmpty, shouldSleep(now) {
                    state = .sleep
                } else if state == .sleep {
                    // 你回到电脑前，她醒过来：高兴一阵。先让起身 + 伸懒腰 / 打哈欠播完（渲染层看到 sleep → idle 才播），
                    // 这一拍不往下排别的；睡着时到点的歇脚 / 散步 / 溜达 / 跳窗口都往后推，不然醒来那一拍就直接坐下或走掉。
                    state = .idle
                    cheer()
                    busyUntil = max(busyUntil, now.addingTimeInterval(wakeDuration))
                    let later = now.addingTimeInterval(wakeDuration + Double.random(in: 3...8))
                    nextLoungeAt = max(nextLoungeAt, later)
                    nextStrollAt = max(nextStrollAt, later)
                    nextWanderAt = max(nextWanderAt, later)
                    nextLedgeJumpAt = max(nextLedgeJumpAt, later)
                    finishFrame(now: now)
                    return
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
                    // 随意放时一半的溜达是上下左右去别处（跳过去 / 飞过去），另一半照旧左右走。
                    // 想上下却没有不碍事的地方可去（比如正在用的窗口铺满了屏幕）：原地蹦一下；平时也偶尔蹦。
                    // 左右随便走也先看一眼走到头那儿碍不碍事（两个方向都碍事就不走），免得停在正在用的窗口上又被「让开」拉走。
                    let wantsVertical = range == .screen && Bool.random()
                    if wantsVertical, let target = randomFreeTarget(), travel(to: target, ledgeID: nil, hurry: false) {
                        routeIsStroll = false
                        pickGait(playful: true)
                    } else if wantsVertical || Double.random(in: 0..<1) < 0.15 {
                        hopInPlace()
                    } else {
                        let duration = Double.random(in: 3...7)
                        pickGait(playful: true)
                        let reach = (gaitSpeeds[gait] ?? walkSpeed) * CGFloat(duration)
                        let span = walkSpan()
                        let first: CGFloat = Bool.random() ? 1 : -1
                        if let direction = [first, -first].first(where: {
                            (roamFilter ?? strollFilter)?(NSPoint(x: span.clamp(origin.x + $0 * reach), y: origin.y)) ?? true
                        }) {
                            state = .wander
                            stateUntil = now.addingTimeInterval(duration)
                            walkDirection = direction
                        }
                    }
                    nextWanderAt = now.addingTimeInterval(Double.random(in: 8...20))
                } else if state == .idle, activity == .calm || activity == .normal, !held, !busy, now >= nextStrollAt {
                    if range == .screen, Double.random(in: 0..<1) < 0.35, strollVertically() {
                        nextStrollAt = now.addingTimeInterval(strollInterval)
                    } else {
                        stroll(now: now)
                    }
                } else if state == .wander, walkTarget == nil, stateUntil.map({ now >= $0 }) ?? true {
                    // 随便走到时间了；没有目标又没有时限的（不该有，保险）也停下，免得在两头来回走个没完。
                    state = .idle
                    stateUntil = nil
                    nextWanderAt = now.addingTimeInterval(Double.random(in: 8...20))
                }
            }
        }

        if state == .wander {
            let span = walkSpan()
            let gaitSpeed = gaitSpeeds[gait] ?? walkSpeed
            let speed = hurry ? (runSpeed ?? gaitSpeed * hurryFactor) : gaitSpeed
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
        finishFrame(now: now)
    }

    /// 没有跑步片段时赶路走快多少（走路片段同样加速，见 PetModelView）。
    static let walkHurryFactor: CGFloat = 1.8
    /// 没有跑步片段的形象赶路时比走路快多少（有跑步片段的按 `runSpeed` 跑）。
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
        pickGait(playful: strollIsPlayful)
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
        // 脚本打断了跳 / 飞、赶路：渲染层别再按旧的飞行阶段播片段（不然背着冒火的助推器钻进黑洞、道别被顶掉）。
        pose.flight = nil
        pose.hurry = false
        updateBlink(now: now)
        onPose?(pose, origin)
    }

    private func finishFrame(now: Date) {
        pose.state = state
        pose.attentive = held || now < busyUntil
        pose.facingLeft = walkDirection < 0
        pose.time = now.timeIntervalSinceReferenceDate
        pose.lying = state == .sleep || state == .rest
        pose.hurry = state == .wander && hurry
        pose.gait = gait
        pose.flight = flightPose(now: now)
        pose.bob = state == .idle ? CGFloat(sin(pose.time * 1.7)) * 1.4 : 0
        updateBlink(now: now)
        if state == .notify, let start = notifyStartedAt {
            let p = now.timeIntervalSince(start) / max(notifyDuration, 0.01)
            // 蹲着时来的提醒要等站起来才跳（notifyStartedAt 推后了），还没到点 p 是负的：不跳。
            pose.bounce = p >= 0 && p < 1 ? CGFloat(sin(p * .pi)) * 13 : 0
        } else {
            pose.bounce = 0
        }
        // 跳的时候人在窗口里抬高、窗口往下挪同样多（advanceFlight），人在屏幕上不动。
        pose.bounce += liftPoints
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
        screen?.visibleFrame ?? .zero
    }

    /// 离这一点最近的屏（点在屏里就是那块屏）：拔了外接屏、合盖换屏以后，原来那块屏不在了也能找到落脚的地方。
    static func nearestScreen(to point: NSPoint) -> NSScreen? {
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return hit }
        return NSScreen.screens.min { distance($0.frame, point) < distance($1.frame, point) } ?? NSScreen.main
    }

    private static func distance(_ rect: NSRect, _ point: NSPoint) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// 宠物还在不在某块屏上（中心点在屏里）。
    var isOnScreen: Bool {
        let probe = NSPoint(x: origin.x + petSize / 2, y: origin.y + petSize / 2)
        return NSScreen.screens.contains { $0.frame.contains(probe) }
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
            route = []
            routeIsStroll = false
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
        liftPoints = 0
        fallVelocity = 0
        state = .fall
        stateUntil = nil
        walkTarget = nil
        // 掉下去了，原来排的路线（按掉之前的位置排的）作废，落地后由 settler 重新排；不然会按旧路线贴地横飞。
        route = []
        routeIsStroll = false
    }

    /// 老式的小跳（只剩把人送回活动范围这种情况在用）：一段抛物线，没有蓄力。
    private func jump(to destination: NSPoint, landing: Surface, apex: CGFloat) {
        walkTarget = nil
        let distance = hypot(destination.x - origin.x, destination.y - origin.y)
        beginFlight(Flight(from: origin, to: destination, start: Date(),
                           duration: min(0.45 + Double(distance) * 0.0007, 1.1), apex: apex, landing: landing))
    }

    /// 跳过去（SETTLE.md §4.4）：先原地蓄力，再沿真实的抛物线飞过去（横向匀速）。往上高过约一个身高就二段跳
    /// （第一段跳到比起点高 0.62 个身高，在最高点空中再蹬一下）；往下是先轻轻往上一跳再落下去。
    private func leap(to destination: NSPoint, landing: Surface) {
        walkTarget = nil
        let h = max(bodyHeight, 1)
        let g = Self.leapGravity * h
        let dy = destination.y - origin.y
        /// 竖直上抛到 `rise` 高：初速、到最高点要多久。
        func throwUp(_ rise: CGFloat) -> (v: CGFloat, t: Double) {
            let v = sqrt(2 * g * max(rise, 0))
            return (v, Double(v / g))
        }
        /// 从最高点往下掉 `drop` 要多久。
        func fallTime(_ drop: CGFloat) -> Double { Double(sqrt(2 * max(drop, 0) / g)) }
        var flight: Flight
        if dy < -h * 0.1 {
            let up = throwUp(h * Self.hopApex)
            flight = Flight(from: origin, to: destination, start: Date(), prepare: hopPrepare,
                            duration: up.t + fallTime(h * Self.hopApex - dy), landing: landing)
            flight.style = .hop
            flight.arcs = [Arc(start: 0, y0: origin.y, v0: up.v)]
        } else if dy <= h * Self.maxSingleLeap {
            let up = throwUp(max(dy, 0) + h * Self.leapApex)
            flight = Flight(from: origin, to: destination, start: Date(), prepare: leapPrepare,
                            duration: up.t + fallTime(h * Self.leapApex + max(dy, 0) - dy), landing: landing)
            flight.style = .leap
            flight.arcs = [Arc(start: 0, y0: origin.y, v0: up.v)]
        } else {
            let first = throwUp(h * Self.doubleLeapFirstApex)
            let second = throwUp(dy + h * Self.doubleLeapSecondApex - h * Self.doubleLeapFirstApex)
            flight = Flight(from: origin, to: destination, start: Date(), prepare: leapPrepare,
                            duration: first.t + second.t + fallTime(h * Self.doubleLeapSecondApex), landing: landing)
            flight.style = .doubleLeap
            flight.arcs = [Arc(start: 0, y0: origin.y, v0: first.v),
                           Arc(start: first.t, y0: origin.y + h * Self.doubleLeapFirstApex, v0: second.v)]
            flight.kickAt = first.t
        }
        beginFlight(flight)
    }

    /// 原地蹦一下（「活泼」想上下溜达却没有不碍事的地方可去时，或者平时偶尔）：跳起来约半个身高再落回原地，
    /// 三次里约有一次是二段跳（空中再蹬一下、转一圈）。
    private func hopInPlace() {
        let h = max(bodyHeight, 1)
        let g = Self.leapGravity * h
        let landing = surface
        var flight: Flight
        if Double.random(in: 0..<1) < 0.3 {
            let v1 = sqrt(2 * g * h * Self.doubleLeapFirstApex)
            let t1 = Double(v1 / g)
            let v2 = sqrt(2 * g * h * 0.3)
            let fall = Double(sqrt(2 * h * (Self.doubleLeapFirstApex + 0.3) / g))
            flight = Flight(from: origin, to: origin, start: Date(), prepare: leapPrepare,
                            duration: t1 + Double(v2 / g) + fall, landing: landing)
            flight.style = .doubleLeap
            flight.arcs = [Arc(start: 0, y0: origin.y, v0: v1),
                           Arc(start: t1, y0: origin.y + h * Self.doubleLeapFirstApex, v0: v2)]
            flight.kickAt = t1
        } else {
            let v = sqrt(2 * g * h * 0.45)
            flight = Flight(from: origin, to: origin, start: Date(), prepare: leapPrepare,
                            duration: 2 * Double(v / g), landing: landing)
            flight.style = .leap
            flight.arcs = [Arc(start: 0, y0: origin.y, v0: v)]
        }
        flight.inPlace = true
        walkTarget = nil
        beginFlight(flight)
    }

    /// 背上火箭飞过去：助推器弹出、点火蓄力（往下飞是直接小火悬停），离地后沿直线先加速后减速飞到落点
    /// （约 1.6 个身高 / 秒，1–3.5 秒）。
    private func fly(to destination: NSPoint, landing: Surface) {
        walkTarget = nil
        let distance = hypot(destination.x - origin.x, destination.y - origin.y)
        let duration = min(max(Double(distance / (max(bodyHeight, 1) * 1.6)) + 0.4, 1.0), 3.5)
        let prepare = destination.y >= origin.y ? rocketPrepare : rocketDescendPrepare
        var flight = Flight(from: origin, to: destination, start: Date(), prepare: prepare,
                            duration: duration, landing: landing)
        flight.style = .rocket
        beginFlight(flight)
    }

    private func beginFlight(_ flight: Flight) {
        if flight.style != .plain {
            let kind = String(describing: flight.style)
            PetLog.log.info("takeoff \(kind, privacy: .public): dx \(Int(flight.to.x - flight.from.x)) dy \(Int(flight.to.y - flight.from.y)), air \(flight.duration, format: .fixed(precision: 2)) s")
        }
        self.flight = flight
        fallVelocity = nil
        surface = .free
        ledgeAnchor = nil
        state = .jump
        stateUntil = nil
        if flight.to.x != flight.from.x { walkDirection = flight.to.x < flight.from.x ? -1 : 1 }
    }

    /// 跳：腾空第 τ 秒时宠物窗的 y 与竖直速度（按所在那段抛物线）。
    private func arcState(_ flight: Flight, at tau: TimeInterval) -> (y: CGFloat, velocity: CGFloat) {
        let g = Self.leapGravity * max(bodyHeight, 1)
        guard let arc = flight.arcs.last(where: { $0.start <= tau }) ?? flight.arcs.first else {
            return (flight.to.y, 0)
        }
        let s = CGFloat(max(tau - arc.start, 0))
        return (arc.y0 + arc.v0 * s - g * s * s / 2, arc.v0 - g * s)
    }

    /// 这一刻在跳 / 飞的哪一段（老式小跳不报，渲染层按 jump / fall 片段播）。
    private func flightPose(now: Date) -> PetFlightPose? {
        guard state == .jump, let flight, flight.style != .plain else { return nil }
        let tau = now.timeIntervalSince(flight.start) - flight.prepare
        let left = flight.duration - tau
        let phase: PetFlightPose.Phase
        if tau < 0 {
            phase = .prepare
        } else if flight.style == .rocket {
            phase = left <= brakeLead ? .brake : .cruise
        } else if left <= reachLead {
            phase = .reach
        } else if let kick = flight.kickAt, tau >= kick, tau < kick + spinDuration {
            phase = .kick
        } else {
            phase = arcState(flight, at: tau).velocity > 0 ? .rise : .fall
        }
        return PetFlightPose(style: flight.style, phase: phase, ascending: flight.to.y >= flight.from.y,
                             elapsed: now.timeIntervalSince(flight.start), air: tau)
    }

    /// 在空中：蓄力、沿轨迹飞 / 按重力往下掉。返回 true = 这一帧还在空中（蓄力时也算，窗口不动）。
    private func advanceFlight(now: Date, dt: Double) -> Bool {
        if var flight {
            let elapsed = now.timeIntervalSince(flight.start)
            let tau = elapsed - flight.prepare
            // 跳 / 飞的时候人在窗口里抬高 3%、窗口往下挪同样多：蓄力时慢慢抬，落地前伸腿 / 刹车那一段慢慢放回去。
            var lift: CGFloat = 0
            if flight.style != .plain {
                let settle = flight.style == .rocket ? brakeLead : reachLead
                let up = min(max(elapsed / max(flight.prepare, 0.05), 0), 1)
                let down = min(max((flight.duration - tau) / max(settle, 0.05), 0), 1)
                lift = CGFloat(min(up, down)) * Self.flightLift * petSize
            }
            liftPoints = lift
            if tau < 0 {
                origin = NSPoint(x: flight.from.x, y: flight.from.y - lift)
                self.flight = flight
                return true
            }
            if !flight.launched {
                flight.launched = true
                onTakeoff?(NSPoint(x: flight.from.x + petSize / 2, y: flight.from.y + footInset), flight.style)
            }
            let t = min(tau / flight.duration, 1)
            var point: NSPoint
            switch flight.style {
            case .plain:
                point = NSPoint(x: flight.from.x + (flight.to.x - flight.from.x) * t,
                                y: flight.from.y + (flight.to.y - flight.from.y) * t + flight.apex * 4 * t * (1 - t))
            case .rocket:
                let s = t * t * (3 - 2 * t)
                point = NSPoint(x: flight.from.x + (flight.to.x - flight.from.x) * s,
                                y: flight.from.y + (flight.to.y - flight.from.y) * s)
            case .leap, .doubleLeap, .hop:
                point = NSPoint(x: flight.from.x + (flight.to.x - flight.from.x) * t, y: arcState(flight, at: tau).y)
            }
            if let kick = flight.kickAt, !flight.kicked, tau >= kick {
                flight.kicked = true
                onKick?(NSPoint(x: point.x + petSize / 2, y: point.y + footInset))
            }
            if t >= 1 {
                self.flight = nil
                liftPoints = 0
                origin = flight.to
                onTouchdown?(NSPoint(x: flight.to.x + petSize / 2, y: flight.to.y + footInset), flight.style)
                land(on: flight.landing, now: now, cushion: flight.style != .plain, inPlace: flight.inPlace)
                return false
            }
            point.y -= lift
            origin = point
            self.flight = flight
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

    /// 落地。`cushion`：跳 / 飞落地（渲染层播 jump_land），路线还没走完时先停 `landPause` 让落地缓冲播出来再走下一段；
    /// `inPlace`：原地蹦，落回原处 —— 不算搬家、不动跳窗口 / 下窗口的计时器、不通知控制器。
    private func land(on target: Surface, now: Date, cushion: Bool = false, inPlace: Bool = false) {
        // 蹦出窗口边（落点没有台面）：接着往下掉。
        if target == .free, range != .screen {
            startFalling()
            return
        }
        surface = target
        ledgeAnchor = anchor(of: target)
        state = notifyUntil.map { now < $0 } == true ? .notify : .idle
        nextWanderAt = now.addingTimeInterval(Double.random(in: 3...8))
        // 路线没走完（迈上窗口顶、跳下来以后还要走过去）：接着下一段（tick 里 !busy 时开始）。
        if !route.isEmpty {
            if cushion { busyUntil = max(busyUntil, now.addingTimeInterval(landPause)) } else { startNextLeg(now: now) }
            return
        }
        hurry = false
        if inPlace { return }
        // 散步上下蹦的那一下不算搬家（家不会越蹦越远）。
        if routeIsStroll {
            routeIsStroll = false
            nextStrollAt = now.addingTimeInterval(strollInterval)
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
            nextLedgeJumpAt = max(nextLedgeJumpAt, now.addingTimeInterval(Double.random(in: 120...300)))
        }
    }

    /// 窗口模式下，隔几分钟跳上某个窗口；在窗口上待够了跳下来。返回 true = 起跳了。
    private func startWindowMove(now: Date) -> Bool {
        guard range == .windows, PetSettings.roam else { return false }
        if case .ledge(let id) = surface {
            guard now >= leaveLedgeAt else { return false }
            leaveLedgeAt = .distantFuture
            // 从近的那一头跳下去，落到那儿下面的窗口顶或地面（太高就背火箭飞下去）；落点出了屏幕就换另一头，两头都不行就再待会儿。
            guard let segment = ledges?().first(where: { $0.id == id })?.segment(containing: feet.x) else {
                startFalling()
                return true
            }
            guard let exit = ledgeExit(segment, toward: feet.x) else {
                leaveLedgeAt = now.addingTimeInterval(Double.random(in: 60...180))
                return false
            }
            let (below, top) = landingSurface(below: NSPoint(x: exit.center, y: feet.y - 1))
            takeoff(to: NSPoint(x: exit.center - petSize / 2, y: top - footInset), landing: below)
            return true
        }
        guard now >= nextLedgeJumpAt else { return false }
        nextLedgeJumpAt = now.addingTimeInterval(Double.random(in: 120...300))
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
        // 落点碍事（压着正在用的窗口）就不去，免得刚跳上去又被「让开」叫下来。
        guard (roamFilter ?? strollFilter)?(destination) ?? true else { return false }
        // 离得近就原地跳上去；远的先走到窗口侧边再跳（不然一跳横飞几百点），和控制器排的路线一样。
        if abs(destination.x - origin.x) <= bodyHeight * 1.5 {
            takeoff(to: destination, landing: .ledge(ledge.id))
        } else if let plan = ledgeLegs(onto: ledge, target: destination) {
            route = plan
            routeIsStroll = false
            pickGait(playful: true)
        } else {
            return false
        }
        return true
    }
}

extension ClosedRange where Bound == CGFloat {
    func clamp(_ value: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
