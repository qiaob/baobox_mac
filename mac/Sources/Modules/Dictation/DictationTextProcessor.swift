import Foundation

/// 听写文字的后处理（docs/dictation/REQUIREMENTS.md §4 第 1–3 步，按顺序）：语音指令 → 口头禅过滤 → 标点规整。
/// 全是纯字符串处理，可单测；第 4 步 AI 润色的提示词与结果把关也在这里，调模型在 `DictationPolisher`。
///
/// 做法：先把语音指令换成私用区的占位符（换行 / 新段落 / 删除上一句），口头禅与标点把占位符当边界处理，
/// 最后 `render` 成真正的文字 ——「删除上一句」删的是已有文字里的最后一句，长听写里能删到收集面板里上一段的末句。
/// 原则是保守：拿不准是不是口头禅 / 指令的，一律原样保留，不改意思。
enum DictationTextProcessor {
    enum Language: Equatable {
        case chinese
        case english
        /// 其他语言：只做语音指令与首尾空白，不过滤口头禅、不动标点。
        case other
    }

    struct Options: Equatable {
        var voiceCommands = true
        var fillerFilter = true
    }

    static let newlineMark: Character = "\u{E000}"
    static let paragraphMark: Character = "\u{E001}"
    static let deleteMark: Character = "\u{E002}"

    // MARK: - 入口

    /// 一次听写（按住说话 / 点按切换）：第 1–3 步，得到要上屏的文字。
    static func process(_ raw: String, language: Language, options: Options) -> String {
        render(prepare(raw, language: language, options: options), into: "")
    }

    /// 第 1–3 步，结果里还留着占位符（长听写拿它接到收集面板已有的文字后面，见 `render`）。
    static func prepare(_ raw: String, language: Language, options: Options) -> String {
        var text = raw
        if options.voiceCommands { text = markCommands(text, language: language) }
        if options.fillerFilter, language != .other {
            let filtered = filterFillers(text, language: language)
            // 整段都是口头禅（比如只「嗯」了一声当回答）：原样保留，不把整句吞掉。
            if hasContent(filtered) || !hasContent(text) { text = filtered }
        }
        return normalize(text, language: language)
    }

    /// 这段里有「删除上一句」（长听写里这样的段不送 AI 润色：润色只看得到这一段，删不到上一段）。
    static func containsDelete(_ prepared: String) -> Bool {
        prepared.contains(deleteMark)
    }

    /// 把 `prepare` 的结果接到 `existing` 后面：占位符换成换行 / 空行，「删除上一句」删掉已有文字的最后一句；
    /// 接缝处英文之间补一个空格，中文不加。
    static func render(_ text: String, into existing: String) -> String {
        var out = existing
        var joinPending = !existing.isEmpty
        var skipSpaces = false
        for ch in text {
            if ch == newlineMark || ch == paragraphMark {
                trimTrailingSpaces(&out)
                if ch == newlineMark {
                    out.append("\n")
                } else if out.hasSuffix("\n\n") {
                    // 已经空着一行了。
                } else if out.hasSuffix("\n") {
                    out.append("\n")
                } else {
                    out.append("\n\n")
                }
                skipSpaces = true
                joinPending = false
                continue
            }
            if ch == deleteMark {
                deleteLastSentence(&out)
                skipSpaces = true
                joinPending = !out.isEmpty
                continue
            }
            if skipSpaces, isHorizontalSpace(ch) { continue }
            skipSpaces = false
            if joinPending {
                joinPending = false
                if let last = out.last, needsSpace(between: last, and: ch) { out.append(" ") }
            }
            out.append(ch)
        }
        return out
    }

    /// 两段识别结果接起来（识别器换段、长听写追加）：英文之间补空格，中文不加。
    static func join(_ first: String, _ second: String) -> String {
        guard let last = first.last else { return second }
        guard let next = second.first else { return first }
        return needsSpace(between: last, and: next) ? first + " " + second : first + second
    }

    /// 删掉最后一句：句末标点（。！？.!?）或换行之后的那一截。不跨行删。
    static func deleteLastSentence(_ text: inout String) {
        var chars = Array(text)
        while let last = chars.last, last.isWhitespace { chars.removeLast() }
        var index = chars.count
        while index > 0, sentenceEnds.contains(chars[index - 1]) || closers.contains(chars[index - 1]) {
            index -= 1
        }
        while index > 0, !sentenceEnds.contains(chars[index - 1]), chars[index - 1] != "\n" {
            index -= 1
        }
        chars.removeSubrange(index..<chars.count)
        while let last = chars.last, isHorizontalSpace(last) { chars.removeLast() }
        text = String(chars)
    }

    // MARK: - 1. 语音指令

    private enum Command {
        case newline
        case paragraph
        case delete
        case punctuation(full: String, ascii: String)
    }

    private static let chineseCommands = regex("删除上一句话?|新的一行|换行|新段落|句号|逗号|问号|感叹号")
    private static let englishCommands = regex("\\b(?:new paragraph|new line|delete (?:the )?last sentence)\\b",
                                               options: [.caseInsensitive])

    private static func command(for word: String) -> Command? {
        switch word.lowercased() {
        case "换行", "新的一行", "new line": return .newline
        case "新段落", "new paragraph": return .paragraph
        case "删除上一句", "删除上一句话", "delete last sentence", "delete the last sentence": return .delete
        case "句号": return .punctuation(full: "。", ascii: ".")
        case "逗号": return .punctuation(full: "，", ascii: ",")
        case "问号": return .punctuation(full: "？", ascii: "?")
        case "感叹号": return .punctuation(full: "！", ascii: "!")
        default: return nil
        }
    }

    /// 前面紧挨着这些字时指令词多半是普通文字：「打个问号」「一个句号」「这是新的一行」。
    private static let literalBeforeChinese: Set<Character> = [
        "个", "一", "打", "画", "加", "的", "用", "写", "是", "这", "那", "此", "该",
    ]
    /// 前面是冠词 / 限定词时是普通文字：「a new line of products」「the new paragraph」。
    private static let literalBeforeEnglish: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "our", "their", "my", "your", "his", "her", "its",
        "another", "every", "each", "any", "no", "one",
    ]

    static func markCommands(_ text: String, language: Language) -> String {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var ranges: [NSRange] = []
        for pattern in [chineseCommands, englishCommands].compactMap({ $0 }) {
            ranges += pattern.matches(in: text, range: whole).map(\.range)
        }
        guard !ranges.isEmpty else { return text }
        let result = NSMutableString(string: text)
        // 从后往前换：前面的位置不受影响；右侧扩展不越过上一个（更靠后的）替换处。
        var rightLimit = ns.length
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            guard range.location + range.length <= rightLimit else { continue }
            let word = ns.substring(with: range)
            guard let command = command(for: word), !isLiteral(command, word: word, range: range, in: ns) else {
                continue
            }
            let span = expand(range, for: command, in: ns, rightLimit: rightLimit)
            result.replaceCharacters(in: span, with: replacement(for: command, language: language))
            rightLimit = span.location
        }
        return result as String
    }

    private static func isLiteral(_ command: Command, word: String, range: NSRange, in ns: NSString) -> Bool {
        let english = word.unicodeScalars.first.map { $0.isASCII } ?? false
        if case .delete = command {
            // 会删东西的指令必须单独说：前面紧挨着别的字（不是开头、标点、空白、换行）就当普通文字。
            if range.location > 0 {
                let before = ns.character(at: range.location - 1)
                if !isBoundaryUnit(before) { return true }
            }
            // 英文的还要求在句首（前面是标点或开头），免得「to delete last sentence」这种普通句子被执行。
            if english, let previous = previousNonSpaceUnit(in: ns, before: range.location),
               !isPauseUnit(previous), !isSentenceEndUnit(previous), !isMarkUnit(previous) {
                return true
            }
            return false
        }
        if english {
            guard let previous = previousWord(in: ns, before: range.location) else { return false }
            return literalBeforeEnglish.contains(previous.lowercased())
        }
        if let unit = previousNonSpaceUnit(in: ns, before: range.location),
           let scalar = Unicode.Scalar(unit), literalBeforeChinese.contains(Character(scalar)) {
            return true
        }
        // 「换行业」是「换个行业」。
        if word == "换行", range.location + range.length < ns.length,
           ns.substring(with: NSRange(location: range.location + range.length, length: 1)) == "业" {
            return true
        }
        return false
    }

    /// 指令连带两边识别器自己加的停顿标点、空白一起换掉。换行 / 新段落 / 删除保留前面的句末标点
    /// （「第一句。换行」→「第一句。⏎」），标点指令连句末标点一起替换。
    private static func expand(_ range: NSRange, for command: Command, in ns: NSString, rightLimit: Int) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        var replacesSentenceEnd = false
        if case .punctuation = command { replacesSentenceEnd = true }
        while start > 0 {
            let unit = ns.character(at: start - 1)
            if isSpaceUnit(unit) || isPauseUnit(unit) || (replacesSentenceEnd && isSentenceEndUnit(unit)) {
                start -= 1
            } else {
                break
            }
        }
        while end < rightLimit {
            let unit = ns.character(at: end)
            if isSpaceUnit(unit) || isPauseUnit(unit) || isSentenceEndUnit(unit) {
                end += 1
            } else {
                break
            }
        }
        return NSRange(location: start, length: end - start)
    }

    private static func replacement(for command: Command, language: Language) -> String {
        switch command {
        case .newline: return String(newlineMark)
        case .paragraph: return String(paragraphMark)
        case .delete: return String(deleteMark)
        case .punctuation(let full, let ascii): return language == .chinese ? full : ascii + " "
        }
    }

    // MARK: - 2. 口头禅过滤

    /// 「嗯、呃、唔」不成词，在哪都去掉（连带后面的停顿标点）。
    private static let zhHesitation = regex("[嗯呃唔]+[，,、\\s]*")
    /// 「额」只在孤立出现时去：前面是开头 / 标点 / 空白，后面是标点 / 空白 / 结尾（「金额」「额外」不动）。
    private static let zhEh = regex("(^|[\\p{P}\\s\\x{E000}-\\x{E002}])额+(?=[\\p{P}\\s]|$)[，,、\\s]*")
    /// 句首孤立的「啊」「那个」（后面跟着停顿）。
    private static let zhLeading = regex("(^|[。.！!？?\\x{E000}-\\x{E002}]\\s*)(?:啊|那个)[，,、\\s]+")
    /// 连说三遍以上的单字（「我我我」）。只收不会叠用成词的字：「哈哈哈」「对对对」「好好好」不动。
    private static let zhRepeatedChar = regex("([我你他她它这那就在要也都把被给跟])\\1{2,}")
    /// 连说两遍以上的常见词（「那个那个」「然后然后」）。
    private static let zhRepeatedWord = regex("(那个|这个|就是|然后|我们|你们|他们|因为|所以|但是|如果|其实)\\1+")
    /// 英文口头禅（整词，连带两边的逗号）；「uh-huh」这种连字符词不动。
    private static let enFiller = regex("(?:,\\s*)?(?<![\\w-])(umm?|uhh?|erm?|hm+)(?![\\w-])(?:\\s*,)?",
                                        options: [.caseInsensitive])
    /// 英文连说的虚词（「the the」）。只收冠词、代词、介词：「very very」「had had」「that that」都是正常说法。
    private static let enRepeated = regex(
        "\\b(the|a|an|i|to|of|and|in|on|at|for|with|it|we|you|he|she|they|my|this)(?:\\s+\\1\\b)+",
        options: [.caseInsensitive])

    static func filterFillers(_ text: String, language: Language) -> String {
        switch language {
        case .chinese:
            var out = replace(zhHesitation, in: text, with: "")
            out = replace(zhEh, in: out, with: "$1")
            out = replace(zhRepeatedChar, in: out, with: "$1")
            out = replace(zhRepeatedWord, in: out, with: "$1")
            for _ in 0..<3 {
                let next = replace(zhLeading, in: out, with: "$1")
                if next == out { break }
                out = next
            }
            return out
        case .english:
            return replace(enRepeated, in: removeEnglishFillers(text), with: "$1")
        case .other:
            return text
        }
    }

    /// 去英文口头禅。句首大写的（「Um, so we…」）去掉后把下一个词的首字母补成大写。
    private static func removeEnglishFillers(_ text: String) -> String {
        guard let enFiller else { return text }
        let ns = text as NSString
        let matches = enFiller.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text as NSString
        for match in matches.reversed() {
            let word = ns.substring(with: match.range(at: 1))
            let capitalized = word.first?.isUppercase ?? false
            let atStart = isSentenceStart(in: ns, at: match.range.location)
            let mutable = NSMutableString(string: result as String)
            mutable.replaceCharacters(in: match.range, with: "")
            if capitalized, atStart {
                capitalizeFirstLetter(in: mutable, from: match.range.location)
            }
            result = mutable
        }
        return result as String
    }

    private static func isSentenceStart(in ns: NSString, at location: Int) -> Bool {
        guard let previous = previousNonSpaceUnit(in: ns, before: location) else { return true }
        return isSentenceEndUnit(previous) || isMarkUnit(previous)
    }

    private static func capitalizeFirstLetter(in text: NSMutableString, from location: Int) {
        var index = location
        while index < text.length {
            let unit = text.character(at: index)
            if let scalar = Unicode.Scalar(unit), CharacterSet.letters.contains(scalar) {
                let letter = text.substring(with: NSRange(location: index, length: 1))
                text.replaceCharacters(in: NSRange(location: index, length: 1), with: letter.uppercased())
                return
            }
            guard isSpaceUnit(unit) else { return }
            index += 1
        }
    }

    // MARK: - 3. 标点规整

    private static let asciiToFull: [Character: Character] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ";": "；", ":": "：",
    ]
    private static let sentenceEnds: Set<Character> = ["。", "！", "？", ".", "!", "?", "…"]
    private static let pauses: Set<Character> = ["，", "、", "；", "：", ",", ";", ":"]
    /// 句末可以替换成句号的停顿标点（冒号多半是有意的，留着）。
    private static let trailingPauses: Set<Character> = ["，", "、", "；", ",", ";"]
    private static let closers: Set<Character> = ["”", "’", "」", "』", "）", ")", "】", "》", "\"", "'"]

    static func normalize(_ text: String, language: Language) -> String {
        var chars = Array(text)
        switch language {
        case .chinese:
            convertToFullWidth(&chars)
            chars = cleanSpaces(chars, language: .chinese)
            chars = cleanCollisions(chars)
            appendTerminal(&chars, chinese: true)
        case .english:
            chars = cleanSpaces(chars, language: .english)
            chars = cleanCollisions(chars)
            appendTerminal(&chars, chinese: false)
        case .other:
            chars = cleanSpaces(chars, language: .other)
        }
        return String(chars)
    }

    /// 中文语境里的半角标点换成全角：挨着汉字的才换；小数点、省略号、时间里的冒号不动。
    private static func convertToFullWidth(_ chars: inout [Character]) {
        for index in chars.indices {
            let ch = chars[index]
            guard let full = asciiToFull[ch] else { continue }
            let previous = neighbor(of: index, in: chars, step: -1)
            let next = neighbor(of: index, in: chars, step: 1)
            let previousCJK = previous.map(isCJK) ?? false
            let nextCJK = next.map(isCJK) ?? false
            switch ch {
            case ".":
                if previous == "." || next == "." { continue }
                if previous?.isNumber == true, next != nil, !nextCJK { continue }
                guard previousCJK || (nextCJK && previous?.isNumber != true) else { continue }
            case ":":
                if previous?.isNumber == true, next?.isNumber == true { continue }
                guard previousCJK || nextCJK else { continue }
            default:
                guard previousCJK || nextCJK else { continue }
            }
            chars[index] = full
        }
    }

    /// 空白：去首尾；中文里汉字之间、全角标点两边的空格去掉（中英之间原样，不乱加也不乱删）；
    /// 中英文标点前的空格去掉（其他语言不动：法语的「Bonjour !」本来就带空格）；连续空格并成一个；
    /// 占位符两边不留空格。
    private static func cleanSpaces(_ chars: [Character], language: Language) -> [Character] {
        var out: [Character] = []
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            guard isHorizontalSpace(ch) else {
                out.append(ch)
                index += 1
                continue
            }
            var end = index
            while end < chars.count, isHorizontalSpace(chars[end]) { end += 1 }
            let previous = out.last
            let next = end < chars.count ? chars[end] : nil
            index = end
            guard let previous, let next else { continue }
            if isMark(previous) || isMark(next) { continue }
            if language == .chinese {
                if isCJK(previous) && isCJK(next) { continue }
                if isFullWidthPunctuation(previous) || isFullWidthPunctuation(next) { continue }
            }
            if language != .other, pauses.contains(next) || sentenceEnds.contains(next) { continue }
            out.append(" ")
        }
        return out
    }

    /// 标点打架（多半是去掉口头禅 / 指令之后留下的）：停顿 + 句末 → 句末；连着的停顿只留一个；
    /// 开头、换行之后的标点去掉；重复的全角句末标点只留一个（英文的点不并：可能是省略号）。
    private static func cleanCollisions(_ chars: [Character]) -> [Character] {
        var out: [Character] = []
        for ch in chars {
            if pauses.contains(ch) {
                guard let last = out.last, !isMark(last), !sentenceEnds.contains(last), !pauses.contains(last) else {
                    continue
                }
                out.append(ch)
            } else if sentenceEnds.contains(ch) {
                guard let last = out.last, !isMark(last) else { continue }
                if pauses.contains(last) {
                    out[out.count - 1] = ch
                } else if last == ch, ch != ".", ch != "…" {
                    continue
                } else {
                    out.append(ch)
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// 整段没有结尾标点就按语言补一个；结尾是逗号之类的换成句号。以换行指令结尾的不补。
    private static func appendTerminal(_ chars: inout [Character], chinese: Bool) {
        guard let lastIndex = chars.lastIndex(where: { !isHorizontalSpace($0) }) else { return }
        let last = chars[lastIndex]
        if isMark(last) || sentenceEnds.contains(last) || last == "：" || last == ":" { return }
        if closers.contains(last), lastIndex > 0, sentenceEnds.contains(chars[lastIndex - 1]) { return }
        guard chars.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        // 中文识别结果里只有英文（「OK」）时补英文句点。
        let useFull = chinese && chars.contains(where: { isCJK($0) && $0.isLetter })
        let terminal: Character = useFull ? "。" : "."
        if trailingPauses.contains(last) {
            chars[lastIndex] = terminal
        } else {
            chars.insert(terminal, at: lastIndex + 1)
        }
    }

    // MARK: - 4. AI 润色（提示词与结果把关）

    /// 太短的不润色：一两个词没什么可整理的，模型反而容易乱改。
    static let polishMinimumLength = 6

    static func polishPrompt(for text: String, language: Language) -> String {
        // 末尾的 /no_think 是 Qwen3 关「思考」的软开关；请求里也带了 enable_thinking = false，双保险。
        if language == .chinese {
            return """
            你是文字整理助手。下面「原文」是一段语音听写的结果，口语化，可能有口头禅、重复和不通顺的地方。
            请把它整理成通顺的书面语：去掉口头禅和无意义的重复，理顺句子，改正明显的同音错字。
            不要增加或删减信息，不要改变原意，不要回答或评论原文的内容，不要翻译，保留原文的换行。
            只输出整理后的文字。

            原文：\(text) /no_think
            """
        }
        return """
        You are a writing assistant. The "Original" below is dictated speech: casual, with filler words, \
        repetitions and rough sentences.
        Rewrite it as clean written text: remove fillers and pointless repetitions, smooth the sentences, \
        fix obviously misrecognized words.
        Do not add or remove information, do not change the meaning, do not answer or comment on the content, \
        do not translate, keep the line breaks.
        Output only the rewritten text.

        Original: \(text) /no_think
        """
    }

    /// 模型给的结果能不能用：去掉思考过程、「整理后：」之类的前缀和包着的引号；长度变化过大、换了语言、
    /// 换行没了的都不用（返回 nil = 上原文）。
    static func acceptPolished(_ raw: String, original: String) -> String? {
        var text = raw
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["整理后：", "整理后:", "输出：", "输出:", "结果：", "结果:", "原文：", "原文:"]
        where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for label in ["rewritten text:", "rewritten:", "output:", "original:"] where text.lowercased().hasPrefix(label) {
            text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("「", "」"), ("“", "”"), ("\"", "\"")] where text.count >= 2 {
            if text.hasPrefix(open), text.hasSuffix(close), !original.hasPrefix(open) {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !text.isEmpty else { return nil }
        let originalLength = max(original.count, 1)
        let ratio = Double(text.count) / Double(originalLength)
        guard ratio >= 0.4, ratio <= 1.3 else { return nil }
        let originalHan = hanRatio(original)
        let polishedHan = hanRatio(text)
        if originalHan >= 0.5, polishedHan < 0.3 { return nil }
        if originalHan < 0.1, polishedHan > 0.3 { return nil }
        let newlines = original.filter { $0 == "\n" }.count
        if newlines > 0, text.filter({ $0 == "\n" }).count < newlines { return nil }
        return text
    }

    /// 字母里汉字的比例（0…1）。
    private static func hanRatio(_ text: String) -> Double {
        var letters = 0
        var han = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if scalar.properties.isIdeographic { han += 1 }
        }
        return letters == 0 ? 0 : Double(han) / Double(letters)
    }

    // MARK: - 小工具

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func replace(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    static func hasContent(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    private static func isHorizontalSpace(_ ch: Character) -> Bool {
        ch == " " || ch == "\t" || ch == "\u{3000}" || ch == "\u{00A0}"
    }

    private static func isMark(_ ch: Character) -> Bool {
        ch == newlineMark || ch == paragraphMark || ch == deleteMark
    }

    private static func trimTrailingSpaces(_ text: inout String) {
        while let last = text.last, isHorizontalSpace(last) { text.removeLast() }
    }

    /// 中日韩文字与全角标点（排版时它们之间不加空格）。
    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0x20000...0x2A6DF).contains(value)
            || (0x3040...0x30FF).contains(value) || (0xAC00...0xD7AF).contains(value)
            || (0x3000...0x303F).contains(value) || (0xFF00...0xFFEF).contains(value)
    }

    private static func isFullWidthPunctuation(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x3000...0x303F).contains(value) || (0xFF00...0xFF0F).contains(value)
            || (0xFF1A...0xFF20).contains(value) || ch == "“" || ch == "”" || ch == "…"
    }

    /// 两段之间要不要补空格：两边都不是中日韩文字、都不是空白，且后一段不以贴左的标点开头。
    private static func needsSpace(between first: Character, and second: Character) -> Bool {
        if first.isWhitespace || second.isWhitespace { return false }
        if isMark(first) || isMark(second) { return false }
        if isCJK(first) || isCJK(second) { return false }
        if ",.!?;:)]}%”’…".contains(second) { return false }
        if "([{“‘".contains(first) { return false }
        return true
    }

    /// 某个位置前 / 后最近的非空白字符。
    private static func neighbor(of index: Int, in chars: [Character], step: Int) -> Character? {
        var cursor = index + step
        while cursor >= 0, cursor < chars.count {
            if !isHorizontalSpace(chars[cursor]) { return chars[cursor] }
            cursor += step
        }
        return nil
    }

    // UTF-16 单元版（NSString 上的指令处理用）。

    private static func isSpaceUnit(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x3000 || unit == 0xA0
    }

    private static func isPauseUnit(_ unit: unichar) -> Bool {
        [0xFF0C, 0x3001, 0xFF1B, 0xFF1A, 0x2C, 0x3B, 0x3A].contains(unit) // ，、；：,;:
    }

    private static func isSentenceEndUnit(_ unit: unichar) -> Bool {
        [0x3002, 0xFF01, 0xFF1F, 0x2E, 0x21, 0x3F, 0x2026].contains(unit) // 。！？.!?…
    }

    private static func isMarkUnit(_ unit: unichar) -> Bool {
        (0xE000...0xE002).contains(unit)
    }

    /// 词与词的分界：空白、换行、标点、占位符。
    private static func isBoundaryUnit(_ unit: unichar) -> Bool {
        if isSpaceUnit(unit) || isPauseUnit(unit) || isSentenceEndUnit(unit) || isMarkUnit(unit) { return true }
        if unit == 0x0A || unit == 0x0D { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.punctuationCharacters.contains(scalar)
    }

    private static func previousNonSpaceUnit(in ns: NSString, before location: Int) -> unichar? {
        var index = location - 1
        while index >= 0 {
            let unit = ns.character(at: index)
            if !isSpaceUnit(unit) { return unit }
            index -= 1
        }
        return nil
    }

    /// 前一个英文单词（跳过空白；遇到标点 / 非字母就没有）。
    private static func previousWord(in ns: NSString, before location: Int) -> String? {
        var end = location
        while end > 0, isSpaceUnit(ns.character(at: end - 1)) { end -= 1 }
        var start = end
        while start > 0 {
            let unit = ns.character(at: start - 1)
            guard let scalar = Unicode.Scalar(unit), scalar.isASCII, CharacterSet.letters.contains(scalar) else { break }
            start -= 1
        }
        guard start < end else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}
