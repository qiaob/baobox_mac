import Foundation

/// 专有名词表的一项。`target` 为空 = 翻译时保持原样不翻（产品名、英文人名常这样用）。
struct GlossaryEntry: Identifiable, Equatable {
    let id: UUID
    var source: String
    var target: String

    init(id: UUID = UUID(), source: String, target: String = "") {
        self.id = id
        self.source = source
        self.target = target
    }
}

/// 专有名词表：识别时作为提示词，离线翻译时按 Hy-MT2 官方「术语」模板给参考译法
/// （docs/translation-engine/DESIGN.md §2.3）。
///
/// 存成纯文本，一行一项：`原文` 或 `原文 = 译名`（全角＝也认）；
/// 早期版本用逗号 / 顿号 / 分号分隔、没有译名，照样读得进来。
enum TranslationGlossary {
    /// 生效的上限：识别器的提示词和翻译提示词都不宜过长。
    static let maxEntries = 100
    /// 一段原文里最多带几条参考译法。
    private static let maxReferences = 20

    static func parse(_ raw: String) -> [GlossaryEntry] {
        var entries: [GlossaryEntry] = []
        var seen = Set<String>()
        func append(_ source: String, _ target: String) {
            let source = source.trimmingCharacters(in: .whitespaces)
            let target = target.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty, seen.insert(source.lowercased()).inserted else { return }
            entries.append(GlossaryEntry(source: source, target: target))
        }
        for line in raw.components(separatedBy: .newlines) {
            if let equals = line.firstIndex(where: { $0 == "=" || $0 == "＝" }) {
                append(String(line[..<equals]), String(line[line.index(after: equals)...]))
            } else {
                for piece in line.components(separatedBy: CharacterSet(charactersIn: ",，、;；")) {
                    append(piece, "")
                }
            }
        }
        return entries
    }

    /// 空行（原文为空）不存。
    static func serialize(_ entries: [GlossaryEntry]) -> String {
        entries.compactMap { entry -> String? in
            let source = entry.source.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty else { return nil }
            let target = entry.target.trimmingCharacters(in: .whitespaces)
            return target.isEmpty ? source : "\(source) = \(target)"
        }
        .joined(separator: "\n")
    }

    /// 识别器的提示词：原文和译名都给 —— 两种语言都可能被说出来。去重，最多 `maxEntries` 个。
    static func recognitionHints(_ entries: [GlossaryEntry]) -> [String] {
        var hints: [String] = []
        var seen = Set<String>()
        for entry in entries.prefix(maxEntries) {
            for term in [entry.source, entry.target] where !term.isEmpty {
                if seen.insert(term.lowercased()).inserted { hints.append(term) }
            }
        }
        return hints
    }

    /// 这段原文里出现了的词条 → 提示词里的「X 翻译成 Y」。
    /// - 出现原文：有译名按译名；没译名时，拉丁字母的词（产品名、英文人名）或本身就像目标语言文字的词保持原样
    ///   （「X 翻译成 X」），其余（如中文词译成英文）交给模型照常翻 —— 只为提高识别率填的中文词不该原样留在英文译文里；
    /// - 出现的是译名（反方向翻译）：译回原文；
    /// - 指定的译法得像目标语言的文字（译名是中文、却要译成日文以外的语言时就不给，交给模型自己翻）。
    static func references(for text: String, target: TranslationLanguage,
                           entries: [GlossaryEntry]) -> [(source: String, target: String)] {
        var references: [(source: String, target: String)] = []
        for entry in entries.prefix(maxEntries) {
            guard references.count < maxReferences else { break }
            if occurs(entry.source, in: text) {
                if entry.target.isEmpty {
                    if isLatin(entry.source) || looksLike(entry.source, target) {
                        references.append((entry.source, entry.source))
                    }
                } else if looksLike(entry.target, target) {
                    references.append((entry.source, entry.target))
                }
            } else if !entry.target.isEmpty, occurs(entry.target, in: text), looksLike(entry.source, target) {
                references.append((entry.target, entry.source))
            }
        }
        return references
    }

    /// 纯字母数字的词按整词匹配（免得「AI」命中「said」），其余（中文等）按子串匹配；都不分大小写。
    private static func occurs(_ term: String, in text: String) -> Bool {
        guard !term.isEmpty else { return false }
        let isWord = term.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " ") }
        guard isWord else {
            return text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 字母全是拉丁字母（产品名、英文人名这类，放进任何语言的译文里都常见）。
    private static func isLatin(_ term: String) -> Bool {
        let letters = term.unicodeScalars.filter { $0.properties.isAlphabetic }
        return !letters.isEmpty && letters.allSatisfy { TranslationScript.latin.contains($0) }
    }

    /// 没有字母的（数字、符号）不挑语言。
    private static func looksLike(_ term: String, _ language: TranslationLanguage) -> Bool {
        let hasLetters = term.unicodeScalars.contains { $0.properties.isAlphabetic }
        return !hasLetters || language.scriptRatio(of: term) >= 0.5
    }
}
