import AppKit

/// 宠物的一个落脚点：宠物窗左下角放在哪、站在哪个窗口顶上（nil = 地面 / 随意放的那条线）。
struct PetSpot {
    let origin: NSPoint
    let ledgeID: CGWindowID?
    var cost: Double = 0
}

/// 给落脚点打「碍事分」（docs/desktop-pet/SETTLE.md §3），越低越好：
/// - 挡住了什么：身子上撒 4×6 个点，看每个点下面最上层是谁 —— 正在用的 App 的窗口 1 分、刚用过的 App 的窗口 0.9 分
///   （十分钟内慢慢降回 0.35，来回切换两个并排的 App 时不会每切一次就跑到另一边）、别的窗口 0.35 分、桌面 0 分，取平均；
/// - 开了「识别屏幕内容」且拿到了画面：挡住窗口的那部分再乘上画面有多「满」（纯色空白处只算三成）；
/// - 离最近在它旁边点过的地方太近：加分（你正在那儿干活）。鼠标只是停在附近不算 —— 不然你想摸它它就跑了。
/// 只用窗口的位置与所属 App（不读标题和内容），不需要权限。
struct PetSpotScorer {
    /// 宠物窗边长、脚离窗口底边多远、身子占窗口的宽 / 高比例。
    let side: CGFloat
    let footInset: CGFloat
    let bodyWidth: CGFloat
    let bodyHeight: CGFloat
    /// 普通 App 窗口，从前往后。
    let windows: [PetWindowInfo]
    /// 正在用的 App（最前面的那个）。
    let activePID: pid_t?
    /// 最近用过的 App → 挡住它的窗口算几分（没列的 0.35）。
    var recentWeights: [pid_t: Double] = [:]
    /// 最近几秒在宠物旁边点过的位置。
    let recentClicks: [NSPoint]
    /// 一块区域的画面有多满（0 空白 – 1 满）；nil = 没有画面信息。
    let busyness: ((NSRect) -> Double?)?

    /// 宠物站在 `origin` 时身子占的矩形（屏幕坐标）。
    func body(at origin: NSPoint) -> NSRect {
        let width = side * bodyWidth, height = side * bodyHeight
        return NSRect(x: origin.x + (side - width) / 2, y: origin.y + footInset, width: width, height: height)
    }

    /// 挡住了多少东西（0–1）。
    func coverage(at origin: NSPoint) -> Double {
        let rect = body(at: origin)
        let cols = 4, rows = 6
        var total = 0.0
        for i in 0..<cols {
            for j in 0..<rows {
                let point = NSPoint(x: rect.minX + rect.width * (CGFloat(i) + 0.5) / CGFloat(cols),
                                    y: rect.minY + rect.height * (CGFloat(j) + 0.5) / CGFloat(rows))
                if let top = windows.first(where: { $0.frame.contains(point) }) {
                    total += top.pid == activePID ? 1 : (recentWeights[top.pid] ?? 0.35)
                }
            }
        }
        var value = total / Double(cols * rows)
        if value > 0, let busy = busyness?(rect) { value *= 0.3 + 0.7 * busy }
        return value
    }

    /// 碍事分：挡住的东西 + 离最近点过的地方太近。
    func cost(at origin: NSPoint) -> Double {
        let rect = body(at: origin)
        var value = coverage(at: origin)
        let reach = max(rect.height, 80)
        for click in recentClicks {
            let d = Self.distance(from: click, to: rect)
            if d < reach { value += 0.45 * Double(1 - d / reach) }
        }
        return value
    }

    private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// 随意放（没有重力）：整块屏的可见区里撒网格，上下左右都能去（2026-11-07 用户选「整个屏幕都找」）。
    static func freeCandidates(visible: NSRect, side: CGFloat) -> [PetSpot] {
        let step = max(side * 0.2, 16)
        var spots: [PetSpot] = []
        var y = visible.minY
        while y <= visible.maxY - side {
            var x = visible.minX
            while x <= visible.maxX - side {
                spots.append(PetSpot(origin: NSPoint(x: x.rounded(), y: y.rounded()), ledgeID: nil))
                x += step
            }
            y += step
        }
        return spots
    }

    /// 候选落脚点：脚下那条线（地面）上每隔一小段一个；窗口模式再加每个窗口顶边上没被挡住的那几段
    /// （上方放得下宠物、明显高于地面，与引擎自己跳窗口的条件一样）。
    static func candidates(line: (span: ClosedRange<CGFloat>, y: CGFloat), ledges: [PetLedge], includeLedges: Bool,
                           side: CGFloat, footInset: CGFloat, visible: NSRect) -> [PetSpot] {
        let step = max(side * 0.12, 12)
        var spots: [PetSpot] = []
        var x = line.span.lowerBound
        while x <= line.span.upperBound {
            spots.append(PetSpot(origin: NSPoint(x: x.rounded(), y: line.y), ledgeID: nil))
            x += step
        }
        if spots.last.map({ $0.origin.x < line.span.upperBound - 1 }) ?? true {
            spots.append(PetSpot(origin: NSPoint(x: line.span.upperBound.rounded(), y: line.y), ledgeID: nil))
        }
        guard includeLedges else { return spots }
        for ledge in ledges where ledge.frame.intersects(visible) {
            let y = ledge.frame.maxY - footInset
            guard y + side <= visible.maxY, ledge.frame.maxY > visible.minY + 60 else { continue }
            for segment in ledge.segments where segment.upperBound - segment.lowerBound >= side * 0.6 {
                // 宠物中心离这段两头至少 0.3 个窗宽，站得稳。
                let low = max(segment.lowerBound, visible.minX) + side * 0.3 - side / 2
                let high = min(segment.upperBound, visible.maxX) - side * 0.3 - side / 2
                guard high >= low else { continue }
                var x = low
                while x <= high {
                    spots.append(PetSpot(origin: NSPoint(x: x.rounded(), y: y), ledgeID: ledge.id))
                    x += step
                }
            }
        }
        return spots
    }
}
