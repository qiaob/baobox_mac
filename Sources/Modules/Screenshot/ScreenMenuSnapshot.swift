import AppKit
import CoreGraphics

/// 「含菜单整屏」快照：状态栏菜单打开时按截图快捷键，CGEventTap 命中、**收起菜单之前**抓一次
/// （每屏一张，含菜单等所有 on-screen 窗口）；截图 `begin` 在极短时间内取用作冻结底图，取后即弃。
///
/// 用同步的 `CGWindowListCreateImage`（能抓到状态栏菜单，且同步、无 async 时序问题）。仅主线程访问。
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
}
