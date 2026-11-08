import AppKit
import CoreGraphics
import os

/// 截图的冻结底图：整屏快照（每屏一张，含菜单等所有 on-screen 窗口）；截图 `begin` 在极短时间内取用，取后即弃。
/// 名字沿用「只在菜单场景冻结」时期的叫法 —— 2026-11-08 起截图与取字**每次**都冻结整屏（CaptureController.begin）。
///
/// 两条抓图路径：
/// 1. 本 App 的菜单开着（状态栏菜单、设置里的下拉框、右键菜单）—— CGEventTap 命中热键后、收起菜单之前
///    由 AppDelegate（`HotkeyCenter.onBeforeFire`）抓，菜单才截得进去；
/// 2. 其余情况 —— `CaptureController.begin` 在创建任何窗口、激活本 App 之前就地抓。别的 App 的菜单也靠这一步：
///    之后的 `NSApp.activate` + overlay 上屏会让对方菜单立刻收起（issue #6）。
///
/// 用同步的 `CGWindowListCreateImage`（能抓到菜单，且同步、无 async 时序问题）。仅主线程访问。
@MainActor
enum ScreenMenuSnapshot {
    private static let log = Logger(subsystem: "com.baobox.app", category: "capture")

    private static var images: [CGDirectDisplayID: CGImage] = [:]
    private static var capturedAt: Date = .distantPast

    /// 抓所有屏幕当前画面（含菜单）。菜单场景必须在收起菜单之前调用。
    /// 每次截图都要先等它（同步、主线程），耗时记进日志（category `capture`），好看出多屏 / 大屏下按快捷键到出蒙层慢了多少。
    static func captureAllScreens() {
        let started = Date()
        var result: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let boundsCG = Geometry.cgRect(fromAppKit: screen.frame)
            guard let image = captureScreen(boundsCG: boundsCG, screen: screen) else { continue }
            result[displayID] = image
        }
        images = result
        capturedAt = Date()
        let ms = Int(capturedAt.timeIntervalSince(started) * 1000)
        log.notice("frozen snapshot: \(result.count) of \(NSScreen.screens.count) screen(s) in \(ms) ms")
    }

    /// 抓一屏并校验实际像素。`CGWindowListCreateImage` 偶尔会无视 `.bestResolution`
    /// 按 1x 出图（与 #40 里 SCK 的出图缩水同类），而这张快照是冻结模式下所有截图
    /// 路径的底图，源头低清则整链低清：按该屏 backing 倍率算期望像素（容差 1px，
    /// 期望值经 rounded() 取整），不足就重抓一次取较大者，并留日志便于在 Console 复核。
    private static func captureScreen(boundsCG: CGRect, screen: NSScreen) -> CGImage? {
        guard let first = CGWindowListCreateImage(boundsCG, .optionOnScreenOnly,
                                                  kCGNullWindowID, .bestResolution) else { return nil }
        let scale = max(screen.backingScaleFactor, 1)
        let expectedW = Int((screen.frame.width * scale).rounded())
        let expectedH = Int((screen.frame.height * scale).rounded())
        guard first.width < expectedW - 1 || first.height < expectedH - 1 else { return first }
        log.warning("menu snapshot below native size: got \(first.width)×\(first.height), want \(expectedW)×\(expectedH); retrying once")
        guard let second = CGWindowListCreateImage(boundsCG, .optionOnScreenOnly,
                                                   kCGNullWindowID, .bestResolution) else { return first }
        let best = second.width * second.height >= first.width * first.height ? second : first
        log.warning("menu snapshot retry result: \(best.width)×\(best.height)")
        return best
    }

    /// 取出并清空快照。仅当足够新鲜（< 0.5s，确保确实是本次截图抓的）才返回，否则视为陈旧丢弃。
    static func take() -> [CGDirectDisplayID: CGImage] {
        defer { images = [:] }
        guard Date().timeIntervalSince(capturedAt) < 0.5 else { return [:] }
        return images
    }
}
