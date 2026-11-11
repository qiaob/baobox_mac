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

/// 另一种语言重认之后的判定（纯函数；票数由识别器存着，每段传进来、取回去）。
enum LiveTranslateLanguageSwitch {
    enum Decision: Equatable {
        /// 另一种语言没赢：用当前语言的文字，识别器不动，票数清零。
        case keep
        /// 另一种语言赢了，但结果短、也还没连赢两段：只这一段用它的文字，之后仍是当前语言的识别器在听。
        /// `votes` = 它已经连赢了几段。
        case publishOther(votes: Int)
        /// 另一种语言赢了，而且结果够长（`long`）或连赢了两段：用它的文字，之后的识别器切过去，票数清零。
        case switchOver(long: Bool)

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
            case .switchOver(let long):
                return long ? "switch (long)" : "switch (\(LiveTranslateLanguageSwitch.votesToSwitch) wins in a row)"
            }
        }
    }

    /// 另一种语言的分要高过当前语言的 1.1 倍、且至少高 0.02 才算赢：差不多时留在当前语言，免得来回跳（2026-11-05 起
    /// 会议 / 字幕的规则；听写原来是只要高一点就算赢，2026-11-11 统一成这条）。
    static let winRatio = 1.1
    static let winMargin = 0.02

    /// 另一种语言的结果至少这么长，赢了就当场切：中日韩按字、其余按词（`LiveTranslateScoring.units` 的口径）。
    /// 一两个词（「OK」「Yes」、人名、产品名）哪种语言里都会冒出来，单凭它不该换掉之后的识别器；真换了语言，
    /// 一句话通常就够长。2026-11-11 的日志里切回中文的几段都有 4 个字以上（0.99 / 4 字、0.79 / 7 字）。
    static let longCJKUnits = 4
    static let longWordUnits = 3

    /// 短的赢了只记一票：连着这么多段都是另一种语言赢（不论长短）才切 —— 真换了语言，下一段也会是它赢；
    /// 夹着的一句「OK」过去，下一段当前语言赢回来，票数就清零了。
    static let votesToSwitch = 2

    /// 另一种语言赢没赢（这一段用不用它的文字）。分数是 `LiveTranslateScoring.score`，没字为 -1。
    static func otherWins(ownScore: Double, otherScore: Double) -> Bool {
        otherScore > max(ownScore * winRatio, ownScore + winMargin)
    }

    /// 另一种语言的结果够不够长（够长的赢了当场切）。
    static func isLong(units: Int, cjk: Bool) -> Bool {
        units >= (cjk ? longCJKUnits : longWordUnits)
    }

    /// - Parameters:
    ///   - ownScore: 当前语言这段的分（`LiveTranslateScoring.score`，没字为 -1）。
    ///   - otherScore: 另一种语言重认的分。
    ///   - otherUnits: 另一种语言重认结果的字 / 词数（`LiveTranslateScoring.units`）。
    ///   - otherCJK: 另一种语言按字数数（中日韩）。
    ///   - votes: 上一段判定之后的票数（`Decision.votes`；开新会话为 0）。
    static func decide(ownScore: Double, otherScore: Double, otherUnits: Int, otherCJK: Bool,
                       votes: Int) -> Decision {
        guard otherWins(ownScore: ownScore, otherScore: otherScore) else { return .keep }
        if isLong(units: otherUnits, cjk: otherCJK) { return .switchOver(long: true) }
        let votes = votes + 1
        return votes >= votesToSwitch ? .switchOver(long: false) : .publishOther(votes: votes)
    }
}
