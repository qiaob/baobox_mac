import Foundation
import XCTest

/// 今日累计与按天 / 项目 / 模型的报表；明细表的合计行与维度（#164 PR5）。
final class CLIUsageReportTests: XCTestCase {

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

    // MARK: - 明细表的合计行（#164 PR5：两个中心窗口原来各写一份 `summed`）

    func testSumMatchesTheOldClaudeTotalBitForBit() {
        var rng = SumRNG(seed: 0xC1A0DE)
        for round in 0..<500 {
            let buckets = (0..<Int.random(in: 0...40, using: &rng)).map { index in
                randomBucket(AnthropicStyleTable.self, index, cacheWrite: true, using: &rng)
            }
            let new = CLIUsageTotals<AnthropicStyleTable>.sum(of: buckets)
            let old = oldClaudeSummed(buckets)
            XCTAssertEqual(new, old, "round \(round)")
            XCTAssertEqual(new.costUSD.bitPattern, old.costUSD.bitPattern, "round \(round)：费用逐位相同")
        }
    }

    func testSumMatchesTheOldCodexTotalBitForBit() {
        var rng = SumRNG(seed: 0xC0DE5)
        for round in 0..<500 {
            let buckets = (0..<Int.random(in: 0...40, using: &rng)).map { index in
                randomBucket(OpenAIStyleTable.self, index, cacheWrite: false, using: &rng)
            }
            let new = CLIUsageTotals<OpenAIStyleTable>.sum(of: buckets)
            let old = oldCodexSummed(buckets)
            XCTAssertEqual(new, old, "round \(round)：Codex 的桶里缓存写恒为 0，多加这一项结果不变")
            XCTAssertEqual(new.cacheWrite, 0)
            XCTAssertEqual(new.costUSD.bitPattern, old.costUSD.bitPattern, "round \(round)：费用逐位相同")
        }
    }

    func testSumAddsCostsInBucketOrder() {
        let buckets = [0.1, 0.2, 0.3].enumerated().map { index, cost in
            CLIUsageBucket<AnthropicStyleTable>(id: "\(index)", label: "\(index)",
                                                totals: CLIUsageTotals(costUSD: cost))
        }
        let total = CLIUsageTotals<AnthropicStyleTable>.sum(of: buckets).costUSD
        XCTAssertEqual(total.bitPattern, ((0.1 + 0.2) + 0.3).bitPattern, "从第一个桶加到最后一个")
        XCTAssertNotEqual(total.bitPattern, (0.1 + (0.2 + 0.3)).bitPattern, "换个结合顺序末位就不同 —— 这条确认上面那条钉得住")
    }

    func testSumOfNoBucketsIsZeroAndUnpricedIsSticky() {
        XCTAssertEqual(CLIUsageTotals<AnthropicStyleTable>.sum(of: []), .zero)
        XCTAssertFalse(CLIUsageTotals<AnthropicStyleTable>.sum(of: []).unpriced)

        let priced = CLIUsageBucket<OpenAIStyleTable>(id: "a", label: "a", totals: CLIUsageTotals(input: 1, unpriced: false))
        let unpriced = CLIUsageBucket<OpenAIStyleTable>(id: "b", label: "b", totals: CLIUsageTotals(input: 2, unpriced: true))
        XCTAssertTrue(CLIUsageTotals.sum(of: [priced, unpriced, priced]).unpriced, "任一桶 unpriced，合计就 unpriced")
        XCTAssertFalse(CLIUsageTotals.sum(of: [priced, priced]).unpriced)
        XCTAssertEqual(CLIUsageTotals.sum(of: [priced, unpriced, priced]).input, 4)
    }

    // MARK: - 明细表的维度

    func testDimensionPicksTheMatchingTable() {
        func bucket(_ id: String) -> CLIUsageBucket<AnthropicStyleTable> {
            CLIUsageBucket(id: id, label: id, totals: .zero)
        }
        let report = CLIUsageReport<AnthropicStyleTable>(byDay: [bucket("d1"), bucket("d2")],
                                                         byProject: [bucket("p1")],
                                                         byModel: [bucket("m1"), bucket("m2"), bucket("m3")])
        XCTAssertEqual(CLIUsageDimension.allCases, [.day, .project, .model], "分段控件的顺序")
        XCTAssertEqual(CLIUsageDimension.day.buckets(of: report).map(\.id), ["d1", "d2"])
        XCTAssertEqual(CLIUsageDimension.project.buckets(of: report).map(\.id), ["p1"])
        XCTAssertEqual(CLIUsageDimension.model.buckets(of: report).map(\.id), ["m1", "m2", "m3"])
        XCTAssertTrue(CLIUsageDimension.model.buckets(of: CLIUsageReport<AnthropicStyleTable>()).isEmpty)
    }

    // MARK: 合计行的旧实现（PR5 之前两个中心窗口里的 `summed`，逐行照抄，只换了类型名；用来钉住新旧逐位相同）

    private func oldClaudeSummed(_ buckets: [CLIUsageBucket<AnthropicStyleTable>]) -> CLIUsageTotals<AnthropicStyleTable> {
        var total = CLIUsageTotals<AnthropicStyleTable>()
        for bucket in buckets {
            total.input += bucket.totals.input
            total.output += bucket.totals.output
            total.cacheWrite += bucket.totals.cacheWrite
            total.cacheRead += bucket.totals.cacheRead
            total.costUSD += bucket.totals.costUSD
            total.unpriced = total.unpriced || bucket.totals.unpriced
        }
        return total
    }

    /// Codex 版：缓存输入（`cachedInput`）就是 `cacheRead`；缓存写不加。
    private func oldCodexSummed(_ buckets: [CLIUsageBucket<OpenAIStyleTable>]) -> CLIUsageTotals<OpenAIStyleTable> {
        var total = CLIUsageTotals<OpenAIStyleTable>()
        for bucket in buckets {
            total.input += bucket.totals.input
            total.cacheRead += bucket.totals.cacheRead
            total.output += bucket.totals.output
            total.costUSD += bucket.totals.costUSD
            total.unpriced = total.unpriced || bucket.totals.unpriced
        }
        return total
    }

    /// 一个随机的桶：token 数从 0 到十亿，费用是若干条真实单价算出来的和（末位各不相同），偶尔 unpriced。
    private func randomBucket<Table: CLIUsagePricingTable>(
        _ table: Table.Type, _ index: Int, cacheWrite: Bool, using rng: inout SumRNG
    ) -> CLIUsageBucket<Table> {
        var totals = CLIUsageTotals<Table>()
        for _ in 0..<Int.random(in: 1...6, using: &rng) {
            let model = Int.random(in: 0..<10, using: &rng) == 0 ? "unknown" : (Table.inputIncludesCacheRead ? "gpt-5" : "sonnet")
            totals.add(CLIUsageEntry(timestamp: Date(timeIntervalSince1970: 0), modelID: model, projectPath: "/p",
                                     input: Int.random(in: 0...200_000_000, using: &rng),
                                     output: Int.random(in: 0...50_000_000, using: &rng),
                                     cacheWrite: cacheWrite ? Int.random(in: 0...80_000_000, using: &rng) : 0,
                                     cacheRead: Int.random(in: 0...150_000_000, using: &rng)))
        }
        return CLIUsageBucket(id: "\(index)", label: "\(index)", totals: totals)
    }
}

/// 固定种子的随机数（SplitMix64），合计行的差分可复现。
private struct SumRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
