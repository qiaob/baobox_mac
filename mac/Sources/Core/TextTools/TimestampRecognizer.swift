import Foundation

/// 时间识别：Unix 秒/毫秒/微秒/纳秒、Apple 绝对时间、ISO 8601 / RFC 3339、
/// 常见日期时间写法、RFC 2822。输出一张转换表。
struct TimestampRecognizer: TextFormatRecognizer {
    let id = "timestamp"
    let priority = 40

    /// 时间字符串不会长，早退可以省掉后面一串 formatter 尝试。
    private static let maxInputLength = 80

    /// 合理区间：1970-01-01 ~ 2100-01-01。10 位数字也可能是订单号/QQ 号，
    /// 区间只能滤掉一部分误报 —— 但误报的代价只是多一张表，**宁可宽松也不漏**。
    private static let minEpoch: Double = 0
    private static let maxEpoch: Double = 4_102_444_800

    func detect(_ text: String) -> FormatMatch? {
        guard text.utf8.count <= Self.maxInputLength,
              let parsed = Self.parse(text) else { return nil }
        return FormatMatch(id: id, badge: parsed.badge, rendered: nil,
                           rows: Self.rows(for: parsed), actions: [])
    }

    // MARK: - 解析

    struct Parsed {
        let date: Date
        let badge: String
        /// 9–10 位纯数字的另一种解释（Apple 绝对时间，2001-01-01 起算）。
        /// 这个歧义**不猜**，两种解释都摆出来让用户自己认。
        let appleAlternative: Date?
    }

    static func parse(_ text: String) -> Parsed? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let numeric = parseNumeric(s) { return numeric }
        if let date = parseTextual(s) {
            return Parsed(date: date, badge: L("clipboard.tools.time.badge.datetime"), appleAlternative: nil)
        }
        return nil
    }

    private static func parseNumeric(_ s: String) -> Parsed? {
        guard s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              s.first?.isNumber == true,
              let value = Double(s) else { return nil }

        let integerDigits = (s.split(separator: ".").first.map(String.init) ?? s).count
        let hasFraction = s.contains(".")

        // 注意：`L()` 收的是 String.LocalizationValue，只能传字面量，不能传变量，
        // 所以这里直接取好本地化字符串，不传 key。
        let epoch: Double
        let badge: String
        switch integerDigits {
        case 9, 10:
            epoch = value
            badge = L("clipboard.tools.time.badge.seconds")
        case 13 where !hasFraction:
            epoch = value / 1_000
            badge = L("clipboard.tools.time.badge.millis")
        case 16 where !hasFraction:
            epoch = value / 1_000_000
            badge = L("clipboard.tools.time.badge.micros")
        case 19 where !hasFraction:
            epoch = value / 1_000_000_000
            badge = L("clipboard.tools.time.badge.nanos")
        default:
            return nil
        }
        guard epoch >= minEpoch, epoch <= maxEpoch else { return nil }

        var apple: Date?
        if integerDigits == 9 || integerDigits == 10 {
            let candidate = Date(timeIntervalSinceReferenceDate: value)
            let asEpoch = candidate.timeIntervalSince1970
            if asEpoch >= minEpoch, asEpoch <= maxEpoch { apple = candidate }
        }
        return Parsed(date: Date(timeIntervalSince1970: epoch), badge: badge, appleAlternative: apple)
    }

    private static func parseTextual(_ s: String) -> Date? {
        for parser in isoParsers {
            if let date = parser.date(from: s) { return date }
        }
        for formatter in textualFormatters {
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }

    // MARK: - 输出表

    static func rows(for parsed: Parsed) -> [FormatRow] {
        var result = Self.rows(for: parsed.date)
        if let apple = parsed.appleAlternative {
            result.append(FormatRow(label: L("clipboard.tools.time.appleEpoch"),
                                    value: localDisplay.string(from: apple),
                                    copyValue: localPlain.string(from: apple)))
        }
        return result
    }

    /// 六行标准转换表。JWT 的 exp/iat 也复用这里的换算，不重复实现。
    static func rows(for date: Date) -> [FormatRow] {
        let epoch = date.timeIntervalSince1970
        return [
            FormatRow(label: L("clipboard.tools.time.local"),
                      value: localDisplay.string(from: date),
                      copyValue: localPlain.string(from: date)),
            FormatRow(label: L("clipboard.tools.time.utc"),
                      value: utcFormatter.string(from: date),
                      copyValue: utcFormatter.string(from: date)),
            FormatRow(label: L("clipboard.tools.time.iso"),
                      value: isoOutput.string(from: date),
                      copyValue: isoOutput.string(from: date)),
            FormatRow(label: L("clipboard.tools.time.seconds"),
                      value: String(Int64(epoch.rounded(.down))),
                      copyValue: String(Int64(epoch.rounded(.down)))),
            FormatRow(label: L("clipboard.tools.time.millis"),
                      value: String(Int64((epoch * 1_000).rounded())),
                      copyValue: String(Int64((epoch * 1_000).rounded()))),
            FormatRow(label: L("clipboard.tools.time.relative"),
                      value: relativeFormatter.localizedString(for: date, relativeTo: Date()),
                      copyValue: nil)
        ]
    }

    /// 相对时间短语，供 JWT 的 exp 复用。
    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func localTimeString(_ date: Date) -> String {
        localDisplay.string(from: date)
    }

    // MARK: - Formatter 缓存
    //
    // DateFormatter 构造开销很大，**必须缓存**，不能在 detect 里 new。
    // 解析用的一律锁 en_US_POSIX，避免用户区域设置影响解析结果。

    private static let localDisplay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return f
    }()

    private static let localPlain: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let isoOutput: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        f.unitsStyle = .full
        return f
    }()

    /// 带小数秒的排前面 —— 不带小数秒的解析器吃不下 `.123`。
    private static let isoParsers: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()

    private static let textualFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "EEE, dd MMM yyyy HH:mm:ss zzz"
        ]
        return formats.map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }
    }()
}
