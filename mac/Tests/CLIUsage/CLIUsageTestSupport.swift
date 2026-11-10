import Foundation
import XCTest

// 测试用的定价表与小工具。真实的 Claude / Codex 定价表留在各自模块里（不编进测试），
// 这里按两种记账口径各备一张，单价抄真实价格，方便手算核对。

/// Anthropic 口径：input 不含缓存，缓存写 / 缓存读单列。单价同 Claude Sonnet / Opus 4.5。
enum AnthropicStyleTable: CLIUsagePricingTable {
    static let inputIncludesCacheRead = false

    static func pricing(for modelID: String) -> ModelPricing? {
        switch modelID {
        case "sonnet": return ModelPricing(inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.3)
        case "opus": return ModelPricing(inputPerM: 5, outputPerM: 25, cacheWritePerM: 6.25, cacheReadPerM: 0.5)
        default: return nil
        }
    }
}

/// OpenAI 口径：input 已含缓存读，没有缓存写。单价同 gpt-5。
enum OpenAIStyleTable: CLIUsagePricingTable {
    static let inputIncludesCacheRead = true

    static func pricing(for modelID: String) -> ModelPricing? {
        modelID == "gpt-5"
            ? ModelPricing(inputPerM: 1.25, outputPerM: 10, cacheWritePerM: 0, cacheReadPerM: 0.125)
            : nil
    }
}

typealias AnthropicCalc = CLIUsageCalculator<AnthropicStyleTable>
typealias OpenAICalc = CLIUsageCalculator<OpenAIStyleTable>

/// 费用比较的容差（美元）。
let costAccuracy = 1e-9

private let isoFormatter = ISO8601DateFormatter()

/// 解析写死在测试里的 ISO 8601 时间；写错了直接让测试失败。
func date(_ iso: String, file: StaticString = #filePath, line: UInt = #line) -> Date {
    guard let parsed = isoFormatter.date(from: iso) else {
        XCTFail("无法解析的时间字面量：\(iso)", file: file, line: line)
        return .distantPast
    }
    return parsed
}

/// 指定时区的公历日历（App 里用的是 `Calendar.current`，测试固定时区才稳定）。
func gregorian(_ timeZoneID: String, file: StaticString = #filePath, line: UInt = #line) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    if let timeZone = TimeZone(identifier: timeZoneID) {
        calendar.timeZone = timeZone
    } else {
        XCTFail("未知时区：\(timeZoneID)", file: file, line: line)
    }
    return calendar
}

/// 造一条用量。
func entry(
    _ iso: String,
    model: String = "sonnet",
    project: String = "/work/app",
    input: Int = 0,
    output: Int = 0,
    cacheWrite: Int = 0,
    cacheRead: Int = 0,
    file: StaticString = #filePath,
    line: UInt = #line
) -> CLIUsageEntry {
    CLIUsageEntry(
        timestamp: date(iso, file: file, line: line),
        modelID: model,
        projectPath: project,
        input: input,
        output: output,
        cacheWrite: cacheWrite,
        cacheRead: cacheRead
    )
}

/// 报表里项目一行的 id / 显示名：路径本身 + 最后一段（模块里各有取项目名的办法，这里取最简单的）。
func pathBucket(_ path: String) -> (id: String, label: String) {
    (id: path, label: (path as NSString).lastPathComponent)
}
