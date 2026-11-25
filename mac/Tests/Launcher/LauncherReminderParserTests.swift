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

    // MARK: - 第 10 步验证后定

    /// 中文数字 + 点、又没有别的时间信号：不是提醒（「一点也不好玩」）。代价是「三点开会」不再认。
    func testChineseNumeralClockNeedsAnotherSignal() {
        for text in ["一点也不好玩", "两点之间直线最短", "三点开会", "八点开会", "十二点吃饭", "两点一线的生活"] {
            XCTAssertNil(parse(text), text)
        }
        // 别的时间信号：日子词、时段词、提醒 / 叫我、点后面的钟 / 半 / 一刻 / 三刻 / N 分 / 整。
        assertReminder("明天三点开会", date(11, 24, 15, 0), "开会")
        assertReminder("周五三点开会", date(11, 27, 15, 0), "开会")
        assertReminder("今晚八点看球", date(11, 23, 20, 0), "看球")
        assertReminder("下午三点开会", date(11, 23, 15, 0), "开会")
        assertReminder("提醒我三点开会", date(11, 23, 15, 0), "开会")
        assertReminder("三点提醒我开会", date(11, 23, 15, 0), "开会")
        assertReminder("叫我两点起来", date(11, 23, 14, 0), "起来")
        assertReminder("两点钟开会", date(11, 23, 14, 0), "开会")
        assertReminder("三点半开会", date(11, 23, 15, 30), "开会")
        assertReminder("三点一刻开会", date(11, 23, 15, 15), "开会")
        assertReminder("三点三刻开会", date(11, 23, 15, 45), "开会")
        assertReminder("三点十五分开会", date(11, 23, 15, 15), "开会")
        assertReminder("三点整开会", date(11, 23, 15, 0), "开会")
        // 阿拉伯数字的钟点不受限制。
        assertReminder("3点开会", date(11, 23, 15, 0), "开会")
        assertReminder("15:30 开会", date(11, 23, 15, 30), "开会")
        assertReminder("3pm meeting", date(11, 23, 15, 0), "meeting")
    }

    func testAboutSomeHourIsNotAReminder() {
        for text in ["三点多开会", "3点多开会", "下午三点多开会", "明天3点多到"] {
            XCTAssertNil(parse(text), text)
        }
    }

    private func at(_ hour: Int, _ minute: Int, day: Int = 23) -> Date {
        date(11, day, hour, minute)
    }

    /// 晚上 / 今晚 / 夜里 + 1–5 点：那一晚之后的凌晨（所指那天的次日）；说的是今天而今天那个钟点还没到 → 今天。
    func testEveningSmallHoursAreTheMorningAfter() {
        // 现在 10:00（周一）
        let ten = at(10, 0)
        XCTAssertEqual(parse("晚上一点睡觉", now: ten)?.date, at(1, 0, day: 24))
        XCTAssertEqual(parse("今晚1点睡觉", now: ten)?.date, at(1, 0, day: 24))
        XCTAssertEqual(parse("夜里两点发布", now: ten)?.date, at(2, 0, day: 24))
        XCTAssertEqual(parse("明天晚上一点睡觉", now: ten)?.date, at(1, 0, day: 25), "明天晚上一点 = 后天 01:00")
        XCTAssertEqual(parse("明晚两点半发布", now: ten)?.date, at(2, 30, day: 25))
        XCTAssertEqual(parse("周五晚上两点发布", now: ten)?.date, date(11, 28, 2, 0), "周五晚上两点 = 周六 02:00")
        XCTAssertEqual(parse("晚上八点看球", now: ten)?.date, at(20, 0), "6 点以后照旧")
        XCTAssertEqual(parse("晚上12点跨年", now: ten)?.date, at(0, 0, day: 24), "同晚上12点 = 次日 0 点")
        // 现在 00:30：今天的 1 点还没到
        let early = at(0, 30)
        XCTAssertEqual(parse("晚上1点睡觉", now: early)?.date, at(1, 0))
        XCTAssertEqual(parse("今晚1点睡觉", now: early)?.date, at(1, 0))
        XCTAssertEqual(parse("明天晚上一点睡觉", now: early)?.date, at(1, 0, day: 25))
        XCTAssertEqual(parse("晚上十二点睡觉", now: early)?.date, at(0, 0, day: 24))
        // 现在 23:50
        let late = at(23, 50)
        XCTAssertEqual(parse("晚上一点睡觉", now: late)?.date, at(1, 0, day: 24))
        XCTAssertEqual(parse("今晚1点睡觉", now: late)?.date, at(1, 0, day: 24))
        XCTAssertEqual(parse("明天晚上一点睡觉", now: late)?.date, at(1, 0, day: 25))
        XCTAssertEqual(parse("晚上12点睡觉", now: late)?.date, at(0, 0, day: 24))
    }

    /// 时间后面跟「前 / 之前 / 以前」：照那个时刻，事由去掉这个词。
    func testBeforeATime() {
        assertReminder("下午3点前交报告", date(11, 23, 15, 0), "交报告")
        assertReminder("明天下午三点之前交报告", date(11, 24, 15, 0), "交报告")
        assertReminder("3点以前交报告", date(11, 23, 15, 0), "交报告")
        assertReminder("明天 15:30 前 交周报", date(11, 24, 15, 30), "交周报")
    }

    /// 时间段：按开始时刻，事由去掉后一个时刻和连接词；后面不是时刻的「到」照常进事由。
    func testTimeRangesStartAtTheFirstTime() {
        assertReminder("3点到5点开会", date(11, 23, 15, 0), "开会")
        assertReminder("3点-5点开会", date(11, 23, 15, 0), "开会")
        assertReminder("3点至5点开会", date(11, 23, 15, 0), "开会")
        assertReminder("下午三点到五点开会", date(11, 23, 15, 0), "开会")
        assertReminder("15:00-17:00 评审", date(11, 23, 15, 0), "评审")
        assertReminder("明天下午3点 ~ 5点 培训", date(11, 24, 15, 0), "培训")
        assertReminder("3点到公司", date(11, 23, 15, 0), "到公司")
        // 现有规则：没写时段的 1–6 点当下午（行上写着具体时刻，用户看得到）。
        assertReminder("明天6点起床", date(11, 24, 18, 0), "起床")
    }

    // MARK: - 第 10 步复查后定

    /// 钟点后面跟「了」：说的是现在几点。
    func testClockFollowedByLeIsNotAReminder() {
        for text in ["3 点了，该走了", "3点了", "下午三点了", "明天三点了", "三点钟了提醒我", "15:30了"] {
            XCTAssertNil(parse(text), text)
        }
        assertReminder("明天三点了解进度", date(11, 24, 15, 0), "了解进度")
    }

    /// 「N 点钟方向」是方位。
    func testClockDirectionIsNotAReminder() {
        for text in ["三点钟方向有敌人", "3点钟方向", "下午三点钟方向", "提醒我三点方向有车"] {
            XCTAssertNil(parse(text), text)
        }
    }

    /// 「前台、前往……」开头的「前」留在事由里；「前 / 之前 / 以前」照旧去掉。
    func testQianStartingAWordStaysInTheEvent() {
        assertReminder("下午3点前台见", date(11, 23, 15, 0), "前台见")
        assertReminder("明天上午十点前往机场", date(11, 24, 10, 0), "前往机场")
        assertReminder("3点前面集合", date(11, 23, 15, 0), "前面集合")
        assertReminder("下午3点前门接人", date(11, 23, 15, 0), "前门接人")
        assertReminder("下午3点前端评审", date(11, 23, 15, 0), "前端评审")
        for word in ["前后", "前方", "前排", "前进", "前提", "前辈", "前任"] {
            XCTAssertEqual(parse("下午3点\(word)x")?.text, "\(word)x", word)
        }
        assertReminder("下午3点前交报告", date(11, 23, 15, 0), "交报告")
        assertReminder("下午3点 前 交报告", date(11, 23, 15, 0), "交报告")
        assertReminder("3点以前交报告", date(11, 23, 15, 0), "交报告")
        assertReminder("明天下午三点之前交报告", date(11, 24, 15, 0), "交报告")
    }

    /// 句末的「提醒我 / 叫我」不进事由（这句有「提醒」，中文数字的钟点也算有信号）。
    func testTrailingAskIsDroppedFromTheEvent() {
        assertReminder("三点开会提醒我", date(11, 23, 15, 0), "开会")
        assertReminder("明天下午三点开会叫我", date(11, 24, 15, 0), "开会")
        assertReminder("三点开会，提醒我", date(11, 23, 15, 0), "开会")
        assertReminder("20分钟后取快递提醒我", date(11, 23, 10, 20), "取快递")
        XCTAssertNil(parse("三点提醒我"), "去掉以后事由是空的")
    }

    /// 「N 点」后面直接跟分钟数、不写「分」：≥ 10 或带零的认，并且算时间信号。
    func testMinutesWithoutFen() {
        assertReminder("三点十五开会", date(11, 23, 15, 15), "开会")
        assertReminder("3点15开会", date(11, 23, 15, 15), "开会")
        assertReminder("三点零五出发", date(11, 23, 15, 5), "出发")
        assertReminder("三点五十出发", date(11, 23, 15, 50), "出发")
        assertReminder("3 点 05 出发", date(11, 23, 15, 5), "出发")
        for text in ["三点一线", "三点一线的生活", "三点五开会"] {
            XCTAssertNil(parse(text), text)
        }
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
