import Foundation

// 计算引擎的 token 与游标（docs/launcher/TECH_DESIGN.md §7）。词法见 LauncherCalcLexer。
// 各句型都在同一串 token 上试，自己决定认哪些词；短语（「现在几点」「time in」）一律按 `LauncherCalcPhrase.join`
// 拼起来再比，所以中文分词怎么切、英文词之间几个空格都不影响匹配。

struct LauncherCalcToken: Equatable {
    enum Kind: Equatable {
        /// 数字：十进制、0x / 0b / 0o 字面量都已换成值；「3万」这类后缀倍数已乘进去。
        case number(LauncherCalcValue)
        /// 英文词（存小写）或词表里的中文词。
        case word(String)
        /// 运算符和符号：+ - * / ^ % ( ) ° √ =
        case symbol(Character)
        /// `2026-12-25`、`2026/12/25` 这样的日期（只校验了格式，没校验日子存不存在）。
        case date(year: Int, month: Int, day: Int)
        /// `15:00` 这样的钟点（只校验了格式）。
        case clock(hour: Int, minute: Int)
    }

    let kind: Kind
    /// 原文：英文大小写原样（数据量单位 `Mb` / `MB` 靠它区分），数字是带千分位逗号的写法。
    let raw: String
    /// 和前一个 token 之间有空白。
    let spaceBefore: Bool
    /// 数字的写法：10 / 16 / 2 / 8。
    var radix: Int = 10

    var word: String? {
        if case .word(let word) = kind { return word }
        return nil
    }

    var number: LauncherCalcValue? {
        if case .number(let value) = kind { return value }
        return nil
    }

    /// 十进制写的整数（`255`，不是 `0xff`、不是 `2.5`）。
    var decimalInteger: Decimal? {
        guard radix == 10, case .number(.exact(let value)) = kind, LauncherCalcMath.isInteger(value) else { return nil }
        return value
    }

    func isSymbol(_ character: Character) -> Bool {
        if case .symbol(let symbol) = kind { return symbol == character }
        return false
    }

    func isWord(_ text: String) -> Bool { word == text }

    func isWord(in set: Set<String>) -> Bool {
        guard let word else { return false }
        return set.contains(word)
    }
}

enum LauncherCalcPhrase {
    /// 一串 word 拼成的短语：中文词直接相连，英文词之间一个空格。有一个不是 word → nil。
    static func join<C: Collection>(_ tokens: C) -> String? where C.Element == LauncherCalcToken {
        var text = ""
        var previousWasLatin = false
        for token in tokens {
            guard let word = token.word else { return nil }
            let isLatin = word.unicodeScalars.first.map { $0.isASCII } ?? false
            if !text.isEmpty, isLatin, previousWasLatin { text += " " }
            text += word
            previousWasLatin = isLatin
        }
        return text.isEmpty ? nil : text
    }
}

/// 在 token 串上前进的游标。所有读取都先判界，越界返回 nil。
struct LauncherCalcCursor {
    let tokens: [LauncherCalcToken]
    private(set) var index: Int

    init(_ tokens: [LauncherCalcToken], index: Int = 0) {
        self.tokens = tokens
        self.index = max(0, min(index, tokens.count))
    }

    var atEnd: Bool { index >= tokens.count }
    var current: LauncherCalcToken? { peek(0) }
    var remainingCount: Int { max(0, tokens.count - index) }

    func peek(_ offset: Int) -> LauncherCalcToken? {
        let position = index + offset
        guard position >= 0, position < tokens.count else { return nil }
        return tokens[position]
    }

    mutating func advance(_ count: Int = 1) {
        index = max(0, min(tokens.count, index + count))
    }

    /// 当前是这个符号就吃掉它。
    mutating func take(symbol character: Character) -> Bool {
        guard current?.isSymbol(character) == true else { return false }
        advance()
        return true
    }

    /// 当前是这个词就吃掉它。
    mutating func take(word text: String) -> Bool {
        guard current?.isWord(text) == true else { return false }
        advance()
        return true
    }

    /// 从当前位置起、拼起来在 `phrases` 里的最长一串 word（最多 `maxTokens` 个）：吃掉并返回这个短语。
    mutating func take(phraseIn phrases: Set<String>, maxTokens: Int = 6) -> String? {
        let longest = min(maxTokens, remainingCount)
        guard longest > 0 else { return nil }
        for count in stride(from: longest, through: 1, by: -1) {
            let window = tokens[index..<(index + count)]
            if let phrase = LauncherCalcPhrase.join(window), phrases.contains(phrase) {
                advance(count)
                return phrase
            }
        }
        return nil
    }

    /// 剩下的 token 全是 word、拼起来在 `phrases` 里：吃到底并返回短语；剩下为空返回 ""。
    mutating func takeRest(phraseIn phrases: Set<String>) -> String? {
        if atEnd { return "" }
        guard let phrase = LauncherCalcPhrase.join(tokens[index...]), phrases.contains(phrase) else { return nil }
        index = tokens.count
        return phrase
    }
}
