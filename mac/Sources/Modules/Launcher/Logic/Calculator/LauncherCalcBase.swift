import Foundation

// 进制与时间戳（docs/launcher/TECH_DESIGN.md §7 第 1 种）。
//   进制：`0xff`（单独一个非十进制字面量 → 十进制）、`255 to hex`、`0b1010 to dec`、`255 转 二进制`、`255 转 16进制`。
//         只做整数，绝对值放得进 UInt64；负数带负号（`-255 to hex` → `-0xFF`）。
//   时间戳：只做「现在」的 Unix 时间戳（`now`、`现在的时间戳`）。**裸的时间戳数字（`1700000000`）不在这里处理**：
//         快速入口的文本识别来源会接剪贴板已有的时间戳识别器，两边都做会出两行重复结果。

enum LauncherCalcBase {
    enum Radix: Int {
        case binary = 2, octal = 8, decimal = 10, hex = 16
    }

    private static let names: [String: Radix] = [
        "hex": .hex, "hexadecimal": .hex, "十六进制": .hex,
        "bin": .binary, "binary": .binary, "二进制": .binary,
        "oct": .octal, "octal": .octal, "八进制": .octal,
        "dec": .decimal, "decimal": .decimal, "十进制": .decimal,
    ]
    private static let connectors: Set<String> = ["to", "in", "as", "into", "转", "转成", "换成", "转换成", "转为", "变成"]
    static let cjkWords: Set<String> = ["十六进制", "二进制", "八进制", "十进制", "进制", "转", "转成", "换成", "转换成", "转为", "变成"]

    static func match(_ tokens: [LauncherCalcToken], _ context: LauncherCalcContext) -> LauncherCalcResult? {
        // 单独一个 0x / 0b / 0o 字面量：给出十进制。
        if tokens.count == 1, let only = tokens.first, only.radix != 10, let value = only.number,
           let magnitude = unsigned(value) {
            return result(magnitude: magnitude, negative: false, source: only.radix, target: .decimal, context: context)
        }
        var cursor = LauncherCalcCursor(tokens)
        let negative = cursor.take(symbol: "-")
        guard let token = cursor.current, let value = token.number else { return nil }
        cursor.advance()
        let hasConnector = cursor.take(symbol: "=") || cursor.take(phraseIn: connectors, maxTokens: 1) != nil
        // 不写连接词时，英文的进制名要和数字隔开（`255 hex`）：`0bin`、`1hex` 不当换算。
        if !hasConnector, let next = cursor.current, !next.spaceBefore,
           next.raw.unicodeScalars.first?.isASCII == true { return nil }
        // 换成同一种进制（`255 dec`、`0xff to hex`）什么也没做，不出结果。
        guard let target = radixName(&cursor), cursor.atEnd, target.rawValue != token.radix else { return nil }
        guard case .exact(let decimal) = value, LauncherCalcMath.isInteger(decimal) else { return nil }
        guard let magnitude = unsigned(value) else {
            let source = (negative ? "-" : "") + LauncherCalcFormat.plain(value)
            return .failed(.base, .overflow, interpretation: "\(source) → \(name(target, context))", context: context)
        }
        return result(magnitude: magnitude, negative: negative, source: token.radix, target: target, context: context)
    }

    /// `hex` / `十六进制` / `16进制`（「16」「进制」被词法切成两个 token）。
    private static func radixName(_ cursor: inout LauncherCalcCursor) -> Radix? {
        if let word = cursor.current?.word, let radix = names[word] {
            cursor.advance()
            return radix
        }
        if let number = cursor.current?.decimalInteger, cursor.peek(1)?.isWord("进制") == true,
           let base = Int(number.description), let radix = Radix(rawValue: base) {
            cursor.advance(2)
            return radix
        }
        return nil
    }

    /// 精确整数的绝对值（放不进 UInt64 时 nil）。
    private static func unsigned(_ value: LauncherCalcValue) -> UInt64? {
        guard case .exact(let decimal) = value, LauncherCalcMath.isInteger(decimal) else { return nil }
        return UInt64(decimal.magnitude.description)
    }

    private static func result(magnitude: UInt64, negative: Bool, source: Int, target: Radix,
                               context: LauncherCalcContext) -> LauncherCalcResult {
        let sign = negative && magnitude != 0 ? "-" : ""
        let sourceRadix = Radix(rawValue: source) ?? .decimal
        let sourceText = sign + render(magnitude, sourceRadix, grouping: false)
        let interpretation = "\(sourceText) → \(name(target, context))"
        return .value(.base, display: sign + render(magnitude, target, grouping: true),
                      copy: sign + render(magnitude, target, grouping: false), interpretation: interpretation)
    }

    private static func render(_ magnitude: UInt64, _ radix: Radix, grouping: Bool) -> String {
        switch radix {
        case .hex: return "0x" + String(magnitude, radix: 16, uppercase: true)
        case .binary: return "0b" + String(magnitude, radix: 2)
        case .octal: return "0o" + String(magnitude, radix: 8)
        case .decimal:
            guard grouping, let number = LauncherCalcFormat.number(.exact(Decimal(magnitude))) else {
                return String(magnitude)
            }
            return number.display
        }
    }

    private static func name(_ radix: Radix, _ context: LauncherCalcContext) -> String {
        switch radix {
        case .hex: return context.text("十六进制", "hex")
        case .binary: return context.text("二进制", "binary")
        case .octal: return context.text("八进制", "octal")
        case .decimal: return context.text("十进制", "decimal")
        }
    }
}

enum LauncherCalcTimestamp {
    private static let secondPhrases: Set<String> = [
        "now", "现在的时间戳", "当前时间戳", "当前的时间戳", "现在时间戳", "unix timestamp", "unix time",
        "current timestamp", "current unix timestamp", "timestamp now", "now timestamp", "now unix",
    ]
    private static let millisecondPhrases: Set<String> = [
        "毫秒时间戳", "当前毫秒时间戳", "现在的毫秒时间戳", "现在毫秒时间戳", "当前的毫秒时间戳",
        "timestamp ms", "timestamp in ms", "now in ms", "now ms", "unix timestamp ms",
    ]
    static let cjkWords: Set<String> = ["现在", "的", "时间戳", "当前", "毫秒时间戳", "现在的时间戳", "当前时间戳"]

    static func match(_ tokens: [LauncherCalcToken], _ context: LauncherCalcContext) -> LauncherCalcResult? {
        guard let phrase = LauncherCalcPhrase.join(tokens) else { return nil }
        let milliseconds: Bool
        if secondPhrases.contains(phrase) {
            milliseconds = false
        } else if millisecondPhrases.contains(phrase) {
            milliseconds = true
        } else {
            return nil
        }
        let seconds = context.now.timeIntervalSince1970
        let value = milliseconds ? (seconds * 1000).rounded(.down) : seconds.rounded(.down)
        guard value.isFinite, Swift.abs(value) < 9e15 else { return nil }
        let text = String(Int64(value))
        let cal = context.gregorian
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: context.now)
        let two = LauncherCalcFormat.twoDigits
        let when = "\(parts.year ?? 0)-\(two(parts.month ?? 0))-\(two(parts.day ?? 0)) "
            + "\(two(parts.hour ?? 0)):\(two(parts.minute ?? 0)):\(two(parts.second ?? 0))"
        let interpretation = milliseconds
            ? context.text("\(when) 的 Unix 时间戳（毫秒）", "Unix timestamp (ms) at \(when)")
            : context.text("\(when) 的 Unix 时间戳（秒）", "Unix timestamp (seconds) at \(when)")
        return .value(.timestamp, display: text, copy: text, interpretation: interpretation)
    }
}
