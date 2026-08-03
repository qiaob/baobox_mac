import AppKit

/// 坐标系转换工具。
/// CoreGraphics 全局坐标（CGWindowList/CGEvent）原点在主屏左上角、y 向下；
/// AppKit（NSScreen/NSWindow/NSView 非翻转）原点在主屏左下角、y 向上。
/// 所有跨界转换统一走此处，变量名以 CG / AK 后缀标注坐标系。
enum Geometry {
    /// 主屏高度。注意用 screens[0]（主屏），不是 main（当前 key 窗所在屏）。
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cgRect(fromAppKit r: NSRect) -> CGRect {
        let h = primaryScreenHeight
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func appKitRect(fromCG r: CGRect) -> NSRect {
        let h = primaryScreenHeight
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func cgPoint(fromAppKit p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryScreenHeight - p.y)
    }
}

extension NSScreen {
    /// NSScreen 对应的 CGDirectDisplayID。
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
