import Foundation

// 快速入口的匹配打分（docs/launcher/TECH_DESIGN.md §5.1）。
// 候选的文本预先算好三份（`LauncherSearchKey`：小写原文、拼音全拼、拼音首字母），每次按键只拿查询（`LauncherMatchQuery`）
// 去比、不再转拼音；`LauncherMatch.score` 给出匹配分（1000 / 800 / 600 / 400 / 200 五档，档内按长度和间隔扣分），
// nil = 不匹配。只依赖 Foundation，进 BaoboxTests。

// MARK: - 可搜索文本

/// 一段可搜索文本预处理后的样子。建一次（面板呼出、来源数据变化时），按键时只读。
/// 纯值、`Sendable`：以后查询挪到后台队列时可以直接带过去。
struct LauncherSearchKey: Equatable, Sendable {

    /// 一份文本：逐个 Unicode 标量（已转小写），以及每个位置是不是词首。
    struct Variant: Equatable, Sendable {
        let scalars: [UInt32]
        /// 与 `scalars` 等长。
        let wordStarts: [Bool]

        /// 拼回字符串（测试与调试用）。
        var text: String {
            var view = String.UnicodeScalarView()
            for value in scalars {
                if let scalar = Unicode.Scalar(value) { view.append(scalar) }
            }
            return String(view)
        }
    }

    /// 小写原文：保留空格与标点；词首在转小写之前算好（大小写边界要看原来的大小写）。
    let original: Variant
    /// 拼音全拼：汉字换成不带声调的拼音（ü 写成 v），其余字母数字原样小写，去掉空格与标点。
    /// 每个音节、每个英文词的开头是词首。文本里没有汉字、或建的时候关了拼音时为 nil。
    let fullPinyin: Variant?
    /// 拼音首字母：每个汉字取拼音的第一个字母，汉字以外的字母数字原样保留（「QQ音乐」→ `qqyy`）。nil 的条件同上。
    let initials: Variant?
    /// 三份文本里出现过的字符的位图（与 `LauncherMatchQuery.mask` 同一算法）：查询里有它没有的字符，就一定不匹配。
    let mask: UInt64

    /// 原文的长度（标量数）。排序同分时短的在前。
    var length: Int { original.scalars.count }

    /// - Parameter pinyin: 文本里有汉字时要不要算拼音两份。转拼音每个汉字约 6–8 µs，
    ///   长文本（剪贴板）多的时候由调用方决定关掉。
    init(_ text: String, pinyin: Bool = true) {
        let source = Array(text.unicodeScalars)

        // 1. 每个字符的类别与是否词首。组合附加符号跟着前一个字，不当词首，也不改变「前一个字」。
        var classes: [CharClass] = []
        var starts: [Bool] = []
        classes.reserveCapacity(source.count)
        starts.reserveCapacity(source.count)
        var previous: CharClass?
        var hasHan = false
        for scalar in source {
            let cls = CharClass(scalar)
            classes.append(cls)
            if cls == .mark {
                starts.append(false)
                continue
            }
            starts.append(Self.isWordStart(cls, after: previous))
            previous = cls
            if cls == .ideograph { hasHan = true }
        }

        // 2. 小写原文（逐字转小写，词首跟着原来的位置走）。
        var builder = LauncherSearchTextBuilder(capacity: source.count)
        for index in source.indices {
            builder.appendLowercased(source[index], start: starts[index])
        }
        let original = builder.variant

        // 3. 拼音两份。
        var fullPinyin: Variant?
        var initials: Variant?
        if pinyin && hasHan {
            (fullPinyin, initials) = Self.makePinyin(source, classes: classes, starts: starts)
        }

        var mask: UInt64 = 0
        for variant in [original, fullPinyin, initials] {
            for value in variant?.scalars ?? [] { mask |= Self.maskBit(value) }
        }

        self.original = original
        self.fullPinyin = fullPinyin
        self.initials = initials
        self.mask = mask
    }

    // MARK: 字符类别与词首

    /// 判断词首用的字符类别。
    fileprivate enum CharClass: Equatable {
        /// 空格、标点、符号：不进拼音两份；它后面的第一个字是词首。
        case separator
        case lower
        case upper
        case digit
        /// 汉字（CJK 表意文字）。
        case ideograph
        /// 其余没有大小写的文字（假名、韩文……）。
        case otherLetter
        /// 组合附加符号（分解形式的声调、重音）。
        case mark

        init(_ scalar: Unicode.Scalar) {
            let value = scalar.value
            if value < 0x80 {
                switch value {
                case 0x61...0x7A: self = .lower
                case 0x41...0x5A: self = .upper
                case 0x30...0x39: self = .digit
                default: self = .separator
                }
                return
            }
            let properties = scalar.properties
            if properties.isIdeographic {
                self = .ideograph
                return
            }
            switch properties.generalCategory {
            case .uppercaseLetter, .titlecaseLetter: self = .upper
            case .lowercaseLetter: self = .lower
            case .otherLetter, .modifierLetter: self = .otherLetter
            case .decimalNumber, .letterNumber, .otherNumber: self = .digit
            case .nonspacingMark, .spacingMark, .enclosingMark: self = .mark
            default: self = .separator
            }
        }

        /// 「不同家族之间换了」就是词首：英文字母 / 数字 / 汉字 / 其余文字。
        var family: Int {
            switch self {
            case .lower, .upper: return 0
            case .digit: return 1
            case .ideograph: return 2
            case .otherLetter: return 3
            case .separator, .mark: return 4
            }
        }
    }

    /// 词首规则（§5.1）：开头；空格、`-_/.` 等标点之后；每个大写字母（`VSCode` 的 V、S、C 都算）；
    /// 字母 ↔ 数字 ↔ 汉字之间换了（`Office365` 的 3、`QQ音乐` 的「音」）。汉字接汉字不算 —— 中文没有分词。
    fileprivate static func isWordStart(_ cls: CharClass, after previous: CharClass?) -> Bool {
        if cls == .separator || cls == .mark { return false }
        guard let previous, previous != .separator else { return true }
        if cls == .upper { return true }
        return cls.family != previous.family
    }

    /// 字符 → 位图的一位：a–z 各占一位，0–9 各占一位，其余字符按码点散到剩下的 28 位。
    static func maskBit(_ value: UInt32) -> UInt64 {
        switch value {
        case 0x61...0x7A: return 1 << UInt64(value - 0x61)
        case 0x30...0x39: return 1 << UInt64(26 + value - 0x30)
        default: return 1 << UInt64(36 + value % 28)
        }
    }

    // MARK: 拼音

    /// 按「汉字连成的一段」转拼音：汉字段一次交给系统转换，其余字母数字原样小写进两份，空格标点丢掉。
    private static func makePinyin(_ source: [Unicode.Scalar], classes: [CharClass],
                                   starts: [Bool]) -> (Variant, Variant) {
        var full = LauncherSearchTextBuilder(capacity: source.count * 3)
        var initials = LauncherSearchTextBuilder(capacity: source.count)
        var index = 0
        while index < source.count {
            if classes[index] == .ideograph {
                var end = index
                while end < source.count && classes[end] == .ideograph { end += 1 }
                for syllable in LauncherPinyin.syllables(for: source[index..<end]) {
                    guard let first = syllable.first else { continue }
                    for (offset, value) in syllable.enumerated() {
                        full.append(value, start: offset == 0)
                    }
                    initials.append(first, start: true)
                }
                index = end
            } else {
                if classes[index] != .separator {
                    full.appendLowercased(source[index], start: starts[index])
                    initials.appendLowercased(source[index], start: starts[index])
                }
                index += 1
            }
        }
        return (full.variant, initials.variant)
    }
}

/// 逐字拼 `LauncherSearchKey.Variant`，查询也用它转小写。
fileprivate struct LauncherSearchTextBuilder {
    private(set) var scalars: [UInt32] = []
    private(set) var starts: [Bool] = []

    init(capacity: Int) {
        scalars.reserveCapacity(capacity)
        starts.reserveCapacity(capacity)
    }

    mutating func append(_ value: UInt32, start: Bool) {
        scalars.append(value)
        starts.append(start)
    }

    /// 逐字转小写：ASCII 直接算，其余查 Unicode 属性；一个字变成几个字时（`İ`）词首记在第一个上。
    mutating func appendLowercased(_ scalar: Unicode.Scalar, start: Bool) {
        let value = scalar.value
        if value < 0x80 {
            append((0x41...0x5A).contains(value) ? value + 0x20 : value, start: start)
            return
        }
        let properties = scalar.properties
        guard properties.changesWhenLowercased else {
            append(value, start: start)
            return
        }
        var first = true
        for lower in properties.lowercaseMapping.unicodeScalars {
            append(lower.value, start: first && start)
            first = false
        }
        if first { append(value, start: start) }
    }

    var variant: LauncherSearchKey.Variant {
        LauncherSearchKey.Variant(scalars: scalars, wordStarts: starts)
    }
}

/// 汉字 → 拼音音节。
fileprivate enum LauncherPinyin {

    /// 一段连续汉字的拼音，一个汉字一个音节（小写、不带声调、ü 写成 v）。
    /// 系统转换（ICU 的 Han-Latin）按字取最常见的读音，转出来的音节数和字数对得上时再用 `overrides` 纠正常用词里的多音字。
    static func syllables(for run: ArraySlice<Unicode.Scalar>) -> [[UInt32]] {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: run)
        guard let latin = String(view).applyingTransform(.mandarinToLatin, reverse: false) else {
            return run.map { [$0.value] }   // 转不了：每个字原样当一个「音节」
        }
        // 分解后丢掉组合符号 = 去声调（等同 `.stripDiacritics`），顺手把 u + 分音符换成 v。
        var syllables: [[UInt32]] = []
        var current: [UInt32] = []
        for scalar in latin.decomposedStringWithCanonicalMapping.unicodeScalars {
            let value = scalar.value
            let properties = scalar.properties
            if properties.isWhitespace {
                if !current.isEmpty { syllables.append(current) }
                current = []
                continue
            }
            if value == 0x0308, current.last == 0x75 {   // ü → v（拼音输入法的习惯：lv、nv）
                current[current.count - 1] = 0x76
                continue
            }
            if properties.generalCategory == .nonspacingMark { continue }
            current.append((0x41...0x5A).contains(value) ? value + 0x20 : value)
        }
        if !current.isEmpty { syllables.append(current) }
        if syllables.count == run.count {
            applyOverrides(run.map(\.value), to: &syllables)
        }
        return syllables
    }

    private static func applyOverrides(_ characters: [UInt32], to syllables: inout [[UInt32]]) {
        var index = 0
        while index < characters.count {
            let hit = overrideIndex[characters[index]]?.first { entry in
                index + entry.phrase.count <= characters.count
                    && characters[index..<(index + entry.phrase.count)].elementsEqual(entry.phrase)
            }
            guard let hit else {
                index += 1
                continue
            }
            for offset in hit.phrase.indices {
                syllables[index + offset] = hit.syllables[offset]
            }
            index += hit.phrase.count
        }
    }

    private struct Override: Sendable {
        let phrase: [UInt32]
        let syllables: [[UInt32]]
    }

    /// 按首字索引，同一个首字的条目长的在前（「重命名」先于「重」）。
    private static let overrideIndex: [UInt32: [Override]] = {
        var index: [UInt32: [Override]] = [:]
        for (phrase, reading) in overrides {
            let characters = phrase.unicodeScalars.map(\.value)
            let syllables = reading.split(separator: " ").map { $0.unicodeScalars.map(\.value) }
            guard let first = characters.first, characters.count == syllables.count else { continue }
            index[first, default: []].append(Override(phrase: characters, syllables: syllables))
        }
        for key in index.keys {
            index[key]?.sort { $0.phrase.count > $1.phrase.count }
        }
        return index
    }()

    /// 多音字纠正表。系统转换读错、而在 App 名、系统设置、Baobox 命令、常见界面用词里常见的词；
    /// 单字条目是在这些场合几乎总读这个音的字（「地」除了做助词都读 di）。读音用空格分音节，音节数必须等于字数。
    private static let overrides: [String: String] = [
        "地": "di",
        "音乐": "yin yue", "乐器": "yue qi", "乐队": "yue dui", "乐曲": "yue qu", "声乐": "sheng yue",
        "银行": "yin hang", "行业": "hang ye", "行情": "hang qing", "行距": "hang ju", "行高": "hang gao",
        "行号": "hang hao", "换行": "huan hang", "单行": "dan hang", "多行": "duo hang", "首行": "shou hang",
        "重新": "chong xin", "重启": "chong qi", "重复": "chong fu", "重试": "chong shi", "重置": "chong zhi",
        "重命名": "chong ming ming", "重做": "chong zuo", "重播": "chong bo", "重叠": "chong die",
        "重连": "chong lian", "重装": "chong zhuang", "重来": "chong lai", "重开": "chong kai",
        "重写": "chong xie", "重载": "chong zai", "重发": "chong fa", "重放": "chong fang", "重建": "chong jian",
        "长截": "chang jie", "长按": "chang an", "长度": "chang du", "长期": "chang qi", "长城": "chang cheng",
        "长江": "chang jiang", "长图": "chang tu", "长文": "chang wen", "长时间": "chang shi jian",
        "调整": "tiao zheng", "调节": "tiao jie", "微调": "wei tiao", "调色": "tiao se", "调试": "tiao shi",
        "空调": "kong tiao", "调光": "tiao guang", "调音": "tiao yin", "调亮": "tiao liang", "调暗": "tiao an",
        "调高": "tiao gao", "调低": "tiao di", "调大": "tiao da", "调小": "tiao xiao",
        "番茄": "fan qie", "茄子": "qie zi",
        "还原": "huan yuan", "归还": "gui huan", "还款": "huan kuan",
        "了解": "liao jie",
        "睡觉": "shui jiao",
        "便宜": "pian yi",
        "弹出": "tan chu", "弹窗": "tan chuang", "弹框": "tan kuang", "弹性": "tan xing",
        "校验": "jiao yan", "校对": "jiao dui", "校正": "jiao zheng", "校准": "jiao zhun",
        "模板": "mu ban", "模具": "mu ju",
        "曝光": "bao guang",
        "拓展": "tuo zhan", "拓扑": "tuo pu", "开拓": "kai tuo",
        "角色": "jue se",
        "成都": "cheng du", "首都": "shou du", "都市": "du shi",
        "厦门": "xia men",
    ]
}

// MARK: - 查询

/// 一次按键的查询，预处理一次、拿去和所有候选比。
struct LauncherMatchQuery: Equatable, Sendable {
    /// 去首尾空白、逐字转小写后的标量。
    let scalars: [UInt32]
    /// 查询里出现的字符的位图（算法同 `LauncherSearchKey.mask`）。
    let mask: UInt64
    /// 全是 ASCII：只有这时才和拼音全拼比（拼音两份只有 ASCII 字母和原文里的字母数字）。
    let isASCII: Bool
    /// 全是 ASCII 字母且不少于 2 个：只有这时才和拼音首字母比，避免一两个字母就误中一大片（§5.1）。
    let allowsInitials: Bool

    var isEmpty: Bool { scalars.isEmpty }

    init(_ text: String) {
        var builder = LauncherSearchTextBuilder(capacity: text.unicodeScalars.count)
        for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            builder.appendLowercased(scalar, start: false)
        }
        let scalars = builder.scalars
        var mask: UInt64 = 0
        var isASCII = true
        var allLetters = true
        for value in scalars {
            mask |= LauncherSearchKey.maskBit(value)
            if value >= 0x80 { isASCII = false }
            if !(0x61...0x7A).contains(value) { allLetters = false }
        }
        self.scalars = scalars
        self.mask = mask
        self.isASCII = isASCII
        self.allowsInitials = allLetters && scalars.count >= LauncherMatch.initialsMinimumLength
    }
}

// MARK: - 打分

/// 匹配打分（§5.1）。
///
/// | 档 | 基础分 | 档内扣分 |
/// |---|---|---|
/// | 完全相等 | 1000 | 不扣 |
/// | 开头匹配 | 800 | 原文比查询每多 1 个字扣 1 分，最多扣 100 |
/// | 词首匹配 | 600 | 同上 |
/// | 连续子串 | 400 | 同上 |
/// | 按顺序跳字 | 200 | 跳过的字每个扣 4 分（最多 110），原文每多 1 个字扣 1 分（最多 40）；最低 50 |
///
/// 扣分封顶保证不会掉到下一档。三份文本各算一次取最高；拼音两份只认从音节开头起的匹配（完全相等 / 开头 / 词首），
/// 不认音节中间的子串和跳字 —— 否则 `an` 会中所有带「an」韵母的中文。跳字只在原文上算。
enum LauncherMatch {
    static let exactScore = 1000
    static let prefixScore = 800
    static let wordStartScore = 600
    static let substringScore = 400
    static let fuzzyScore = 200
    /// 连续子串那一档扣满长度惩罚后的最低分（400 − 100 = 300）。不低于它的都至少「包含这段字」，
    /// 低于它的只可能是按顺序跳字（跳字最高 200 减扣分）—— 排序按来源设最低匹配分时用它当门槛。
    static let substringMinimumScore = substringScore - lengthPenaltyCap
    /// 查询为空时的匹配分：不过滤，每个候选都算命中、匹配分 0，排序只看使用分。
    static let emptyQueryScore = 0

    static let lengthPenaltyCap = 100
    static let fuzzyGapPenaltyPerCharacter = 4
    static let fuzzyGapPenaltyCap = 110
    static let fuzzyLengthPenaltyCap = 40
    /// 拼音首字母参与匹配要求的最少字母数。
    static let initialsMinimumLength = 2

    /// 查询和一个搜索键的匹配分；nil = 不匹配。查询为空返回 `emptyQueryScore`。
    static func score(_ query: LauncherMatchQuery, in key: LauncherSearchKey) -> Int? {
        if query.isEmpty { return emptyQueryScore }
        guard query.mask & ~key.mask == 0 else { return nil }
        return query.scalars.withUnsafeBufferPointer { q -> Int? in
            var best = score(q, in: key.original, loose: true)
            if best == exactScore { return best }
            if query.isASCII, let full = key.fullPinyin {
                best = higher(best, score(q, in: full, loose: false))
                if best == exactScore { return best }
            }
            if query.allowsInitials, let initials = key.initials {
                best = higher(best, score(q, in: initials, loose: false))
            }
            return best
        }
    }

    /// 一个候选有几个搜索键（标题、关键词、英文名……）时取最高。
    static func score(_ query: LauncherMatchQuery, in keys: [LauncherSearchKey]) -> Int? {
        if query.isEmpty { return emptyQueryScore }
        var best: Int?
        for key in keys {
            best = higher(best, score(query, in: key))
            if best == exactScore { break }
        }
        return best
    }

    private static func higher(_ a: Int?, _ b: Int?) -> Int? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

    /// 一份文本的匹配分。`loose` = 允许连续子串与跳字（只有原文允许）。
    private static func score(_ q: UnsafeBufferPointer<UInt32>, in variant: LauncherSearchKey.Variant,
                              loose: Bool) -> Int? {
        let m = q.count
        let n = variant.scalars.count
        guard m > 0, m <= n else { return nil }
        let lengthPenalty = min(lengthPenaltyCap, n - m)
        return variant.scalars.withUnsafeBufferPointer { t -> Int? in
            variant.wordStarts.withUnsafeBufferPointer { starts -> Int? in
                // 连续出现：开头 > 词首 > 中间。开头只可能在 0，找到词首就是剩下最好的，直接返回。
                let first = q[0]
                var foundInside = false
                var i = 0
                while i <= n - m {
                    if t[i] == first {
                        var k = 1
                        while k < m && t[i + k] == q[k] { k += 1 }
                        if k == m {
                            if i == 0 { return m == n ? exactScore : prefixScore - lengthPenalty }
                            if starts[i] { return wordStartScore - lengthPenalty }
                            foundInside = true
                        }
                    }
                    i += 1
                }
                guard loose else { return nil }
                if foundInside { return substringScore - lengthPenalty }
                guard m >= 2 else { return nil }

                // 按顺序跳字：先从左往右贪心找到最早的结尾，再从结尾往回贪心收紧开头，得到一个较紧的窗口。
                var j = 0
                var end = -1
                i = 0
                while i < n {
                    if t[i] == q[j] {
                        j += 1
                        if j == m {
                            end = i
                            break
                        }
                    }
                    i += 1
                }
                guard end >= 0 else { return nil }
                var k = m - 1
                var start = end
                i = end
                while i >= 0 {
                    if t[i] == q[k] {
                        if k == 0 {
                            start = i
                            break
                        }
                        k -= 1
                    }
                    i -= 1
                }
                let gap = end - start + 1 - m
                let gapPenalty = min(fuzzyGapPenaltyCap, gap * fuzzyGapPenaltyPerCharacter)
                return fuzzyScore - gapPenalty - min(fuzzyLengthPenaltyCap, n - m)
            }
        }
    }
}
