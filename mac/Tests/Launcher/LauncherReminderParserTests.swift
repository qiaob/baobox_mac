import Foundation
import XCTest

/// 带时间的句子（docs/launcher/TECH_DESIGN.md §5.4「一次性提醒」，第 10 步）：「现在」写死成 2026-11-23（周一）10:00 Asia/Shanghai。
final class LauncherReminderParserTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = LauncherCalcTestSupport.shanghai
        return cal
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func parse(_ text: String, now: Date = LauncherCalcTestSupport.now) -> LauncherReminderDraft? {
        LauncherReminderParser.parse(text, context: LauncherCalcTestSupport.context(now: now))
    }

    private func assertReminder(_ input: String, _ expected: Date, _ text: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let draft = parse(input) else {
            XCTFail("「\(input)」没认出来", file: file, line: line)
            return
        }
        XCTAssertEqual(draft.date, expected, "「\(input)」的时刻", file: file, line: line)
        XCTAssertEqual(draft.text, text, "「\(input)」的事由", file: file, line: line)
    }

    // MARK: - 相对时间

    func testChineseRelative() {
        assertReminder("20 分钟后提醒我取快递", date(11, 23, 10, 20), "取快递")
        assertReminder("20分钟后提醒我取快递", date(11, 23, 10, 20), "取快递")
        assertReminder("２０分钟后提醒我取快递", date(11, 23, 10, 20), "取快递")
        assertReminder("半小时后开会", date(11, 23, 10, 30), "开会")
        assertReminder("半个小时以后 开会", date(11, 23, 10, 30), "开会")
        assertReminder("一刻钟后提醒我关火", date(11, 23, 10, 15), "关火")
        assertReminder("两个小时后去接孩子", date(11, 23, 12, 0), "去接孩子")
        assertReminder("一个半小时后提醒我出门", date(11, 23, 11, 30), "出门")
        assertReminder("1.5 小时后 交周报", date(11, 23, 11, 30), "交周报")
        assertReminder("二十分钟之后喝水", date(11, 23, 10, 20), "喝水")
        assertReminder("过 10 分钟提醒我喝水", date(11, 23, 10, 10), "喝水")
        assertReminder("提醒我20分钟后取快递", date(11, 23, 10, 20), "取快递")
        assertReminder("20 分钟后，提醒我：取快递。", date(11, 23, 10, 20), "取快递")
    }

    func testEnglishRelative() {
        assertReminder("in 20 minutes stretch", date(11, 23, 10, 20), "stretch")
        assertReminder("In 20 min, stretch", date(11, 23, 10, 20), "stretch")
        assertReminder("in an hour call mom", date(11, 23, 11, 0), "call mom")
        assertReminder("in half an hour standup", date(11, 23, 10, 30), "standup")
        assertReminder("in 90 mins deploy", date(11, 23, 11, 30), "deploy")
        assertReminder("in 2h review the PR", date(11, 23, 12, 0), "review the PR")
        assertReminder("remind me in 20 minutes to take out the trash", date(11, 23, 10, 20), "take out the trash")
        assertReminder("remind me to call mom in 20 minutes", date(11, 23, 10, 20), "call mom")
        assertReminder("call mom in 2 hours", date(11, 23, 12, 0), "call mom")
    }

    func testRelativeKeepsTheSeconds() {
        let now = LauncherCalcTestSupport.now.addingTimeInterval(37)
        XCTAssertEqual(parse("20 分钟后取快递", now: now)?.date, now.addingTimeInterval(20 * 60))
    }

    // MARK: - 绝对时间

    func testChineseDayAndClock() {
        assertReminder("明天下午三点开会", date(11, 24, 15, 0), "开会")
        assertReminder("明天 15:30 评审", date(11, 24, 15, 30), "评审")
        assertReminder("明天１５：３０评审", date(11, 24, 15, 30), "评审")
        assertReminder("后天上午十点半面试", date(11, 25, 10, 30), "面试")
        assertReminder("大后天上午九点体检", date(11, 26, 9, 0), "体检")
        assertReminder("今晚八点看球", date(11, 23, 20, 0), "看球")
        assertReminder("今天下午3点一刻 交报告", date(11, 23, 15, 15), "交报告")
        assertReminder("今天下午三点十五分交报告", date(11, 23, 15, 15), "交报告")
        assertReminder("今天下午三点零五交报告", date(11, 23, 15, 5), "交报告")
        assertReminder("今天下午3点05交报告", date(11, 23, 15, 5), "交报告")
        assertReminder("今天下午3点5分交报告", date(11, 23, 15, 5), "交报告")
        assertReminder("今天下午三点三刻交报告", date(11, 23, 15, 45), "交报告")
        assertReminder("明天早上 7 点 跑步", date(11, 24, 7, 0), "跑步")
        assertReminder("明早七点跑步", date(11, 24, 7, 0), "跑步")
        assertReminder("明天凌晨两点发布", date(11, 24, 2, 0), "发布")
        assertReminder("中午12点吃饭", date(11, 23, 12, 0), "吃饭")
        assertReminder("中午1点吃饭", date(11, 23, 13, 0), "吃饭")
        assertReminder("下午13点吃饭", date(11, 23, 13, 0), "吃饭")
        assertReminder("今晚12点跨年", date(11, 24, 0, 0), "跨年")
        assertReminder("15:30 开会", date(11, 23, 15, 30), "开会")
        assertReminder("明天下午三点，提醒我开会", date(11, 24, 15, 0), "开会")
        assertReminder("提醒我明天下午三点开会", date(11, 24, 15, 0), "开会")
        assertReminder("明天下午三点钟开会", date(11, 24, 15, 0), "开会")
    }

    func testWeekdays() {
        assertReminder("周五 下午三点 交周报", date(11, 27, 15, 0), "交周报")
        assertReminder("星期五下午三点交周报", date(11, 27, 15, 0), "交周报")
        assertReminder("下周五下午三点交周报", date(12, 4, 15, 0), "交周报")
        assertReminder("周一下午两点开会", date(11, 23, 14, 0), "开会")
        // 今天就是周一、上午九点已经过了：下周一。
        assertReminder("周一上午九点开会", date(11, 30, 9, 0), "开会")
        assertReminder("friday 10am demo", date(11, 27, 10, 0), "demo")
        assertReminder("next friday at 3pm retro", date(12, 4, 15, 0), "retro")
    }

    func testEnglishClock() {
        assertReminder("明天3pm meeting", date(11, 24, 15, 0), "meeting")
        assertReminder("tomorrow at 3pm call bob", date(11, 24, 15, 0), "call bob")
        assertReminder("tomorrow 9:30am dentist", date(11, 24, 9, 30), "dentist")
        assertReminder("tomorrow 9:30 a.m. dentist", date(11, 24, 9, 30), "dentist")
        assertReminder("tonight 8pm movie", date(11, 23, 20, 0), "movie")
        assertReminder("at 5 dinner", date(11, 23, 17, 0), "dinner")
        assertReminder("3 pm standup", date(11, 23, 15, 0), "standup")
    }

    /// 没写上午下午时：1–6 点当成下午；7–11 点先当上午，已经过了再当晚上；写成 15:30 的不猜。
    func testHoursWithoutAPeriod() {
        assertReminder("明天三点开会", date(11, 24, 15, 0), "开会")
        assertReminder("明天9点开会", date(11, 24, 9, 0), "开会")
        assertReminder("今天 9 点吃饭", date(11, 23, 21, 0), "吃饭")
        assertReminder("今天11点开会", date(11, 23, 11, 0), "开会")
        XCTAssertNil(parse("9:00 开会"), "写成 9:00 的就是 9 点，已经过了")
    }

    // MARK: - 不算的

    func testPastTimesAreRejected() {
        for text in ["今天上午九点开会", "本周一上午九点开会", "上周五下午三点开会", "今天凌晨两点发布", "08:00 晨会"] {
            XCTAssertNil(parse(text), text)
        }
    }

    func testNoTimeOrNoEventIsRejected() {
        for text in ["明天再说", "下午开会", "明天下午开会", "3点", "明天下午三点", "20 分钟", "20分钟后", "20分钟后提醒我",
                     "in 20 minutes", "remind me in 20 minutes", "20 分钟取快递", "下周五是几号", "东京现在几点",
                     "今天 + 45 天", "2026-12-25 开会", "in 2026 we", "in a while call", "3个苹果", "3 apples",
                     "monitor 3pm check", "", "   "] {
            XCTAssertNil(parse(text), text)
        }
    }

    /// 时间后面跟「的」：说的是一样东西（「12点的会议纪要」），不是事由。
    func testTimeThatDescribesAThingIsRejected() {
        for text in ["12点的会议纪要", "10:30 的航班", "明天下午三点的会", "今晚八点的电影票"] {
            XCTAssertNil(parse(text), text)
        }
        assertReminder("明天下午三点开会的材料", date(11, 24, 15, 0), "开会的材料")
    }

    func testInvalidClocksAreRejected() {
        for text in ["三点五开会", "上午13点开会", "25点开会", "明天下午三点60分开会", "1.5点开会", "中午五点吃饭",
                     "in 0 minutes x", "10000 小时后 x"] {
            XCTAssertNil(parse(text), text)
        }
    }

    func testLongAndMultiLineInputIsRejected() {
        XCTAssertNil(parse("20 分钟后提醒我" + String(repeating: "取快递", count: 50)))
        XCTAssertNil(parse("20 分钟后提醒我\n取快递"))
    }

    func testOtherTimeZone() {
        // 同一个时刻在纽约是 2026-11-22 21:00（周日）。
        var cal = Calendar(identifier: .gregorian)
        let newYork = TimeZone(identifier: "America/New_York") ?? .current
        cal.timeZone = newYork
        let context = LauncherCalcTestSupport.context(timeZone: newYork)
        let draft = LauncherReminderParser.parse("明天上午九点开会", context: context)
        XCTAssertEqual(draft?.date, cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9)))
    }
}
