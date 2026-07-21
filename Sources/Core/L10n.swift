import Foundation

/// 本地化取词入口。所有语义 key 与译文定义在 `Sources/Resources/Localizable.xcstrings`。
///
/// - SwiftUI 视图里直接写 key 字面量（如 `Text("settings.tab.general")`），
///   LocalizedStringKey 会自动查表；
/// - AppKit / 纯 Swift 场景用 `L("app.menu.settings")`；
///   带参数用插值：`L("clipboard.footer.count \(n)")`，
///   对应 catalog 中的 key 为 `clipboard.footer.count %lld`。
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

/// 应用语言（应用内切换，重启生效）。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// 语言名按惯例用各自语言书写，不随界面语言翻译；仅「跟随系统」需要本地化。
    var displayName: String {
        switch self {
        case .system: return L("settings.general.language.system")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

enum L10n {
    /// 应用内语言覆盖标记（缺省 = 跟随系统）。真正让 Bundle 换语言的是 AppleLanguages。
    private static let markerKey = "app.languageOverride"

    static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: markerKey),
              let language = AppLanguage(rawValue: raw) else { return .system }
        return language
    }

    /// 写入语言偏好。Bundle 的语言表在进程启动时定死，必须重启才生效。
    static func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        switch language {
        case .system:
            defaults.removeObject(forKey: markerKey)
            defaults.removeObject(forKey: "AppleLanguages")
        case .simplifiedChinese, .english:
            defaults.set(language.rawValue, forKey: markerKey)
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// 跟随**应用语言**的 Locale，用于日期等格式化展示。
    /// `Locale.current` 跟随系统地区设置而非应用语言，两者可能不一致。
    static var locale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }
}
