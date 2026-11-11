import Foundation
import XCTest

/// `CLIFormat`（Claude Code / Codex 助手共用的展示格式化），docs/codex-assistant/DEDUPE-P2.md §2.4 类 2。
/// 两个模块的 `ClaudeFormat` / `AIToolsFormat` 是它的 typealias，只差 Localization（文案 key 与语言），
/// 这里用假的 Localization 把各阈值与现状钉住（包括 999,950–999,999 token 显示「1000.0k」）。
final class CLIFormatTests: XCTestCase {

    // MARK: - 费用

    func testCostIsDollarsWithTwoDecimals() {
        XCTAssertEqual(EnglishFormat.cost(0), "$0.00")
        XCTAssertEqual(EnglishFormat.cost(0.004), "$0.00")
        XCTAssertEqual(EnglishFormat.cost(12.345678), "$12.35")
        XCTAssertEqual(EnglishFormat.cost(1234.5), "$1234.50", "不加千分位")
        XCTAssertEqual(EnglishFormat.cost(-0.5), "$-0.50")
    }

    // MARK: - token

    func testTokensBelowOneThousandArePlainIntegers() {
        XCTAssertEqual(EnglishFormat.tokens(0), "0")
        XCTAssertEqual(EnglishFormat.tokens(999), "999")
        XCTAssertEqual(EnglishFormat.tokens(-5), "-5")
    }

    func testTokensFromOneThousandUseOneDecimalK() {
        XCTAssertEqual(EnglishFormat.tokens(1000), "1.0k")
        XCTAssertEqual(EnglishFormat.tokens(1049), "1.0k")
        XCTAssertEqual(EnglishFormat.tokens(1500), "1.5k")
        XCTAssertEqual(EnglishFormat.tokens(12_345), "12.3k")
        XCTAssertEqual(EnglishFormat.tokens(999_949), "999.9k")
    }

    /// 先判门槛（< 100 万走 k）再按一位小数四舍五入，所以 999,950–999,999 显示「1000.0k」。一直如此，这里只钉住、不改（§1.6）。
    func testTokensJustUnderOneMillionShowAsThousandK() {
        XCTAssertEqual(EnglishFormat.tokens(999_950), "1000.0k")
        XCTAssertEqual(EnglishFormat.tokens(999_999), "1000.0k")
    }

    func testTokensFromOneMillionUseOneDecimalM() {
        XCTAssertEqual(EnglishFormat.tokens(1_000_000), "1.0M")
        XCTAssertEqual(EnglishFormat.tokens(1_049_999), "1.0M")
        XCTAssertEqual(EnglishFormat.tokens(1_050_000), "1.1M")
        XCTAssertEqual(EnglishFormat.tokens(1_250_000), "1.2M", "%.1f 对正好一半的值取偶")
        XCTAssertEqual(EnglishFormat.tokens(123_456_789), "123.5M")
    }

    // MARK: - 倒计时

    func testCountdownShowsHoursAndMinutes() {
        XCTAssertEqual(EnglishFormat.countdown(0), "0m")
        XCTAssertEqual(EnglishFormat.countdown(59), "0m")
        XCTAssertEqual(EnglishFormat.countdown(59.9), "0m", "秒数向下取整")
        XCTAssertEqual(EnglishFormat.countdown(60), "1m")
        XCTAssertEqual(EnglishFormat.countdown(3599), "59m")
        XCTAssertEqual(EnglishFormat.countdown(3600), "1h0m")
        XCTAssertEqual(EnglishFormat.countdown(8100), "2h15m")
        XCTAssertEqual(EnglishFormat.countdown(86_400), "24h0m", "短倒计时不进位到天")
        XCTAssertEqual(EnglishFormat.countdown(-10), "0m", "负数当 0")
    }

    func testCountdownLongSwitchesToTheLocalizedDayHourFromOneDay() {
        XCTAssertEqual(EnglishFormat.countdownLong(86_399), "23h59m", "不到一天沿用 countdown")
        XCTAssertEqual(EnglishFormat.countdownLong(86_400), "dayHour(1,0)")
        XCTAssertEqual(EnglishFormat.countdownLong(90_000), "dayHour(1,1)")
        XCTAssertEqual(EnglishFormat.countdownLong(7 * 86_400 - 1), "dayHour(6,23)", "小时向下取整")
        XCTAssertEqual(EnglishFormat.countdownLong(7 * 86_400), "dayHour(7,0)")
        XCTAssertEqual(EnglishFormat.countdownLong(-10), "0m")
        XCTAssertEqual(ChineseFormat.countdownLong(90_000), "1 天 1 小时", "文案由各自的 Localization 给")
    }

    // MARK: - 字节

    func testBytesUseTheFileCountStyle() {
        for value: Int64 in [0, 1, 999, 1000, 1_000_000, 1_048_576, 5_368_709_120] {
            XCTAssertEqual(EnglishFormat.bytes(value),
                           ByteCountFormatter.string(fromByteCount: value, countStyle: .file))
        }
        // .file 是十进制（1 MB = 1000 × 1000 字节），与二进制口径不同。
        XCTAssertNotEqual(EnglishFormat.bytes(1_000_000),
                          ByteCountFormatter.string(fromByteCount: 1_000_000, countStyle: .binary))
    }

    // MARK: - 相对时间

    func testRelativeIsAbbreviatedInTheLocalizationLocaleAndRelativeToNow() {
        let now = Date(timeIntervalSince1970: 1_794_297_600)
        let threeMinutesAgo = now.addingTimeInterval(-180)
        XCTAssertEqual(EnglishFormat.relative(threeMinutesAgo, now: now),
                       Self.reference(threeMinutesAgo, now: now, locale: "en"))
        XCTAssertEqual(ChineseFormat.relative(threeMinutesAgo, now: now),
                       Self.reference(threeMinutesAgo, now: now, locale: "zh-Hans"))
        XCTAssertTrue(ChineseFormat.relative(threeMinutesAgo, now: now).contains("分钟"))
        XCTAssertNotEqual(EnglishFormat.relative(threeMinutesAgo, now: now),
                          ChineseFormat.relative(threeMinutesAgo, now: now))
        // 相对的是传进来的 now，不是此刻。
        XCTAssertNotEqual(EnglishFormat.relative(threeMinutesAgo, now: now),
                          EnglishFormat.relative(threeMinutesAgo, now: now.addingTimeInterval(7200)))
        XCTAssertEqual(EnglishFormat.relative(now.addingTimeInterval(180), now: now),
                       Self.reference(now.addingTimeInterval(180), now: now, locale: "en"), "将来的时间也照常")
    }

    private static func reference(_ date: Date, now: Date, locale: String) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - 星期名

    func testWeekdayNamesAreStandaloneFromSundayInTheLocalizationLocale() {
        XCTAssertEqual(EnglishFormat.weekdayName(1), "Sunday")
        XCTAssertEqual(EnglishFormat.weekdayName(2), "Monday")
        XCTAssertEqual(EnglishFormat.weekdayName(7), "Saturday")
        XCTAssertEqual(ChineseFormat.weekdayName(1), "星期日")
        XCTAssertEqual(ChineseFormat.weekdayName(4), "星期三")
    }

    func testWeekdayNameOutOfRangeIsTheNumberItself() {
        XCTAssertEqual(EnglishFormat.weekdayName(0), "0")
        XCTAssertEqual(EnglishFormat.weekdayName(8), "8")
        XCTAssertEqual(ChineseFormat.weekdayName(-1), "-1")
    }

    func testWeekAnchorIsTheWeekdayNameAndTheZeroPaddedHour() {
        XCTAssertEqual(EnglishFormat.weekAnchor(weekday: 4, hour: 9), "Wednesday 09:00")
        XCTAssertEqual(EnglishFormat.weekAnchor(weekday: 1, hour: 0), "Sunday 00:00")
        XCTAssertEqual(EnglishFormat.weekAnchor(weekday: 7, hour: 23), "Saturday 23:00")
        XCTAssertEqual(ChineseFormat.weekAnchor(weekday: 4, hour: 9), "星期三 09:00")
        XCTAssertEqual(EnglishFormat.weekAnchor(weekday: 9, hour: 100), "9 100:00", "越界原样带出")
    }
}

// MARK: - 假的 Localization

/// 英文；「N 天 M 小时」拼成一眼能认出的串，看天数、小时的换算。
private enum EnglishTestLocalization: CLIFormatLocalization {
    static func dayHour(days: Int, hours: Int) -> String { "dayHour(\(days),\(hours))" }
    static var locale: Locale { Locale(identifier: "en") }
}

/// 简体中文；看「语言、文案由 Localization 给」。
private enum ChineseTestLocalization: CLIFormatLocalization {
    static func dayHour(days: Int, hours: Int) -> String { "\(days) 天 \(hours) 小时" }
    static var locale: Locale { Locale(identifier: "zh-Hans") }
}

private typealias EnglishFormat = CLIFormat<EnglishTestLocalization>
private typealias ChineseFormat = CLIFormat<ChineseTestLocalization>
