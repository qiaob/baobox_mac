import Foundation
import XCTest

/// 额度 80% 提醒的防重与窗口切换。
final class CLIUsageBudgetReminderTests: XCTestCase {

    private let windowA = date("2026-11-02T10:00:00Z")
    private let windowB = date("2026-11-02T15:00:00Z")

    func testRemindsOnceWhenUsageCrosses80Percent() {
        var reminder = CLIUsageBudgetReminder()

        XCTAssertEqual(reminder.check(windowStart: windowA, totalTokens: 799, budget: 1_000), .init())
        XCTAssertEqual(reminder.check(windowStart: windowA, totalTokens: 800, budget: 1_000), .init(reachedPercent: 80))
        XCTAssertEqual(reminder.check(windowStart: windowA, totalTokens: 990, budget: 1_000), .init(), "同一窗口不重复提醒")
    }

    func testPercentIsRounded() {
        var reminder = CLIUsageBudgetReminder()
        XCTAssertEqual(reminder.check(windowStart: windowA, totalTokens: 857, budget: 1_000), .init(reachedPercent: 86))

        var over = CLIUsageBudgetReminder()
        XCTAssertEqual(over.check(windowStart: windowA, totalTokens: 1_500, budget: 1_000), .init(reachedPercent: 150))
    }

    func testNewWindowAfterAReminderReportsTheSwitchAndCanRemindAgain() {
        var reminder = CLIUsageBudgetReminder()
        XCTAssertEqual(reminder.check(windowStart: windowA, totalTokens: 900, budget: 1_000), .init(reachedPercent: 90))

        XCTAssertEqual(reminder.check(windowStart: windowB, totalTokens: 100, budget: 1_000), .init(windowChanged: true))
        XCTAssertEqual(reminder.remindedStarts, [])
        XCTAssertEqual(reminder.check(windowStart: windowB, totalTokens: 850, budget: 1_000), .init(reachedPercent: 85))
        XCTAssertEqual(reminder.check(windowStart: windowB, totalTokens: 950, budget: 1_000), .init())
    }

    func testSwitchStraightIntoAnotherFullWindowReportsBoth() {
        var reminder = CLIUsageBudgetReminder()
        _ = reminder.check(windowStart: windowA, totalTokens: 900, budget: 1_000)
        XCTAssertEqual(reminder.check(windowStart: windowB, totalTokens: 820, budget: 1_000),
                       .init(windowChanged: true, reachedPercent: 82))
        XCTAssertEqual(reminder.remindedStarts, [windowB])
    }

    func testWindowSwitchWithoutAnEarlierReminderIsNotReported() {
        var reminder = CLIUsageBudgetReminder()
        XCTAssertEqual(reminder.check(windowStart: windowA, totalTokens: 100, budget: 1_000), .init())
        XCTAssertEqual(reminder.check(windowStart: windowB, totalTokens: 100, budget: 1_000), .init())
    }

    func testNoBudgetMeansNoReminderAndNoStateChange() {
        var reminder = CLIUsageBudgetReminder()
        XCTAssertEqual(reminder.check(windowStart: windowA, totalTokens: 5_000, budget: 0), .init())
        XCTAssertEqual(reminder.check(windowStart: windowA, totalTokens: 5_000, budget: -1), .init())
        XCTAssertEqual(reminder.remindedStarts, [])

        // 已经提醒过的状态在「预算被清成 0」期间原样保留。
        _ = reminder.check(windowStart: windowA, totalTokens: 900, budget: 1_000)
        XCTAssertEqual(reminder.check(windowStart: windowB, totalTokens: 900, budget: 0), .init())
        XCTAssertEqual(reminder.remindedStarts, [windowA])
    }
}
