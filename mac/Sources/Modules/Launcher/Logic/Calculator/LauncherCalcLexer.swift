import Foundation

// 计算引擎的归一化与词法（docs/launcher/TECH_DESIGN.md §7）。
// 归一化：全角转半角、× ÷ − 换成 * / -、** 换成 ^、→ 换成 to、去掉变音符号、去掉首尾的 = 和 ?。
// 词法：数字（千分位、小数、科学计数、0x/0b/0o）、日期 `2026-12-25`、钟点 `15:00`、英文词、中文词（按词表切分）、符号。
// 有一个字认不出（不在词表里的汉字、表情、# $ 之类的符号）就整段返回 nil —— 那样的输入不会是算式，后面也不用再试。

enum LauncherCalcLexer {
    /// 单个英文词、单个数字字面量的长度上限：再长就不是人会打的算式。
    private static let maxWordLength = 32
    private static let maxNumberLength = 40

    /// 词法认的符号。逗号、句点、冒号只出现在数字、日期、钟点里面，单独出现就不认。
    private static let symbols: Set<Unicode.Scalar> = ["+", "-", "*", "/", "^", "%", "(", ")", "°", "√", "="]

    /// 后缀倍数：「3万」「1.5亿」「2千」。英文的 k / m 后缀不做（`m` 是米、`k` 是开尔文，会和单位打架）。
    static let multipliers: [String: Decimal] = [
        "万": 10_000, "亿": 100_000_000, "千": 1_000, "百万": 1_000_000, "千万": 10_000_000, "万亿": 1_000_000_000_000,
    ]

    // MARK: - 归一化

    static func normalize(_ input: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E:                          // 全角 ASCII（＋－＊／（）０-９ａ-ｚ％…）
                if let half = Unicode.Scalar(scalar.value - 0xFEE0) { scalars.append(half) }
            case 0x3000: scalars.append(" ")               // 全角空格
            case 0x00D7, 0x2715, 0x2A2F, 0x2217: scalars.append("*")   // × ✕ ⨯ ∗
            case 0x00F7, 0x2215: scalars.append("/")       // ÷ ∕
            case 0x2212, 0x2013, 0x2014: scalars.append("-")           // − – —
            case 0x00BA: scalars.append("°")               // º（常被当度数符号用）
            case 0x2103: scalars.append(contentsOf: "°C".unicodeScalars)   // ℃
            case 0x2109: scalars.append(contentsOf: "°F".unicodeScalars)   // ℉
            case 0x00B2: scalars.append(contentsOf: "^2".unicodeScalars)   // ²
            case 0x00B3: scalars.append(contentsOf: "^3".unicodeScalars)   // ³
            case 0x2192, 0x27F6: scalars.append(contentsOf: " to ".unicodeScalars)  // → ⟶
            case 0x03C0: scalars.append(contentsOf: "pi".unicodeScalars)   // π
            default: scalars.append(scalar)
            }
        }
        var text = String(scalars).folding(options: .diacriticInsensitive, locale: nil)
        text = text.replacingOccurrences(of: "**", with: "^")
            .replacingOccurrences(of: "->", with: " to ")
            .replacingOccurrences(of: "=>", with: " to ")
        // 句末的 = 和 ?（「1+2=」「下周五是几号？」）、开头的 =（表格里的习惯）不影响意思，去掉。
        let edge: Set<Character> = ["=", "?"]
        while let last = text.last, last.isWhitespace || edge.contains(last) { text.removeLast() }
        while let first = text.first, first.isWhitespace || first == "=" { text.removeFirst() }
        return text
    }

    // MARK: - 词法

    /// 整段切成 token；有认不出的字返回 nil。
    static func tokenize(_ input: String) -> [LauncherCalcToken]? {
        let scalars = Array(normalize(input).unicodeScalars)
        var tokens: [LauncherCalcToken] = []
        var index = 0
        var spaceBefore = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.properties.isWhitespace {
                spaceBefore = true
                index += 1
                continue
            }
            if isDigit(scalar) || (scalar == "." && isDigit(at: index + 1, in: scalars)) {
                guard let (token, next) = scanNumeric(scalars, from: index, spaceBefore: spaceBefore) else { return nil }
                tokens.append(token)
                index = next
            } else if isLatinLetter(scalar) {
                var end = index
                while end < scalars.count, isLatinLetter(scalars[end]) || scalars[end] == "_" { end += 1 }
                guard end - index <= maxWordLength else { return nil }
                let raw = String(String.UnicodeScalarView(scalars[index..<end]))
                tokens.append(LauncherCalcToken(kind: .word(raw.lowercased()), raw: raw, spaceBefore: spaceBefore))
                index = end
            } else if isCJK(scalar) {
                var end = index
                while end < scalars.count, isCJK(scalars[end]) { end += 1 }
                let run = String(String.UnicodeScalarView(scalars[index..<end]))
                guard let words = LauncherCalcLexicon.segment(run) else { return nil }
                for (offset, word) in words.enumerated() {
                    tokens.append(LauncherCalcToken(kind: .word(word), raw: word, spaceBefore: offset == 0 && spaceBefore))
                }
                index = end
            } else if symbols.contains(scalar) {
                tokens.append(LauncherCalcToken(kind: .symbol(Character(scalar)), raw: String(scalar),
                                                spaceBefore: spaceBefore))
                index += 1
            } else {
                return nil
            }
            spaceBefore = false
        }
        return mergeMultipliers(tokens)
    }

    // MARK: - 数字、日期、钟点

    private static func scanNumeric(_ s: [Unicode.Scalar], from start: Int,
                                    spaceBefore: Bool) -> (LauncherCalcToken, Int)? {
        if let date = scanDate(s, from: start, spaceBefore: spaceBefore) { return date }
        if let clock = scanClock(s, from: start, spaceBefore: spaceBefore) { return clock }
        if let literal = scanRadixLiteral(s, from: start, spaceBefore: spaceBefore) { return literal }
        return scanDecimal(s, from: start, spaceBefore: spaceBefore)
    }

    /// `2026-12-25` / `2026/12/25`：四位年、同一种分隔符、一到两位的月和日，后面不能再接数字或分隔符。
    private static func scanDate(_ s: [Unicode.Scalar], from start: Int,
                                 spaceBefore: Bool) -> (LauncherCalcToken, Int)? {
        guard let (year, afterYear) = digits(s, from: start, min: 4, max: 4),
              afterYear < s.count, s[afterYear] == "-" || s[afterYear] == "/" else { return nil }
        let separator = s[afterYear]
        guard let (month, afterMonth) = digits(s, from: afterYear + 1, min: 1, max: 2),
              afterMonth < s.count, s[afterMonth] == separator,
              let (day, end) = digits(s, from: afterMonth + 1, min: 1, max: 2),
              isBoundary(at: end, in: s, forbidding: ["-", "/", ".", ":"]) else { return nil }
        let raw = String(String.UnicodeScalarView(s[start..<end]))
        return (LauncherCalcToken(kind: .date(year: year, month: month, day: day), raw: raw, spaceBefore: spaceBefore), end)
    }

    /// `15:00` / `5:30`：一到两位的时、两位的分。
    private static func scanClock(_ s: [Unicode.Scalar], from start: Int,
                                  spaceBefore: Bool) -> (LauncherCalcToken, Int)? {
        guard let (hour, afterHour) = digits(s, from: start, min: 1, max: 2),
              afterHour < s.count, s[afterHour] == ":",
              let (minute, end) = digits(s, from: afterHour + 1, min: 2, max: 2),
              isBoundary(at: end, in: s, forbidding: [":", "."]) else { return nil }
        let raw = String(String.UnicodeScalarView(s[start..<end]))
        return (LauncherCalcToken(kind: .clock(hour: hour, minute: minute), raw: raw, spaceBefore: spaceBefore), end)
    }

    /// `0xff` / `0b1010` / `0o17`。前缀后面紧跟的字母数字必须全是这个进制的数字；不是（`0xg`、`0b102`、
    /// 「0B」= 0 字节）就不当进制字面量，交给十进制那条路 —— 那边切出来的「0」+「xg」不会被任何句型认下。
    private static func scanRadixLiteral(_ s: [Unicode.Scalar], from start: Int,
                                         spaceBefore: Bool) -> (LauncherCalcToken, Int)? {
        guard s[start] == "0", start + 1 < s.count else { return nil }
        let radix: Int
        let maxDigits: Int
        switch s[start + 1] {
        case "x", "X": radix = 16; maxDigits = 16
        case "b", "B": radix = 2; maxDigits = 64
        case "o", "O": radix = 8; maxDigits = 22
        default: return nil
        }
        var end = start + 2
        var text = ""
        while end < s.count, isDigit(s[end]) || isLatinLetter(s[end]) {
            guard let digit = Int(String(s[end]), radix: 36), digit < radix else { return nil }
            text.unicodeScalars.append(s[end])
            end += 1
        }
        guard !text.isEmpty, text.count <= maxDigits, let value = UInt64(text, radix: radix),
              isBoundary(at: end, in: s, forbidding: [".", ":", ","]) else { return nil }
        let raw = String(String.UnicodeScalarView(s[start..<end]))
        let token = LauncherCalcToken(kind: .number(.exact(Decimal(value))), raw: raw, spaceBefore: spaceBefore,
                                      radix: radix)
        return (token, end)
    }

    /// 十进制：整数部分可带千分位逗号（每组正好三位），可带小数和 e 指数。
    /// 数字后面紧跟句点（`1.2.3`、`192.168.1.1`）、不合规的逗号（`1,2`）都整段不认。
    private static func scanDecimal(_ s: [Unicode.Scalar], from start: Int,
                                    spaceBefore: Bool) -> (LauncherCalcToken, Int)? {
        var end = start
        var plain = ""
        let integerStart = end
        while end < s.count, isDigit(s[end]) { plain.unicodeScalars.append(s[end]); end += 1 }
        // 千分位：第一组一到三位，之后每组正好三位。
        if end < s.count, s[end] == ",", end > integerStart {
            guard end - integerStart <= 3 else { return nil }
            while end < s.count, s[end] == "," {
                guard let (_, groupEnd) = digits(s, from: end + 1, min: 3, max: 3),
                      !(groupEnd < s.count && isDigit(s[groupEnd])) else { return nil }
                plain += String(String.UnicodeScalarView(s[(end + 1)..<groupEnd]))
                end = groupEnd
            }
        }
        if end < s.count, s[end] == "." {
            guard isDigit(at: end + 1, in: s) else { return nil }
            plain += "."
            end += 1
            while end < s.count, isDigit(s[end]) { plain.unicodeScalars.append(s[end]); end += 1 }
        }
        if plain.hasPrefix(".") { plain = "0" + plain }
        // 指数：e 后面必须紧跟数字（或正负号再数字），否则 e 是下一个词（`5em`、`2e`）。
        if end < s.count, s[end] == "e" || s[end] == "E" {
            var cursor = end + 1
            var exponent = "e"
            if cursor < s.count, s[cursor] == "+" || s[cursor] == "-" {
                exponent.unicodeScalars.append(s[cursor])
                cursor += 1
            }
            if isDigit(at: cursor, in: s) {
                while cursor < s.count, isDigit(s[cursor]) { exponent.unicodeScalars.append(s[cursor]); cursor += 1 }
                plain += exponent
                end = cursor
            }
        }
        guard end - start <= maxNumberLength, isBoundary(at: end, in: s, forbidding: [".", ",", ":"]) else { return nil }
        guard let value = decimalValue(plain) else { return nil }
        let raw = String(String.UnicodeScalarView(s[start..<end]))
        return (LauncherCalcToken(kind: .number(value), raw: raw, spaceBefore: spaceBefore), end)
    }

    /// 字面量的值：Decimal 表示得了就用精确值，否则（`1e300`）退成 Double。
    private static func decimalValue(_ plain: String) -> LauncherCalcValue? {
        let posix = Locale(identifier: "en_US_POSIX")
        if let decimal = Decimal(string: plain, locale: posix), !decimal.isNaN { return .exact(decimal) }
        // 连 Double 都放不下（`1e999`）的字面量不是人会打的数，整段不认。
        guard let double = Double(plain), double.isFinite else { return nil }
        return .approx(double)
    }

    /// 从 `start` 起连续 `min...max` 个数字（多一个都不行）。
    private static func digits(_ s: [Unicode.Scalar], from start: Int, min: Int, max: Int) -> (Int, Int)? {
        var end = start
        var text = ""
        while end < s.count, isDigit(s[end]), end - start < max {
            text.unicodeScalars.append(s[end])
            end += 1
        }
        guard text.count >= min, !(end < s.count && isDigit(s[end])), let value = Int(text) else { return nil }
        return (value, end)
    }

    /// `index` 处是结尾，或不是数字、也不是 `forbidden` 里的字。
    private static func isBoundary(at index: Int, in s: [Unicode.Scalar], forbidding forbidden: Set<Unicode.Scalar>) -> Bool {
        guard index < s.count else { return true }
        return !isDigit(s[index]) && !forbidden.contains(s[index])
    }

    // MARK: - 合并后缀倍数

    /// 「3万」「1.5 亿」：十进制数字后面跟倍数词，乘进去合成一个数字。
    private static func mergeMultipliers(_ tokens: [LauncherCalcToken]) -> [LauncherCalcToken] {
        var merged: [LauncherCalcToken] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.radix == 10, case .number(.exact(let value)) = token.kind,
               index + 1 < tokens.count, let word = tokens[index + 1].word, let factor = multipliers[word] {
                let product = value * factor
                if !product.isNaN {
                    merged.append(LauncherCalcToken(kind: .number(.exact(product)), raw: token.raw + word,
                                                    spaceBefore: token.spaceBefore))
                    index += 2
                    continue
                }
            }
            merged.append(token)
            index += 1
        }
        return merged
    }

    // MARK: - 字符类

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }

    private static func isDigit(at index: Int, in s: [Unicode.Scalar]) -> Bool {
        index >= 0 && index < s.count && isDigit(s[index])
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF) || (scalar.value >= 0x3400 && scalar.value <= 0x4DBF)
    }
}

/// 中文词表：各句型认的中文词的并集，用来把一段连续的汉字切成词。
enum LauncherCalcLexicon {
    static let words: Set<String> = {
        var words = Set(LauncherCalcLexer.multipliers.keys)
        words.formUnion(LauncherCalcUnitTable.cjkNames)
        words.formUnion(LauncherCalcUnitConversion.cjkWords)
        words.formUnion(LauncherCalcBase.cjkWords)
        words.formUnion(LauncherCalcTimestamp.cjkWords)
        words.formUnion(LauncherCalcDates.cjkWords)
        words.formUnion(LauncherCalcTimeZones.cjkWords)
        words.formUnion(LauncherCalcPercent.cjkWords)
        words.formUnion(LauncherCalcArithmetic.cjkWords)
        return words.filter { word in word.unicodeScalars.allSatisfy(LauncherCalcLexer.isCJK) }
    }()

    static let maxWordLength: Int = words.map(\.count).max() ?? 1

    /// 把一段汉字切成词表里的词：每一步先试最长的，走不通就回退试短的（「现在的时间戳」不能被「现在的时间」+「戳」卡住）。
    /// 切不完整（有不在词表里的字）返回 nil。
    static func segment(_ run: String) -> [String]? {
        let characters = Array(run)
        var failed = Set<Int>()
        func split(from start: Int) -> [String]? {
            if start == characters.count { return [] }
            if failed.contains(start) { return nil }
            let longest = min(maxWordLength, characters.count - start)
            for length in stride(from: longest, through: 1, by: -1) {
                let word = String(characters[start..<(start + length)])
                guard words.contains(word), let rest = split(from: start + length) else { continue }
                return [word] + rest
            }
            failed.insert(start)
            return nil
        }
        return split(from: 0)
    }
}
