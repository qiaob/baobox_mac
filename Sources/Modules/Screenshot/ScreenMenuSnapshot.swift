import AppKit
import CoreGraphics

/// 「含菜单整屏」快照：菜单打开时按截图快捷键，在**收起菜单之前**抓一次
/// （每屏一张，含菜单等所有 on-screen 窗口）；截图 `begin` 在极短时间内取用作冻结底图，取后即弃。
///
/// 两条触发路径：
/// 1. 本 App 的状态栏菜单 —— CGEventTap 命中热键后、`dismissMenu()` 之前由 AppDelegate 调用；
/// 2. 其它 App 的右键菜单 / 菜单栏下拉 —— Carbon 热键能正常触发，但紧接着的
///    `NSApp.activate` + overlay 上屏会让对方菜单立刻收起，于是 `CaptureController.begin`
///    在动任何窗口之前先用 `hasForeignMenuOnScreen()` 探一下，命中就地抓一张。
///
/// 用同步的 `CGWindowListCreateImage`（能抓到菜单，且同步、无 async 时序问题）。仅主线程访问。
@MainActor
enum ScreenMenuSnapshot {
    private static var images: [CGDirectDisplayID: CGImage] = [:]
    private static var capturedAt: Date = .distantPast

    /// 抓所有屏幕当前画面（含菜单）。必须在收起菜单之前调用。
    static func captureAllScreens() {
        var result: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let boundsCG = Geometry.cgRect(fromAppKit: screen.frame)
            guard let image = CGWindowListCreateImage(boundsCG, .optionOnScreenOnly,
                                                      kCGNullWindowID, .bestResolution) else { continue }
            result[displayID] = image
        }
        images = result
        capturedAt = Date()
    }

    /// 取出并清空快照。仅当足够新鲜（< 0.5s，确保确实是本次菜单场景抓的）才返回，否则视为陈旧丢弃。
    static func take() -> [CGDirectDisplayID: CGImage] {
        defer { images = [:] }
        guard Date().timeIntervalSince(capturedAt) < 0.5 else { return [:] }
        return images
    }

    /// 屏上是否有**别的 App** 的弹出菜单（右键菜单、菜单栏下拉、状态栏图标菜单）。
    ///
    /// NSMenu 的承载窗口固定在 `kCGPopUpMenuWindowLevelKey`(101)，用窗口层精确等值匹配即可；
    /// 放宽成 `>=` 会把拖拽层、屏保层等一并算进来，导致每次截图都误入冻结模式。
    /// 只做一次窗口列表查询（不抓图），命中才付整屏快照的代价。
    static func hasForeignMenuOnScreen() -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let myPID = getpid()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == menuLevel else { continue }
            // 本 App 自己的菜单走 CGEventTap 那条路径，这里跳过，避免重复抓图。
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID else { continue }
            // 透明或过小的占位窗口不算「屏上有菜单」。
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if alpha <= 0.01 { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 20, bounds.height >= 20 else { continue }
            return true
        }
        return false
    }
}
