import Foundation
import XCTest

/// 定价与累加：两种记账口径、缓存写 / 缓存读、未知模型。
final class AIUsagePricingTests: XCTestCase {

    func testAnthropicStyleBillsCacheWriteAndCacheReadSeparately() {
        var totals = AIUsageTotals<AnthropicStyleTable>()
        totals.add(entry("2026-11-02T10:00:00Z", model: "sonnet",
                         input: 1_000_000, output: 100_000, cacheWrite: 200_000, cacheRead: 3_000_000))

        // 1M×$3 + 0.1M×$15 + 0.2M×$3.75 + 3M×$0.3
        XCTAssertEqual(totals.costUSD, 3 + 1.5 + 0.75 + 0.9, accuracy: costAccuracy)
        XCTAssertEqual(totals.input, 1_000_000)
        XCTAssertEqual(totals.output, 100_000)
        XCTAssertEqual(totals.cacheWrite, 200_000)
        XCTAssertEqual(totals.cacheRead, 3_000_000)
        XCTAssertEqual(totals.totalTokens, 4_300_000, "Anthropic 口径四项相加")
        XCTAssertFalse(totals.unpriced)
    }

    func testOpenAIStyleBillsTheCachedPartOfInputAtTheCacheReadPrice() {
        var totals = AIUsageTotals<OpenAIStyleTable>()
        // input 1M 里有 0.4M 命中缓存。
        totals.add(entry("2026-11-02T10:00:00Z", model: "gpt-5", input: 1_000_000, output: 100_000, cacheRead: 400_000))

        // 0.6M×$1.25 + 0.4M×$0.125 + 0.1M×$10
        XCTAssertEqual(totals.costUSD, 0.75 + 0.05 + 1.0, accuracy: costAccuracy)
        XCTAssertEqual(totals.input, 1_000_000)
        XCTAssertEqual(totals.cacheRead, 400_000)
        XCTAssertEqual(totals.totalTokens, 1_100_000, "input 已含缓存读，不再重复加")
        XCTAssertFalse(totals.unpriced)
    }

    func testCachedInputLargerThanInputIsNotBilledNegative() {
        var totals = AIUsageTotals<OpenAIStyleTable>()
        totals.add(entry("2026-11-02T10:00:00Z", model: "gpt-5", input: 100_000, cacheRead: 300_000))

        // 可计费输入扣到 0 为止，只剩缓存读：0.3M×$0.125
        XCTAssertEqual(totals.costUSD, 0.0375, accuracy: costAccuracy)
    }

    func testUnknownModelCostsNothingButIsFlaggedAndStillCountsTokens() {
        var totals = AIUsageTotals<AnthropicStyleTable>()
        totals.add(entry("2026-11-02T10:00:00Z", model: "mystery-model", input: 1_000, output: 2_000))

        XCTAssertEqual(totals.costUSD, 0)
        XCTAssertTrue(totals.unpriced)
        XCTAssertEqual(totals.totalTokens, 3_000)

        // 之后再加认识的模型：费用照算，unpriced 一旦标上就不会被清掉。
        totals.add(entry("2026-11-02T10:05:00Z", model: "sonnet", input: 1_000_000))
        XCTAssertEqual(totals.costUSD, 3, accuracy: costAccuracy)
        XCTAssertTrue(totals.unpriced)
    }

    func testEmptyModelIDIsUnpriced() {
        var totals = AIUsageTotals<OpenAIStyleTable>()
        totals.add(entry("2026-11-02T10:00:00Z", model: "", input: 500))
        XCTAssertTrue(totals.unpriced)
        XCTAssertEqual(totals.costUSD, 0)
    }

    func testCostAccumulatesAcrossEntriesAndModels() {
        var totals = AIUsageTotals<AnthropicStyleTable>()
        totals.add(entry("2026-11-02T10:00:00Z", model: "sonnet", input: 1_000_000))   // $3
        totals.add(entry("2026-11-02T10:01:00Z", model: "opus", output: 1_000_000))    // $25
        totals.add(entry("2026-11-02T10:02:00Z", model: "opus", cacheRead: 2_000_000)) // $1
        XCTAssertEqual(totals.costUSD, 29, accuracy: costAccuracy)
        XCTAssertEqual(totals.totalTokens, 4_000_000)
    }

    func testPricingCostFormulaDirectly() {
        let sonnet = ModelPricing(inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.3)
        let usage = entry("2026-11-02T10:00:00Z", input: 2_000_000, output: 0, cacheWrite: 1_000_000, cacheRead: 1_000_000)
        XCTAssertEqual(sonnet.cost(of: usage, inputIncludesCacheRead: false), 6 + 3.75 + 0.3, accuracy: costAccuracy)
        // 同一组数换成「input 含缓存读」口径：可计费输入 = 2M − 1M。
        XCTAssertEqual(sonnet.cost(of: usage, inputIncludesCacheRead: true), 3 + 0.3 + 3.75, accuracy: costAccuracy)
        XCTAssertEqual(ModelPricing.zero.cost(of: usage, inputIncludesCacheRead: false), 0)
    }

    func testTokenCountToleratesJSONNumberShapes() {
        XCTAssertEqual(AIUsageEntry.tokenCount(42), 42)
        XCTAssertEqual(AIUsageEntry.tokenCount(42.9), 42)
        XCTAssertEqual(AIUsageEntry.tokenCount(NSNumber(value: 7)), 7)
        XCTAssertEqual(AIUsageEntry.tokenCount("13"), 13)
        XCTAssertEqual(AIUsageEntry.tokenCount("13k"), 0)
        XCTAssertEqual(AIUsageEntry.tokenCount(nil), 0)
        XCTAssertEqual(AIUsageEntry.tokenCount(["input_tokens": 5]), 0)
    }
}
