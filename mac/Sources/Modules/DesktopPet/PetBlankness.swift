import AppKit
import ScreenCaptureKit

/// 屏幕上哪里「空」（docs/desktop-pet/SETTLE.md §3.2）：截一张宠物所在屏的低分辨率灰度画面（宽 480 像素，
/// 不含 Baobox 自己的窗口），按区域算纹理多少 —— 文字、图片多的地方相邻像素差得大，纯色空白处几乎为 0。
///
/// 隐私与开销：只用截图功能已有的屏幕录制权限（没有就不用，绝不弹授权）；只在按窗口位置找不到空桌面时才截，
/// 10 秒内最多一次；画面只在内存里留 20 秒供打分，不写盘、不上传、不进日志。
@MainActor
final class PetBlankness {
    private struct Snapshot {
        let screenFrame: NSRect
        let at: Date
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    private var snapshot: Snapshot?
    private var inFlight = false
    private var lastAttempt = Date.distantPast

    /// 设置里开着、有屏幕录制权限。
    static var isAvailable: Bool { PetSettings.contentAware && Permissions.hasScreenRecording }

    /// 画面变了（切了 App / 桌面）：旧的作废。
    func invalidate() {
        snapshot = nil
    }

    /// 有没有这块屏 20 秒内的画面。
    func isFresh(for screen: NSScreen) -> Bool {
        guard let snapshot else { return false }
        return snapshot.screenFrame == screen.frame && Date().timeIntervalSince(snapshot.at) < 20
    }

    /// 这块区域（屏幕坐标）的画面有多满：0 空白 – 1 满满的内容。没有画面时 nil。
    func busyness(of rect: NSRect) -> Double? {
        guard let s = snapshot, Date().timeIntervalSince(s.at) < 20 else { return nil }
        let area = rect.intersection(s.screenFrame)
        guard !area.isNull, area.width > 1, area.height > 1 else { return nil }
        let sx = CGFloat(s.width) / s.screenFrame.width, sy = CGFloat(s.height) / s.screenFrame.height
        // 图像原点在左上角。
        let x0 = max(Int((area.minX - s.screenFrame.minX) * sx), 0)
        let x1 = min(Int((area.maxX - s.screenFrame.minX) * sx), s.width - 1)
        let y0 = max(Int((s.screenFrame.maxY - area.maxY) * sy), 0)
        let y1 = min(Int((s.screenFrame.maxY - area.minY) * sy), s.height - 1)
        guard x1 > x0 + 1, y1 > y0 + 1 else { return nil }
        var sum = 0, count = 0
        for y in y0..<y1 {
            let row = y * s.width
            for x in x0..<x1 {
                let v = Int(s.pixels[row + x])
                sum += abs(v - Int(s.pixels[row + x + 1])) + abs(v - Int(s.pixels[row + x + s.width]))
                count += 2
            }
        }
        let mean = Double(sum) / Double(max(count, 1))
        // 空白处 < 1；一屏正文 / 代码约 8 以上。
        return min(max((mean - 1) / 7, 0), 1)
    }

    /// 截一张这块屏的画面（异步），好了回调（没截成也回调，调用方照旧按窗口位置决定）。
    func refresh(screen: NSScreen, completion: @escaping () -> Void) {
        guard Self.isAvailable, !inFlight, Date().timeIntervalSince(lastAttempt) > 10,
              let displayID = screen.displayID else {
            completion()
            return
        }
        inFlight = true
        lastAttempt = Date()
        let frame = screen.frame
        Task { [weak self] in
            let result = await Self.capture(displayID: displayID)
            guard let self else { return }
            self.inFlight = false
            if let result {
                self.snapshot = Snapshot(screenFrame: frame, at: Date(), pixels: result.pixels,
                                         width: result.width, height: result.height)
            }
            completion()
        }
    }

    private nonisolated static func capture(displayID: CGDirectDisplayID) async -> (pixels: [UInt8], width: Int, height: Int)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let own = content.applications.filter { $0.processID == ownPID }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let rect = filter.contentRect
            let width = 480
            config.width = width
            config.height = max(Int((CGFloat(width) * rect.height / max(rect.width, 1)).rounded()), 2)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return grayscale(image)
        } catch {
            PetLog.log.info("blankness: capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private nonisolated static func grayscale(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        guard width > 2, height > 2 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }
}
