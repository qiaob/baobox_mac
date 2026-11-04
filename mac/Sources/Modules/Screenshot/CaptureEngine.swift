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
            // 混合 DPI 时 `pointPixelScale` 偶尔报的不是窗口所在屏的倍率：窗口在 Retina
            // 屏上、主屏却是 1x 外接屏时它可能报 1，按它配 config 就会把窗口以 1x 抓下来，
            // 成图发糊（偶发模糊的主因之一）。窗口内容由窗口服务器按所在屏倍率渲染，
            // 用「窗口所在屏（交集最大者）的 backing 倍率」兜底取较大值不会虚构细节：
            // 窗口真在 1x 屏上时 pointPixelScale 本就不会报 2。
            let windowAK = Geometry.appKitRect(fromCG: window.frame)
            let screenScale = WindowLayout.targetScreen(forWindowAK: windowAK,
                                                        screens: NSScreen.screens,
                                                        mouseScreen: nil)?.backingScaleFactor ?? 1
            return try await captureImage(filter: filter, minimumScale: screenScale)

        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.targetNotFound
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            return try await captureImage(filter: filter,
                                          minimumScale: nativeScale(displayID: displayID, filter: filter))

        case .displayRect(let displayID, let rectAK, let screen):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.targetNotFound
            }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let full = try await captureImage(filter: filter,
                                              minimumScale: nativeScale(displayID: displayID, filter: filter))

            // AK 全局 rect → 该屏图像像素 rect（图像原点在左上）。
            // 倍率从**图像自身**反推（像素宽 ÷ 屏点宽），不用 backingScaleFactor 假设：
            // 两者一旦不一致（缩放模式 / 镜像屏 / 系统给的倍率与实际渲染不符），按假设值
            // 裁剪要么裁错区域、要么把高像素图按低倍率理解，成图等于被降采样。
            let scaleX = CGFloat(full.width) / screen.frame.width
            let scaleY = CGFloat(full.height) / screen.frame.height
            let x = (rectAK.minX - screen.frame.minX) * scaleX
            let y = (screen.frame.maxY - rectAK.maxY) * scaleY
            let w = rectAK.width * scaleX
            let h = rectAK.height * scaleY
            let pixelRect = CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
            guard let cropped = full.cropping(to: pixelRect) else {
                throw CaptureError.cropFailed
            }
            return cropped
        }
    }

    /// 显示器当前模式的原生像素倍率（原生像素宽 ÷ 点宽）。与 `pointPixelScale` 正常时
    /// 恒等，仅作兜底下限：缩放显示模式下两者偶有不一致，取大者保证不按低分辨率抓屏。
    private static func nativeScale(displayID: CGDirectDisplayID, filter: SCContentFilter) -> CGFloat {
        let points = filter.contentRect.width
        guard points > 0 else { return 1 }
        return CGFloat(CGDisplayPixelsWide(displayID)) / points
    }

    private static func captureImage(filter: SCContentFilter,
                                     minimumScale: CGFloat = 1) async throws -> CGImage {
        let config = SCStreamConfiguration()
        let contentRect = filter.contentRect
        let scale = max(CGFloat(filter.pointPixelScale), minimumScale)
        // rounded() 而非 Int() 截断：宽高乘倍率出现 .5 时截断会少一行/一列像素。
        config.width = Int((contentRect.width * scale).rounded())
        config.height = Int((contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
