import Foundation

// 「自动（A / B）」轮流识别：一段话交给另一种语言重认之后，这段用哪种语言的文字、之后的识别器切不切
// （docs/translation-engine/DESIGN.md §3.3、docs/dictation/TECH_DESIGN.md §3）。会议 / 字幕与同传
// （`LiveTranslateSwitchingRecognizer`）和听写（`DictationRecognizer`）共用。
// 本文件只依赖 Foundation，可脱离 App 单独编译测试；识别、录音、重认在上面两个识别器里。
//
// 2026-11-11 用户真机（会议，说话语言「自动（简体中文 / English）」）：以前另一种语言一赢，就既用它的文字、又把**之后**的
// 识别器切过去，不看这段多短。对方说了一句「OK」（zh-Hans 0.10 vs en 0.83，1 个词），整个识别器就切到英文；下一句中文被
// 英文识别器认成「Phone」，中文重认没出字，只好留着英文乱码。所以把两件事分开：这段的文字照旧谁赢用谁的；之后切不切，
// 要另一种语言的结果够长，或者连着两段都是它赢。
//
// 拿同一场会议的日志整段重放，这条规则还剩两处不对（主语言 = 两种里的第一种，即自动 A，那场是简体中文）：
// - seg 16：中文识别器报 1110、一个字没出，英文重认出了 3 个词、置信度 0.00（`zh-Hans -1.00 vs en 0.00`）——
//   3 个词算「够长」，当场切到了英文。所以从主语言切走要更有把握：够长还得可信（`longIsTrusted`），不然只记票。
// - seg 17：切回中文那句只有 3 个字（`en 0.02 vs zh-Hans 0.48`），算短句，要连赢两段才切回来，这期间还是英文识别器在听。
//   所以切回主语言不设门槛：主语言赢了就当场切回（`Decision.Reason.backToPrimary`）。

/// 另一种语言重认之后的判定（纯函数；票数由识别器存着，每段传进来、取回去）。
enum LiveTranslateLanguageSwitch {
    enum Decision: Equatable {
        /// 另一种语言没赢：用当前语言的文字，识别器不动，票数清零。
        case keep
        /// 另一种语言赢了，但还不够切（从主语言切走，结果短或不可信，也还没连赢两段）：只这一段用它的文字，
        /// 之后仍是当前语言的识别器在听。`votes` = 它已经连赢了几段。
        case publishOther(votes: Int)
        /// 另一种语言赢了，而且够切（为什么够见 `Reason`）：用它的文字，之后的识别器切过去，票数清零。
        case switchOver(Reason)

        enum Reason: Equatable {
            /// 另一种是主语言：赢了就切回来，不看长短、不攒票。
            case backToPrimary
            /// 从主语言切走：结果够长（`isLong`）而且可信（`longIsTrusted`）。
            case long
            /// 从主语言切走：连赢了 `votesToSwitch` 段（不论长短）。
            case votes
        }

        /// 这一段用另一种语言的文字。
        var usesOther: Bool { self != .keep }

        /// 之后的识别器切到另一种语言。
        var switches: Bool {
            if case .switchOver = self { return true }
            return false
        }

        /// 判定之后的票数：识别器存着，下一段传回 `decide`。
        var votes: Int {
            if case .publishOther(let votes) = self { return votes }
            return 0
        }

        /// 日志里 `->` 后面那截（只有判定，不含文字）。
        var logLabel: String {
            switch self {
            case .keep:
                return "keep"
            case .publishOther(let votes):
                return "publish other, keep active (vote \(votes)/\(LiveTranslateLanguageSwitch.votesToSwitch))"
            case .switchOver(.backToPrimary):
                return "switch back to primary"
            case .switchOver(.long):
                return "switch (long)"
            case .switchOver(.votes):
                return "switch (\(LiveTranslateLanguageSwitch.votesToSwitch) wins in a row)"
            }
        }
    }

    /// 另一种语言的分要高过当前语言的 1.1 倍、且至少高 0.02 才算赢：差不多时留在当前语言，免得来回跳（2026-11-05 起
    /// 会议 / 字幕的规则；听写原来是只要高一点就算赢，2026-11-11 统一成这条）。切回主语言也要先赢过这道线。
    static let winRatio = 1.1
    static let winMargin = 0.02

    /// 从主语言切走时，另一种语言的结果至少这么长（还得可信，见 `longIsTrusted`），赢了就当场切：中日韩按字、其余按词
    /// （`LiveTranslateScoring.units` 的口径）。一两个词（「OK」「Yes」、人名、产品名）哪种语言里都会冒出来，单凭它不该
    /// 换掉之后的识别器；真换了语言，一句话通常就够长（2026-11-11 seg 9「So I like animation」：英文 4 个词、置信度 0.68）。
    /// 切回主语言不看长短，所以 4 个字这条只在从主语言切到中日韩时用（比如英文系统的听写，主语言是英文）。
    static let longCJKUnits = 4
    static let longWordUnits = 3

    /// 「可信」的第一条：另一种语言这一遍的平均置信度高过它（0 = 只要带了置信度就算；系统只给 final 结果置信度，
    /// 出错收尾、只拿到 partial 的是 0）。
    ///
    /// 注意 2026-11-11 那场的日志置信度只记两位小数：seg 16 英文那遍记的是 conf 0.00，分也是 0.00 —— 置信度正好是 0 时
    /// 打分按中性值 0.3 算（`LiveTranslateScoring.score`），3 个词、1.9 秒人声至少 0.045，不会是 0.00，所以那一遍其实是
    /// 0.005 以下的正数，这一条挡不住，seg 16 是被第二条（当前语言没出字）挡住的。现在日志记三位小数。
    static let longMinConfidence = 0.0

    /// 从主语言切走时，够长的结果（`isLong`）能不能当场切：另一种语言这一遍带置信度（> `longMinConfidence`），
    /// 而且当前语言这段出了字（`ownScore >= 0`，没字为 -1）。缺一条就只按连赢两段走：当前语言一个字没出（1110 这类错误、
    /// 没听清）时，另一种只要出了字就赢，赢了也不说明说的是它（seg 16：中文 1110 没出字，英文 3 个词、置信度 0.00）。
    static func longIsTrusted(ownScore: Double, otherConfidence: Double) -> Bool {
        otherConfidence > longMinConfidence && ownScore >= 0
    }

    /// 从主语言切走时，短的（或够长但不可信的）赢了只记一票：连着这么多段都是另一种语言赢（不论长短）才切 —— 真换了语言，
    /// 下一段也会是它赢；夹着的一句「OK」过去，下一段当前语言赢回来，票数就清零了。
    static let votesToSwitch = 2

    /// 另一种语言赢没赢（这一段用不用它的文字）。分数是 `LiveTranslateScoring.score`，没字为 -1。
    static func otherWins(ownScore: Double, otherScore: Double) -> Bool {
        otherScore > max(ownScore * winRatio, ownScore + winMargin)
    }

    /// 另一种语言的结果够不够长。
    static func isLong(units: Int, cjk: Bool) -> Bool {
        units >= (cjk ? longCJKUnits : longWordUnits)
    }

    /// 主语言 = 两种里的第一种（自动 A）。
    /// 1. 另一种没赢（`otherWins`）→ `keep`：用当前语言的文字，票数清零。
    /// 2. 另一种是主语言 → 当场切回（`backToPrimary`），不看长短、不攒票（seg 17）。
    /// 3. 从主语言切走：够长（`isLong`）而且可信（`longIsTrusted`）→ 当场切（`long`，seg 9）；否则记一票，连赢
    ///    `votesToSwitch` 段才切（`votes`），不到就只这一段用它的文字（`publishOther`，seg 2 的「OK」、seg 16）。
    ///
    /// - Parameters:
    ///   - ownScore: 当前语言这段的分（`LiveTranslateScoring.score`，没字为 -1）。
    ///   - otherScore: 另一种语言重认的分。
    ///   - otherUnits: 另一种语言重认结果的字 / 词数（`LiveTranslateScoring.units`）。
    ///   - otherCJK: 另一种语言按字数数（中日韩）。
    ///   - otherConfidence: 另一种语言重认结果的平均置信度（`LiveTranslateScoring.averageConfidence`，没有为 0）。
    ///   - otherIsPrimary: 另一种是主语言（也就是当前在听的不是主语言）。
    ///   - votes: 上一段判定之后的票数（`Decision.votes`；开新会话为 0）。
    static func decide(ownScore: Double, otherScore: Double, otherUnits: Int, otherCJK: Bool,
                       otherConfidence: Double, otherIsPrimary: Bool, votes: Int) -> Decision {
        guard otherWins(ownScore: ownScore, otherScore: otherScore) else { return .keep }
        if otherIsPrimary { return .switchOver(.backToPrimary) }
        if isLong(units: otherUnits, cjk: otherCJK),
           longIsTrusted(ownScore: ownScore, otherConfidence: otherConfidence) {
            return .switchOver(.long)
        }
        let votes = votes + 1
        return votes >= votesToSwitch ? .switchOver(.votes) : .publishOther(votes: votes)
    }
}
