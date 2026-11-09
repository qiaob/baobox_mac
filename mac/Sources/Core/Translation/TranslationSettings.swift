import Foundation
#if canImport(Translation)
import Translation
#endif

/// 用户在设置里选的翻译引擎（每个翻译模块各一个）。见 docs/translation-engine/DESIGN.md §2、docs/ai-service/DESIGN.md §5。
enum TranslationEngineChoice: String, CaseIterable, Identifiable {
    case auto
    case system
    case offline
    /// 云端服务：只能手动选，「自动」不会自己切过来（要花钱，内容也会离开本机）。
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return L("translation.engine.auto")
        case .system: return L("translation.engine.system")
        case .offline: return L("translation.engine.offline")
        case .cloud: return L("translation.engine.cloud")
        }
    }
}

/// 一次翻译实际用的引擎。
enum TranslationEngineKind: Equatable {
    case system
    case offline
    case cloud
}

/// 哪个模块的翻译设置。划词助手一个；字幕与同传一个（会议的翻译也用它）。
enum TranslationScope {
    case selection
    case live

    var engineKey: String {
        switch self {
        case .selection: return "selectiontranslate.engine"
        case .live: return "livetranslate.engine"
        }
    }

    /// 选云端时告诉用户会发出去什么。
    var cloudDisclosure: String {
        switch self {
        case .selection: return L("ai.disclosure.selection")
        case .live: return L("ai.disclosure.live")
        }
    }
}

enum TranslationSettings {
    /// 旧版两个模块共用的键：保留不删，只在模块自己的新键没值时读一次（降级回旧版本也不坏）。
    static let legacyEngineKey = "translation.engine"

    /// 新键没值 → 取旧键的值 → 都没有就是「自动」。升级后用户什么都不改就和以前一样。
    static func engineChoice(_ scope: TranslationScope) -> TranslationEngineChoice {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: scope.engineKey) ?? defaults.string(forKey: legacyEngineKey)
        return raw.flatMap(TranslationEngineChoice.init(rawValue:)) ?? .auto
    }

    static func setEngineChoice(_ choice: TranslationEngineChoice, for scope: TranslationScope) {
        UserDefaults.standard.set(choice.rawValue, forKey: scope.engineKey)
    }

    /// 本机能否用系统翻译（Translation 框架要求 macOS 15）。
    static var systemAvailable: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    /// 本次该用哪个引擎；nil = 都不可用（典型：macOS 14 且没下载离线模型）。
    /// 选了云端但云端没配置好：有离线模型就用离线模型。
    @MainActor
    static func resolve(_ scope: TranslationScope) -> TranslationEngineKind? {
        let offlineReady = OfflineTranslator.shared.isReady
        switch engineChoice(scope) {
        case .system:
            return systemAvailable ? .system : nil
        case .offline:
            return offlineReady ? .offline : nil
        case .cloud:
            if AIService.shared.cloudConfigured { return .cloud }
            return offlineReady ? .offline : nil
        case .auto:
            if systemAvailable { return .system }
            return offlineReady ? .offline : nil
        }
    }

    /// 系统翻译失败或不支持这对语言时，能否自动改用离线模型（只有「自动」会用到系统翻译之后再退）。
    @MainActor
    static func canFallBackToOffline(_ scope: TranslationScope) -> Bool {
        engineChoice(scope) == .auto && OfflineTranslator.shared.isReady
    }

    /// 系统翻译是否支持这些翻译方向（macOS 15+；判为 unsupported 才算不支持，未下载语言包不算）。
    static func systemSupports(_ pairs: [(source: TranslationLanguage, target: TranslationLanguage)]) async -> Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let availability = LanguageAvailability()
            for pair in pairs {
                let status = await availability.status(from: Locale.Language(identifier: pair.source.appleCode),
                                                       to: Locale.Language(identifier: pair.target.appleCode))
                if status == .unsupported { return false }
            }
            return true
        }
        #endif
        return false
    }
}
