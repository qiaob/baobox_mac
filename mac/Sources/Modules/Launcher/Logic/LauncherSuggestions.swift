import Foundation

// 快速入口的建议（docs/launcher/TECH_DESIGN.md §5.4）：输入不为空时列表里总有「可以拿这段东西做什么」。
// - 对应建议：按输入的类别固定排在最前（计算结果之后）—— 网址「打开」、邮箱「写邮件」、颜色的三种写法、一大段文字的字数。
// - 兜底建议：排在普通结果之后的一组 —— 各模块声明的文字动作（翻译、解释、总结、存为片段……）和快速入口自己的
//   「上网搜」「搜文件」，按「适用哪几类、默认优先级、用得多不多」排，最多 8 行。
// 这里是规则：什么时候出哪些、怎么排、标题里的引用怎么截断、搜索引擎表；纯值、只依赖 Foundation，进 BaoboxTests。
// 换成面板的行（文案、图标、执行）在 App 侧 `Providers/SuggestionProvider.swift`。打字时只做内存里的计算，不调模型、不联网、不读盘。

/// 固定排在最前的一条「对应建议」。
enum LauncherLeadingSuggestion: Equatable, Sendable {
    /// 用浏览器（默认 App）打开。
    case openURL(URL)
    /// 写邮件（`mailto:`）。
    case email(String)
    /// 颜色：HEX / RGB / HSL 三行，⏎ 复制该写法。
    case color(LauncherColor)
    /// 一大段文字的字数，⏎ 复制字数。
    case wordCount(LauncherTextStats)
    /// 像命令（第 10 步）：「在终端里运行」，排在兜底建议第一条，要按两次 ⏎。值是要跑的命令（`$ ` 已去掉）。
    case runInTerminal(String)
    /// 带时间的句子（第 10 步）：「14:35 提醒我：取快递」，排在最前（计算结果那个位置）。
    case reminder(LauncherReminderDraft)
}

/// 这次输入出哪些建议。
struct LauncherSuggestionPlan: Equatable, Sendable {
    /// 去首尾空白后的输入：执行时交给动作的就是它。
    let text: String
    let leading: [LauncherLeadingSuggestion]
    /// 兜底建议按这些类别筛选、提前；nil = 不出兜底建议。
    let fallbackKinds: Set<LauncherTextKind>?
    /// 排在兜底建议最前面的（在翻译前面）：「在终端里运行」、有歧义的网址（`claude.ai`、`Safari.app`）的「打开」放这里，不排最前。
    var fallbackLeading: [LauncherLeadingSuggestion] = []
    /// 排在所有建议、固定的文件行之前的（计算结果那个位置；两者不会同时有）：带时间的句子的「到时提醒我」（第 10 步）。
    var top: [LauncherLeadingSuggestion] = []
    /// 输入是「提醒」/「reminders」：列出还没到点的提醒（每条一行，⏎ 取消，第 10 步）。
    var showsReminders = false

    static let none = LauncherSuggestionPlan(text: "", leading: [], fallbackKinds: nil)

    /// 兜底建议里交给排序的最多几行：总数仍是 `LauncherSuggestionRanking.maxRows`，排在最前面的那几条占掉名额。
    var rankedFallbackLimit: Int {
        max(0, LauncherSuggestionRanking.maxRows - fallbackLeading.count)
    }
}

enum LauncherSuggestionPolicy {
    /// 输入不足这么多个字符时不出兜底建议（一个字几乎都是在搜东西）。
    static let minimumFallbackLength = 2

    /// 规则：
    /// - 打了来源前缀（`a `、`c `、`> `…）、输入为空、输入是路径（以 `/` 或 `~` 开头）：什么都不出。
    /// - 有计算结果：不出对应建议，兜底建议照出（按普通文字）、排在最后。
    /// - 网址 / 邮箱 / 颜色：出对应的那一条（有文本识别结果时也出：「打开」比 URL 的参数表更像是要做的事）。
    ///   有歧义的网址（可能是文件名：`Safari.app`、`logo.ai`）不排最前，「打开」改成兜底建议的第一条，兜底建议按普通文字。
    /// - 一大段文字：出字数，兜底建议里总结、润色提前；但有文本识别结果时（长串 JSON、Base64、JWT）按普通文字算。
    /// - 英文单词 / 短语：没有对应建议，兜底建议里「学习」提前。
    /// - 兜底建议要输入不少于 2 个字符。
    /// - `placed`：放进来的原文（⌘V、拖放、「选中的 / 刚复制的」），控制器已经核对过输入框里的文字还是它（空白归一后相等，
    ///   `LauncherPlacedText.matches`；一改动就不再交进来）。带换行的按原文分类、算字数、交给动作 —— 多行的原文算一大段文字；
    ///   单行的和输入框里的一样。这里只读它放进来时算好的 `suggestionText`，不再归一。
    /// - 像命令（第 10 步）：兜底建议第一条是「在终端里运行」（占一个名额）。带时间的句子：最前面一行「到时提醒我」。
    ///   有计算结果时这两样都不出。输入是「提醒」/「reminders」时 `showsReminders`。分类读的同上：单行的放进来的文字就是输入框里的，
    ///   照常认；带换行的原文不是一条命令。
    /// - `clock`：认「带时间的句子」用的「现在」、日历、时区；nil = 不认。
    static func plan(for query: LauncherQuery, hasCalculation: Bool, hasRecognition: Bool,
                     placed: LauncherPlacedText? = nil, clock: LauncherCalcContext? = nil) -> LauncherSuggestionPlan {
        guard query.isUnscoped, !query.text.isEmpty else { return .none }
        let source = placed?.suggestionText ?? query.text
        let input = LauncherInputClassifier.classify(source, clock: hasCalculation ? nil : clock)
        guard !input.isPath, !input.kinds.isEmpty else { return .none }
        // 数到第 2 个字符就够了，几 MB 的粘贴也不用整段数。
        let allowsFallback = input.text.index(input.text.startIndex, offsetBy: minimumFallbackLength,
                                              limitedBy: input.text.endIndex) != nil
        let showsReminders = LauncherReminderBook.isListQuery(input.text)
        if hasCalculation {
            var plan = LauncherSuggestionPlan(text: input.text, leading: [],
                                              fallbackKinds: allowsFallback ? [.plainText] : nil)
            plan.showsReminders = showsReminders
            return plan
        }
        var leading: [LauncherLeadingSuggestion] = []
        var fallbackLeading: [LauncherLeadingSuggestion] = []
        var top: [LauncherLeadingSuggestion] = []
        var kinds = input.kinds
        if let command = input.command {
            fallbackLeading.append(.runInTerminal(command))
        }
        if let reminder = input.reminder {
            top.append(.reminder(reminder))
        }
        if let url = input.url {
            if input.isAmbiguousURL {
                fallbackLeading.append(.openURL(url))
            } else {
                leading.append(.openURL(url))
            }
        } else if let email = input.email {
            leading.append(.email(email))
        } else if let color = input.color {
            leading.append(.color(color))
        } else if input.kinds.contains(.longText) {
            if hasRecognition {
                kinds = [.plainText]
            } else {
                leading.append(.wordCount(LauncherTextStats.count(input.text)))
            }
        }
        return LauncherSuggestionPlan(text: input.text, leading: leading, fallbackKinds: allowsFallback ? kinds : nil,
                                      fallbackLeading: allowsFallback ? fallbackLeading : [], top: top,
                                      showsReminders: showsReminders)
    }
}

// MARK: - 字数

/// 一段文字的字数。
struct LauncherTextStats: Equatable, Sendable {
    /// 字数：每个汉字（及日文假名、韩文）算一个，连着的字母数字（英文单词、数字）算一个 —— 同文字处理软件的「字数」。
    let words: Int
    /// 字符数（含空格和标点）。
    let characters: Int

    static func count(_ text: String) -> LauncherTextStats {
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                words += 1
                inWord = false
            } else if scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
                if !inWord { words += 1 }
                inWord = true
            } else if inWord, scalar == "'" || scalar == "’" {
                continue // don't、it’s 算一个词
            } else {
                inWord = false
            }
        }
        return LauncherTextStats(words: words, characters: text.count)
    }

    /// 汉字（含扩展区、兼容区）、日文假名、韩文音节。
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF,
             0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}

// MARK: - 兜底建议的排序

/// 一条兜底建议的排序信息。
struct LauncherSuggestionCandidate: Equatable, Sendable {
    /// 命令 id（快速入口自己的两条是 `launcher.webSearch`、`launcher.findFiles`）。使用记录的键是 `textaction/<id>`。
    let id: String
    let traits: LauncherSuggestionTraits
}

enum LauncherSuggestionRanking {
    /// 兜底建议最多几行：普通文字时正好放下用户认可的那张清单（翻译、解释、总结、上网搜、搜文件、存为片段、
    /// 钉成贴卡、二维码），没有别的结果时面板不用滚动（最多 8.5 行）。
    static let maxRows = 8
    /// 使用记录的键前缀。
    static let usageKeyPrefix = "textaction/"
    /// 输入属于 `boostedKinds` 里的类别时，优先级当成这个（排在所有默认档位前面）。
    static let boostedPriority = 0
    /// 使用分（0…300，`LauncherUsageRecords.usageScore`）每多这么多，优先级往前挪 1；最多挪 30（三个档位）。
    static let usagePointsPerStep = 10.0
    static let maxUsagePromotion = 30.0

    /// 快速入口自己的两条：上网搜（30）、搜文件名（40）。
    static let webSearch = LauncherSuggestionCandidate(id: "launcher.webSearch",
                                                       traits: LauncherSuggestionTraits(priority: 30))
    static let findFiles = LauncherSuggestionCandidate(id: "launcher.findFiles",
                                                       traits: LauncherSuggestionTraits(priority: 40))

    static func usageKey(for id: String) -> String {
        usageKeyPrefix + id
    }

    /// 适用于 `kinds` 的候选，排好序取前 `limit` 个，返回它们在 `candidates` 里的下标。
    ///
    /// 排序键 = 优先级（输入属于 `boostedKinds` 时是 0）− min(30, 使用分 ÷ 10)，小的在前；
    /// 同分看原来的优先级（小的在前），再看传入的先后（模块注册顺序、模块里声明的顺序）。
    /// 所以用了 7 次以上（使用分 300）的能往前挪三个档位，用过一两次的只在同档里往前；14 天不用减半（使用分自带衰减）。
    /// `usageKeyPrefix`：使用记录的键前缀（图片的建议用 `imageaction/`，§5.5）。
    static func order(_ candidates: [LauncherSuggestionCandidate], kinds: Set<LauncherTextKind>,
                      records: LauncherUsageRecords, now: Date, limit: Int = maxRows,
                      usageKeyPrefix: String = usageKeyPrefix) -> [Int] {
        // 标了 `traits.leading` 的不在这里：它们排在对应建议后面（`leadingOrder`）。
        let applicable = candidates.indices.filter {
            !candidates[$0].traits.leading && !candidates[$0].traits.kinds.isDisjoint(with: kinds)
        }
        let keyed = applicable.map { index -> (index: Int, key: Double, base: Int) in
            let traits = candidates[index].traits
            let priority = traits.boostedKinds.isDisjoint(with: kinds) ? traits.priority : boostedPriority
            let usage = records.usageScore(for: usageKeyPrefix + candidates[index].id, now: now)
            return (index, Double(priority) - min(maxUsagePromotion, usage / usagePointsPerStep), traits.priority)
        }
        let sorted = keyed.sorted { a, b in
            if a.key != b.key { return a.key < b.key }
            if a.base != b.base { return a.base < b.base }
            return a.index < b.index
        }
        return sorted.prefix(max(0, limit)).map(\.index)
    }

    /// 排在对应建议后面的文字动作（`traits.leading`，「入会并开始会议记录」排在「打开网址」后面）：适用于 `kinds` 的，
    /// 按档位、再按传入的先后；不看使用记录（这一块的次序是固定的），不占兜底建议的名额。返回下标。
    static func leadingOrder(_ candidates: [LauncherSuggestionCandidate], kinds: Set<LauncherTextKind>) -> [Int] {
        candidates.indices
            .filter { candidates[$0].traits.leading && !candidates[$0].traits.kinds.isDisjoint(with: kinds) }
            .sorted { a, b in
                let (pa, pb) = (candidates[a].traits.priority, candidates[b].traits.priority)
                return pa != pb ? pa < pb : a < b
            }
    }
}

// MARK: - 标题里的引用

enum LauncherSuggestionText {
    /// 兜底建议标题里引用输入时最多几个字符（「翻译「……」」别把行撑破）。
    static let quoteLength = 24
    /// 对应建议（打开网址、写邮件）标题里最多几个字符：这一行就是在说这段东西本身，给长一点。
    static let leadingQuoteLength = 60

    /// 压成一行（连续空白换成一个空格），超出 `maxLength` 个字符时截断、末尾加省略号（省略号算在长度里）。
    static func quote(_ text: String, maxLength: Int = quoteLength) -> String {
        let limit = max(1, maxLength)
        let line = LauncherConversions.singleLine(text, maxLength: limit + 1)
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)) + "…"
    }
}

// MARK: - 网页搜索

/// 一个搜索引擎。以后设置里能增删（需求 §3.10 第 5 条），现在只内置 Google。
struct LauncherWebSearchEngine: Equatable, Sendable {
    let id: String
    /// 显示名（品牌名，不翻译）。
    let name: String
    /// 搜索地址，`{query}` 处换成编码后的查询词。
    let template: String

    /// 查询词最多带这么多个字符（一大段文字整段放进地址里太长，浏览器可能打不开）。
    static let maxQueryLength = 500

    /// 这次查询的地址：查询词压成一行、截到 500 个字符，除字母数字和 `-._~` 外都按 UTF-8 百分号编码（空格是 %20）。
    func url(for query: String) -> URL? {
        let text = LauncherConversions.singleLine(query, maxLength: Self.maxQueryLength)
        guard !text.isEmpty, let encoded = text.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else {
            return nil
        }
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }

    /// RFC 3986 的非保留字符：只有这些不编码。
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

enum LauncherWebSearch {
    static let google = LauncherWebSearchEngine(id: "google", name: "Google",
                                                template: "https://www.google.com/search?q={query}")
    /// 内置的搜索引擎表（第一个是默认）。
    static let engines: [LauncherWebSearchEngine] = [google]

    static var defaultEngine: LauncherWebSearchEngine { engines.first ?? google }
}
