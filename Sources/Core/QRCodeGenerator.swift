import CoreGraphics
import CoreImage
import Foundation

/// 二维码生成：纯本地（CIQRCodeGenerator），无需任何权限。
///
/// 原属独立的 QRCode 工具模块；该模块已移除（能力并入剪贴板的文本动作），
/// 但生成器被剪贴板与网络抓包两处共用，故下沉为共享基础设施。
enum QRCodeGenerator {
    /// 最大可编码字节数（版本 40、纠错 M 上限约 2953，留少量余量）。
    static let maxBytes = 2900

    /// 生成含 2 模块白色静区的二维码，边长 ≥ minPixels（整数倍放大保持模块边缘锐利）。
    /// 内容为空或超容量返回 nil。
    static func image(for text: String, minPixels: Int) -> CGImage? {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= maxBytes,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let moduleCount = Int(output.extent.width)
        guard moduleCount > 0,
              let small = CIContext().createCGImage(output, from: output.extent) else { return nil }

        let quiet = 2 // 两侧各留 2 模块静区，扫码可靠性要求
        let scale = max(1, Int((Double(minPixels) / Double(moduleCount + 2 * quiet)).rounded(.up)))
        let side = (moduleCount + 2 * quiet) * scale
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .none
        ctx.draw(small, in: CGRect(x: quiet * scale, y: quiet * scale,
                                   width: moduleCount * scale, height: moduleCount * scale))
        return ctx.makeImage()
    }
}
