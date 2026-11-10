import Foundation
import XCTest

/// 5 小时额度窗口与周窗口（滚动块 / 固定锚点）。2026-11-02 是星期一。
final class AIUsageWindowTests: XCTestCase {

    // MARK: - 5 小时窗口

    func testFiveHourBlockStartsAtTheFlooredHourAndSumsItsEntries() throws {
        // 故意乱序：算法自己按时间排。
        let entries = [
            entry("2026-11-02T12:05:00Z", input: 200),
            entry("2026-11-02T14:59:59Z", input: 300),
            entry("2026-11-02T10:17:30Z", input: 100),
        ]
        let window = try XCTUnwrap(AnthropicCalc.activeWindow(from: entries, now: date("2026-11-02T14:00:00Z")))

        XCTAssertEqual(window.start, date("2026-11-02T10:00:00Z"), "首条 10:17:30 向下取整到 10:00")
        XCTAssertEqual(window.end, date("2026-11-02T15:00:00Z"))
        XCTAssertEqual(window.totals.input, 600)
    }

    func testEntryExactlyAtTheBlockEndStaysInThatBlock() throws {
        let entries = [
            entry("2026-11-02T10:17:00Z", input: 100),
            entry("2026-11-02T15:00:00Z", input: 200),   // = start + 5h，不算超出
        ]
        let window = try XCTUnwrap(AnthropicCalc.activeWindow(from: entries, now: date("2026-11-02T15:00:00Z")))
        XCTAssertEqual(window.start, date("2026-11-02T10:00:00Z"))
        XCTAssertEqual(window.totals.input, 300)
    }

    func testEntryPastFiveHoursOpensANewBlockAtItsFlooredHour() throws {
        let entries = [
            entry("2026-11-02T10:17:00Z", input: 100),
            entry("2026-11-02T15:00:01Z", input: 200),   // > start + 5h → 新块
            entry("2026-11-02T19:30:00Z", input: 400),
        ]
        let window = try XCTUnwrap(AnthropicCalc.activeWindow(from: entries, now: date("2026-11-02T19:45:00Z")))

        XCTAssertEqual(window.start, date("2026-11-02T15:00:00Z"), "新块从 15:00:01 取整后的 15:00 开始")
        XCTAssertEqual(window.end, date("2026-11-02T20:00:00Z"))
        XCTAssertEqual(window.totals.input, 600, "旧块的 100 不算进当前窗口")
    }

    func testLastBlockIsActiveUntilItsEndInclusive() {
        let entries = [entry("2026-11-02T10:17:00Z", input: 100)]

        XCTAssertNotNil(AnthropicCalc.activeWindow(from: entries, now: date("2026-11-02T15:00:00Z")), "now == end 仍活跃")
        XCTAssertNil(AnthropicCalc.activeWindow(from: entries, now: date("2026-11-02T15:00:01Z")), "过了 end 就没有活跃窗口")
    }

    func testNoEntriesMeansNoWindow() {
        XCTAssertNil(AnthropicCalc.activeWindow(from: [], now: date("2026-11-02T10:00:00Z")))
    }

    func testFloorToHourUsesUTCHours() {
        XCTAssertEqual(AnthropicCalc.floorToHour(date("2026-11-02T10:59:59Z")), date("2026-11-02T10:00:00Z"))
        XCTAssertEqual(AnthropicCalc.floorToHour(date("2026-11-02T10:00:00Z")), date("2026-11-02T10:00:00Z"))
        // 印度 +05:30：本地 16:17 = UTC 10:47 → UTC 10:00（本地 15:30），不随时区取整到本地整点。
        XCTAssertEqual(AnthropicCalc.floorToHour(date("2026-11-02T16:17:00+05:30")), date("2026-11-02T10:00:00Z"))
    }

    // MARK: - 周窗口：滚动块

    func testRollingWeekUsesTheSameBlockingWithA168HourSpan() throws {
        let rolling = AIUsageWeeklyAnchor(fixed: false, weekday: 2, hour: 0)
        var entries = [
            entry("2026-11-02T10:30:00Z", input: 100),
            entry("2026-11-08T09:00:00Z", input: 200),
        ]
        let week = try XCTUnwrap(AnthropicCalc.weeklyWindow(from: entries, anchor: rolling, now: date("2026-11-08T12:00:00Z")))
        XCTAssertEqual(week.start, date("2026-11-02T10:00:00Z"))
        XCTAssertEqual(week.end, date("2026-11-09T10:00:00Z"))
        XCTAssertEqual(week.totals.input, 300)

        // 超过 start + 168h 的用量开新的一周。
        entries.append(entry("2026-11-09T10:00:01Z", input: 400))
        let next = try XCTUnwrap(AnthropicCalc.weeklyWindow(from: entries, anchor: rolling, now: date("2026-11-09T11:00:00Z")))
        XCTAssertEqual(next.start, date("2026-11-09T10:00:00Z"))
        XCTAssertEqual(next.end, date("2026-11-16T10:00:00Z"))
        XCTAssertEqual(next.totals.input, 400)
    }

    func testRollingWeekWithoutEntriesIsNil() {
        let rolling = AIUsageWeeklyAnchor(fixed: false, weekday: 2, hour: 0)
        XCTAssertNil(AnthropicCalc.weeklyWindow(from: [], anchor: rolling, now: date("2026-11-04T12:00:00Z")))
    }

    // MARK: - 周窗口：固定锚点

    func testFixedAnchorSumsUsageSinceTheLastResetTime() throws {
        let mondayNine = AIUsageWeeklyAnchor(fixed: true, weekday: 2, hour: 9)
        let entries = [
            entry("2026-11-02T08:59:59Z", input: 1),     // 重置前一秒：不算
            entry("2026-11-02T09:00:00Z", input: 10),    // 正好重置：算
            entry("2026-11-04T11:00:00Z", input: 100),
        ]
        let week = try XCTUnwrap(AnthropicCalc.weeklyWindow(
            from: entries, anchor: mondayNine, now: date("2026-11-04T12:00:00Z"), calendar: gregorian("UTC")))

        XCTAssertEqual(week.start, date("2026-11-02T09:00:00Z"), "周三中午往前最近的「周一 9:00」")
        XCTAssertEqual(week.end, date("2026-11-09T09:00:00Z"))
        XCTAssertEqual(week.totals.input, 110)
    }

    func testFixedAnchorFollowsTheCalendarTimeZone() throws {
        let mondayNine = AIUsageWeeklyAnchor(fixed: true, weekday: 2, hour: 9)
        let entries = [entry("2026-11-02T08:59:59Z", input: 1)]   // = 上海周一 16:59:59
        let week = try XCTUnwrap(AnthropicCalc.weeklyWindow(
            from: entries, anchor: mondayNine, now: date("2026-11-04T12:00:00Z"), calendar: gregorian("Asia/Shanghai")))

        XCTAssertEqual(week.start, date("2026-11-02T09:00:00+08:00"))
        XCTAssertEqual(week.totals.input, 1)
    }

    func testFixedAnchorWithoutUsageStillGivesAnEmptyWindow() throws {
        let mondayNine = AIUsageWeeklyAnchor(fixed: true, weekday: 2, hour: 9)
        let week = try XCTUnwrap(AnthropicCalc.weeklyWindow(
            from: [], anchor: mondayNine, now: date("2026-11-04T12:00:00Z"), calendar: gregorian("UTC")))

        XCTAssertEqual(week.start, date("2026-11-02T09:00:00Z"))
        XCTAssertEqual(week.end, date("2026-11-09T09:00:00Z"))
        XCTAssertEqual(week.totals, .zero)
    }

    func testAnchorFromSettingsIsClamped() {
        XCTAssertEqual(AIUsageWeeklyAnchor(fixed: true, clampingWeekday: 0, hour: 24),
                       AIUsageWeeklyAnchor(fixed: true, weekday: 1, hour: 23))
        XCTAssertEqual(AIUsageWeeklyAnchor(fixed: false, clampingWeekday: 9, hour: -1),
                       AIUsageWeeklyAnchor(fixed: false, weekday: 7, hour: 0))
        XCTAssertEqual(AIUsageWeeklyAnchor(fixed: true, clampingWeekday: 3, hour: 5),
                       AIUsageWeeklyAnchor(fixed: true, weekday: 3, hour: 5))
    }
}
