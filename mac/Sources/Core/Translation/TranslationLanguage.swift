import Foundation
import NaturalLanguage

/// 文字系统：用于语种兜底判断，以及双识别器给识别结果打分（文字和语言对不上就扣分）。
enum TranslationScript {
    case han, kana, hangul, latin, cyrillic, arabic, thai, devanagari

    func contains(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        switch self {
        case .han:
            return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0x20000...0x2A6DF).contains(v)
        case .kana:
            return (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
        case .hangul:
            return (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
        case .latin:
            return (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
                || (0xC0...0x24F).contains(v) || (0x1E00...0x1EFF).contains(v)
        case .cyrillic:
            return (0x0400...0x04FF).contains(v)
        case .arabic:
            return (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
        case .thai:
            return (0x0E00...0x0E7F).contains(v)
        case .devanagari:
            return (0x0900...0x097F).contains(v)
        }
    }
}

/// 翻译支持的语言（离线模型 Hy-MT2 的 33 种里挑常用的；系统翻译能翻哪些由系统判定）。
struct TranslationLanguage: Hashable, Identifiable {
    /// 存储 / 比较用的代码（`zh-Hans`、`en`…）。
    let code: String
    /// 语言名按惯例用各自语言书写，不随界面语言翻译。
    let endonym: String
    /// 离线模型中文提示词里的语言名。
    let chineseName: String
    /// 离线模型英文提示词里的语言名。
    let englishName: String
    let nlLanguage: NLLanguage
    /// 朗读嗓音语言。
    let voiceLanguage: String
    /// 语音识别 locale；nil = 实时翻译不提供这种语言。
    let speechLocale: String?
    /// 系统 Translation 框架用的语言标识。
    let appleCode: String
    /// 这种语言的文字由哪些文字系统组成（日文 = 假名 + 汉字）。
    let scripts: [TranslationScript]

    var id: String { code }

    /// 简繁中文算同一种语言（「原文已是目标语言」的判断用）。
    var family: String { code.hasPrefix("zh") ? "zh" : code }

    var isChinese: Bool { family == "zh" }

    func isSameLanguage(as other: TranslationLanguage) -> Bool { family == other.family }

    static func == (lhs: TranslationLanguage, rhs: TranslationLanguage) -> Bool { lhs.code == rhs.code }
    func hash(into hasher: inout Hasher) { hasher.combine(code) }

    // MARK: - 语言表

    private static func make(_ code: String, _ endonym: String, _ zh: String, _ en: String,
                             _ nl: NLLanguage, voice: String, speech: String?, apple: String? = nil,
                             scripts: [TranslationScript]) -> TranslationLanguage {
        TranslationLanguage(code: code, endonym: endonym, chineseName: zh, englishName: en, nlLanguage: nl,
                            voiceLanguage: voice, speechLocale: speech, appleCode: apple ?? code, scripts: scripts)
    }

    static let simplifiedChinese = make("zh-Hans", "简体中文", "中文", "Chinese", .simplifiedChinese,
                                        voice: "zh-CN", speech: "zh-CN", scripts: [.han])
    static let english = make("en", "English", "英语", "English", .english,
                              voice: "en-US", speech: "en-US", scripts: [.latin])

    static let all: [TranslationLanguage] = [
        simplifiedChinese,
        make("zh-Hant", "繁體中文", "繁体中文", "Traditional Chinese", .traditionalChinese,
             voice: "zh-TW", speech: "zh-TW", scripts: [.han]),
        english,
        make("ja", "日本語", "日语", "Japanese", .japanese, voice: "ja-JP", speech: "ja-JP", scripts: [.kana, .han]),
        make("ko", "한국어", "韩语", "Korean", .korean, voice: "ko-KR", speech: "ko-KR", scripts: [.hangul]),
        make("fr", "Français", "法语", "French", .french, voice: "fr-FR", speech: "fr-FR", scripts: [.latin]),
        make("de", "Deutsch", "德语", "German", .german, voice: "de-DE", speech: "de-DE", scripts: [.latin]),
        make("es", "Español", "西班牙语", "Spanish", .spanish, voice: "es-ES", speech: "es-ES", scripts: [.latin]),
        make("pt", "Português", "葡萄牙语", "Portuguese", .portuguese,
             voice: "pt-BR", speech: "pt-BR", apple: "pt-BR", scripts: [.latin]),
        make("it", "Italiano", "意大利语", "Italian", .italian, voice: "it-IT", speech: "it-IT", scripts: [.latin]),
        make("ru", "Русский", "俄语", "Russian", .russian, voice: "ru-RU", speech: "ru-RU", scripts: [.cyrillic]),
        make("uk", "Українська", "乌克兰语", "Ukrainian", .ukrainian,
             voice: "uk-UA", speech: "uk-UA", scripts: [.cyrillic]),
        make("ar", "العربية", "阿拉伯语", "Arabic", .arabic, voice: "ar-SA", speech: "ar-SA", scripts: [.arabic]),
        make("th", "ไทย", "泰语", "Thai", .thai, voice: "th-TH", speech: "th-TH", scripts: [.thai]),
        make("vi", "Tiếng Việt", "越南语", "Vietnamese", .vietnamese,
             voice: "vi-VN", speech: "vi-VN", scripts: [.latin]),
        make("id", "Bahasa Indonesia", "印尼语", "Indonesian", .indonesian,
             voice: "id-ID", speech: "id-ID", scripts: [.latin]),
        make("ms", "Bahasa Melayu", "马来语", "Malay", .malay, voice: "ms-MY", speech: "ms-MY", scripts: [.latin]),
        make("tr", "Türkçe", "土耳其语", "Turkish", .turkish, voice: "tr-TR", speech: "tr-TR", scripts: [.latin]),
        make("pl", "Polski", "波兰语", "Polish", .polish, voice: "pl-PL", speech: "pl-PL", scripts: [.latin]),
        make("nl", "Nederlands", "荷兰语", "Dutch", .dutch, voice: "nl-NL", speech: "nl-NL", scripts: [.latin]),
        make("hi", "हिन्दी", "印地语", "Hindi", .hindi, voice: "hi-IN", speech: "hi-IN", scripts: [.devanagari]),
    ]

    /// 菜单里常驻的几种（完整列表在设置页）。
    static let common: [TranslationLanguage] = all.filter { ["zh-Hans", "en", "ja", "ko"].contains($0.code) }

    static func from(code: String?) -> TranslationLanguage? {
        guard let code else { return nil }
        return all.first { $0.code == code }
    }

    /// 由语音识别 locale 反查（`zh-CN` → 简体中文）。
    static func from(speechLocale: String?) -> TranslationLanguage? {
        guard let speechLocale else { return nil }
        return all.first { $0.speechLocale == speechLocale }
    }

    static func from(nlLanguage: NLLanguage) -> TranslationLanguage? {
        all.first { $0.nlLanguage == nlLanguage }
    }

    /// 系统首选语言对应的那种；不在表里就是英文。
    static var systemPreferred: TranslationLanguage {
        for identifier in Locale.preferredLanguages {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh") {
                let traditional = lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk")
                    || lower.contains("-mo")
                return traditional ? (from(code: "zh-Hant") ?? simplifiedChinese) : simplifiedChinese
            }
            let base = String(lower.prefix { $0 != "-" && $0 != "_" })
            if let match = all.first(where: { $0.code == base }) { return match }
        }
        return english
    }

    /// 某段文字有多大比例的字母属于这种语言的文字系统（0…1；没有字母时为 0）。
    func scriptRatio(of text: String) -> Double {
        var letters = 0
        var matched = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if scripts.contains(where: { $0.contains(scalar) }) { matched += 1 }
        }
        return letters == 0 ? 0 : Double(matched) / Double(letters)
    }
}

/// 本地语种检测（NaturalLanguage）。
enum LanguageDetector {
    /// 约束在支持的语言内；`preferred` 作为先验偏向（短词最容易误判）；认不出时按文字系统兜底。
    static func detect(_ text: String, preferred: [TranslationLanguage]) -> TranslationLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = TranslationLanguage.all.map(\.nlLanguage)
        var hints: [NLLanguage: Double] = [:]
        for language in TranslationLanguage.all { hints[language.nlLanguage] = 0.02 }
        for language in preferred { hints[language.nlLanguage] = 0.4 }
        recognizer.languageHints = hints
        recognizer.processString(text)
        // 含假名却被判成中文：以假名为准（汉字 + 假名混排的日文短句偶尔会被判成中文）。
        let hasKana = text.unicodeScalars.contains { TranslationScript.kana.contains($0) }
        if let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
           let language = TranslationLanguage.from(nlLanguage: best.key) {
            if hasKana, language.isChinese, let japanese = TranslationLanguage.from(code: "ja") {
                return japanese
            }
            return language
        }
        return scriptFallback(text, hasKana: hasKana)
    }

    private static func scriptFallback(_ text: String, hasKana: Bool) -> TranslationLanguage {
        if hasKana, let japanese = TranslationLanguage.from(code: "ja") { return japanese }
        let order: [(TranslationScript, String)] = [
            (.hangul, "ko"), (.han, "zh-Hans"), (.thai, "th"), (.arabic, "ar"),
            (.devanagari, "hi"), (.cyrillic, "ru"),
        ]
        for (script, code) in order where text.unicodeScalars.contains(where: { script.contains($0) }) {
            if let language = TranslationLanguage.from(code: code) { return language }
        }
        return .english
    }
}
