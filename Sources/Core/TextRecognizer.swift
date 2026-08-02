import CoreGraphics
import Foundation
import Vision

/// 屏幕取字：Vision 本地识别（文字 + 条码/二维码）。全程离线、不联网，
/// 不需要屏幕录制以外的任何权限。
///
/// 只用 macOS 11 起就稳定的 `VNImageRequestHandler` + `VNRecognizeTextRequest`，
/// 不碰 macOS 15 才有的新 Vision Swift 接口。
///
/// 非 `@MainActor`：识别耗时（大图可能上百毫秒到秒级），一律在后台队列上调用。
enum TextRecognizer {

    struct Result {
        /// 已按版面还原过换行/分段的文本。
        let text: String
        /// 画面里的二维码 / 条码内容（去重保序）。
        let barcodes: [String]

        var isEmpty: Bool { text.isEmpty && barcodes.isEmpty }
    }

    /// 识别语言组合。存 UserDefaults 用 rawValue，避免以后加语言时破坏旧配置。
    enum LanguageOption: String, CaseIterable, Identifiable {
        case chineseEnglish
        case english
        case chineseEnglishJapanese

        var id: String { rawValue }

        /// Vision 语言码，顺序即优先级。
        var visionLanguages: [String] {
            switch self {
            case .chineseEnglish: return ["zh-Hans", "en-US"]
            case .english: return ["en-US"]
            case .chineseEnglishJapanese: return ["zh-Hans", "en-US", "ja-JP"]
            }
        }

        var displayName: String {
            switch self {
            case .chineseEnglish: return L("screenshot.ocr.language.zhEn")
            case .english: return L("screenshot.ocr.language.en")
            case .chineseEnglishJapanese: return L("screenshot.ocr.language.zhEnJa")
            }
        }
    }

    /// 同步识别一张图。失败/无结果都返回空 `Result`，不抛错、不 crash。
    static func recognize(_ image: CGImage, languages: [String]) -> Result {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        if !languages.isEmpty {
            textRequest.recognitionLanguages = languages
        }
        let barcodeRequest = VNDetectBarcodesRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // 两个请求一起跑：同一张图只解码一次。任一请求抛错就整体降级为空结果。
        do {
            try handler.perform([textRequest, barcodeRequest])
        } catch {
            return Result(text: "", barcodes: [])
        }

        let observations = (textRequest.results ?? [])
        let text = layout(observations)

        var seen = Set<String>()
        var codes: [String] = []
        for observation in (barcodeRequest.results ?? []) {
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { continue }
            if seen.insert(payload).inserted { codes.append(payload) }
        }
        return Result(text: text, barcodes: codes)
    }

    // MARK: - 版面还原

    /// Vision 给的是一堆带 `boundingBox`（归一化、原点左下）的碎片，直接首尾相连会糊成一行。
    /// 这里按纵向中心聚成行、行内按横坐标排序，再按行距判断要不要空一行分段。
    private static func layout(_ observations: [VNRecognizedTextObservation]) -> String {
        var pieces: [(box: CGRect, text: String)] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            pieces.append((observation.boundingBox, text))
        }
        guard !pieces.isEmpty else { return "" }

        // 自上而下（归一化坐标原点在左下，midY 大的在上）。
        pieces.sort { $0.box.midY > $1.box.midY }

        var lines: [[(box: CGRect, text: String)]] = []
        for piece in pieces {
            guard var last = lines.last else {
                lines.append([piece])
                continue
            }
            // 与当前行的平均中心相差不到半个行高，视为同一行（多栏排版会命中这里）。
            let averageMidY = last.reduce(0) { $0 + $1.box.midY } / CGFloat(last.count)
            let averageHeight = last.reduce(0) { $0 + $1.box.height } / CGFloat(last.count)
            if abs(piece.box.midY - averageMidY) < averageHeight * 0.5 {
                last.append(piece)
                lines[lines.count - 1] = last
            } else {
                lines.append([piece])
            }
        }

        var out = ""
        var previousMinY: CGFloat?
        var previousHeight: CGFloat = 0
        for line in lines {
            let ordered = line.sorted { $0.box.minX < $1.box.minX }
            var joined = ""
            for piece in ordered {
                joined = merge(joined, piece.text)
            }
            let minY = ordered.map { $0.box.minY }.min() ?? 0
            let maxY = ordered.map { $0.box.maxY }.max() ?? 0
            let height = max(maxY - minY, 0.0001)

            if let previousMinY {
                // 行距明显大于行高 → 认为是段落间隔，多空一行。
                let gap = previousMinY - maxY
                out += gap > max(previousHeight, height) * 0.8 ? "\n\n" : "\n"
            }
            out += joined
            previousMinY = minY
            previousHeight = height
        }
        return out
    }

    /// 行内拼接：中日韩之间不补空格，其余情况补一个 —— 否则中文会被塞满空格、英文会粘成一坨。
    private static func merge(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if isCJK(left.unicodeScalars.last) || isCJK(right.unicodeScalars.first) {
            return left + right
        }
        return left + " " + right
    }

    private static func isCJK(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        switch value {
        case 0x3000...0x303F,   // CJK 标点
             0x3040...0x30FF,   // 日文假名
             0x3400...0x4DBF,   // CJK 扩展 A
             0x4E00...0x9FFF,   // CJK 统一表意
             0xF900...0xFAFF,   // CJK 兼容表意
             0xFF00...0xFFEF:   // 全角字符
            return true
        default:
            return false
        }
    }
}
