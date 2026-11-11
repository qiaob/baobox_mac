import Foundation
import XCTest

/// 轮流识别里「这段用哪种语言的文字 / 之后的识别器切不切」的判定（docs/translation-engine/DESIGN.md §3.3、
/// docs/dictation/TECH_DESIGN.md §3）。分数是 `LiveTranslateScoring.score` 的口径（没字为 -1），字数是
/// `LiveTranslateScoring.units`。名字里带 `Seg` 的用例取自 2026-11-11 用户真机会议的日志
/// （说话语言「自动（简体中文 / English）」，category `livetranslate.recognition`）。
final class LiveTranslateLanguageSwitchTests: XCTestCase {
    private typealias Switch = LiveTranslateLanguageSwitch

    /// 一种语言对这段的分（`LiveTranslateScoring.score`，没字为 -1）与字 / 词数。
    private struct Scored {
        let score: Double
        let units: Int

        init(_ score: Double, _ units: Int) {
            self.score = score
            self.units = units
        }
    }

    /// 日志里的一段：当时在听的是不是中文；重认过的段两种语言各自的分（没重认的段为 nil = 当时在听的那种认得像样）。
    private struct LoggedSegment {
        let seg: Int
        let loggedZh: Bool
        let zh: Scored?
        let en: Scored?
    }

    /// 当前是中文识别器在听，英文重认（按词数）。
    private func toEnglish(own: Double, other: Double, units: Int, votes: Int = 0) -> Switch.Decision {
        Switch.decide(ownScore: own, otherScore: other, otherUnits: units, otherCJK: false, votes: votes)
    }

    /// 当前是英文识别器在听，中文重认（按字数）。
    private func toChinese(own: Double, other: Double, units: Int, votes: Int = 0) -> Switch.Decision {
        Switch.decide(ownScore: own, otherScore: other, otherUnits: units, otherCJK: true, votes: votes)
    }

    // MARK: - 规则

    func testOneShortEnglishWordWinsOnlyItsOwnSegment() {
        let decision = toEnglish(own: 0.2, other: 0.9, units: 1)
        XCTAssertEqual(decision, .publishOther(votes: 1))
        XCTAssertTrue(decision.usesOther, "这一段用英文的文字")
        XCTAssertFalse(decision.switches, "之后仍是中文识别器在听")
        XCTAssertEqual(decision.votes, 1, "记一票")
    }

    func testTwoShortWinsInARowSwitch() {
        let first = toEnglish(own: 0.2, other: 0.9, units: 1)
        let second = toEnglish(own: 0.3, other: 0.7, units: 2, votes: first.votes)
        XCTAssertEqual(second, .switchOver(long: false), "连着两段都是英文赢（不论长短）就切")
        XCTAssertTrue(second.usesOther)
        XCTAssertTrue(second.switches)
        XCTAssertEqual(second.votes, 0, "切过去后票数清零")
    }

    func testALongResultSwitchesAtOnce() {
        XCTAssertEqual(toEnglish(own: 0.1, other: 0.8, units: 3), .switchOver(long: true), "英文按词：3 个词算长")
        XCTAssertEqual(toEnglish(own: 0.1, other: 0.8, units: 2), .publishOther(votes: 1), "2 个词还算短")
        XCTAssertEqual(toChinese(own: 0.1, other: 0.8, units: 4), .switchOver(long: true), "中文按字：4 个字算长")
        XCTAssertEqual(toChinese(own: 0.1, other: 0.8, units: 3), .publishOther(votes: 1), "3 个字还算短")
        XCTAssertEqual(toChinese(own: 0.1, other: 0.8, units: 9, votes: 1), .switchOver(long: true),
                       "已经记了一票时来了长句：照样当场切，记成「够长」")
        XCTAssertTrue(Switch.isLong(units: Switch.longCJKUnits, cjk: true))
        XCTAssertFalse(Switch.isLong(units: Switch.longCJKUnits - 1, cjk: true))
        XCTAssertTrue(Switch.isLong(units: Switch.longWordUnits, cjk: false))
        XCTAssertFalse(Switch.isLong(units: Switch.longWordUnits - 1, cjk: false))
    }

    func testTheCurrentLanguageWinningASegmentResetsTheVotes() {
        let short = toEnglish(own: 0.2, other: 0.9, units: 1)
        let back = toEnglish(own: 0.7, other: 0.2, units: 1, votes: short.votes)
        XCTAssertEqual(back, .keep)
        XCTAssertFalse(back.usesOther, "用当前语言（中文）的文字")
        XCTAssertFalse(back.switches)
        XCTAssertEqual(back.votes, 0, "当前语言赢一段，票数清零")
        XCTAssertEqual(toEnglish(own: 0.2, other: 0.9, units: 1, votes: back.votes), .publishOther(votes: 1),
                       "中间隔了一段中文赢的，不算连赢")
    }

    func testCloseScoresKeepTheCurrentLanguage() {
        // 1.1 倍：0.50 要被高过 0.55 才算输。
        XCTAssertEqual(toEnglish(own: 0.50, other: 0.54, units: 5), .keep)
        XCTAssertEqual(toEnglish(own: 0.50, other: 0.56, units: 5), .switchOver(long: true))
        // 至少高 0.02：分低时光看 1.1 倍太容易翻（0.10 要被高过 0.12）。
        XCTAssertEqual(toEnglish(own: 0.10, other: 0.115, units: 5), .keep)
        XCTAssertEqual(toEnglish(own: 0.10, other: 0.125, units: 5), .switchOver(long: true))
        // 打平、两边都没字，都不算赢。
        XCTAssertEqual(toEnglish(own: 0.40, other: 0.40, units: 5), .keep)
        XCTAssertEqual(toEnglish(own: -1, other: -1, units: 0), .keep)
        // 当前语言没出字（-1）：另一种只要出了字就赢（这段用它的文字）。
        XCTAssertTrue(Switch.otherWins(ownScore: -1, otherScore: 0))
        XCTAssertFalse(Switch.otherWins(ownScore: 0.3, otherScore: -1))
    }

    func testLogLabelsTellPublishingApartFromSwitching() {
        XCTAssertEqual(Switch.Decision.keep.logLabel, "keep")
        XCTAssertEqual(Switch.Decision.publishOther(votes: 1).logLabel, "publish other, keep active (vote 1/2)")
        XCTAssertEqual(Switch.Decision.switchOver(long: true).logLabel, "switch (long)")
        XCTAssertEqual(Switch.Decision.switchOver(long: false).logLabel, "switch (2 wins in a row)")
    }

    // MARK: - 2026-11-11 日志里的真实分数

    /// seg 2：`zh-Hans 0.10 vs en 0.83 (1 units, conf 0.83) -> switch` —— 对方说了一句「OK」，以前整个识别器切到英文，
    /// 下一句中文被英文识别器认成「Phone」。现在只这一段用英文的文字。
    func testSeg2OneWordOKNoLongerSwitchesTheRecognizer() {
        XCTAssertTrue(Switch.otherWins(ownScore: 0.10, otherScore: 0.83), "这段的文字照旧用英文（旧规则这里就切了）")
        XCTAssertEqual(toEnglish(own: 0.10, other: 0.83, units: 1), .publishOther(votes: 1))
    }

    /// seg 9：`zh-Hans 0.12 vs en 0.68 (4 units, conf 0.68) -> switch` —— 4 个英文词算长，照样当场切。
    func testSeg9FourEnglishWordsStillSwitch() {
        XCTAssertEqual(toEnglish(own: 0.12, other: 0.68, units: 4), .switchOver(long: true))
    }

    /// seg 4：`en 0.34 vs zh-Hans 0.99 (4 units, conf 0.99) -> switch` —— 切回中文的那段，4 个字算长，当场切回来。
    func testSeg4FourChineseCharactersSwitchBack() {
        XCTAssertEqual(toChinese(own: 0.34, other: 0.99, units: 4), .switchOver(long: true))
    }

    /// seg 10：`en 0.09 vs zh-Hans 0.79 (7 units, conf 0.79) -> switch`。
    func testSeg10SevenChineseCharactersSwitchBack() {
        XCTAssertEqual(toChinese(own: 0.09, other: 0.79, units: 7), .switchOver(long: true))
    }

    /// seg 8：`zh-Hans 0.21 vs en 0.04 (1 units, conf 0.23) -> keep`。
    func testSeg8LowEnglishScoreKeepsChinese() {
        XCTAssertEqual(toEnglish(own: 0.21, other: 0.04, units: 1), .keep)
    }

    /// seg 3：`en 0.18 vs zh-Hans -1.00 (0 units, conf 0.00) -> keep` —— 中文重认没出字，只能留着英文。
    func testSeg3EmptyChineseRecheckKeepsEnglish() {
        XCTAssertEqual(toChinese(own: 0.18, other: -1, units: 0), .keep)
    }

    /// seg 1 / seg 12：另一种重认没出字（`-1.00 vs -1.00`、`zh-Hans 0.55 vs en -1.00`）。
    func testSeg1AndSeg12EmptyRechecksKeep() {
        XCTAssertEqual(toEnglish(own: -1, other: -1, units: 0), .keep)
        XCTAssertEqual(toEnglish(own: 0.55, other: -1, units: 0), .keep)
    }

    /// 把 seg 1–12 按顺序喂进来，谁在听由判定自己推（分数按语言取，和当时谁在听无关）。没重认的段（5、6、7、11）是
    /// 当时在听的语言认得像样，记作当前语言赢。
    ///
    /// 和日志的分歧从 seg 3 开始：seg 2 不再切，seg 3 就该是中文识别器在实时听，而日志里中文那份（0 字）来自重认 ——
    /// 实时的中文结果日志里没有。这里按日志的数推（中文 0 字 → 英文「Phone」0.18 第二次赢 → 切），是最坏的情况；
    /// 实时的中文识别器出了像样的字，就是当前语言赢、票数清零、不切。seg 4 起两边又一致。
    func testReplayOfSegments1To12FromTheLog() {
        let log = [
            LoggedSegment(seg: 1, loggedZh: true, zh: Scored(-1, 0), en: Scored(-1, 0)),
            LoggedSegment(seg: 2, loggedZh: true, zh: Scored(0.10, 1), en: Scored(0.83, 1)),
            LoggedSegment(seg: 3, loggedZh: false, zh: Scored(-1, 0), en: Scored(0.18, 1)),
            LoggedSegment(seg: 4, loggedZh: false, zh: Scored(0.99, 4), en: Scored(0.34, 1)),
            LoggedSegment(seg: 5, loggedZh: true, zh: nil, en: nil),
            LoggedSegment(seg: 6, loggedZh: true, zh: nil, en: nil),
            LoggedSegment(seg: 7, loggedZh: true, zh: nil, en: nil),
            LoggedSegment(seg: 8, loggedZh: true, zh: Scored(0.21, 25), en: Scored(0.04, 1)),
            LoggedSegment(seg: 9, loggedZh: true, zh: Scored(0.12, 7), en: Scored(0.68, 4)),
            LoggedSegment(seg: 10, loggedZh: false, zh: Scored(0.79, 7), en: Scored(0.09, 1)),
            LoggedSegment(seg: 11, loggedZh: true, zh: nil, en: nil),
            LoggedSegment(seg: 12, loggedZh: true, zh: Scored(0.55, 5), en: Scored(-1, 0)),
        ]
        var activeZh = true
        var votes = 0
        var decisions: [Switch.Decision] = []
        for entry in log {
            guard let zh = entry.zh, let en = entry.en else {
                XCTAssertEqual(activeZh, entry.loggedZh, "seg \(entry.seg)：没重认的段，新旧在听的得是同一种")
                decisions.append(.keep)
                votes = 0
                continue
            }
            let own = activeZh ? zh : en
            let other = activeZh ? en : zh
            let decision = Switch.decide(ownScore: own.score, otherScore: other.score, otherUnits: other.units,
                                         otherCJK: !activeZh, votes: votes)
            decisions.append(decision)
            votes = decision.votes
            if decision.switches { activeZh.toggle() }
        }
        XCTAssertEqual(decisions, [
            .keep,                    // 1
            .publishOther(votes: 1),  // 2：「OK」只用这段，中文识别器接着听（旧：切到英文）
            .switchOver(long: false), // 3：最坏情况（见上）；旧：英文在听、中文重认 0 字，留英文
            .switchOver(long: true),  // 4：切回中文（同旧）
            .keep, .keep, .keep,      // 5–7
            .keep,                    // 8
            .switchOver(long: true),  // 9：4 个英文词（同旧）
            .switchOver(long: true),  // 10：7 个字切回中文（同旧）
            .keep,                    // 11
            .keep,                    // 12
        ])
        XCTAssertTrue(activeZh, "最后是中文识别器在听")
    }
}
