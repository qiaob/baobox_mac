import CoreGraphics
import Foundation
import ImageIO

/// 把交给图片动作的图（`LauncherImage`，docs/launcher/TECH_DESIGN.md §5.5）读成位图：像素尺寸、缩略图、整图。
/// 快速入口（附件的缩略图、后台取字）和声明图片动作的模块（截图的取字、贴图、预览、保存）共用，所以放在 Core；
/// `Core/Launcher/` 只能 import Foundation，解码放在这里。
///
/// 非 `@MainActor`：解码可能要几十毫秒到上百毫秒，一律在后台线程调。全程容错：读不出来返回 nil，不抛错、不崩。
enum LauncherImageLoader {
    /// 整图最多这么多像素（4000 万，约 8000 × 5000）：超过的按比例缩到以内。位图一个像素 4 字节，
    /// 不设上限的话一张 30000 × 30000 的图解出来要 3.6 GB。长截屏（1600 × 20000 = 3200 万）不受影响。
    static let maxPixelCount = 40_000_000

    static func source(_ image: LauncherImage) -> CGImageSource? {
        switch image {
        case .data(let data):
            return data.isEmpty ? nil : CGImageSourceCreateWithData(data as CFData, nil)
        case .file(let url):
            return CGImageSourceCreateWithURL(url as CFURL, nil)
        }
    }

    /// 像素尺寸（只读文件头、不解码）；照片带 EXIF 方向、要转 90° 的宽高互换。读不出为 nil。
    static func pixelSize(_ image: LauncherImage) -> CGSize? {
        guard let source = source(image) else { return nil }
        return pixelSize(source)
    }

    /// 缩略图：长边不超过 `maxPixelSize`，按 EXIF 方向转正。只解到这个尺寸，不先解整图（JPEG 能直接按比例解）。
    static func thumbnail(_ image: LauncherImage, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, let source = source(image) else { return nil }
        return downsampled(source, maxPixelSize: maxPixelSize)
    }

    /// 整图（按 EXIF 方向转正）。像素数超过 `maxPixelCount` 时等比缩到以内。读不出为 nil。
    static func cgImage(_ image: LauncherImage, maxPixelCount: Int = maxPixelCount) -> CGImage? {
        guard let source = source(image), CGImageSourceGetCount(source) > 0, let size = pixelSize(source),
              size.width >= 1, size.height >= 1 else { return nil }
        let longSide = max(size.width, size.height)
        let pixels = size.width * size.height
        if pixels <= CGFloat(max(1, maxPixelCount)), orientation(source) == 1 {
            // 最常见的情况（截图、PNG）：不用转向、不用缩，直接取（ImageIO 按需解码）。
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let scale = min(1, (CGFloat(max(1, maxPixelCount)) / pixels).squareRoot())
        return downsampled(source, maxPixelSize: max(1, Int((longSide * scale).rounded(.down))))
    }

    // MARK: - 内部

    private static func properties(_ source: CGImageSource) -> [CFString: Any]? {
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    /// EXIF 方向（1–8，1 = 不用转）；没有写就是 1。
    private static func orientation(_ source: CGImageSource) -> Int {
        (properties(source)?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    private static func pixelSize(_ source: CGImageSource) -> CGSize? {
        guard CGImageSourceGetCount(source) > 0, let properties = properties(source),
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // 5–8 是转 90° 的方向：显示出来宽高互换。
        let rotated = (5...8).contains((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
        return rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    private static func downsampled(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
