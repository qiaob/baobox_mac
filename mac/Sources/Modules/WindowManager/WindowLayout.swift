import AppKit

/// 窗口布局动作。几何计算全部为纯函数，便于单元测试，不触碰 AX / 系统状态。
///
/// 坐标约定：本文件所有 NSRect 参数与返回值均为 **AppKit 坐标（AK，主屏左下原点、y 向上）**，
/// 与 `NSScreen.frame` / `NSScreen.visibleFrame` 同系。与 AX（CG 全局，左上原点）的换算
/// 一律在调用方经 `Geometry` 完成，本文件不做坐标翻转。
enum WindowLayout {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center
    case nextDisplay, prevDisplay, restore

    /// 是否为对单屏做几何切分的布局（半屏 / 四分屏 / 最大化 / 居中）。
    var isSlicing: Bool {
        switch self {
        case .nextDisplay, .prevDisplay, .restore: return false
        default: return true
        }
    }
}

extension WindowLayout {
    /// 目标屏判定：与窗口 AK frame **交集面积最大**的屏；零交集（窗口游离）时回退到
    /// `mouseScreen`（鼠标所在屏），再退回列表首个。空列表返回 nil。
    static func targetScreen(forWindowAK frameAK: NSRect,
                             screens: [NSScreen],
                             mouseScreen: NSScreen?) -> NSScreen? {
        guard !screens.isEmpty else { return nil }
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let inter = screen.frame.intersection(frameAK)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        if let best, bestArea > 0 { return best }
        return mouseScreen ?? screens.first
    }

    /// 屏幕排序：先按 `frame.origin.x`，再按 `frame.origin.y`，保证 next/prev 循环顺序稳定。
    static func sortedScreens(_ screens: [NSScreen]) -> [NSScreen] {
        screens.sorted {
            if $0.frame.origin.x != $1.frame.origin.x {
                return $0.frame.origin.x < $1.frame.origin.x
            }
            return $0.frame.origin.y < $1.frame.origin.y
        }
    }

    /// 切分布局的目标 frame（AK）。基准区域一律用 `screen.visibleFrame`——自动避开菜单栏与 Dock，
    /// 且每屏各自不同，这是多屏正确性的关键。四周内缩 `gap`，切分线两侧各留 `gap/2`。
    /// `.center` 保持窗口原尺寸仅平移到 visibleFrame 中心；跨屏 / 恢复类布局原样返回 frameAK。
    static func targetFrameAK(for layout: WindowLayout,
                             window frameAK: NSRect,
                             on screen: NSScreen,
                             gap: CGFloat) -> NSRect {
        let vf = screen.visibleFrame
        let g = max(0, gap)
        let half = g / 2

        switch layout {
        case .maximize:
            return vf.insetBy(dx: g, dy: g)

        case .center:
            var r = frameAK
            r.origin.x = vf.minX + (vf.width - r.width) / 2
            r.origin.y = vf.minY + (vf.height - r.height) / 2
            return r

        case .left:
            return NSRect(x: vf.minX + g, y: vf.minY + g,
                          width: vf.width / 2 - g - half, height: vf.height - 2 * g)
        case .right:
            return NSRect(x: vf.midX + half, y: vf.minY + g,
                          width: vf.width / 2 - g - half, height: vf.height - 2 * g)
        case .top:
            // AK：上半屏位于较高的 y。
            return NSRect(x: vf.minX + g, y: vf.midY + half,
                          width: vf.width - 2 * g, height: vf.height / 2 - g - half)
        case .bottom:
            return NSRect(x: vf.minX + g, y: vf.minY + g,
                          width: vf.width - 2 * g, height: vf.height / 2 - g - half)

        case .topLeft:
            return NSRect(x: vf.minX + g, y: vf.midY + half,
                          width: vf.width / 2 - g - half, height: vf.height / 2 - g - half)
        case .topRight:
            return NSRect(x: vf.midX + half, y: vf.midY + half,
                          width: vf.width / 2 - g - half, height: vf.height / 2 - g - half)
        case .bottomLeft:
            return NSRect(x: vf.minX + g, y: vf.minY + g,
                          width: vf.width / 2 - g - half, height: vf.height / 2 - g - half)
        case .bottomRight:
            return NSRect(x: vf.midX + half, y: vf.minY + g,
                          width: vf.width / 2 - g - half, height: vf.height / 2 - g - half)

        case .nextDisplay, .prevDisplay, .restore:
            return frameAK
        }
    }

    /// 把 frame 夹进可见区域：尺寸超出时先缩小，再平移回区域内。
    /// 恢复类操作（恢复槽、布局快照）都要经此防止窗口落到已不存在的屏幕区域。
    static func clamped(_ frameAK: NSRect, into visible: NSRect) -> NSRect {
        var r = frameAK
        r.size.width = min(r.width, visible.width)
        r.size.height = min(r.height, visible.height)
        r.origin.x = min(max(r.minX, visible.minX), visible.maxX - r.width)
        r.origin.y = min(max(r.minY, visible.minY), visible.maxY - r.height)
        return r
    }

    /// 跨屏等比映射：把窗口在源屏 visibleFrame 内的相对位置与相对尺寸映射到目标屏 visibleFrame，
    /// 映射后 clamp 确保完全落在目标屏内（不同分辨率 / 缩放比之间不变形溢出）。
    static func mappedFrameAK(window frameAK: NSRect,
                             from source: NSScreen,
                             to dest: NSScreen) -> NSRect {
        let sf = source.visibleFrame
        let df = dest.visibleFrame

        let relW = sf.width > 0 ? frameAK.width / sf.width : 1
        let relH = sf.height > 0 ? frameAK.height / sf.height : 1
        let relX = sf.width > 0 ? (frameAK.minX - sf.minX) / sf.width : 0
        let relY = sf.height > 0 ? (frameAK.minY - sf.minY) / sf.height : 0

        var w = min(relW * df.width, df.width)
        var h = min(relH * df.height, df.height)
        w = max(0, w)
        h = max(0, h)

        var x = df.minX + relX * df.width
        var y = df.minY + relY * df.height

        // clamp：完全落入目标屏 visibleFrame。
        x = min(max(x, df.minX), df.maxX - w)
        y = min(max(y, df.minY), df.maxY - h)

        return NSRect(x: x, y: y, width: w, height: h)
    }
}
