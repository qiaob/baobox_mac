import Foundation
#if canImport(Translation)
import Translation
#endif

/// 用户在设置里选的翻译引擎（两个翻译模块共用）。见 docs/translation-engine/DESIGN.md §2。
enum TranslationEngineChoice: String, CaseIterable, Identifiable {
    case auto
    case system
    case offline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return L("translation.engine.auto")
        case .system: return L("translation.engine.system")
        case .offline: return L("translation.engine.offline")
        }
    }
}

/// 一次翻译实际用的引擎。
enum TranslationEngineKind: Equatable {
    case system
    case offline
}

enum TranslationSettings {
    static let engineKey = "translation.engine"

    static var engineChoice: TranslationEngineChoice {
        get {
            UserDefaults.standard.string(forKey: engineKey).flatMap(TranslationEngineChoice.init(rawValue:)) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }

    /// 本机能否用系统翻译（Translation 框架要求 macOS 15）。
    static var systemAvailable: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    /// 本次该用哪个引擎；nil = 都不可用（典型：macOS 14 且没下载离线模型）。
    @MainActor
    static func resolve() -> TranslationEngineKind? {
        let offlineReady = OfflineTranslator.shared.isReady
        switch engineChoice {
        case .system:
            return systemAvailable ? .system : nil
        case .offline:
            return offlineReady ? .offline : nil
        case .auto:
            if systemAvailable { return .system }
            return offlineReady ? .offline : nil
        }
    }

    /// 系统翻译失败或不支持这对语言时，能否自动改用离线模型。
    @MainActor
    static var canFallBackToOffline: Bool {
        engineChoice == .auto && OfflineTranslator.shared.isReady
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
