import Foundation
#if canImport(Translation)
import Translation
#endif

/// 这次实际用的翻译引擎（`TranslationSettings.resolve`）。
enum TranslationEngineKind: Equatable {
    case system
    case offline
    /// 云端模型（`AICloudModel.id`）。
    case cloud(String)
    /// 本机下载的 Qwen3 大模型（`LocalModelEntry.id`）。
    case localModel(String)
}

/// 翻译功能的引擎解析（docs/ai-service/DESIGN.md §5.1）。每个翻译功能选什么存在 `AIFeatureSettings` 里。
enum TranslationSettings {
    /// 旧版两个翻译模块共用的引擎键（`auto` / `system` / `offline`）：翻译类功能的新键没值时读它（只读、不删、不写），升级后行为不变。
    static let legacyEngineKey = "translation.engine"

    /// 本机能否用系统翻译（Translation 框架要求 macOS 15）。
    static var systemAvailable: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    /// 本次该用哪个引擎；nil = 都不可用（典型：macOS 14 且没下载离线模型）。
    /// 选了云端模型但它配置不完整（或已删除）：有离线模型就用离线模型。
    @MainActor
    static func resolve(_ feature: AIFeature) -> TranslationEngineKind? {
        let offlineReady = OfflineTranslator.shared.isReady
        switch AIFeatureSettings.choice(feature) {
        case .system:
            return systemAvailable ? .system : nil
        case .local:
            return offlineReady ? .offline : nil
        case .model(let id):
            if AIModelStore.shared.isConfigured(id) { return .cloud(id) }
            return offlineReady ? .offline : nil
        case .localModel(let id):
            if LocalModels.isInstalled(id) { return .localModel(id) }
            return offlineReady ? .offline : nil
        case .auto:
            if systemAvailable { return .system }
            return offlineReady ? .offline : nil
        }
    }

    /// 系统翻译失败或不支持这对语言时，能否自动改用离线模型（只有「自动」会用到系统翻译之后再退）。
    @MainActor
    static func canFallBackToOffline(_ feature: AIFeature) -> Bool {
        AIFeatureSettings.choice(feature) == .auto && OfflineTranslator.shared.isReady
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
