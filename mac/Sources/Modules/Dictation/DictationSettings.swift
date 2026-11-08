import Foundation

/// 识别语言（需求 §3）。默认自动（2026-11-08 前默认跟随实时翻译，而它出厂是固定英文）。
enum DictationLanguageSetting: String, CaseIterable, Identifiable {
    /// 跟随实时翻译的说话语言（实时翻译是「自动 A / B」时这里也自动判别）。
    case follow
    case chinese = "zh"
    case english = "en"
    /// 中英自动判别。
    case auto

    var id: String { rawValue }
}

/// AI 润色作用范围（需求 §4.4）。
enum DictationPolishMode: String, CaseIterable, Identifiable {
    case off
    case all
    /// 仅名单里的 App。
    case apps

    var id: String { rawValue }
}

/// 插入方式（需求 §7）。
enum DictationInsertMode: String, CaseIterable, Identifiable {
    /// 能直接写进输入框就写，写不进去再借剪贴板粘贴。
    case auto
    /// 一律借剪贴板粘贴。
    case paste

    var id: String { rawValue }
}

/// 录音条位置（需求 §2）。
enum DictationBarPosition: String, CaseIterable, Identifiable {
    /// 光标旁（取不到插入点时退回屏幕底部）。
    case caret
    case bottom

    var id: String { rawValue }
}

/// 语音听写的 UserDefaults 键（前缀 `dictation.`）与默认值。
enum DictationSettings {
    static let languageKey = "dictation.language"
    static let pauseKey = "dictation.pauseSeconds"
    static let onDeviceKey = "dictation.onDevice"
    static let voiceCommandsKey = "dictation.voiceCommands"
    static let fillerFilterKey = "dictation.fillerFilter"
    static let polishModeKey = "dictation.polishMode"
    /// 「仅这些 App」的名单：bundle id，一行一个。
    static let polishAppsKey = "dictation.polishApps"
    static let insertModeKey = "dictation.insertMode"
    static let barPositionKey = "dictation.barPosition"
    static let soundsKey = "dictation.sounds"
    static let historyEnabledKey = DictationHistoryDefaults.enabledKey
    static let historyLimitKey = DictationHistoryDefaults.limitKey

    /// 连续听写安静多久自动结束，可选的秒数（0 = 关）。每句停顿约 1 秒就上屏（`DictationRecognizer.pauseCut`），
    /// 这里是整次听写的收尾，所以比旧版的 2 / 3 / 5 秒长得多。
    static let pauseOptions = [0, 10, 30, 60]
    static let defaultPauseSeconds = 30

    private static var defaults: UserDefaults { .standard }

    static var language: DictationLanguageSetting {
        DictationLanguageSetting(rawValue: defaults.string(forKey: languageKey) ?? "") ?? .auto
    }

    /// 连续听写（点按切换）安静多少秒自动结束；0 = 不自动结束。
    static var pauseSeconds: Int {
        let value = defaults.object(forKey: pauseKey) as? Int ?? defaultPauseSeconds
        return pauseOptions.contains(value) ? value : defaultPauseSeconds
    }

    /// 旧版本存的停顿秒数（2 / 3 / 5）不在新选项里：清掉回到默认，设置页的选择器才有选中项。
    static func migrateLegacyValues() {
        if let value = defaults.object(forKey: pauseKey) as? Int, !pauseOptions.contains(value) {
            defaults.removeObject(forKey: pauseKey)
        }
    }

    static var preferOnDevice: Bool { defaults.object(forKey: onDeviceKey) as? Bool ?? true }
    static var voiceCommands: Bool { defaults.object(forKey: voiceCommandsKey) as? Bool ?? true }
    static var fillerFilter: Bool { defaults.object(forKey: fillerFilterKey) as? Bool ?? true }

    static var polishMode: DictationPolishMode {
        DictationPolishMode(rawValue: defaults.string(forKey: polishModeKey) ?? "") ?? .off
    }

    static var polishApps: [String] {
        parseApps(defaults.string(forKey: polishAppsKey) ?? "")
    }

    static func parseApps(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 这个 App 的听写要不要 AI 润色。
    static func polishes(bundleID: String?) -> Bool {
        switch polishMode {
        case .off: return false
        case .all: return true
        case .apps: return bundleID.map { polishApps.contains($0) } ?? false
        }
    }

    static var insertMode: DictationInsertMode {
        DictationInsertMode(rawValue: defaults.string(forKey: insertModeKey) ?? "") ?? .auto
    }

    static var barPosition: DictationBarPosition {
        DictationBarPosition(rawValue: defaults.string(forKey: barPositionKey) ?? "") ?? .caret
    }

    static var sounds: Bool { defaults.object(forKey: soundsKey) as? Bool ?? false }
    static var historyEnabled: Bool { defaults.object(forKey: historyEnabledKey) as? Bool ?? true }

    static var historyLimit: Int {
        DictationHistoryCodec.clampLimit(defaults.object(forKey: historyLimitKey) as? Int ?? DictationHistoryCodec.defaultLimit)
    }

    static var processingOptions: DictationTextProcessor.Options {
        DictationTextProcessor.Options(voiceCommands: voiceCommands, fillerFilter: fillerFilter)
    }

    /// 这次听写用哪几种语言：一种 = 固定；两种 = 自动判别（第一种是主语言，先按它识别）。
    static var speechLanguages: [TranslationLanguage] {
        speechLanguages(for: language)
    }

    static func speechLanguages(for setting: DictationLanguageSetting) -> [TranslationLanguage] {
        let languages: [TranslationLanguage]
        switch setting {
        case .follow:
            languages = LiveTranslateSettings.speech.languages
        case .chinese:
            languages = [.simplifiedChinese]
        case .english:
            languages = [.english]
        case .auto:
            // 主语言随系统：系统是英文就先按英文认。
            languages = TranslationLanguage.systemPreferred.isSameLanguage(as: .english)
                ? [.english, .simplifiedChinese] : [.simplifiedChinese, .english]
        }
        let usable = languages.filter { $0.speechLocale != nil }
        return usable.isEmpty ? [.simplifiedChinese] : usable
    }

    /// 后处理按哪种语言的规则来。
    static func processingLanguage(for language: TranslationLanguage) -> DictationTextProcessor.Language {
        if language.isChinese { return .chinese }
        if language.isSameLanguage(as: .english) { return .english }
        return .other
    }
}
