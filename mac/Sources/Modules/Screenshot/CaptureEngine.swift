import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureTarget {
    case window(CGWindowID)
    case display(CGDirectDisplayID)                                      // 全屏
    case displayRect(CGDirectDisplayID, rectAK: NSRect, screen: NSScreen) // 区域（AK 全局坐标）
}

enum CaptureError: LocalizedError {
    case targetNotFound
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .targetNotFound: return L("screenshot.error.targetMissing")
        case .cropFailed: return L("screenshot.error.cropFailed")
        }
    }
}

/// 基于 ScreenCaptureKit（macOS 14 API）的截图引擎。
enum CaptureEngine {
    /// `excludingWindowIDs`：从画面中剔除的窗口（用于"overlay 不消隐直接冻结画面"，
    /// 把自己的蒙层 / 工具条排除掉）。仅对 display 类目标生效。
    static func capture(_ target: CaptureTarget,
                        excludingWindowIDs: Set<CGWindowID> = []) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }

        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.targetNotFound
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return try await captureImage(filter: filter)

        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.targetNotFound
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            return try await captureImage(filter: filter)

        case .displayRect(let displayID, let rectAK, let screen):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.targetNotFound
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let full = try await captureImage(filter: filter)

            // AK 全局 rect → 该屏图像像素 rect（图像原点在左上）。
            let scale = screen.backingScaleFactor
            let x = (rectAK.minX - screen.frame.minX) * scale
            let y = (screen.frame.maxY - rectAK.maxY) * scale
            let w = rectAK.width * scale
            let h = rectAK.height * scale
            let pixelRect = CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
            guard let cropped = full.cropping(to: pixelRect) else {
                throw CaptureError.cropFailed
            }
            return cropped
        }
    }

    private static func captureImage(filter: SCContentFilter) async throws -> CGImage {
        let config = SCStreamConfiguration()
        let contentRect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(contentRect.width * scale)
        config.height = Int(contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
