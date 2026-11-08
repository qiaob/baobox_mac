import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 手机互传里的图片：判断、按 EXIF 方向转正的解码、复制到剪贴板。
/// 见 docs/phone-transfer/TECH_DESIGN.md §5.1。
enum PhoneTransferImage {
    /// 按扩展名判断是不是图片（jpg / png / heic / gif / webp …）。
    static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// 解码并按 EXIF 方向转正（手机照片多数带方向）。`maxPixel` = 最长边像素上限，0 = 原尺寸。
    /// 读文件 + 解码，必须在后台线程调用。
    static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        var limit = maxPixel
        if limit <= 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            limit = max(width, height)
            guard limit > 0 else { return nil }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 在后台解码成 `NSImage`，回主线程交给 `completion`（失败给 nil）。
    static func load(_ url: URL, maxPixel: Int, completion: @escaping @MainActor (NSImage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let cg = decode(url, maxPixel: maxPixel)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
                }
            }
        }
    }

    /// 原尺寸复制到剪贴板：写 PNG + TIFF（和截图模块一样，粘到聊天软件里是图片而不是文件）。
    /// 解码和编码在后台做（手机照片动辄几千万像素），写剪贴板回主线程。
    static func copy(_ url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var png: Data?
            var tiff: Data?
            if let cg = decode(url, maxPixel: 0) {
                // 从 bitmap rep 编码，不经 NSImage：逐像素保真，与屏幕 DPI 无关（见 ScreenshotResultHandler）。
                let rep = NSBitmapImageRep(cgImage: cg)
                png = rep.representation(using: .png, properties: [:])
                tiff = rep.representation(using: .tiff, properties: [:])
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard png != nil || tiff != nil else {
                        completion(false)
                        return
                    }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if let png { pasteboard.setData(png, forType: .png) }
                    if let tiff { pasteboard.setData(tiff, forType: .tiff) }
                    completion(true)
                }
            }
        }
    }

    /// 用「预览」打开；找不到「预览」就用默认 App。
    static func openInPreview(_ url: URL) {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 时刻与用时的显示（docs/phone-transfer/REQUIREMENTS.md §3.4）。
enum PhoneTransferFormat {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    /// 不到 60 秒保留一位小数（「1.2 秒」），否则「1分5秒」这类。
    static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        if value < 60 {
            return L("phonetransfer.time.seconds \(String(format: "%.1f", value))")
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = value >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        return formatter.string(from: value) ?? ""
    }
}
