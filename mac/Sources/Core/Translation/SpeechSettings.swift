import Foundation

/// 说话的语言：固定一种，或在两种之间逐句自动判别（双识别器）。
/// 见 docs/translation-engine/DESIGN.md §3.2。显示名 `title` 要用 `L()`，是字幕与同传那边的扩展（`LiveTranslateController.swift`）。
enum SpeechLanguages: Equatable {
    case fixed(TranslationLanguage)
    case auto(TranslationLanguage, TranslationLanguage)

    /// 这次会出现的语言（固定 = 一种，自动 = 两种）。
    var languages: [TranslationLanguage] {
        switch self {
        case .fixed(let language): return [language]
        case .auto(let first, let second): return [first, second]
        }
    }
}

/// 说话语言（含自动 A / B）与专有名词表：字幕与同传、会议、听写共用（docs/meeting/ENGINE.md §4.7）。
/// 键名沿用 `livetranslate.*`，**一个字都不能改**（改了用户升级后设置就丢了）。
/// 只依赖 Foundation 与同目录的 `TranslationLanguage`、`TranslationGlossary`。
enum SpeechSettings {
    static let languageKey = "livetranslate.language"
    static let autoAKey = "livetranslate.autoA"
    static let autoBKey = "livetranslate.autoB"
    static let vocabularyKey = "livetranslate.vocabulary"
    /// `languageKey` 存这个值 = 自动（双识别器）；否则存识别 locale（`en-US`、`zh-CN`…，与旧版兼容）。
    static let autoValue = "auto"

    static var speech: SpeechLanguages {
        let raw = UserDefaults.standard.string(forKey: languageKey) ?? "en-US"
        if raw == autoValue { return .auto(autoA, autoB) }
        return .fixed(TranslationLanguage.from(speechLocale: raw) ?? .english)
    }

    /// 设为固定某种语言。
    static func setSpeech(_ language: TranslationLanguage) {
        guard let locale = language.speechLocale else { return }
        UserDefaults.standard.set(locale, forKey: languageKey)
    }

    static func setAutoSpeech() {
        UserDefaults.standard.set(autoValue, forKey: languageKey)
    }

    static var autoA: TranslationLanguage {
        TranslationLanguage.from(code: UserDefaults.standard.string(forKey: autoAKey)) ?? .simplifiedChinese
    }

    /// 与 A 相同时自动换成另一种（中英互为兜底）。
    static var autoB: TranslationLanguage {
        let stored = TranslationLanguage.from(code: UserDefaults.standard.string(forKey: autoBKey)) ?? .english
        guard stored.isSameLanguage(as: autoA) else { return stored }
        return autoA.isSameLanguage(as: .english) ? .simplifiedChinese : .english
    }

    /// 专有名词表（设置页编辑，存成文本，格式见 `TranslationGlossary`）。
    static var glossary: [GlossaryEntry] {
        TranslationGlossary.parse(UserDefaults.standard.string(forKey: vocabularyKey) ?? "")
    }

    /// 识别器的提示词：专有名词的原文与译名。识别器每段现读，改完从下一句起生效。
    static var vocabulary: [String] {
        TranslationGlossary.recognitionHints(glossary)
    }
}
