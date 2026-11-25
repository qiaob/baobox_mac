import Foundation

// 挂着图片时的建议（docs/launcher/TECH_DESIGN.md §5.5）的规则：图片动作怎么排、输入框里打的字怎么筛建议行、
// 识别出的二维码 / 条码怎么换成行（去重、最多几行、是不是网址）、识别出的文字那一行写什么。
// 纯值、只依赖 Foundation，进 BaoboxTests。换成面板的行（文案、图标、执行）在 App 侧 `Providers/ImageSuggestionProvider.swift`。

enum LauncherImageSuggestionRanking {
    /// 使用记录的键前缀（和文字的兜底建议 `textaction/` 分开记：同一个动作对文字、对图片用得多不多是两回事）。
    static let usageKeyPrefix = "imageaction/"

    static func usageKey(for id: String) -> String {
        usageKeyPrefix + id
    }

    /// 图片动作（和「<命令名>图里的文字」）排好序，返回它们在 `candidates` 里的下标，不限行数。
    /// 排序同文字的兜底建议（`LauncherSuggestionRanking.order`）：档位 − min(30, 使用分 ÷ 10)，小的在前；同分看档位，
    /// 再看传入的先后。图片不分类别，`traits.kinds` / `boostedKinds` 不看。
    static func order(_ candidates: [LauncherSuggestionCandidate], records: LauncherUsageRecords, now: Date) -> [Int] {
        let anyKind = candidates.map { LauncherSuggestionCandidate(id: $0.id, traits: LauncherSuggestionTraits(priority: $0.traits.priority)) }
        return LauncherSuggestionRanking.order(anyKind, kinds: Set(LauncherTextKind.allCases), records: records, now: now,
                                               limit: candidates.count, usageKeyPrefix: usageKeyPrefix)
    }
}

enum LauncherImageSuggestionFilter {
    /// 挂着图片时输入框里打的字 = 筛建议行：标题匹配得上（完全相等、开头、词首、包含、按顺序跳字，拼音全拼和首字母也算，
    /// 同 `LauncherMatch`）就留下。没打字（全是空白）时全留。
    static func keeps(title: String, filter: String) -> Bool {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return LauncherMatch.score(LauncherMatchQuery(trimmed), in: LauncherSearchKey(title)) != nil
    }
}

enum LauncherRecognizedContent {
    /// 识别出的二维码 / 条码最多出几行。
    static let maxCodeRows = 3
    /// 识别出的文字那一行，标题最多几个字符（同对应建议的引用长度）。
    static let textTitleLength = LauncherSuggestionText.leadingQuoteLength

    /// 二维码 / 条码的内容：去首尾空白、去掉空的、去重（保持先后），最多 3 个。
    static func codes(_ payloads: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for payload in payloads {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count == maxCodeRows { break }
        }
        return result
    }

    /// 内容是网页地址时给出地址（⏎ 用浏览器打开），否则 nil（⏎ 复制）。认法同输入分类的网址（`LauncherInputClassifier`），
    /// 但只收 http / https：二维码里的 `weixin://`、`WIFI:…`、`otpauth://` 这类交给浏览器没意义，复制下来更有用。
    static func webURL(in payload: String) -> URL? {
        guard let url = LauncherInputClassifier.classify(payload).url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// 识别出的文字：去首尾空白；全是空白为 nil（不出这一行）。
    static func text(_ recognized: String) -> String? {
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 识别出的文字那一行的标题：文字开头压成一行，最多 60 个字符。
    static func textTitle(_ text: String) -> String {
        LauncherSuggestionText.quote(text, maxLength: textTitleLength)
    }

    /// 那一行右侧的「N 字」：字数同字数统计（每个汉字一个、连着的字母数字一个）。
    static func wordCount(_ text: String) -> Int {
        LauncherTextStats.count(text).words
    }
}
