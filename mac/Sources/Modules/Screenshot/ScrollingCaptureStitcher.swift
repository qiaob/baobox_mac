import CoreGraphics

/// 长截屏拼接器：把「同一块屏幕区域、随页面滚动不断变化」的多帧图像按纵向重叠对齐，拼成一张长图。
///
/// 匹配用灰度**行特征**：每帧先由 CoreGraphics 缩成 `sampleCount` 列宽的灰度位图，
/// 于是每行压成一条 32 字节特征；拿已累积图像底部的一条带（band）去新帧里滑窗做 SAD 搜索，
/// 找到重叠位置后只追加「对不上的那一段」。纯 CPU、零第三方依赖。
///
/// **非 `@MainActor`**：实例只在 `ScrollingCaptureController` 自己的串行队列上被调用，
/// 主线程不直接碰它（`compose()` 也派发到同一队列，天然排在在途 `append` 之后）。
final class ScrollingCaptureStitcher {

    enum AppendResult {
        case first(rows: Int)      // 首帧，直接铺底
        case appended(rows: Int)   // 找到重叠并追加了新内容
        case duplicate             // 画面没动（重叠 = 整帧）
        case noOverlap             // 找不到重叠：滚太快跳过了一屏，或内容整体换了 —— 丢弃该帧
        case rejected              // 尺寸不符 / 取样失败
        case full                  // 已达长度上限，不再接收
    }

    /// 每行取样列数。32 列足以区分正文行，又让匹配开销与内存都很小。
    private static let sampleCount = 32
    /// 参与匹配的带高（已累积图像底部的行数）。
    private static let bandRows = 48
    /// 带内隔行比对，省一半算力；滚动位移是整行级的，隔行不影响判定。
    private static let rowStride = 2
    /// 平均绝对差阈值（0–255）。超过即认为没对上 —— 宁可丢帧也不要拼错位。
    private static let matchThreshold = 12.0

    /// 各段独立位图（自上而下顺序）。切出来后立刻重绘一份，好让整帧像素及时释放。
    private var segments: [CGImage] = []
    /// 已累积图像的逐行特征，长度 = `totalRows * sampleCount`。
    private var signatures: [UInt8] = []

    private(set) var totalRows = 0
    private(set) var pixelWidth = 0

    /// 长度上限：按像素总量折算（约 3000 万像素 ≈ 120MB 位图），再夹一个绝对行数上限。
    private var maxRows: Int {
        guard pixelWidth > 0 else { return 40_000 }
        return min(40_000, max(2_000, 30_000_000 / pixelWidth))
    }

    var isEmpty: Bool { segments.isEmpty }

    // MARK: - 追加

    func append(_ frame: CGImage) -> AppendResult {
        let height = frame.height
        guard height > 0, frame.width > 0, let sig = Self.rowSignatures(frame) else { return .rejected }

        if segments.isEmpty {
            guard let strip = Self.copyStrip(frame, top: 0, rows: height) else { return .rejected }
            pixelWidth = frame.width
            segments.append(strip)
            signatures = sig
            totalRows = height
            return .first(rows: height)
        }

        // 中途换屏 / 改缩放会让帧宽变化，此时旧内容无法与新内容对齐，直接丢弃。
        guard frame.width == pixelWidth else { return .rejected }
        guard totalRows < maxRows else { return .full }

        let band = min(Self.bandRows, height / 2, totalRows)
        guard band >= 4 else { return .rejected }

        // overlap = 新帧顶部与已累积图像底部重合的行数。从大到小试：并列时取最大重叠，
        // 也就是「尽量少认新内容」—— 大片空白区域不会被误判成滚动过一段。
        var bestOverlap = 0
        var bestScore = Double.greatestFiniteMagnitude
        var overlap = min(height, totalRows)
        while overlap >= band {
            let score = Self.bandScore(acc: signatures, accRows: totalRows,
                                       frame: sig, overlap: overlap, band: band)
            if score < bestScore {
                bestScore = score
                bestOverlap = overlap
            }
            overlap -= 1
        }

        guard bestOverlap > 0, bestScore <= Self.matchThreshold else { return .noOverlap }
        let newRows = height - bestOverlap
        guard newRows > 0 else { return .duplicate }
        guard let strip = Self.copyStrip(frame, top: bestOverlap, rows: newRows) else { return .rejected }

        segments.append(strip)
        signatures.append(contentsOf: sig[(bestOverlap * Self.sampleCount)...])
        totalRows += newRows
        return totalRows >= maxRows ? .full : .appended(rows: newRows)
    }

    // MARK: - 输出

    /// 把各段自上而下画进一张整图。无内容时返回 nil。
    func compose() -> CGImage? {
        guard totalRows > 0, pixelWidth > 0, !segments.isEmpty else { return nil }
        guard let context = Self.makeContext(width: pixelWidth, height: totalRows) else { return nil }

        var drawnTop = 0
        for strip in segments {
            let rows = strip.height
            // CGContext 原点在左下，而各段是自上而下排的 —— y 要从底部反算。
            context.draw(strip, in: CGRect(x: 0, y: totalRows - drawnTop - rows,
                                           width: pixelWidth, height: rows))
            drawnTop += rows
        }
        return context.makeImage()
    }

    // MARK: - 内部：取样 / 匹配 / 切段

    /// 每行的灰度特征：把整帧缩成 `sampleCount × height` 的灰度图，一行即一条特征。
    /// 缩放由 CG 做盒式滤波，天然抗一两像素的横向抖动。
    /// 返回缓冲区第 0 行对应图像**顶部**（CG 位图内存自上而下排列）。
    private static func rowSignatures(_ image: CGImage) -> [UInt8]? {
        let height = image.height
        let width = sampleCount
        guard height > 0 else { return nil }

        var data = [UInt8](repeating: 0, count: width * height)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    /// 已累积图像底部 `band` 行 与 新帧 `[overlap-band, overlap)` 行的平均绝对差。
    private static func bandScore(acc: [UInt8], accRows: Int,
                                  frame: [UInt8], overlap: Int, band: Int) -> Double {
        let stride = sampleCount
        var total = 0
        var count = 0
        var r = 0
        while r < band {
            let accOffset = (accRows - band + r) * stride
            let frameOffset = (overlap - band + r) * stride
            var i = 0
            while i < stride {
                let delta = Int(acc[accOffset + i]) - Int(frame[frameOffset + i])
                total += delta < 0 ? -delta : delta
                i += 1
            }
            count += stride
            r += rowStride
        }
        return count == 0 ? Double.greatestFiniteMagnitude : Double(total) / Double(count)
    }

    /// 切出 `[top, top+rows)` 行并**重绘成独立位图**。
    /// `CGImage.cropping` 只是惰性视图、仍持有整帧像素，直接存下来会让每一帧都留在内存里。
    private static func copyStrip(_ frame: CGImage, top: Int, rows: Int) -> CGImage? {
        guard rows > 0,
              let cropped = frame.cropping(to: CGRect(x: 0, y: top, width: frame.width, height: rows)),
              let context = makeContext(width: frame.width, height: rows) else { return nil }
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: frame.width, height: rows))
        return context.makeImage()
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(data: nil, width: width, height: height,
                         bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: bitmapInfo)
    }
}
