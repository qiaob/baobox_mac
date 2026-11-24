import Foundation
import XCTest

/// 快速入口的排序（docs/launcher/TECH_DESIGN.md §5.2）。
final class LauncherRankingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(_ sourceID: String, _ entryID: String, _ titles: String...) -> LauncherCandidate {
        LauncherCandidate(sourceID: sourceID, entryID: entryID, searchKeys: titles.map { LauncherSearchKey($0) })
    }

    private func rank(_ candidates: [LauncherCandidate], _ query: String,
                      records: LauncherUsageRecords = LauncherUsageRecords(),
                      weights: LauncherSourceWeights = .standard,
                      limit: Int = LauncherRanking.defaultLimit,
                      sourceLimits: [String: Int] = [:]) -> LauncherRankingResult {
        LauncherRanking.rank(candidates, query: query, records: records, now: now, weights: weights, limit: limit,
                             sourceLimits: sourceLimits)
    }

    private func records(_ build: (inout LauncherUsageRecords) -> Void) -> LauncherUsageRecords {
        var records = LauncherUsageRecords()
        build(&records)
        return records
    }

    // MARK: - 候选

    func testCandidateKeyJoinsSourceAndEntry() {
        let item = candidate("apps", "/Applications/Safari.app", "Safari")
        XCTAssertEqual(item.key, "apps//Applications/Safari.app")
        XCTAssertEqual(LauncherUsageRecords.sourceID(ofKey: item.key), "apps")
    }

    // MARK: - 来源权重

    func testSourceWeightsOrderEqualMatches() {
        let candidates = [
            candidate("clipboard", "1", "Notes"),
            candidate("meetings", "1", "Notes"),
            candidate("snippets", "1", "Notes"),
            candidate("apps", "notes", "Notes"),
        ]
        let result = rank(candidates, "notes")
        XCTAssertEqual(result.keys, ["apps/notes", "snippets/1", "meetings/1", "clipboard/1"])
        XCTAssertEqual(result.items.map(\.score), [1000, 900, 800, 700])
        XCTAssertEqual(result.items.map(\.matchScore), [1000, 1000, 1000, 1000])
    }

    func testStandardWeights() {
        let weights = LauncherSourceWeights.standard
        XCTAssertEqual(weights.weight(for: "commands"), 1.0)
        XCTAssertEqual(weights.weight(for: "apps"), 1.0)
        XCTAssertEqual(weights.weight(for: "snippets"), 0.9)
        XCTAssertEqual(weights.weight(for: "clipboard"), 0.7)
        XCTAssertEqual(weights.weight(for: "sessions"), 0.8)
    }

    func testCallerCanOverrideWeights() {
        let candidates = [candidate("apps", "notes", "Notes"), candidate("clipboard", "1", "Notes")]
        var weights = LauncherSourceWeights.standard
        weights.bySource["clipboard"] = 2
        XCTAssertEqual(rank(candidates, "notes", weights: weights).keys, ["clipboard/1", "apps/notes"])
    }

    // MARK: - 使用分

    func testUsageBreaksEqualMatches() {
        let candidates = [candidate("apps", "a", "Notes A"), candidate("apps", "b", "Notes B")]
        XCTAssertEqual(rank(candidates, "notes").keys, ["apps/a", "apps/b"], "同分按键排")
        let used = records { $0.recordUse(of: "apps/b", at: now) }
        let result = rank(candidates, "notes", records: used)
        XCTAssertEqual(result.keys, ["apps/b", "apps/a"])
        XCTAssertEqual(result.items.first?.usageScore, 100)
    }

    func testHeavyUsageLiftsAWordStartAboveAFreshPrefix() {
        let candidates = [candidate("apps", "studio", "Studio Display"), candidate("apps", "vsc", "Visual Studio Code")]
        XCTAssertEqual(rank(candidates, "studio").keys.first, "apps/studio", "没用过：开头匹配在前")

        let once = records { $0.recordUse(of: "apps/vsc", at: now) }
        XCTAssertEqual(rank(candidates, "studio", records: once).keys.first, "apps/studio", "用过一次（100 分）还不够")

        let often = records { r in for _ in 0..<7 { r.recordUse(of: "apps/vsc", at: now) } }
        XCTAssertEqual(rank(candidates, "studio", records: often).keys.first, "apps/vsc", "常用（300 分）超过开头匹配")
    }

    func testOldUsageCountsLess() {
        let candidates = [candidate("apps", "a", "Notes A"), candidate("apps", "b", "Notes B")]
        let usage = records { r in
            r.recordUse(of: "apps/a", at: now.addingTimeInterval(-60 * 24 * 3600))
            r.recordUse(of: "apps/a", at: now.addingTimeInterval(-60 * 24 * 3600))
            r.recordUse(of: "apps/b", at: now.addingTimeInterval(-3600))
        }
        XCTAssertEqual(rank(candidates, "notes", records: usage).keys, ["apps/b", "apps/a"])
    }

    // MARK: - 这个输入上次选了谁

    func testRememberedChoiceGoesFirst() {
        let candidates = [candidate("apps", "notes", "Notes"), candidate("clipboard", "9", "my notes about x")]
        let remembered = records { $0.recordChoice("clipboard/9", forInput: "Notes", at: now) }
        let result = rank(candidates, "  NOTES ", records: remembered)
        XCTAssertEqual(result.keys, ["clipboard/9", "apps/notes"])
        XCTAssertEqual(result.items.map(\.isRemembered), [true, false])
        XCTAssertLessThan(result.items[0].score, result.items[1].score, "分数低也排第一")
    }

    func testRememberedChoiceOnlyForTheSameInput() {
        let candidates = [candidate("apps", "notes", "Notes"), candidate("clipboard", "9", "my notes about x")]
        let remembered = records { $0.recordChoice("clipboard/9", forInput: "notes", at: now) }
        XCTAssertEqual(rank(candidates, "note", records: remembered).keys.first, "apps/notes")
    }

    func testRememberedChoiceMustStillMatch() {
        let candidates = [candidate("apps", "notes", "Notes"), candidate("apps", "safari", "Safari")]
        let remembered = records { $0.recordChoice("apps/safari", forInput: "notes", at: now) }
        XCTAssertEqual(rank(candidates, "notes", records: remembered).keys, ["apps/notes"])
    }

    // MARK: - 别名

    func testAliasCountsAsExactMatch() {
        let candidates = [
            candidate("apps", "ocrtool", "OCR Tool"),
            candidate("commands", "screenshot.ocr", "屏幕取字"),
        ]
        let aliased = records { $0.setAlias("ocr", for: "commands/screenshot.ocr") }
        let result = rank(candidates, "OCR", records: aliased)
        XCTAssertEqual(result.keys, ["commands/screenshot.ocr", "apps/ocrtool"])
        XCTAssertEqual(result.items.first?.matchScore, LauncherMatch.exactScore)
        XCTAssertEqual(result.items.map(\.isAliasMatch), [true, false])
    }

    func testAliasOnAClipboardEntryBeatsAnExactlyNamedApp() {
        let candidates = [
            candidate("apps", "notes", "Notes"),
            candidate("clipboard", "7", "meeting notes 11-23"),
        ]
        let aliased = records { r in
            r.setAlias("notes", for: "clipboard/7")
            for _ in 0..<7 { r.recordUse(of: "apps/notes", at: now) }
        }
        let result = rank(candidates, "Notes", records: aliased)
        XCTAssertEqual(result.keys, ["clipboard/7", "apps/notes"])
        XCTAssertEqual(result.items[0].matchScore, LauncherMatch.exactScore, "匹配分仍记 1000")
        XCTAssertEqual(result.items[0].score, 700, "最终分照算（1000 × 0.7），只是不按它排")
        XCTAssertGreaterThan(result.items[1].score, result.items[0].score, "App 完全相等 + 常用，分数更高也排在后面")
    }

    func testAliasRanksBeforeTheRememberedChoice() {
        let candidates = [
            candidate("apps", "terminal", "Terminal"),
            candidate("commands", "translate", "翻译 Translate"),
            candidate("apps", "tableplus", "TablePlus"),
        ]
        let both = records { r in
            r.setAlias("t", for: "commands/translate")
            r.recordChoice("apps/terminal", forInput: "t", at: now)
        }
        let result = rank(candidates, "t", records: both)
        XCTAssertEqual(result.keys, ["commands/translate", "apps/terminal", "apps/tableplus"])
        XCTAssertEqual(result.items.map(\.isAliasMatch), [true, false, false])
        XCTAssertEqual(result.items.map(\.isRemembered), [false, true, false])
    }

    func testAliasAndRememberedChoiceOnTheSameEntryAppearOnce() {
        let candidates = [candidate("apps", "terminal", "Terminal"), candidate("apps", "tableplus", "TablePlus")]
        let both = records { r in
            r.setAlias("t", for: "apps/tableplus")
            r.recordChoice("apps/tableplus", forInput: "t", at: now)
        }
        let result = rank(candidates, "t", records: both)
        XCTAssertEqual(result.keys, ["apps/tableplus", "apps/terminal"])
        XCTAssertEqual(result.items.first?.isAliasMatch, true)
        XCTAssertEqual(result.items.first?.isRemembered, true)
    }

    func testHiddenEntryDoesNotAppearEvenOnAnAliasMatch() {
        let candidates = [candidate("apps", "notes", "Notes"), candidate("clipboard", "7", "meeting notes 11-23")]
        let hidden = records { r in
            r.setAlias("notes", for: "clipboard/7")
            r.hide("clipboard/7")
        }
        let result = rank(candidates, "notes", records: hidden)
        XCTAssertEqual(result.keys, ["apps/notes"])
        XCTAssertFalse(result.items.contains(where: \.isAliasMatch))
    }

    func testAliasMustBeExact() {
        let candidates = [candidate("commands", "screenshot.ocr", "屏幕取字")]
        let aliased = records { $0.setAlias("ocr", for: "commands/screenshot.ocr") }
        XCTAssertTrue(rank(candidates, "oc", records: aliased).items.isEmpty)
        XCTAssertTrue(rank(candidates, "ocrx", records: aliased).items.isEmpty)
    }

    // MARK: - 隐藏

    func testHiddenRowsAreFilteredOut() {
        let candidates = [candidate("apps", "notes", "Notes"), candidate("apps", "notion", "Notion")]
        let hidden = records { r in
            r.hide("apps/notes")
            r.setAlias("n", for: "apps/notes")
            r.recordChoice("apps/notes", forInput: "no", at: now)
        }
        XCTAssertEqual(rank(candidates, "no", records: hidden).keys, ["apps/notion"], "上次选过也不出现")
        XCTAssertEqual(rank(candidates, "n", records: hidden).keys, ["apps/notion"], "等于别名也不出现")
        XCTAssertEqual(rank(candidates, "", records: hidden).keys, ["apps/notion"])
    }

    // MARK: - 同分的次序

    func testTiesAreStableRegardlessOfInputOrder() {
        let candidates = [
            candidate("apps", "b", "Notes"),
            candidate("apps", "a", "Notes"),
            candidate("apps", "c", "Note"),
            candidate("apps", "d", "Notes 2"),
        ]
        // Note、Notes、Notes 2 都是开头匹配（扣分不同）；查询为空时分数全一样，只剩标题长度和键。
        let expected = ["apps/c", "apps/a", "apps/b", "apps/d"]
        XCTAssertEqual(rank(candidates, "").keys, expected)
        for seed in 0..<10 {
            var shuffled = candidates
            var generator = LauncherSeededGenerator(seed: UInt64(seed))
            shuffled.shuffle(using: &generator)
            XCTAssertEqual(rank(shuffled, "").keys, expected)
            XCTAssertEqual(rank(shuffled, "no").keys, expected)
        }
    }

    func testEqualScoresPreferHigherUsage() {
        // a：1000 × 0.6 = 600；b：1000 × 0.5 + 100（用过一次）= 600。最终分相同，使用分高的在前。
        let candidates = [candidate("a", "1", "Notes"), candidate("b", "1", "Notes")]
        let weights = LauncherSourceWeights(bySource: ["a": 0.6, "b": 0.5], other: 1)
        let used = records { $0.recordUse(of: "b/1", at: now) }
        let result = rank(candidates, "notes", records: used, weights: weights)
        XCTAssertEqual(result.items.map(\.score), [600, 600])
        XCTAssertEqual(result.keys, ["b/1", "a/1"])
    }

    // MARK: - 时间（剪贴板、片段）

    private func dated(_ sourceID: String, _ entryID: String, _ title: String, _ secondsAgo: TimeInterval) -> LauncherCandidate {
        LauncherCandidate(sourceID: sourceID, entryID: entryID, searchKeys: [LauncherSearchKey(title, pinyin: false)],
                          date: now.addingTimeInterval(-secondsAgo))
    }

    func testCandidateDateDefaultsToNil() {
        XCTAssertNil(candidate("apps", "a", "Alpha").date)
        XCTAssertNotNil(dated("clipboard", "1", "x", 0).date)
    }

    func testEqualScoresPutTheNewerEntryFirst() {
        // 同一段文字复制过三次：同分时新的在前，不看条目键和标题长度。
        let candidates = [
            dated("clipboard", "a", "docker ps", 300),
            dated("clipboard", "b", "docker ps", 10),
            dated("clipboard", "c", "docker ps", 3_600),
        ]
        XCTAssertEqual(rank(candidates, "docker").keys, ["clipboard/b", "clipboard/a", "clipboard/c"])
        for seed in 0..<10 {
            var shuffled = candidates
            var generator = LauncherSeededGenerator(seed: UInt64(seed))
            shuffled.shuffle(using: &generator)
            XCTAssertEqual(rank(shuffled, "docker").keys, ["clipboard/b", "clipboard/a", "clipboard/c"])
        }
    }

    func testDateComesBeforeTitleLength() {
        // 都是开头匹配且扣分一样（长度差都超过 100）：较长的那条更新，排前面。
        let long = String(repeating: "x", count: 150)
        let candidates = [
            dated("clipboard", "old", "curl " + long, 600),
            dated("clipboard", "new", "curl " + long + long, 5),
        ]
        let result = rank(candidates, "curl")
        XCTAssertEqual(result.items.map(\.score), [result.items[0].score, result.items[0].score])
        XCTAssertEqual(result.keys, ["clipboard/new", "clipboard/old"])
    }

    func testUndatedEntriesPrecedeDatedOnesAtEqualScore() {
        // App 1000 × 0.7（权重改成和剪贴板一样）与剪贴板同分：没有时间的排在有时间的前面。
        let candidates = [dated("clipboard", "1", "Notes", 1), candidate("apps", "notes", "Notes")]
        let weights = LauncherSourceWeights(bySource: ["clipboard": 0.7, "apps": 0.7], other: 1)
        XCTAssertEqual(rank(candidates, "notes", weights: weights).keys, ["apps/notes", "clipboard/1"])
    }

    func testUsageStillBeatsDate() {
        let candidates = [dated("snippets", "old", "signature", 86_400 * 30), dated("snippets", "new", "signature", 1)]
        let used = records { $0.recordUse(of: "snippets/old", at: now) }
        XCTAssertEqual(rank(candidates, "signature", records: used).keys, ["snippets/old", "snippets/new"])
    }

    // MARK: - 每个来源最多几行

    func testSourceLimitCapsOneSourceAndLetsOthersFill() {
        var candidates = (0..<8).map { dated("clipboard", "\($0)", "notes \($0)", TimeInterval($0)) }
        candidates.append(candidate("apps", "notes", "Notes"))
        candidates.append(candidate("snippets", "s", "notes snippet"))
        let result = rank(candidates, "notes", sourceLimits: ["clipboard": 5])
        XCTAssertEqual(result.items.filter { $0.sourceID == "clipboard" }.count, 5)
        XCTAssertEqual(result.keys.prefix(2), ["apps/notes", "snippets/s"])
        XCTAssertEqual(result.keys.dropFirst(2), ["clipboard/0", "clipboard/1", "clipboard/2", "clipboard/3", "clipboard/4"],
                       "留下的是最新的 5 条")
        XCTAssertEqual(rank(candidates, "notes").items.filter { $0.sourceID == "clipboard" }.count, 8, "不传就不限")
    }

    func testSourceLimitKeepsTheTotalLimit() {
        let candidates = (0..<10).map { dated("clipboard", "\($0)", "notes \($0)", TimeInterval($0)) }
            + (0..<10).map { candidate("apps", "\($0)", "Panotes \($0)") }   // 中间的子串，分数低于剪贴板
        let result = rank(candidates, "notes", limit: 8, sourceLimits: ["clipboard": 2])
        XCTAssertEqual(result.items.count, 8)
        XCTAssertEqual(result.items.filter { $0.sourceID == "clipboard" }.count, 2)
        XCTAssertEqual(rank(candidates, "notes", limit: 0, sourceLimits: ["clipboard": 2]).items.count, 0)
    }

    func testSourceLimitZeroHidesThatSourceButBestScoreStillCountsIt() {
        let candidates = [dated("clipboard", "1", "safari", 1), candidate("apps", "safari", "Safari browser")]
        let result = rank(candidates, "safari", sourceLimits: ["clipboard": 0])
        XCTAssertEqual(result.keys, ["apps/safari"])
        XCTAssertEqual(result.bestMatchScore, 1000)
    }

    func testAliasRowCountsTowardsItsSourceLimit() {
        let candidates = (0..<3).map { dated("clipboard", "\($0)", "token \($0)", TimeInterval($0)) }
        let aliased = records { $0.setAlias("tk", for: "clipboard/2") }
        let result = rank(candidates, "tk", records: aliased, sourceLimits: ["clipboard": 1])
        XCTAssertEqual(result.keys, ["clipboard/2"])
    }

    // MARK: - 前 N 行与最高匹配分

    func testLimit() {
        let candidates = (0..<60).map { candidate("apps", "\($0)", "Notes \($0)") }
        XCTAssertEqual(rank(candidates, "notes").items.count, 50)
        XCTAssertEqual(rank(candidates, "notes", limit: 3).items.count, 3)
        XCTAssertEqual(rank(candidates, "notes", limit: 0).items.count, 0)
    }

    func testBestMatchScoreCoversRowsBeyondTheLimit() {
        let candidates = [candidate("apps", "vsc", "Visual Studio Code"), candidate("clipboard", "1", "studio")]
        let often = records { r in for _ in 0..<7 { r.recordUse(of: "apps/vsc", at: now) } }
        let result = rank(candidates, "studio", records: often, limit: 1)
        XCTAssertEqual(result.keys, ["apps/vsc"])
        XCTAssertEqual(result.items.first?.matchScore, 600 - 12)
        XCTAssertEqual(result.bestMatchScore, 1000, "剪贴板那条完全相等，虽然没进前 1 行")
    }

    func testUnmatchedCandidatesAreExcluded() {
        let candidates = [candidate("apps", "safari", "Safari"), candidate("apps", "notes", "Notes")]
        let result = rank(candidates, "saf")
        XCTAssertEqual(result.keys, ["apps/safari"])
        XCTAssertEqual(result.bestMatchScore, 797)
        let none = rank(candidates, "zzz")
        XCTAssertTrue(none.items.isEmpty)
        XCTAssertNil(none.bestMatchScore)
    }

    func testEmptyQueryReturnsEverythingByUsage() {
        let candidates = [candidate("apps", "a", "Alpha"), candidate("apps", "b", "Beta"), candidate("apps", "c", "Gamma")]
        let used = records { r in
            r.recordUse(of: "apps/c", at: now)
            r.recordUse(of: "apps/c", at: now)
            r.recordUse(of: "apps/b", at: now)
        }
        let result = rank(candidates, "", records: used)
        XCTAssertEqual(result.keys, ["apps/c", "apps/b", "apps/a"])
        XCTAssertEqual(result.bestMatchScore, LauncherMatch.emptyQueryScore)
    }

    func testCandidateWithSeveralKeys() {
        let candidates = [candidate("commands", "caffeinate.start", "防休眠", "别睡", "保持唤醒")]
        XCTAssertEqual(rank(candidates, "别睡").items.first?.matchScore, 1000)
        XCTAssertEqual(rank(candidates, "bhxm").items.first?.matchScore, nil)
        XCTAssertEqual(rank(candidates, "bchx").items.first?.matchScore, 1000)
    }

    // MARK: - 「让 AI 来办」提到第一行

    func testAIRowThresholdOnScore() {
        let query = "translate this"
        XCTAssertTrue(LauncherRanking.shouldPromoteAIRow(query: query, bestMatchScore: nil))
        XCTAssertTrue(LauncherRanking.shouldPromoteAIRow(query: query, bestMatchScore: 399))
        XCTAssertFalse(LauncherRanking.shouldPromoteAIRow(query: query, bestMatchScore: 400))
        XCTAssertFalse(LauncherRanking.shouldPromoteAIRow(query: query, bestMatchScore: 800))
    }

    func testAIRowThresholdOnLength() {
        XCTAssertFalse(LauncherRanking.shouldPromoteAIRow(query: "abcdef", bestMatchScore: nil), "6 个字符")
        XCTAssertTrue(LauncherRanking.shouldPromoteAIRow(query: "abcdefg", bestMatchScore: nil), "7 个字符")
        XCTAssertFalse(LauncherRanking.shouldPromoteAIRow(query: "帮我翻译一下", bestMatchScore: nil))
        XCTAssertTrue(LauncherRanking.shouldPromoteAIRow(query: "帮我翻译剪贴板", bestMatchScore: nil))
        XCTAssertFalse(LauncherRanking.shouldPromoteAIRow(query: "  abcdef  ", bestMatchScore: nil), "去首尾空白后算")
        XCTAssertFalse(LauncherRanking.shouldPromoteAIRow(query: "", bestMatchScore: nil))
    }

    func testAIRowFromRankingResult() {
        let candidates = [
            candidate("apps", "safari", "Safari"),
            candidate("clipboard", "1", "please summarize the meeting notes from yesterday"),
        ]
        let query = "summarize notes"
        let result = rank(candidates, query)
        XCTAssertEqual(result.keys, ["clipboard/1"], "只有跳字匹配")
        XCTAssertLessThan(result.bestMatchScore ?? 0, 400)
        XCTAssertTrue(LauncherRanking.shouldPromoteAIRow(query: query, result: result))

        let exact = rank(candidates, "safari")
        XCTAssertFalse(LauncherRanking.shouldPromoteAIRow(query: "safari browser", result: exact))
    }

    func testAIRowNotPromotedWhenTheInputHasARememberedChoice() {
        let candidates = [candidate("clipboard", "1", "please summarize the meeting notes from yesterday")]
        let query = "summarize notes"
        let remembered = records { $0.recordChoice("clipboard/1", forInput: query, at: now) }
        let result = rank(candidates, query, records: remembered)
        XCTAssertEqual(result.items.first?.isRemembered, true)
        XCTAssertFalse(LauncherRanking.shouldPromoteAIRow(query: query, result: result))
    }

    func testAIRowNotPromotedOnAnAliasMatch() {
        let candidates = [candidate("commands", "translate.clipboard", "翻译剪贴板")]
        let query = "translate clip"
        let aliased = records { $0.setAlias(query, for: "commands/translate.clipboard") }
        let result = rank(candidates, query, records: aliased)
        XCTAssertEqual(result.items.first?.isAliasMatch, true)
        XCTAssertFalse(LauncherRanking.shouldPromoteAIRow(query: query, result: result))

        // 只看「有别名命中」这一条：就算最高匹配分（假设）低于 400 也不提。
        let item = LauncherRankedItem(key: "commands/x", sourceID: "commands", matchScore: 1000, usageScore: 0,
                                      score: 1000, isAliasMatch: true, isRemembered: false)
        let lowScore = LauncherRankingResult(items: [item], bestMatchScore: 100)
        XCTAssertFalse(LauncherRanking.shouldPromoteAIRow(query: query, result: lowScore))
    }
}

/// 可复现的随机数（SplitMix64），测试里打乱顺序、造数据用。
struct LauncherSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
