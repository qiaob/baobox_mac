import Foundation
import XCTest

/// 轮流识别里「这段用哪种语言的文字 / 之后的识别器切不切」的判定（docs/translation-engine/DESIGN.md §3.3、
/// docs/dictation/TECH_DESIGN.md §3）。分数是 `LiveTranslateScoring.score` 的口径（没字为 -1），字数是
/// `LiveTranslateScoring.units`，置信度是 `LiveTranslateScoring.averageConfidence`。名字里带 `Seg` 的用例取自
/// 2026-11-11 用户真机会议的日志（说话语言「自动（简体中文 / English）」，主语言 = 简体中文，category
/// `livetranslate.recognition`，10:33:34 那次开始的识别器）。
final class LiveTranslateLanguageSwitchTests: XCTestCase {
    private typealias Switch = LiveTranslateLanguageSwitch

    /// 一种语言对这段的分（`LiveTranslateScoring.score`，没字为 -1）、字 / 词数、平均置信度。
    private struct Scored {
        let score: Double
        let units: Int
        let confidence: Double

        init(_ score: Double, _ units: Int, _ confidence: Double) {
            self.score = score
            self.units = units
            self.confidence = confidence
        }
    }

    /// 日志里的一段：当时在听的是不是中文；重认过的段两种语言各自的分（当时在听的那种取实时结果的置信度，另一种取重认的）；
    /// 没重认的段为 nil（当时在听的那种认得像样）。
    private struct LoggedSegment {
        let seg: Int
        let loggedZh: Bool
        let zh: Scored?
        let en: Scored?

        init(_ seg: Int, loggedZh: Bool, zh: Scored? = nil, en: Scored? = nil) {
            self.seg = seg
            self.loggedZh = loggedZh
            self.zh = zh
            self.en = en
        }
    }

    /// 主语言是中文、中文识别器在听，英文（按词数）重认：从主语言切走。
    private func awayFromChinese(own: Double, other: Double, units: Int, confidence: Double,
                                 votes: Int = 0) -> Switch.Decision {
        Switch.decide(ownScore: own, otherScore: other, otherUnits: units, otherCJK: false,
                      otherConfidence: confidence, otherIsPrimary: false, votes: votes)
    }

    /// 主语言是中文、英文识别器在听，中文（按字数）重认：切回主语言。
    private func backToChinese(own: Double, other: Double, units: Int, confidence: Double,
                               votes: Int = 0) -> Switch.Decision {
        Switch.decide(ownScore: own, otherScore: other, otherUnits: units, otherCJK: true,
                      otherConfidence: confidence, otherIsPrimary: true, votes: votes)
    }

    /// 主语言是英文（英文系统的听写）、英文识别器在听，中文（按字数）重认：从主语言切走。
    private func awayFromEnglish(own: Double, other: Double, units: Int, confidence: Double,
                                 votes: Int = 0) -> Switch.Decision {
        Switch.decide(ownScore: own, otherScore: other, otherUnits: units, otherCJK: true,
                      otherConfidence: confidence, otherIsPrimary: false, votes: votes)
    }

    // MARK: - 切回主语言

    func testThePrimaryLanguageWinningOneSegmentSwitchesBackAtOnce() {
        let decision = backToChinese(own: 0.3, other: 0.6, units: 1, confidence: 0.6)
        XCTAssertEqual(decision, .switchOver(.backToPrimary), "主语言赢了就切回，一个字也算")
        XCTAssertTrue(decision.usesOther, "这一段用中文的文字")
        XCTAssertTrue(decision.switches, "之后是中文识别器在听")
        XCTAssertEqual(decision.votes, 0, "切回后票数清零")
        XCTAssertEqual(backToChinese(own: -1, other: 0.2, units: 2, confidence: 0), .switchOver(.backToPrimary),
                       "不看置信度、也不看当前语言出没出字")
        XCTAssertEqual(backToChinese(own: 0.3, other: 0.6, units: 1, confidence: 0.6, votes: 1),
                       .switchOver(.backToPrimary), "不攒票：之前有没有票都一样")
    }

    func testThePrimaryLanguageStillHasToWin() {
        XCTAssertEqual(backToChinese(own: 0.50, other: 0.54, units: 9, confidence: 0.54), .keep,
                       "差不多时留在当前语言（1.1 倍）")
        XCTAssertEqual(backToChinese(own: 0.40, other: -1, units: 0, confidence: 0), .keep, "中文重认没出字，不切回")
        XCTAssertEqual(backToChinese(own: -1, other: -1, units: 0, confidence: 0), .keep, "两边都没字")
    }

    // MARK: - 从主语言切走

    func testALongTrustedResultSwitchesAwayAtOnce() {
        let decision = awayFromChinese(own: 0.1, other: 0.8, units: 3, confidence: 0.8)
        XCTAssertEqual(decision, .switchOver(.long), "3 个词、带置信度、中文这段出了字：当场切")
        XCTAssertTrue(decision.usesOther)
        XCTAssertTrue(decision.switches)
        XCTAssertEqual(decision.votes, 0)
        XCTAssertEqual(awayFromChinese(own: 0, other: 0.8, units: 3, confidence: 0.8), .switchOver(.long),
                       "中文出了字但没置信度（分 0）也算出了字")
        XCTAssertEqual(awayFromChinese(own: 0.1, other: 0.8, units: 9, confidence: 0.8, votes: 1), .switchOver(.long),
                       "已经记了一票时来了长句：照样当场切，记成「够长」")
    }

    func testALongResultWithoutConfidenceOnlyVotes() {
        let first = awayFromChinese(own: 0.1, other: 0.3, units: 5, confidence: 0)
        XCTAssertEqual(first, .publishOther(votes: 1), "够长但英文那遍没置信度：只这段用英文的文字，记一票")
        XCTAssertTrue(first.usesOther)
        XCTAssertFalse(first.switches)
        XCTAssertEqual(awayFromChinese(own: 0.1, other: 0.3, units: 5, confidence: 0, votes: first.votes),
                       .switchOver(.votes), "再赢一段就按连赢两段切")
        XCTAssertFalse(Switch.longIsTrusted(ownScore: 0.1, otherConfidence: Switch.longMinConfidence))
        XCTAssertTrue(Switch.longIsTrusted(ownScore: 0.1, otherConfidence: Switch.longMinConfidence + 0.001))
    }

    func testALongResultWhenTheCurrentLanguageHeardNothingOnlyVotes() {
        let first = awayFromChinese(own: -1, other: 0.8, units: 6, confidence: 0.8)
        XCTAssertEqual(first, .publishOther(votes: 1), "中文一个字没出（-1）：英文再长也只记一票")
        XCTAssertTrue(first.usesOther, "这段只有英文的字，照样用它")
        XCTAssertEqual(awayFromChinese(own: -1, other: 0.8, units: 6, confidence: 0.8, votes: first.votes),
                       .switchOver(.votes))
        XCTAssertFalse(Switch.longIsTrusted(ownScore: -1, otherConfidence: 0.8))
    }

    func testAShortWinOnlyVotesAndTwoInARowSwitch() {
        let first = awayFromChinese(own: 0.2, other: 0.9, units: 1, confidence: 0.9)
        XCTAssertEqual(first, .publishOther(votes: 1), "一个词：只这段用英文的文字")
        XCTAssertTrue(first.usesOther)
        XCTAssertFalse(first.switches, "之后仍是中文识别器在听")
        XCTAssertEqual(first.votes, 1, "记一票")
        let second = awayFromChinese(own: 0.3, other: 0.7, units: 2, confidence: 0.7, votes: first.votes)
        XCTAssertEqual(second, .switchOver(.votes), "连着两段都是英文赢（不论长短）就切")
        XCTAssertTrue(second.switches)
        XCTAssertEqual(second.votes, 0, "切过去后票数清零")
    }

    func testTheCurrentLanguageWinningASegmentResetsTheVotes() {
        let short = awayFromChinese(own: 0.2, other: 0.9, units: 1, confidence: 0.9)
        let back = awayFromChinese(own: 0.7, other: 0.2, units: 1, confidence: 0.2, votes: short.votes)
        XCTAssertEqual(back, .keep)
        XCTAssertFalse(back.usesOther, "用当前语言（中文）的文字")
        XCTAssertFalse(back.switches)
        XCTAssertEqual(back.votes, 0, "当前语言赢一段，票数清零")
        XCTAssertEqual(awayFromChinese(own: 0.2, other: 0.9, units: 1, confidence: 0.9, votes: back.votes),
                       .publishOther(votes: 1), "中间隔了一段中文赢的，不算连赢")
    }

    func testLongIsCountedInCharactersForCJKAndInWordsOtherwise() {
        XCTAssertEqual(awayFromChinese(own: 0.1, other: 0.8, units: 3, confidence: 0.8), .switchOver(.long),
                       "英文按词：3 个词算长")
        XCTAssertEqual(awayFromChinese(own: 0.1, other: 0.8, units: 2, confidence: 0.8), .publishOther(votes: 1),
                       "2 个词还算短")
        XCTAssertEqual(awayFromEnglish(own: 0.1, other: 0.8, units: 4, confidence: 0.8), .switchOver(.long),
                       "主语言是英文时切到中文：4 个字算长")
        XCTAssertEqual(awayFromEnglish(own: 0.1, other: 0.8, units: 3, confidence: 0.8), .publishOther(votes: 1),
                       "3 个字还算短")
        XCTAssertTrue(Switch.isLong(units: Switch.longCJKUnits, cjk: true))
        XCTAssertFalse(Switch.isLong(units: Switch.longCJKUnits - 1, cjk: true))
        XCTAssertTrue(Switch.isLong(units: Switch.longWordUnits, cjk: false))
        XCTAssertFalse(Switch.isLong(units: Switch.longWordUnits - 1, cjk: false))
    }

    func testCloseScoresKeepTheCurrentLanguage() {
        // 1.1 倍：0.50 要被高过 0.55 才算输。
        XCTAssertEqual(awayFromChinese(own: 0.50, other: 0.54, units: 5, confidence: 0.54), .keep)
        XCTAssertEqual(awayFromChinese(own: 0.50, other: 0.56, units: 5, confidence: 0.56), .switchOver(.long))
        // 至少高 0.02：分低时光看 1.1 倍太容易翻（0.10 要被高过 0.12）。
        XCTAssertEqual(awayFromChinese(own: 0.10, other: 0.115, units: 5, confidence: 0.115), .keep)
        XCTAssertEqual(awayFromChinese(own: 0.10, other: 0.125, units: 5, confidence: 0.125), .switchOver(.long))
        // 打平、两边都没字，都不算赢。
        XCTAssertEqual(awayFromChinese(own: 0.40, other: 0.40, units: 5, confidence: 0.40), .keep)
        XCTAssertEqual(awayFromChinese(own: -1, other: -1, units: 0, confidence: 0), .keep)
        // 当前语言没出字（-1）：另一种只要出了字就赢（这段用它的文字）。
        XCTAssertTrue(Switch.otherWins(ownScore: -1, otherScore: 0))
        XCTAssertFalse(Switch.otherWins(ownScore: 0.3, otherScore: -1))
    }

    func testLogLabelsTellPublishingApartFromSwitching() {
        XCTAssertEqual(Switch.Decision.keep.logLabel, "keep")
        XCTAssertEqual(Switch.Decision.publishOther(votes: 1).logLabel, "publish other, keep active (vote 1/2)")
        XCTAssertEqual(Switch.Decision.switchOver(.backToPrimary).logLabel, "switch back to primary")
        XCTAssertEqual(Switch.Decision.switchOver(.long).logLabel, "switch (long)")
        XCTAssertEqual(Switch.Decision.switchOver(.votes).logLabel, "switch (2 wins in a row)")
    }

    // MARK: - 2026-11-11 日志里的真实分数

    /// seg 2：`zh-Hans 0.10 vs en 0.83 (1 units, conf 0.83)` —— 对方说了一句「OK」，以前整个识别器切到英文，
    /// 下一句中文被英文识别器认成「Phone」。现在只这一段用英文的文字（同 #168）。
    func testSeg2OneWordOKDoesNotSwitchTheRecognizer() {
        XCTAssertTrue(Switch.otherWins(ownScore: 0.10, otherScore: 0.83), "这段的文字照旧用英文（旧规则这里就切了）")
        XCTAssertEqual(awayFromChinese(own: 0.10, other: 0.83, units: 1, confidence: 0.83), .publishOther(votes: 1))
    }

    /// seg 4：`en 0.34 vs zh-Hans 0.99 (4 units, conf 0.99)` —— 英文识别器在听时中文赢了：切回主语言（#168 是 switch (long)）。
    func testSeg4ChineseWinsAndSwitchesBackToThePrimary() {
        XCTAssertEqual(backToChinese(own: 0.34, other: 0.99, units: 4, confidence: 0.99), .switchOver(.backToPrimary))
    }

    /// seg 9：`zh-Hans 0.12 vs en 0.68 (4 units, conf 0.68)` ——「So I like animation」：4 个英文词、带置信度，中文那段也出了
    /// 7 个字（几乎全是拉丁字母，所以分低），够长且可信，照样当场切。
    func testSeg9FourTrustedEnglishWordsStillSwitch() {
        XCTAssertEqual(awayFromChinese(own: 0.12, other: 0.68, units: 4, confidence: 0.68), .switchOver(.long))
    }

    /// seg 10：`en 0.09 vs zh-Hans 0.79 (7 units, conf 0.79)` —— 切回主语言。
    func testSeg10ChineseWinsAndSwitchesBackToThePrimary() {
        XCTAssertEqual(backToChinese(own: 0.09, other: 0.79, units: 7, confidence: 0.79), .switchOver(.backToPrimary))
    }

    /// seg 16：`zh-Hans -1.00 vs en 0.00 (3 units, conf 0.00)` —— 中文识别器报 1110、一个字没出，英文 3 个词：#168 算「够长」
    /// 当场切到了英文。现在中文没出字，只记一票；这段只有英文的字，照样用它。日志的 conf 0.00 是两位小数，按分反推其实是
    /// 0.005 以下的正数（`longMinConfidence` 的注释），这样也只记一票。
    func testSeg16EnglishAfterAChineseErrorOnlyVotes() {
        XCTAssertTrue(Switch.isLong(units: 3, cjk: false), "#168 按「够长」当场切了")
        XCTAssertEqual(awayFromChinese(own: -1, other: 0.00, units: 3, confidence: 0), .publishOther(votes: 1))
        XCTAssertEqual(awayFromChinese(own: -1, other: 0.004, units: 3, confidence: 0.004), .publishOther(votes: 1))
    }

    /// seg 17：`en 0.02 vs zh-Hans 0.48 (3 units, conf 0.59)` —— 切回中文那句只有 3 个字：#168 算短句只记一票、英文识别器
    /// 接着听。现在主语言赢了就切回。新规则下 seg 16 没切，seg 17 本来就是中文识别器在听：中文 0.48 赢过英文 0.02，
    /// seg 16 那一票清零。
    func testSeg17ThreeChineseCharactersSwitchBackToThePrimary() {
        XCTAssertFalse(Switch.isLong(units: 3, cjk: true), "#168 算短句，没切回")
        XCTAssertEqual(backToChinese(own: 0.02, other: 0.48, units: 3, confidence: 0.59), .switchOver(.backToPrimary))
        let afterSeg16 = awayFromChinese(own: -1, other: 0.00, units: 3, confidence: 0)
        let seg17 = awayFromChinese(own: 0.48, other: 0.02, units: 1, confidence: 0.06, votes: afterSeg16.votes)
        XCTAssertEqual(seg17, .keep)
        XCTAssertEqual(seg17.votes, 0)
    }

    /// seg 8：`zh-Hans 0.21 vs en 0.04 (1 units, conf 0.23)`。
    func testSeg8LowEnglishScoreKeepsChinese() {
        XCTAssertEqual(awayFromChinese(own: 0.21, other: 0.04, units: 1, confidence: 0.23), .keep)
    }

    /// seg 3：`en 0.18 vs zh-Hans -1.00 (0 units, conf 0.00)` —— 中文重认没出字，只能留着英文。
    func testSeg3EmptyChineseRecheckKeepsEnglish() {
        XCTAssertEqual(backToChinese(own: 0.18, other: -1, units: 0, confidence: 0), .keep)
    }

    /// seg 1 / seg 12：另一种重认没出字（`-1.00 vs -1.00`、`zh-Hans 0.55 vs en -1.00`）。
    func testSeg1AndSeg12EmptyRechecksKeep() {
        XCTAssertEqual(awayFromChinese(own: -1, other: -1, units: 0, confidence: 0), .keep)
        XCTAssertEqual(awayFromChinese(own: 0.55, other: -1, units: 0, confidence: 0), .keep)
    }

    /// 那场会议的 seg 1–32（10:34:25–10:37:35，之后 10:37:52 会议结束）按顺序喂进来，谁在听由判定自己推（分数按语言取，
    /// 和当时谁在听无关）。没重认的段是当时在听的语言认得像样，记作当前语言赢。会议开头 10:33:16 起的那次识别器只有两段，
    /// 都是 1110、两边都没字（`-1.00 vs -1.00`，三种规则都是 keep），18 秒后识别器重开（票数从 0 起），不在这里。
    ///
    /// 和日志（旧规则）的分歧在 seg 3 和 seg 17：
    /// - seg 3：seg 2 不再切，seg 3 就该是中文识别器在实时听，而日志里中文那份（0 字）来自重认 —— 实时的中文结果日志里没有。
    ///   这里按日志的数推（中文 0 字 → 英文「Phone」0.18 第二次赢 → 切），是最坏的情况；实时的中文识别器没出字时这句不会重认，
    ///   也就不切。seg 4 中文赢、切回主语言，两边又一致。
    /// - seg 17：seg 16 不再切，seg 17 是中文识别器在听，中文那份（3 字、0.48）同样来自重认。
    func testReplayOfTheWholeMeetingFromTheLog() {
        let log = [
            LoggedSegment(1, loggedZh: true, zh: Scored(-1, 0, 0), en: Scored(-1, 0, 0)),
            LoggedSegment(2, loggedZh: true, zh: Scored(0.10, 1, 0.69), en: Scored(0.83, 1, 0.83)),
            LoggedSegment(3, loggedZh: false, zh: Scored(-1, 0, 0), en: Scored(0.18, 1, 0.25)),
            LoggedSegment(4, loggedZh: false, zh: Scored(0.99, 4, 0.99), en: Scored(0.34, 1, 0.46)),
            LoggedSegment(5, loggedZh: true),
            LoggedSegment(6, loggedZh: true),
            LoggedSegment(7, loggedZh: true),
            LoggedSegment(8, loggedZh: true, zh: Scored(0.21, 25, 0.21), en: Scored(0.04, 1, 0.23)),
            LoggedSegment(9, loggedZh: true, zh: Scored(0.12, 7, 0.55), en: Scored(0.68, 4, 0.68)),
            LoggedSegment(10, loggedZh: false, zh: Scored(0.79, 7, 0.79), en: Scored(0.09, 1, 0.18)),
            LoggedSegment(11, loggedZh: true),
            LoggedSegment(12, loggedZh: true, zh: Scored(0.55, 5, 0.55), en: Scored(-1, 0, 0)),
            LoggedSegment(13, loggedZh: true),
            LoggedSegment(14, loggedZh: true),
            LoggedSegment(15, loggedZh: true),
            LoggedSegment(16, loggedZh: true, zh: Scored(-1, 0, 0), en: Scored(0.00, 3, 0)),
            LoggedSegment(17, loggedZh: false, zh: Scored(0.48, 3, 0.59), en: Scored(0.02, 1, 0.06)),
            LoggedSegment(18, loggedZh: true),
            LoggedSegment(19, loggedZh: true, zh: Scored(0.05, 3, 0.05), en: Scored(0.00, 4, 0)),
            LoggedSegment(20, loggedZh: true),
            LoggedSegment(21, loggedZh: true),
            LoggedSegment(22, loggedZh: true, zh: Scored(0.49, 13, 0.49), en: Scored(0.00, 2, 0)),
            LoggedSegment(23, loggedZh: true),
            LoggedSegment(24, loggedZh: true),
            LoggedSegment(25, loggedZh: true, zh: Scored(-1, 0, 0), en: Scored(-1, 0, 0)),
            LoggedSegment(26, loggedZh: true),
            LoggedSegment(27, loggedZh: true),
            LoggedSegment(28, loggedZh: true),
            LoggedSegment(29, loggedZh: true),
            LoggedSegment(30, loggedZh: true),
            LoggedSegment(31, loggedZh: true),
            LoggedSegment(32, loggedZh: true, zh: Scored(0.09, 5, 0.09), en: Scored(0.10, 5, 0.10)),
        ]
        XCTAssertEqual(log.map(\.seg), Array(1...32), "日志里的段一段不落")
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
            // 中文是主语言：英文识别器在听时，另一种（中文）就是主语言。
            let decision = Switch.decide(ownScore: own.score, otherScore: other.score, otherUnits: other.units,
                                         otherCJK: !activeZh, otherConfidence: other.confidence,
                                         otherIsPrimary: !activeZh, votes: votes)
            decisions.append(decision)
            votes = decision.votes
            if decision.switches { activeZh.toggle() }
        }
        // 只列不是 keep 的段，其余都是 keep。
        let expected: [Int: Switch.Decision] = [
            2: .publishOther(votes: 1),     // 「OK」只用这段，中文识别器接着听（旧：切到英文）
            3: .switchOver(.votes),         // 最坏情况（见上）；旧：英文在听、中文重认 0 字，留英文
            4: .switchOver(.backToPrimary), // 切回中文（旧、#168 都切，#168 记成 long）
            9: .switchOver(.long),          // 4 个英文词（同旧、#168）
            10: .switchOver(.backToPrimary),
            16: .publishOther(votes: 1),    // 中文 1110 没出字：只记一票（旧、#168：切到英文）
            17: .keep,                      // 中文识别器在听，中文赢（旧：从英文切回；#168：英文接着听、记一票）
        ]
        for (index, decision) in decisions.enumerated() {
            let seg = index + 1
            XCTAssertEqual(decision, expected[seg] ?? .keep, "seg \(seg)")
        }
        XCTAssertTrue(activeZh, "最后是中文识别器在听")
    }
}
