import Foundation
import XCTest

/// 快速入口的匹配打分（docs/launcher/TECH_DESIGN.md §5.1）。
final class LauncherMatchTests: XCTestCase {

    private func score(_ query: String, _ text: String, pinyin: Bool = true) -> Int? {
        LauncherMatch.score(LauncherMatchQuery(query), in: LauncherSearchKey(text, pinyin: pinyin))
    }

    /// 分数落在哪一档（档的基础分）。
    private func tier(_ score: Int?) -> Int? {
        guard let score else { return nil }
        switch score {
        case LauncherMatch.exactScore: return LauncherMatch.exactScore
        case 700..<LauncherMatch.exactScore: return LauncherMatch.prefixScore
        case 500...LauncherMatch.wordStartScore: return LauncherMatch.wordStartScore
        case 300...LauncherMatch.substringScore: return LauncherMatch.substringScore
        case 1...LauncherMatch.fuzzyScore: return LauncherMatch.fuzzyScore
        default: return -1
        }
    }

    // MARK: - 每一档

    func testExactMatchIgnoresCase() {
        XCTAssertEqual(score("safari", "Safari"), 1000)
        XCTAssertEqual(score("SAFARI", "safari"), 1000)
        XCTAssertEqual(score("  Safari ", "Safari"), 1000, "查询去首尾空白")
    }

    func testPrefixMatch() {
        XCTAssertEqual(score("saf", "Safari"), 800 - 3)
        XCTAssertEqual(score("SAF", "Safari"), 800 - 3)
        XCTAssertEqual(score("visual st", "Visual Studio Code"), 800 - 9)
    }

    func testWordStartMatchAfterSeparators() {
        XCTAssertEqual(score("code", "Visual Studio Code"), 600 - 14)
        for text in ["foo bar", "foo-bar", "foo_bar", "foo/bar", "foo.bar"] {
            XCTAssertEqual(score("bar", text), 600 - 4, text)
        }
    }

    func testWordStartAtCaseBoundaries() {
        XCTAssertEqual(tier(score("code", "VSCode")), 600, "大写 C 是词首")
        XCTAssertEqual(tier(score("sc", "VSCode")), 600, "连续大写里的 S 也算词首")
        XCTAssertEqual(tier(score("phone", "iPhone")), 600)
        XCTAssertEqual(tier(score("365", "Office365")), 600, "字母后面接数字")
    }

    func testVSCodeAbbreviation() {
        XCTAssertEqual(score("vsc", "VSCode"), 800 - 3, "小写原文 vscode 的开头")
        XCTAssertEqual(score("vsc", "Visual Studio Code"), 200 - 12 * 4 - 15, "跳字：v…s…c，窗口里跳过 12 个字")
    }

    func testSubstringMatch() {
        XCTAssertEqual(score("ari", "Safari"), 400 - 3)
        XCTAssertEqual(tier(score("co", "Xcode")), 400, "小写 c 跟在 X 后面不是词首")
    }

    func testFuzzyMatch() {
        XCTAssertEqual(score("sfr", "Safari"), 200 - 2 * 4 - 3)
        XCTAssertEqual(tier(score("vsc", "Visual Studio Code")), 200)
    }

    // MARK: - 档与档、档内

    func testTiersAreOrdered() throws {
        let text = "Visual Studio Code"
        let prefix = try XCTUnwrap(score("vis", text))
        let wordStart = try XCTUnwrap(score("stu", text))
        let substring = try XCTUnwrap(score("tud", text))
        let fuzzy = try XCTUnwrap(score("vsc", text))
        XCTAssertGreaterThan(prefix, wordStart)
        XCTAssertGreaterThan(wordStart, substring)
        XCTAssertGreaterThan(substring, fuzzy)
        XCTAssertGreaterThan(fuzzy, 0)
    }

    func testLengthPenaltyPrefersShorterWithinTier() throws {
        let short = try XCTUnwrap(score("saf", "Safari"))
        let long = try XCTUnwrap(score("saf", "Safari Technology Preview"))
        XCTAssertGreaterThan(short, long)
        XCTAssertEqual(tier(short), tier(long))
    }

    func testLengthPenaltyNeverDropsToTheNextTier() throws {
        let longText = "ab" + String(repeating: "x", count: 500)
        let worstPrefix = try XCTUnwrap(score("ab", longText))
        XCTAssertEqual(worstPrefix, 800 - LauncherMatch.lengthPenaltyCap)
        XCTAssertGreaterThan(worstPrefix, LauncherMatch.wordStartScore)

        let worstWordStart = try XCTUnwrap(score("ab", "x ab" + String(repeating: "x", count: 500)))
        XCTAssertGreaterThan(worstWordStart, LauncherMatch.substringScore)

        let worstSubstring = try XCTUnwrap(score("ab", "xab" + String(repeating: "x", count: 500)))
        XCTAssertGreaterThan(worstSubstring, LauncherMatch.fuzzyScore)

        let worstFuzzy = try XCTUnwrap(score("az", "a" + String(repeating: "x", count: 500) + "z"))
        XCTAssertEqual(worstFuzzy, 200 - LauncherMatch.fuzzyGapPenaltyCap - LauncherMatch.fuzzyLengthPenaltyCap)
        XCTAssertGreaterThan(worstFuzzy, 0)
    }

    func testFuzzyGapLowersScore() throws {
        let tight = try XCTUnwrap(score("abc", "axbxc"))
        let loose = try XCTUnwrap(score("abc", "axxxxbxxxxc"))
        XCTAssertGreaterThan(tight, loose)
    }

    func testFuzzyUsesTheTightestWindowEndingAtTheFirstCompletion() {
        // 先从左往右贪心找到 a…b…c 最早的结尾 c，再往回收紧：窗口是最后那段 "abc"，间隔 0。
        XCTAssertEqual(score("abc", "a-----ab-c"), 200 - 1 * 4 - 7)
    }

    // MARK: - 中文与拼音

    func testWeChatByFullPinyinInitialsAndCharacter() {
        XCTAssertEqual(score("weixin", "微信"), 1000, "全拼完全相等")
        XCTAssertEqual(score("wx", "微信"), 1000, "首字母完全相等")
        XCTAssertEqual(score("微", "微信"), 800 - 1, "汉字开头匹配")
        XCTAssertEqual(tier(score("weix", "微信")), 800, "全拼打到一半")
        XCTAssertEqual(tier(score("xin", "微信")), 600, "第二个音节是词首")
        XCTAssertEqual(score("微信", "微信"), 1000)
    }

    func testPinyinVariants() {
        let key = LauncherSearchKey("微信")
        XCTAssertEqual(key.original.text, "微信")
        XCTAssertEqual(key.fullPinyin?.text, "weixin")
        XCTAssertEqual(key.initials?.text, "wx")
        XCTAssertEqual(key.fullPinyin?.wordStarts, [true, false, false, true, false, false])
    }

    func testMixedLatinAndChinese() {
        let key = LauncherSearchKey("QQ音乐")
        XCTAssertEqual(key.fullPinyin?.text, "qqyinyue")
        XCTAssertEqual(key.initials?.text, "qqyy", "汉字以外的字母原样保留")
        XCTAssertEqual(score("qqyy", "QQ音乐"), 1000)
        XCTAssertEqual(tier(score("yinyue", "QQ音乐")), 600)
        XCTAssertEqual(tier(score("音乐", "QQ音乐")), 600, "字母后面接汉字是词首")

        let spaced = LauncherSearchKey("Final Cut Pro 中文")
        XCTAssertEqual(spaced.fullPinyin?.text, "finalcutprozhongwen", "空格和标点不进拼音")
        XCTAssertEqual(tier(score("zhongwen", "Final Cut Pro 中文")), 600)
    }

    func testPolyphoneOverridesForCommonWords() {
        XCTAssertEqual(LauncherSearchKey("地图").fullPinyin?.text, "ditu", "系统转换给的是 de tu")
        XCTAssertEqual(LauncherSearchKey("网易云音乐").initials?.text, "wyyyy", "系统转换给的是 yin le")
        XCTAssertEqual(LauncherSearchKey("招商银行").fullPinyin?.text, "zhaoshangyinhang")
        XCTAssertEqual(LauncherSearchKey("长截屏").initials?.text, "cjp")
        XCTAssertEqual(LauncherSearchKey("重命名文件").fullPinyin?.text, "chongmingmingwenjian", "长的词条优先")
        XCTAssertEqual(LauncherSearchKey("还原窗口").initials?.text, "hyck")
        XCTAssertEqual(LauncherSearchKey("番茄钟").initials?.text, "fqz")
        XCTAssertEqual(LauncherSearchKey("重要").fullPinyin?.text, "zhongyao", "不在表里的词照系统转换")
        XCTAssertEqual(score("dt", "地图"), 1000)
    }

    func testUmlautIsWrittenAsV() {
        XCTAssertEqual(LauncherSearchKey("绿色").fullPinyin?.text, "lvse")
        XCTAssertEqual(LauncherSearchKey("女").fullPinyin?.text, "nv")
        XCTAssertEqual(LauncherSearchKey("区").fullPinyin?.text, "qu", "j q x y 后面的 u 不带分音符")
    }

    func testPinyinOnlyMatchesFromASyllableStart() {
        XCTAssertNil(score("ei", "微信"), "音节中间的子串不算")
        XCTAssertNil(score("in", "微信"))
        XCTAssertNil(score("wxin", "微信"), "拼音不做跳字匹配")
    }

    func testNoPinyinForTextWithoutChineseOrWhenDisabled() {
        XCTAssertNil(LauncherSearchKey("Safari").fullPinyin)
        XCTAssertNil(LauncherSearchKey("Café").initials)
        XCTAssertNil(LauncherSearchKey("微信", pinyin: false).fullPinyin)
        XCTAssertNil(score("wx", "微信", pinyin: false))
        XCTAssertEqual(score("微", "微信", pinyin: false), 800 - 1)
    }

    // MARK: - 拼音首字母只在查询全是字母且不少于 2 个时参与

    func testInitialsEligibility() {
        XCTAssertTrue(LauncherMatchQuery("wx").allowsInitials)
        XCTAssertTrue(LauncherMatchQuery("WX").allowsInitials)
        XCTAssertFalse(LauncherMatchQuery("w").allowsInitials, "只有 1 个字母")
        XCTAssertFalse(LauncherMatchQuery("w1").allowsInitials, "含数字")
        XCTAssertFalse(LauncherMatchQuery("w x").allowsInitials, "含空格")
        XCTAssertFalse(LauncherMatchQuery("微x").allowsInitials, "含汉字")
    }

    func testSingleLetterDoesNotUseInitials() {
        // 首字母 "wx" 里 x 在第 2 位、开头匹配 w 只扣 1 分；全拼 "weixin" 扣 5 分。
        // 1 个字母时只能是全拼给的分，说明首字母没参与。
        XCTAssertEqual(score("w", "微信"), 800 - 5)
        XCTAssertEqual(score("x", "微信"), 600 - 5)
    }

    func testInitialsIgnoredWhenQueryHasNonLetters() {
        XCTAssertNil(score("x1", "微信1"), "首字母 wx1 里有 x1，但查询含数字，不和首字母比")
        XCTAssertNil(score("w x", "微信"))
    }

    // MARK: - 不该中的

    func testNonMatches() {
        XCTAssertNil(score("xyz", "Safari"))
        XCTAssertNil(score("fs", "Safari"), "跳字要按顺序")
        XCTAssertNil(score("safarii", "Safari"), "查询比原文长")
        XCTAssertNil(score("wx", "Safari"))
        XCTAssertNil(score("x", "Safari"), "1 个字只有连续出现才算")
    }

    // MARK: - 其他

    func testEmptyQueryDoesNotFilter() {
        XCTAssertEqual(score("", "Safari"), LauncherMatch.emptyQueryScore)
        XCTAssertEqual(score("   ", "微信"), LauncherMatch.emptyQueryScore)
        XCTAssertEqual(LauncherMatch.score(LauncherMatchQuery(""), in: []), LauncherMatch.emptyQueryScore)
    }

    func testNonASCIILowercasing() {
        XCTAssertEqual(tier(score("éc", "ÉCOLE")), 800)
        XCTAssertEqual(LauncherSearchKey("ÉCOLE").original.text, "école")
    }

    func testOriginalKeepsSeparatorsAndWordStarts() {
        let key = LauncherSearchKey("VSCode-x")
        XCTAssertEqual(key.original.text, "vscode-x")
        XCTAssertEqual(key.original.wordStarts, [true, true, true, false, false, false, false, true])
        XCTAssertEqual(key.length, 8)
    }

    func testMultipleKeysTakeTheHighest() {
        let keys = [LauncherSearchKey("防休眠"), LauncherSearchKey("别睡"), LauncherSearchKey("Caffeinate")]
        XCTAssertEqual(LauncherMatch.score(LauncherMatchQuery("别睡"), in: keys), 1000)
        XCTAssertEqual(LauncherMatch.score(LauncherMatchQuery("caf"), in: keys), 800 - 7)
        XCTAssertEqual(LauncherMatch.score(LauncherMatchQuery("fxm"), in: keys), 1000)
        XCTAssertNil(LauncherMatch.score(LauncherMatchQuery("zzz"), in: keys))
        XCTAssertNil(LauncherMatch.score(LauncherMatchQuery("caf"), in: []))
    }

    /// 编译期检查：这些类型能跨线程传（以后查询挪到后台队列）。
    func testValueTypesAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(LauncherSearchKey.self)
        requireSendable(LauncherMatchQuery.self)
        requireSendable(LauncherCandidate.self)
        requireSendable(LauncherRankingResult.self)
        requireSendable(LauncherUsageRecords.self)
    }

    func testMaskContainsAllVariants() {
        let key = LauncherSearchKey("微信")
        let query = LauncherMatchQuery("wx")
        XCTAssertEqual(query.mask & ~key.mask, 0, "首字母里的字符也在位图里")
        XCTAssertNotEqual(LauncherMatchQuery("q").mask & ~key.mask, 0)
    }
}
