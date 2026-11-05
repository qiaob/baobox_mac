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
}

/// 宠物行为状态机（设计 §6）。只产出窗口位置与姿态，不管 2D / 3D 怎么画。
@MainActor
final class PetEngine {
    enum State {
        case idle, wander, sleep, notify, dragged
    }

    private(set) var state: State = .idle
    private(set) var pose = PetPose()
    private(set) var origin = NSPoint.zero

    /// 每帧回调：（姿态， 窗口左下角屏幕坐标）。
    var onPose: ((PetPose, NSPoint) -> Void)?

    var petSize: CGFloat = 104

    private var timer: Timer?
    private var stateUntil: Date?
    private var nextWanderAt = Date().addingTimeInterval(6)
    private var blinkStart = Date().addingTimeInterval(2.5)
    private var walkDirection: CGFloat = 1
    private var notifyStartedAt: Date?
    private var notifyUntil: Date?
    private var notifyDuration: TimeInterval = 1

    func start(at origin: NSPoint) {
        self.origin = origin
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
            state = .dragged
        } else if state == .dragged {
            state = .idle
            nextWanderAt = Date().addingTimeInterval(6)
        }
    }

    /// 收到通知时的提醒动作：从睡眠中醒来并跳一下（alert 跳得更高、更久）。
    /// 拖拽中不改状态 —— 否则提醒结束后引擎会在用户手里开始走动；松手后 tick 按 notifyUntil 补上提醒动作。
    func notify(level: PetNotification.Level) {
        if state == .sleep { state = .idle }
        notifyStartedAt = Date()
        notifyDuration = level == .alert ? 1.5 : 0.9
        notifyUntil = Date().addingTimeInterval(notifyDuration)
        if state != .dragged { state = .notify }
    }

    private var sleepCheckedAt = Date.distantPast
    private var sleepCached = false

    /// 勿扰 / 长空闲判定。查窗口列表（全屏检测）和 HID 空闲时间都要跨进程，
    /// tick 是 30fps，每秒算一次就够（实测每帧都查时空闲 CPU 约 10%）。
    private func shouldSleep(_ now: Date) -> Bool {
        if now.timeIntervalSince(sleepCheckedAt) >= 1 {
            sleepCheckedAt = now
            sleepCached = NotifyDND.shared.isSuppressed || Self.secondsSinceAnyInput() > 300
        }
        return sleepCached
    }

    private func tick() {
        let now = Date()
        let dt = 1.0 / 30.0

        if state != .dragged {
            if let until = notifyUntil, now < until {
                state = .notify
            } else if state == .notify {
                state = .idle
                notifyUntil = nil
                nextWanderAt = now.addingTimeInterval(Double.random(in: 6...14))
            }
            if state != .notify {
                if shouldSleep(now) {
                    state = .sleep
                } else if state == .sleep {
                    state = .idle
                }
                if state == .idle, PetSettings.roam, now >= nextWanderAt {
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
            let frame = visibleFrame()
            var x = origin.x + walkDirection * 34 * dt
            if x < frame.minX {
                x = frame.minX
                walkDirection = 1
            }
            if x > frame.maxX - petSize {
                x = frame.maxX - petSize
                walkDirection = -1
            }
            origin.x = x
            pose.walkPhase += dt * 9
        }

        pose.state = state
        pose.facingLeft = walkDirection < 0
        pose.time = now.timeIntervalSinceReferenceDate
        pose.lying = state == .sleep
        pose.bob = state == .idle ? CGFloat(sin(pose.time * 1.7)) * 1.4 : 0
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
        if state == .notify, let start = notifyStartedAt {
            let p = now.timeIntervalSince(start) / max(notifyDuration, 0.01)
            pose.bounce = p < 1 ? CGFloat(sin(min(p, 1) * .pi)) * 13 : 0
        } else {
            pose.bounce = 0
        }

        onPose?(pose, origin)
    }

    /// 宠物当前所在屏的可见区（走动范围）。
    private func visibleFrame() -> NSRect {
        let probe = NSPoint(x: origin.x + petSize / 2, y: origin.y + petSize / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? .zero
    }

    /// 距最近一次键鼠输入的秒数（取多类事件的最小值，即最近的活动）。
    private static func secondsSinceAnyInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? 0
    }
}
