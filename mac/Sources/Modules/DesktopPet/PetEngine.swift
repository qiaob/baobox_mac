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
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setOrigin(_ point: NSPoint) {
        origin = point
    }

    func setDragged(_ dragging: Bool) {
        if dragging {
            flight = nil
            fallVelocity = nil
            state = .dragged
        } else if state == .dragged {
            state = .idle
            nextWanderAt = Date().addingTimeInterval(6)
            settle(animated: true)
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
        if state == .sleep || state == .wander || state == .rest {
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
                if !busy, shouldSleep(now) {
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
                } else if state == .idle, !held, !busy, startWindowMove(now: now) {
                    // 跳上 / 跳下窗口已经开始。
                } else if state == .idle, case .ledge = surface, !held, !busy, now >= nextRestAt {
                    state = .rest
                    stateUntil = now.addingTimeInterval(Double.random(in: 20...60))
                    nextRestAt = now.addingTimeInterval(Double.random(in: 40...90))
                } else if state == .idle, PetSettings.roam, !held, !busy, now >= nextWanderAt {
                    state = .wander
                    stateUntil = now.addingTimeInterval(Double.random(in: 3...7))
                    walkDirection = Bool.random() ? 1 : -1
                } else if state == .wander, let until = stateUntil, now >= until {
                    state = .idle
                    stateUntil = nil
                    nextWanderAt = now.addingTimeInterval(Double.random(in: 8...20))
                }
            }
        }

        if state == .wander {
            let span = walkSpan()
            var x = origin.x + walkDirection * walkSpeed * dt
            if x < span.lowerBound {
                x = span.lowerBound
                walkDirection = 1
            }
            if x > span.upperBound {
                x = span.upperBound
                walkDirection = -1
            }
            origin.x = x
            pose.walkPhase += dt * 9
        }
        finishFrame(now: now)
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
                origin.x += ledge.frame.minX - anchor.x
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
    }

    private func jump(to destination: NSPoint, landing: Surface, apex: CGFloat) {
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
