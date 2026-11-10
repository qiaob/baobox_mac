import Foundation
import XCTest

/// 今日累计与按天 / 项目 / 模型的报表。
final class AIUsageReportTests: XCTestCase {

    private let posix = Locale(identifier: "en_US_POSIX")

    // MARK: - 今日

    func testTodayCountsOnlyTodayInTheCalendarTimeZone() throws {
        let entries = [
            entry("2026-11-03T23:59:59+08:00", input: 1),      // 上海昨天最后一秒
            entry("2026-11-04T00:00:00+08:00", input: 10),
            entry("2026-11-04T23:59:59+08:00", input: 100),
            entry("2026-11-05T00:00:00+08:00", input: 1_000),  // 上海明天
        ]

        let shanghai = try XCTUnwrap(AnthropicCalc.todayTotals(
            from: entries, now: date("2026-11-04T10:00:00+08:00"), calendar: gregorian("Asia/Shanghai")))
        XCTAssertEqual(shanghai.input, 110)

        // 同一时刻换成 UTC 日历：「今天」是 UTC 11-04，落进来的是另外两条。
        let utc = try XCTUnwrap(AnthropicCalc.todayTotals(
            from: entries, now: date("2026-11-04T10:00:00+08:00"), calendar: gregorian("UTC")))
        XCTAssertEqual(utc.input, 1_100)
    }

    func testTodayIsNilWithoutUsageToday() {
        let entries = [entry("2026-11-03T10:00:00Z", input: 1)]
        XCTAssertNil(AnthropicCalc.todayTotals(from: entries, now: date("2026-11-04T10:00:00Z"), calendar: gregorian("UTC")))
    }

    func testTodayCostUsesThePricingTable() throws {
        let entries = [entry("2026-11-04T09:00:00Z", model: "opus", input: 1_000_000, cacheWrite: 1_000_000)]
        let today = try XCTUnwrap(AnthropicCalc.todayTotals(from: entries, now: date("2026-11-04T10:00:00Z"), calendar: gregorian("UTC")))
        XCTAssertEqual(today.costUSD, 5 + 6.25, accuracy: costAccuracy)
    }

    // MARK: - 报表

    func testReportGroupsByDayProjectAndModel() {
        let entries = [
            entry("2026-11-03T10:00:00Z", model: "sonnet", project: "/work/alpha", input: 1_000_000),   // $3
            entry("2026-11-04T09:00:00Z", model: "opus", project: "/work/beta", input: 1_000_000),      // $5
            entry("2026-11-04T10:00:00Z", model: "sonnet", project: "/work/alpha", output: 100_000),    // $1.5
            entry("2026-11-04T11:00:00Z", model: "", project: "/work/gamma", input: 500),               // 未知模型
        ]
        let report = AnthropicCalc.buildReport(
            from: entries, order: .byCost, locale: posix, calendar: gregorian("UTC"), projectBucket: pathBucket)

        // 按天：新的在前。
        XCTAssertEqual(report.byDay.map(\.id), ["2026-11-04", "2026-11-03"])
        XCTAssertEqual(report.byDay.map(\.label), ["2026-11-04", "2026-11-03"])
        XCTAssertEqual(report.byDay.first?.date, date("2026-11-04T00:00:00Z"))
        XCTAssertEqual(report.byDay[0].totals.input, 1_000_500)
        XCTAssertEqual(report.byDay[0].totals.output, 100_000)
        XCTAssertEqual(report.byDay[0].totals.costUSD, 6.5, accuracy: costAccuracy)
        XCTAssertTrue(report.byDay[0].totals.unpriced)
        XCTAssertEqual(report.byDay[1].totals.costUSD, 3, accuracy: costAccuracy)
        XCTAssertFalse(report.byDay[1].totals.unpriced)

        // 按项目：费用从高到低；id / 显示名来自模块给的 projectBucket。
        XCTAssertEqual(report.byProject.map(\.id), ["/work/beta", "/work/alpha", "/work/gamma"])
        XCTAssertEqual(report.byProject.map(\.label), ["beta", "alpha", "gamma"])
        XCTAssertEqual(report.byProject[1].totals.costUSD, 4.5, accuracy: costAccuracy)
        XCTAssertNil(report.byProject[0].date)

        // 按模型：费用从高到低；空模型 id 归到 "unknown"。
        XCTAssertEqual(report.byModel.map(\.id), ["opus", "sonnet", "unknown"])
        XCTAssertEqual(report.byModel.map(\.label), ["opus", "sonnet", "unknown"])
        XCTAssertEqual(report.byModel[1].totals.input, 1_000_000)
        XCTAssertEqual(report.byModel[1].totals.output, 100_000)
        XCTAssertTrue(report.byModel[2].totals.unpriced)
    }

    func testReportCanRankProjectsAndModelsByTokens() {
        let entries = [
            // 300 万 token 全部命中缓存：便宜但量大。
            entry("2026-11-04T10:00:00Z", model: "gpt-5", project: "/work/cheap", input: 3_000_000, cacheRead: 3_000_000),
            // 20 万输出 token：量小但贵（$2）。
            entry("2026-11-04T11:00:00Z", model: "gpt-5", project: "/work/pricey", output: 200_000),
            entry("2026-11-04T12:00:00Z", model: "o3", project: "", input: 1_000),
        ]
        // 模块可以把空路径映射成自己的占位行（Codex 用 "unknown"）。
        let bucket: (String) -> (id: String, label: String) = { path in
            path.isEmpty ? (id: "unknown", label: "unknown") : pathBucket(path)
        }

        let byTokens = OpenAICalc.buildReport(
            from: entries, order: .byTokens, locale: posix, calendar: gregorian("UTC"), projectBucket: bucket)
        XCTAssertEqual(byTokens.byProject.map(\.id), ["/work/cheap", "/work/pricey", "unknown"])
        XCTAssertEqual(byTokens.byProject.map(\.label), ["cheap", "pricey", "unknown"])
        XCTAssertEqual(byTokens.byProject[0].totals.totalTokens, 3_000_000)
        XCTAssertEqual(byTokens.byModel.map(\.id), ["gpt-5", "o3"])
        XCTAssertEqual(byTokens.byModel[0].totals.costUSD, 0.375 + 2, accuracy: costAccuracy)
        XCTAssertTrue(byTokens.byModel[1].totals.unpriced)

        // 同一批数据按费用排，贵的那个项目排到前面。
        let byCost = OpenAICalc.buildReport(
            from: entries, order: .byCost, locale: posix, calendar: gregorian("UTC"), projectBucket: bucket)
        XCTAssertEqual(byCost.byProject.map(\.id), ["/work/pricey", "/work/cheap", "unknown"])
    }

    func testReportDaysFollowTheCalendarTimeZone() {
        let entries = [entry("2026-11-03T20:00:00Z", input: 1)]   // = 上海 11-04 凌晨 4 点

        let shanghai = AnthropicCalc.buildReport(
            from: entries, order: .byCost, locale: posix, calendar: gregorian("Asia/Shanghai"), projectBucket: pathBucket)
        XCTAssertEqual(shanghai.byDay.map(\.id), ["2026-11-04"])
        XCTAssertEqual(shanghai.byDay.first?.date, date("2026-11-04T00:00:00+08:00"))

        let utc = AnthropicCalc.buildReport(
            from: entries, order: .byCost, locale: posix, calendar: gregorian("UTC"), projectBucket: pathBucket)
        XCTAssertEqual(utc.byDay.map(\.id), ["2026-11-03"])
    }

    func testEmptyReport() {
        let report = AnthropicCalc.buildReport(
            from: [], order: .byCost, locale: posix, calendar: gregorian("UTC"), projectBucket: pathBucket)
        XCTAssertTrue(report.byDay.isEmpty)
        XCTAssertTrue(report.byProject.isEmpty)
        XCTAssertTrue(report.byModel.isEmpty)
    }
}
