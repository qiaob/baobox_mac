import AppKit

/// 出场 / 退场的编排（#54，设计 docs/desktop-pet/ENTRANCE.md）：给定时间 → 宠物窗位置、渲染层看到的状态、
/// 透明度与形变。只算数，不碰窗口；由 `PetController` 逐帧交给引擎（`PetEngine.runScript`）执行。
struct PetEntrancePlan {
    struct Frame {
        var origin: NSPoint
        var look: PetEngine.State
        var attentive: Bool
        var bounce: CGFloat = 0
        var alpha: CGFloat = 1
        /// 以脚底中点为原点的横竖缩放（落地压一下、2D 退场缩小）。
        var scale = CGSize(width: 1, height: 1)
        var facingLeft: Bool?
    }

    let duration: TimeInterval
    let sample: (TimeInterval) -> Frame

    /// 出场：从屏幕底边外跳上来落到原位，落地压一下再弹起，然后转过来面向用户。
    /// `greetClip`：形象有招手片段（VRM），由控制器在播完后接上；没有的最后弹一下、放大一点当招呼。约 1 秒。
    static func enter(home: NSPoint, side: CGFloat, screen: NSRect, greetClip: Bool) -> PetEntrancePlan {
        let start = NSPoint(x: home.x, y: screen.minY - side - 4)
        // 抛物线顶点比原位高出一截：从下面「跳上来」，越过落点再落下去。
        let apex = max(home.y - start.y, 0) * 0.35 + side * 0.4
        let rise = 0.5, land = 0.28, greet = 0.22
        return PetEntrancePlan(duration: rise + land + greet) { t in
            if t < rise {
                let u = t / rise
                let y = start.y + (home.y - start.y) * u + apex * 4 * u * (1 - u)
                return Frame(origin: NSPoint(x: home.x, y: y), look: u < 0.5 ? .jump : .fall, attentive: false)
            }
            if t < rise + land {
                let v = (t - rise) / land
                // 先压扁再拉长一点，越来越小：sin 的前半周压、后半周弹。
                let k = CGFloat(sin(2 * .pi * v) * (1 - v))
                return Frame(origin: home, look: .idle, attentive: true,
                             scale: CGSize(width: 1 + 0.12 * k, height: 1 - 0.18 * k))
            }
            let w = min((t - rise - land) / greet, 1)
            if greetClip { return Frame(origin: home, look: .idle, attentive: true) }
            let pop = CGFloat(sin(.pi * w))
            return Frame(origin: home, look: .notify, attentive: true, bounce: pop * 10,
                         scale: CGSize(width: 1 + 0.06 * pop, height: 1 + 0.06 * pop))
        }
    }

    /// 退场：先道别（有道别片段的播片段，没有的弹一下），再往近的那侧屏幕边一蹦、掉出屏幕底边，最后一段淡出；
    /// 2D 一路缩小。`quick`（退出 Baobox）：不道别，只留掉下去那一段，0.4 秒内做完。
    static func leave(home: NSPoint, side: CGFloat, screen: NSRect, is3D: Bool, farewellClip: Bool,
                      quick: Bool) -> PetEntrancePlan {
        // 道别片段（VRM 0.55 秒）要播完再起跳：跳的状态会打断它。
        let wave = quick ? 0 : (farewellClip ? 0.5 : 0.4)
        let drop = farewellClip && !quick ? 0.35 : 0.4
        let toLeft = home.x + side / 2 - screen.minX < screen.maxX - home.x - side / 2
        let end = NSPoint(x: home.x + (toLeft ? -1 : 1) * side * 0.5, y: screen.minY - side - 4)
        let apex = side * 0.25
        return PetEntrancePlan(duration: wave + drop) { t in
            if t < wave {
                let w = t / wave
                if farewellClip { return Frame(origin: home, look: .idle, attentive: true) }
                return Frame(origin: home, look: .notify, attentive: true, bounce: CGFloat(sin(.pi * w)) * 10)
            }
            let u = min((t - wave) / drop, 1)
            let x = home.x + (end.x - home.x) * u
            // 先往上蹦一点再加速往下掉（u² 让下落越来越快）。
            let y = home.y + (end.y - home.y) * u * u + apex * 4 * u * (1 - u)
            let fade = CGFloat(1 - max(0, (u - 0.6) / 0.4))
            let shrink = is3D ? 1 : CGFloat(1 - 0.6 * u)
            return Frame(origin: NSPoint(x: x, y: y), look: u < 0.3 ? .jump : .fall, attentive: false,
                         alpha: fade, scale: CGSize(width: shrink, height: shrink), facingLeft: toLeft)
        }
    }

    /// 系统打开了「减弱动态效果」：原地淡入 / 淡出。
    static func fade(home: NSPoint, appearing: Bool) -> PetEntrancePlan {
        let duration = appearing ? 0.3 : 0.25
        return PetEntrancePlan(duration: duration) { t in
            let p = CGFloat(min(t / duration, 1))
            return Frame(origin: home, look: .idle, attentive: appearing, alpha: appearing ? p : 1 - p)
        }
    }

    /// 宠物所在的屏（按窗口中心找；找不到用主屏）。
    static func screenFrame(containing origin: NSPoint, side: CGFloat) -> NSRect {
        let center = NSPoint(x: origin.x + side / 2, y: origin.y + side / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        return screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
