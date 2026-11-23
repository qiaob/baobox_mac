import Foundation
import XCTest

/// 计算引擎：时区（docs/launcher/TECH_DESIGN.md §7 第 2 种句型）。「现在」= 上海 2026-11-23 10:00（UTC 02:00）。
final class LauncherCalcTimeZoneTests: XCTestCase {

    // MARK: - 某地现在几点

    func testRequirementExamples() {
        assertLauncherCalc("东京现在几点", "11:00 · 11月23日 周一", "东京现在（UTC+9）", kind: .timeZone, copy: "11:00")
        assertLauncherCalc("time in tokyo", "11:00 · 11月23日 周一", "东京现在（UTC+9）")
        assertLauncherCalc("下午 3 点 新加坡 北京", "15:00 · 11月23日 周一", "15:00 新加坡（UTC+8） → 北京（UTC+8）",
                           copy: "15:00")
        assertLauncherCalc("15:00 SGT in PST", "23:00 · 11月22日 周日（前一天）", "15:00 SGT（UTC+8） → PST（UTC-8）")
    }

    func testEnglishInterface() {
        assertLauncherCalc("time in tokyo", "11:00 · Mon, Nov 23", "Now in Tokyo (UTC+9)", english: true)
        assertLauncherCalc("15:00 SGT in PST", "23:00 · Sun, Nov 22 (previous day)", "15:00 SGT (UTC+8) → PST (UTC-8)",
                           english: true)
    }

    func testOtherNowWordings() {
        assertLauncherCalc("现在东京几点", "11:00 · 11月23日 周一", "东京现在（UTC+9）")
        assertLauncherCalc("tokyo time", "11:00 · 11月23日 周一", "东京现在（UTC+9）")
        assertLauncherCalc("北京时间", "10:00 · 11月23日 周一", "北京现在（UTC+8）")
        assertLauncherCalc("what time is it in london", "02:00 · 11月23日 周一", "伦敦现在（UTC+0）")
        assertLauncherCalc("time in new york", "21:00 · 11月22日 周日（前一天）", "纽约现在（UTC-5）")
    }

    func testIANANamesAndUTCOffsets() {
        assertLauncherCalc("time in America/New_York", "21:00 · 11月22日 周日（前一天）", "America/New_York 现在（UTC-5）")
        assertLauncherCalc("UTC+5:30 现在几点", "07:30 · 11月23日 周一", "UTC+5:30 现在")
        assertLauncherCalc("now in UTC-3", "23:00 · 11月22日 周日（前一天）", "UTC-3 现在")
        assertLauncherCalc("15:00 UTC+8 to Asia/Tokyo", "16:00 · 11月23日 周一", "15:00 UTC+8 → Asia/Tokyo（UTC+9）")
        assertLauncherCalc("12am utc in jst", "09:00 · 11月23日 周一", "00:00 UTC → JST（UTC+9）")
    }

    // MARK: - 换算

    func testOnePlaceMeansTheOtherSideIsLocal() {
        assertLauncherCalc("3pm in tokyo", "16:00 · 11月23日 周一", "15:00 本地（UTC+8） → 东京（UTC+9）")
        assertLauncherCalc("3pm tokyo", "14:00 · 11月23日 周一", "15:00 东京（UTC+9） → 本地（UTC+8）")
        assertLauncherCalc("东京下午3点是几点", "14:00 · 11月23日 周一", "15:00 东京（UTC+9） → 本地（UTC+8）")
    }

    func testChineseTimeOfDay() {
        assertLauncherCalc("东京下午3点是北京几点", "14:00 · 11月23日 周一", "15:00 东京（UTC+9） → 北京（UTC+8）")
        assertLauncherCalc("下午3点半 伦敦", "23:30 · 11月23日 周一", "15:30 伦敦（UTC+0） → 本地（UTC+8）")
        assertLauncherCalc("上午10点20分 东京 北京", "09:20 · 11月23日 周一", "10:20 东京（UTC+9） → 北京（UTC+8）")
        assertLauncherCalc("晚上8点 洛杉矶 北京", "12:00 · 11月23日 周一（后一天）", "20:00 洛杉矶（UTC-8） → 北京（UTC+8）")
        assertLauncherCalc("15点 东京", "14:00 · 11月23日 周一", "15:00 东京（UTC+9） → 本地（UTC+8）")
    }

    func testFixedAbbreviationsIgnoreDaylightSavingButCitiesFollowIt() {
        // 2026-07-01 02:00 UTC：纽约是夏令时 UTC-4；PST 按字面永远是 UTC-8。
        let summer = LauncherCalcTestSupport.context(now: Date(timeIntervalSince1970: 1_782_871_200))
        XCTAssertEqual(LauncherCalculator.evaluate("time in new york", context: summer)?.copyText, "22:00")
        XCTAssertEqual(LauncherCalculator.evaluate("15:00 PST in UTC", context: summer)?.copyText, "23:00")
        XCTAssertEqual(LauncherCalculator.evaluate("15:00 PT in UTC", context: summer)?.copyText, "22:00")
    }

    // MARK: - 不出结果

    func testPlaceOrTimeAloneGivesNothing() {
        assertLauncherCalcNil("东京")
        assertLauncherCalcNil("tokyo")
        assertLauncherCalcNil("下午3点")
        assertLauncherCalcNil("15:00")
        assertLauncherCalcNil("3pm")
        assertLauncherCalcNil("UTC+8")
        assertLauncherCalcNil("Asia/Tokyo")
        assertLauncherCalcNil("time in")
    }

    func testInvalidTimesAndOffsetsGiveNothing() {
        assertLauncherCalcNil("25:00 东京")
        assertLauncherCalcNil("13pm tokyo")
        assertLauncherCalcNil("utc+15 现在几点")
        assertLauncherCalcNil("15:61 东京")
    }

    func testOrdinaryNamesThatContainAPlaceGiveNothing() {
        assertLauncherCalcNil("new york times")
        assertLauncherCalcNil("tokyo ghoul")
        assertLauncherCalcNil("london eye")
        assertLauncherCalcNil("北京烤鸭")
    }
}
