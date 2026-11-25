import Foundation
import XCTest

/// 快速入口的使用记录模型（docs/launcher/TECH_DESIGN.md §5.3）。
final class LauncherUsageStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func decode(_ json: String) throws -> LauncherUsageRecords {
        try JSONDecoder().decode(LauncherUsageRecords.self, from: Data(json.utf8))
    }

    // MARK: - 使用分

    func testUsageScoreHalvesEveryFourteenDays() {
        let score = { (age: TimeInterval) in
            LauncherUsageRecords.usageScore(count: 1, last: self.now.addingTimeInterval(-age), now: self.now)
        }
        XCTAssertEqual(score(0), 100, accuracy: 1e-9)
        XCTAssertEqual(score(14 * day), 50, accuracy: 1e-9)
        XCTAssertEqual(score(28 * day), 25, accuracy: 1e-9)
        XCTAssertEqual(score(7 * day), 100 / 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testUsageScoreGrowsWithCountAndIsCapped() {
        let score = { (count: Int) in LauncherUsageRecords.usageScore(count: count, last: self.now, now: self.now) }
        XCTAssertEqual(score(0), 0)
        XCTAssertEqual(score(1), 100, accuracy: 1e-9)
        XCTAssertEqual(score(3), 200, accuracy: 1e-9)
        XCTAssertEqual(score(7), 300, accuracy: 1e-9)
        XCTAssertEqual(score(1000), 300, "上限 300")
        XCTAssertGreaterThan(score(2), score(1))
    }

    func testCapIsAppliedBeforeDecay() {
        let old = now.addingTimeInterval(-14 * day)
        XCTAssertEqual(LauncherUsageRecords.usageScore(count: 1000, last: old, now: now), 150, accuracy: 1e-9,
                       "用得再多，14 天没用也是一半")
    }

    func testFutureLastUseCountsAsJustUsed() {
        let future = now.addingTimeInterval(3 * day)
        XCTAssertEqual(LauncherUsageRecords.usageScore(count: 1, last: future, now: now), 100, accuracy: 1e-9)
    }

    // MARK: - 记一次使用

    func testRecordUseCountsAndUpdatesLast() {
        var records = LauncherUsageRecords()
        records.recordUse(of: "apps/safari", at: now)
        records.recordUse(of: "apps/safari", at: now.addingTimeInterval(60))
        XCTAssertEqual(records.usage["apps/safari"],
                       LauncherUsageRecords.Usage(count: 2, last: now.addingTimeInterval(60)))
        XCTAssertEqual(records.usageScore(for: "apps/safari", now: now.addingTimeInterval(60)), 100 * log2(3),
                       accuracy: 1e-9)
        XCTAssertEqual(records.usageScore(for: "apps/never", now: now), 0)
    }

    func testClipboardAndEmptyKeysAreNotCounted() {
        var records = LauncherUsageRecords()
        records.recordUse(of: "clipboard/42", at: now)
        records.recordUse(of: "", at: now)
        XCTAssertTrue(records.usage.isEmpty)
        records.recordUse(of: "snippets/1", at: now)
        XCTAssertEqual(records.usage.count, 1)
    }

    func testSourceIDOfKey() {
        XCTAssertEqual(LauncherUsageRecords.sourceID(ofKey: "apps//Applications/Safari.app"), "apps")
        XCTAssertEqual(LauncherUsageRecords.sourceID(ofKey: "clipboard/42"), "clipboard")
        XCTAssertEqual(LauncherUsageRecords.sourceID(ofKey: "nokey"), "nokey")
    }

    // MARK: - 输入 → 选了谁

    func testInputNormalization() {
        XCTAssertEqual(LauncherUsageRecords.normalizedInput("  SAFari \n"), "safari")
        XCTAssertEqual(LauncherUsageRecords.normalizedInput("微信 WeChat"), "微信 wechat")
        let long = "abcdefghijklmnopqrstuvwxyz"
        XCTAssertEqual(LauncherUsageRecords.normalizedInput(long), "abcdefghijklmnopqrst")
        XCTAssertEqual(LauncherUsageRecords.normalizedInput(long).count, LauncherUsageRecords.inputPrefixLength)
    }

    func testRecordChoice() {
        var records = LauncherUsageRecords()
        records.recordChoice("apps/safari", forInput: "Saf", at: now)
        XCTAssertEqual(records.rememberedKey(forInput: " saf "), "apps/safari")
        XCTAssertEqual(records.rememberedKey(forInput: "SAF"), "apps/safari")
        XCTAssertNil(records.rememberedKey(forInput: "sa"), "只认同一个输入")

        records.recordChoice("apps/safari-tp", forInput: "saf", at: now)
        XCTAssertEqual(records.rememberedKey(forInput: "saf"), "apps/safari-tp", "后选的覆盖")
    }

    func testRecordChoiceOnlyKeepsTheFirstTwentyCharacters() {
        var records = LauncherUsageRecords()
        records.recordChoice("commands/x", forInput: "abcdefghijklmnopqrstuvwxyz", at: now)
        XCTAssertEqual(records.rememberedKey(forInput: "abcdefghijklmnopqrst-something-else"), "commands/x")
        XCTAssertEqual(Array(records.choices.keys), ["abcdefghijklmnopqrst"])
    }

    func testRecordChoiceIgnoresBlankInputAndKey() {
        var records = LauncherUsageRecords()
        records.recordChoice("apps/safari", forInput: "   ", at: now)
        records.recordChoice("", forInput: "saf", at: now)
        XCTAssertTrue(records.choices.isEmpty)
        XCTAssertNil(records.rememberedKey(forInput: ""))
    }

    func testClipboardChoicesAreRemembered() {
        var records = LauncherUsageRecords()
        records.recordChoice("clipboard/42", forInput: "token", at: now)
        XCTAssertEqual(records.rememberedKey(forInput: "token"), "clipboard/42", "剪贴板不记次数，但记「选了谁」")
    }

    // MARK: - 别名

    func testSetAndRemoveAlias() {
        var records = LauncherUsageRecords()
        records.setAlias("  OCR ", for: "commands/screenshot.ocr")
        XCTAssertEqual(records.aliases["commands/screenshot.ocr"], "OCR", "去首尾空白，保留大小写")
        XCTAssertEqual(records.key(forAlias: "ocr"), "commands/screenshot.ocr")
        XCTAssertEqual(records.key(forAlias: " Ocr "), "commands/screenshot.ocr")
        XCTAssertNil(records.key(forAlias: "oc"))
        XCTAssertNil(records.key(forAlias: ""))

        records.setAlias("   ", for: "commands/screenshot.ocr")
        XCTAssertTrue(records.aliases.isEmpty, "空白 = 删掉")
        records.setAlias("ocr", for: "commands/screenshot.ocr")
        records.setAlias(nil, for: "commands/screenshot.ocr")
        XCTAssertTrue(records.aliases.isEmpty)
    }

    func testAliasIsUnique() {
        var records = LauncherUsageRecords()
        records.setAlias("t", for: "apps/terminal")
        records.setAlias("T", for: "commands/translate")
        XCTAssertEqual(records.aliases, ["commands/translate": "T"], "同一个别名从旧条目上拿掉")
        XCTAssertEqual(records.key(forAlias: "t"), "commands/translate")
    }

    func testOneAliasPerEntry() {
        var records = LauncherUsageRecords()
        records.setAlias("a", for: "apps/x")
        records.setAlias("b", for: "apps/x")
        XCTAssertEqual(records.aliases, ["apps/x": "b"])
        XCTAssertNil(records.key(forAlias: "a"))
    }

    // MARK: - 隐藏

    func testHideAndUnhide() {
        var records = LauncherUsageRecords()
        records.hide("apps/chess")
        records.hide("")
        XCTAssertTrue(records.isHidden("apps/chess"))
        XCTAssertEqual(records.hidden, ["apps/chess"])
        records.unhide("apps/chess")
        XCTAssertFalse(records.isHidden("apps/chess"))
    }

    // MARK: - 清空与裁剪

    func testClearUsageKeepsAliasesAndHiddenRows() {
        var records = LauncherUsageRecords()
        records.recordUse(of: "apps/safari", at: now)
        records.recordChoice("apps/safari", forInput: "saf", at: now)
        records.setAlias("s", for: "apps/safari")
        records.hide("apps/chess")
        records.clearUsage()
        XCTAssertTrue(records.usage.isEmpty)
        XCTAssertTrue(records.choices.isEmpty)
        XCTAssertEqual(records.aliases, ["apps/safari": "s"])
        XCTAssertEqual(records.hidden, ["apps/chess"])
    }

    func testUsageIsPrunedToTheMostRecentEntries() {
        var records = LauncherUsageRecords()
        let limit = LauncherUsageRecords.maxEntries
        for index in 0..<limit {
            records.recordUse(of: "apps/\(index)", at: now.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertEqual(records.usage.count, limit)

        records.recordUse(of: "apps/new", at: now.addingTimeInterval(TimeInterval(limit)))
        XCTAssertEqual(records.usage.count, limit)
        XCTAssertNil(records.usage["apps/0"], "最久没用的被删")
        XCTAssertNotNil(records.usage["apps/1"])
        XCTAssertNotNil(records.usage["apps/new"])
    }

    func testPruneKeepsTheJustRecordedEntryEvenWithAnOldClock() {
        var records = LauncherUsageRecords()
        let limit = LauncherUsageRecords.maxEntries
        for index in 0..<limit {
            records.recordUse(of: "apps/\(index)", at: now)
        }
        records.recordUse(of: "apps/old-clock", at: now.addingTimeInterval(-365 * day))
        XCTAssertEqual(records.usage.count, limit)
        XCTAssertNotNil(records.usage["apps/old-clock"])
        XCTAssertNil(records.usage["apps/999"], "时间相同按键排，键最大的被删")
    }

    func testChoicesArePrunedToo() {
        var records = LauncherUsageRecords()
        let limit = LauncherUsageRecords.maxEntries
        for index in 0...limit {
            records.recordChoice("apps/x", forInput: "input \(index)", at: now.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertEqual(records.choices.count, limit)
        XCTAssertNil(records.rememberedKey(forInput: "input 0"))
        XCTAssertEqual(records.rememberedKey(forInput: "input \(limit)"), "apps/x")
    }

    func testExplicitPrune() {
        var records = LauncherUsageRecords()
        for index in 0..<5 {
            records.recordUse(of: "apps/\(index)", at: now.addingTimeInterval(TimeInterval(index)))
            records.recordChoice("apps/\(index)", forInput: "q\(index)", at: now.addingTimeInterval(TimeInterval(index)))
        }
        records.prune(limit: 2)
        XCTAssertEqual(Set(records.usage.keys), ["apps/3", "apps/4"])
        XCTAssertEqual(Set(records.choices.keys), ["q3", "q4"])
    }

    // MARK: - 编解码

    func testCodableRoundTrip() throws {
        var records = LauncherUsageRecords()
        records.recordUse(of: "apps/safari", at: now)
        records.recordUse(of: "apps/safari", at: now)
        records.recordUse(of: "commands/caffeinate.start", at: now.addingTimeInterval(-day))
        records.recordChoice("apps/safari", forInput: "saf", at: now)
        records.setAlias("ocr", for: "commands/screenshot.ocr")
        records.hide("apps/chess")
        records.hide("clipboard/1")

        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode(LauncherUsageRecords.self, from: data)
        XCTAssertEqual(decoded, records)
        XCTAssertEqual(decoded.version, LauncherUsageRecords.currentVersion)
    }

    func testEncodedFormat() throws {
        var records = LauncherUsageRecords()
        records.recordUse(of: "apps/safari", at: now)
        records.hide("b")
        records.hide("a")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(records), as: UTF8.self)
        XCTAssertEqual(json, #"{"aliases":{},"choices":{},"hidden":["a","b"],"usage":{"apps\/safari":{"count":1,"last":1800000000}},"version":1}"#)
    }

    func testDecodesWithMissingFields() throws {
        XCTAssertEqual(try decode("{}"), LauncherUsageRecords())
        let onlyHidden = try decode(#"{"hidden":["apps/chess"]}"#)
        XCTAssertEqual(onlyHidden.hidden, ["apps/chess"])
        XCTAssertTrue(onlyHidden.usage.isEmpty)
        XCTAssertEqual(onlyHidden.version, LauncherUsageRecords.currentVersion)
    }

    func testBadEntriesAreSkippedAndGoodOnesKept() throws {
        let json = """
        {
          "version": "one",
          "usage": {
            "apps/good": {"count": 3, "last": 1800000000},
            "apps/float": {"count": 2.0, "last": 1800000000.5},
            "apps/zero": {"count": 0, "last": 1800000000},
            "apps/negative": {"count": -4, "last": 1800000000},
            "apps/nocount": {"last": 1800000000},
            "apps/nolast": {"count": 1},
            "apps/textdate": {"count": 1, "last": "yesterday"},
            "apps/array": [1, 2],
            "": {"count": 1, "last": 1800000000}
          },
          "choices": {
            "saf": {"key": "apps/good", "last": 1800000000},
            "bad": {"key": 5, "last": 1800000000},
            "empty": {"key": "", "last": 1800000000},
            "nolast": {"key": "apps/good"}
          },
          "aliases": {"apps/good": " g ", "apps/blank": "  ", "apps/number": 7},
          "hidden": ["apps/chess", 3, "", null]
        }
        """
        let records = try decode(json)
        XCTAssertEqual(records.version, LauncherUsageRecords.currentVersion, "版本号类型不对就按当前")
        XCTAssertEqual(Set(records.usage.keys), ["apps/good", "apps/float"])
        XCTAssertEqual(records.usage["apps/good"]?.count, 3)
        XCTAssertEqual(records.usage["apps/float"]?.count, 2)
        XCTAssertEqual(Array(records.choices.keys), ["saf"])
        XCTAssertEqual(records.aliases, ["apps/good": "g"])
        XCTAssertEqual(records.hidden, ["apps/chess"])
    }

    func testWrongTypesForWholeSectionsAreSkipped() throws {
        let records = try decode(#"{"usage": [1, 2], "choices": "x", "aliases": [], "hidden": {"a": 1}}"#)
        XCTAssertEqual(records, LauncherUsageRecords())
    }

    func testTopLevelThatIsNotAnObjectGivesEmptyRecords() throws {
        XCTAssertEqual(try decode("[1, 2, 3]"), LauncherUsageRecords())
        XCTAssertEqual(try decode("42"), LauncherUsageRecords())
        XCTAssertEqual(try decode("null"), LauncherUsageRecords())
    }

    func testNewerVersionIsStillRead() throws {
        let records = try decode(#"{"version": 9, "usage": {"apps/a": {"count": 1, "last": 1800000000}}, "extra": true}"#)
        XCTAssertEqual(records.version, 9)
        XCTAssertEqual(records.usage["apps/a"]?.count, 1)
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records)) as? [String: Any]
        XCTAssertEqual(reencoded?["version"] as? Int, LauncherUsageRecords.currentVersion, "写出去总是当前版本")
    }

    func testHugeCountIsClamped() throws {
        let records = try decode(#"{"usage": {"apps/a": {"count": 99999999999, "last": 1800000000}}}"#)
        XCTAssertEqual(records.usage["apps/a"]?.count, LauncherUsageRecords.maxCount)
    }
}
