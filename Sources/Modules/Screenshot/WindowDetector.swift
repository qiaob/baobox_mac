import AppKit
import CoreGraphics

/// 命中检测到的窗口信息（frame 为 CG 全局坐标）。
struct DetectedWindow {
    let windowID: CGWindowID
    let frameCG: CGRect
    let appName: String
    let title: String?
    let ownerPID: pid_t
}

/// 基于 CGWindowList 的窗口命中检测。
enum WindowDetector {
    /// 返回位于 CG 全局坐标 point 下、最前面的一个满足条件的窗口。
    static func window(atCG point: CGPoint) -> DetectedWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let myPID = getpid()

        // list 为前到后顺序，取第一个命中的即为最上层窗口。
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if alpha <= 0 { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if bounds.width < 40 || bounds.height < 40 { continue }
            if !bounds.contains(point) { continue }
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }

            let appName = info[kCGWindowOwnerName as String] as? String ?? L("screenshot.detector.unknownApp")
            let title = info[kCGWindowName as String] as? String
            return DetectedWindow(windowID: windowID, frameCG: bounds, appName: appName, title: title, ownerPID: pid)
        }
        return nil
    }
}
