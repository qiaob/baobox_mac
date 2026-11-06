import AppKit

/// 出场 / 退场的编排（#54，设计 docs/desktop-pet/ENTRANCE.md）：脚下张开一个黑洞，
/// 出场时宠物从黑洞里蹦出来、落地，黑洞合上；退场时黑洞张开，宠物钻进去，黑洞合上。
///
/// 只算数，不碰窗口：给定时间 → 宠物窗位置、渲染层看到的状态、透明度、形变、黑洞开多大、
/// 宠物在哪条线以下被「吞掉」（看不见）。由 `PetController` 逐帧交给引擎（`PetEngine.runScript`）执行。
struct PetEntrancePlan {
    struct Frame {
        var origin: NSPoint
        var look: PetEngine.State
        var attentive: Bool
        var bounce: CGFloat = 0
        var alpha: CGFloat = 1
        /// 以脚底中点为原点的横竖缩放（钻进去时被挤长、落地压一下）。
        var scale = CGSize(width: 1, height: 1)
        var facingLeft: Bool?
        /// 黑洞张开的程度（0 = 没有，1 = 全开）。
        var hole: CGFloat = 0
        /// 这条线（屏幕 y）以下的宠物看不见：钻进洞里的那部分。nil = 不裁。
        var swallowLine: CGFloat?
    }

    /// 黑洞在哪（屏幕坐标，椭圆中心 = 宠物脚底）、多宽。淡入淡出的编排没有黑洞。
    struct Hole {
        let center: NSPoint
        let width: CGFloat
    }

    let duration: TimeInterval
    let hole: Hole?
    let sample: (TimeInterval) -> Frame

    /// 出场（约 1.1 秒）：黑洞在脚下张开 → 宠物从洞里蹦出来（被拉长）、越过原位再落下、落地压一下 → 黑洞合上 →
    /// 转过来面向用户。`greetClip`：形象有招手片段（VRM），由控制器在播完后接上；没有的最后弹一下当招呼。
    static func enter(home: NSPoint, side: CGFloat, footInset: CGFloat, holeWidth: CGFloat,
                      greetClip: Bool) -> PetEntrancePlan {
        let line = home.y + footInset
        let hole = Hole(center: NSPoint(x: home.x + side / 2, y: line), width: holeWidth)
        let below = NSPoint(x: home.x, y: home.y - side)      // 整个宠物都在洞线以下
        let peak = home.y + side * 0.35
        let open = 0.22, rise = 0.3, fall = 0.2, land = 0.25, greet = 0.2
        let tRise = open, tFall = tRise + rise, tLand = tFall + fall, tGreet = tLand + land
        return PetEntrancePlan(duration: tGreet + greet, hole: hole) { t in
            if t < tRise {
                return Frame(origin: below, look: .jump, attentive: false, hole: CGFloat(ease(t / open)), swallowLine: line)
            }
            if t < tFall {
                // 从洞里往上冲（先快后慢），身子被拉长。
                let u = CGFloat((t - tRise) / rise)
                let y = below.y + (peak - below.y) * (1 - (1 - u) * (1 - u))
                let stretch = (1 - u) * 0.18
                return Frame(origin: NSPoint(x: home.x, y: y), look: .jump, attentive: false,
                             scale: CGSize(width: 1 - stretch * 0.5, height: 1 + stretch), hole: 1, swallowLine: line)
            }
            if t < tLand {
                let u = (t - tFall) / fall
                let k = CGFloat(u)
                let y = peak + (home.y - peak) * k * k
                return Frame(origin: NSPoint(x: home.x, y: y), look: .fall, attentive: false,
                             hole: CGFloat(1 - ease(u)), swallowLine: nil)
            }
            if t < tGreet {
                let v = (t - tLand) / land
                // 落地：先压扁再弹一点，越来越小。
                let k = CGFloat(sin(2 * .pi * v) * (1 - v))
                return Frame(origin: home, look: .idle, attentive: true,
                             scale: CGSize(width: 1 + 0.12 * k, height: 1 - 0.18 * k))
            }
            if greetClip { return Frame(origin: home, look: .idle, attentive: true) }
            let w = min((t - tGreet) / greet, 1)
            let pop = CGFloat(sin(.pi * w))
            return Frame(origin: home, look: .notify, attentive: true, bounce: pop * 10,
                         scale: CGSize(width: 1 + 0.06 * pop, height: 1 + 0.06 * pop))
        }
    }

    /// 退场（约 1 秒）：道别（有道别片段的播片段，没有的弹一下）→ 黑洞在脚下张开，宠物往上一缩身子钻进去
    /// （越钻越快，身子被挤长）→ 黑洞合上。`quick`（退出 Baobox）：不道别、动作加快，0.5 秒内做完。
    static func leave(home: NSPoint, side: CGFloat, footInset: CGFloat, holeWidth: CGFloat,
                      farewellClip: Bool, quick: Bool) -> PetEntrancePlan {
        let line = home.y + footInset
        let hole = Hole(center: NSPoint(x: home.x + side / 2, y: line), width: holeWidth)
        // 道别片段（VRM 0.55 秒）要播完再动：跳的状态会打断它。
        let wave = quick ? 0 : (farewellClip ? 0.5 : 0.35)
        let open = quick ? 0.1 : 0.2
        let dive = quick ? 0.25 : 0.35
        let close = quick ? 0.1 : 0.18
        let tOpen = wave, tDive = tOpen + open, tClose = tDive + dive
        let bottom = home.y - side * 1.05
        return PetEntrancePlan(duration: tClose + close, hole: hole) { t in
            if t < tOpen {
                let w = t / max(wave, 0.01)
                if farewellClip { return Frame(origin: home, look: .idle, attentive: true) }
                return Frame(origin: home, look: .notify, attentive: true, bounce: CGFloat(sin(.pi * w)) * 10)
            }
            if t < tDive {
                // 黑洞张开，宠物蹲一下准备钻。
                let u = (t - tOpen) / open
                let crouch = CGFloat(sin(.pi * u)) * 0.12
                return Frame(origin: home, look: .idle, attentive: false,
                             scale: CGSize(width: 1 + crouch * 0.6, height: 1 - crouch), hole: CGFloat(ease(u)),
                             swallowLine: line)
            }
            if t < tClose {
                // 钻进去：先往上一窜再一头扎下去，越来越快；身子被洞挤长。
                let u = CGFloat((t - tDive) / dive)
                let hop: CGFloat = side * 0.48 * u * (1 - u)
                let sink: CGFloat = (bottom - home.y) * u * u
                let y = home.y + hop + sink
                let squeeze = u * 0.25
                return Frame(origin: NSPoint(x: home.x, y: y), look: .fall, attentive: false,
                             scale: CGSize(width: 1 - squeeze, height: 1 + squeeze), hole: 1, swallowLine: line)
            }
            let u = (t - tClose) / close
            return Frame(origin: NSPoint(x: home.x, y: bottom), look: .fall, attentive: false, alpha: 0,
                         hole: CGFloat(1 - ease(u)), swallowLine: line)
        }
    }

    /// 系统打开了「减弱动态效果」：原地淡入 / 淡出，没有黑洞。
    static func fade(home: NSPoint, appearing: Bool) -> PetEntrancePlan {
        let duration = appearing ? 0.3 : 0.25
        return PetEntrancePlan(duration: duration, hole: nil) { t in
            let p = CGFloat(min(t / duration, 1))
            return Frame(origin: home, look: .idle, attentive: appearing, alpha: appearing ? p : 1 - p)
        }
    }

    /// 0 → 1 先快后慢。
    private static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return 1 - (1 - t) * (1 - t)
    }
}
