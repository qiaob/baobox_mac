import Foundation
import XCTest

/// 计算引擎：日期（docs/launcher/TECH_DESIGN.md §7 第 2 种句型）。「现在」= 2026-11-23（周一）10:00 上海。
final class LauncherCalcDateTests: XCTestCase {

    func testRequirementExamples() {
        assertLauncherCalc("今天 + 45 天", "2027年1月7日 星期四", "今天 + 45 天", kind: .date, copy: "2027-01-07")
        assertLauncherCalc("today + 2 weeks", "2026年12月7日 星期一", "今天 + 2 周", copy: "2026-12-07")
        assertLauncherCalc("2026-12-25 - today", "32 天（4 周 4 天）", "2026-12-25 - 今天", copy: "32")
        assertLauncherCalc("下周五是几号", "2026年12月4日 星期五", "下周五", copy: "2026-12-04")
        assertLauncherCalc("月底", "2026年11月30日 星期一", "月底", copy: "2026-11-30")
    }

    func testEnglishInterface() {
        assertLauncherCalc("today + 2 weeks", "Mon, Dec 7, 2026", "today + 2 weeks", english: true)
        assertLauncherCalc("2026-12-25 - today", "32 days (4 weeks 4 days)", "2026-12-25 - today", english: true)
        assertLauncherCalc("下周五是几号", "Fri, Dec 4, 2026", "next Friday", english: true)
        assertLauncherCalc("2026-12-26 - 2026-12-25", "1 day", "2026-12-26 - 2026-12-25", english: true)
    }

    func testRelativeDays() {
        assertLauncherCalc("明天是星期几", "2026年11月24日 星期二", "明天")
        assertLauncherCalc("45 天后", "2027年1月7日 星期四", "今天 + 45 天")
        assertLauncherCalc("3 周前", "2026年11月2日 星期一", "今天 - 3 周")
        assertLauncherCalc("in 3 days", "2026年11月26日 星期四", "今天 + 3 天")
        assertLauncherCalc("3 days ago", "2026年11月20日 星期五", "今天 - 3 天")
        assertLauncherCalc("今天 - 3 天", "2026年11月20日 星期五", "今天 - 3 天")
        assertLauncherCalc("今天 + 1 个月", "2026年12月23日 星期三", "今天 + 1 个月")
        assertLauncherCalc("2026-01-31 + 1 month", "2026年2月28日 星期六", "2026-01-31 + 1 个月")
        assertLauncherCalc("年底", "2026年12月31日 星期四", "年底")
    }

    func testWeekdays() {
        assertLauncherCalc("下周五", "2026年12月4日 星期五", "下周五")
        assertLauncherCalc("周五是几号", "2026年11月27日 星期五", "周五")
        assertLauncherCalc("this friday", "2026年11月27日 星期五", "本周五")
        assertLauncherCalc("next friday", "2026年12月4日 星期五", "下周五")
        assertLauncherCalc("last monday", "2026年11月16日 星期一", "上周一")
        assertLauncherCalc("这周日", "2026年11月29日 星期日", "本周日")
        assertLauncherCalc("下个星期三", "2026年12月2日 星期三", "下周三")
    }

    func testDateDifferences() {
        assertLauncherCalc("today - 2026-12-25", "-32 天（4 周 4 天）", "今天 - 2026-12-25", copy: "-32")
        assertLauncherCalc("2026-12-25 - 2026-12-20", "5 天", "2026-12-25 - 2026-12-20")
        assertLauncherCalc("2026-12-25 - 2026-12-11", "14 天（2 周）", "2026-12-25 - 2026-12-11")
        assertLauncherCalc("2026/12/25 - 今天", "32 天（4 周 4 天）", "2026-12-25 - 今天")
        assertLauncherCalc("12月25日 - 今天", "32 天（4 周 4 天）", "2026-12-25 - 今天")
        assertLauncherCalc("离 2026-12-25 还有几天", "32 天（4 周 4 天）", "2026-12-25 - 今天")
        assertLauncherCalc("2026-12-25还有几天", "32 天（4 周 4 天）", "2026-12-25 - 今天")
        assertLauncherCalc("days until 2026-12-25", "32 天（4 周 4 天）", "2026-12-25 - 今天")
        assertLauncherCalc("days since 2026-01-01", "326 天（46 周 4 天）", "今天 - 2026-01-01")
    }

    func testWhatDayIsADate() {
        assertLauncherCalc("2026-12-25 是星期几", "2026年12月25日 星期五", "2026-12-25")
        assertLauncherCalc("2026年12月25日是星期几", "2026年12月25日 星期五", "2026-12-25")
    }

    func testOutOfRangeAndInvalidDates() {
        assertLauncherCalcFailure("今天 + 100000 年", .outOfRange, interpretation: "今天 + 100000 年")
        assertLauncherCalcNil("2026-02-30 - today")
        assertLauncherCalcNil("2026-13-01 - today")
        assertLauncherCalcNil("今天 + 1.5 天")
        assertLauncherCalcNil("今天 + 1000000 天")
    }

    func testSingleWordsAndPlainDatesGiveNothing() {
        assertLauncherCalcNil("今天")
        assertLauncherCalcNil("today")
        assertLauncherCalcNil("明天")
        assertLauncherCalcNil("周五")
        assertLauncherCalcNil("friday")
        assertLauncherCalcNil("2026-11-23")
        assertLauncherCalcNil("12月25日")
        assertLauncherCalcNil("下周")
        assertLauncherCalcNil("5 days")
        assertLauncherCalcNil("离 2026-12-25")
    }

    func testUsesTheContextTimeZone() {
        // 上海 10:00 = 洛杉矶前一天 18:00：「明天」是 11 月 23 日。
        let losAngeles = TimeZone(identifier: "America/Los_Angeles") ?? .current
        let context = LauncherCalcTestSupport.context(timeZone: losAngeles)
        XCTAssertEqual(LauncherCalculator.evaluate("明天是几号", context: context)?.copyText, "2026-11-23")
    }

    func testWeekAlwaysStartsOnMondayAndNonGregorianCalendarsAreHandled() {
        var sundayFirst = Calendar(identifier: .gregorian)
        sundayFirst.firstWeekday = 1
        let context = LauncherCalcTestSupport.context(calendar: sundayFirst)
        XCTAssertEqual(LauncherCalculator.evaluate("下周五", context: context)?.copyText, "2026-12-04")
        let buddhist = LauncherCalcTestSupport.context(calendar: Calendar(identifier: .buddhist))
        XCTAssertEqual(LauncherCalculator.evaluate("2026-12-25 - today", context: buddhist)?.copyText, "32")
        XCTAssertEqual(LauncherCalculator.evaluate("今天 + 45 天", context: buddhist)?.copyText, "2027-01-07")
    }
}
