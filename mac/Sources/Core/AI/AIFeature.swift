import Foundation

/// 功能的类型：决定下拉框里有哪些本地选项、走本地时用哪个模型（docs/ai-service/DESIGN.md §1）。
enum AIFeatureKind {
    /// 翻译：自动 / 系统翻译 / 离线模型（Hy-MT2）/ 云端模型。
    case translation
    /// 通用生成（纠错、纪要、周报、润色）：本地模型（Qwen3-1.7B）/ 云端模型。
    case generation
}

/// 一个用到模型的功能：设置键 + 类型（docs/ai-service/DESIGN.md §3.2、§3.3）。
/// 各模块在自己的文件里用 `extension AIFeature` 声明常量，框架不认识具体工具。
struct AIFeature: Hashable {
    let id: String
    let kind: AIFeatureKind
    /// 旧版设置键：新键没值时读一次（只读、不删、不写）。
    var legacyKey: String? = nil

    var storageKey: String { "ai.feature." + id }
}

/// 一个功能选了什么。
enum AIEngineChoice: Hashable {
    /// 翻译类：系统翻译优先，不支持或失败时离线模型（= 以前的「自动」）。
    case auto
    /// 翻译类：系统翻译。
    case system
    /// 这一类功能的默认本地模型（`LocalModels.defaultEntry`）：翻译类 = Hy-MT2，通用类 = Qwen3-1.7B。
    case local
    /// 云端模型（`AICloudModel.id`）。
    case model(String)
    /// 某个本地模型（`LocalModelEntry.id`，docs/local-models/DESIGN.md §5）。这一类功能的默认本地模型存成 `.local`。
    case localModel(String)

    private static let modelPrefix = "model:"
    private static let localModelPrefix = "localmodel:"

    init?(storageValue: String) {
        switch storageValue {
        case "auto": self = .auto
        case "system": self = .system
        // 「offline」是旧键 translation.engine 里离线模型的写法。
        case "local", "offline": self = .local
        default:
            if storageValue.hasPrefix(Self.localModelPrefix) {
                let id = String(storageValue.dropFirst(Self.localModelPrefix.count))
                guard !id.isEmpty else { return nil }
                self = .localModel(id)
                return
            }
            guard storageValue.hasPrefix(Self.modelPrefix) else { return nil }
            let id = String(storageValue.dropFirst(Self.modelPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .model(id)
        }
    }

    var storageValue: String {
        switch self {
        case .auto: return "auto"
        case .system: return "system"
        case .local: return "local"
        case .model(let id): return Self.modelPrefix + id
        case .localModel(let id): return Self.localModelPrefix + id
        }
    }

    var localModelID: String? {
        if case .localModel(let id) = self { return id }
        return nil
    }

    var modelID: String? {
        if case .model(let id) = self { return id }
        return nil
    }
}

/// 「AI」页和模块页里的一行：功能 + 界面文案。模块的 `aiFeatures()` 每次现建，文案跟着当前语言。
struct AIFeatureDefinition {
    let feature: AIFeature
    let title: String
    /// 选了云端模型时发出去的是什么（名词短语，如「选中的文字」），显示成「会把…发给…」。
    let sends: String
}

/// 功能 → 选择的读写（UserDefaults `ai.feature.<功能 id>`，docs/ai-service/DESIGN.md §3.2）。
enum AIFeatureSettings {
    /// 某个功能的选择变了（userInfo["id"] = 功能 id）。字幕与同传运行中据此重启。
    static let didChange = Notification.Name("com.baobox.ai.featureChoiceDidChange")

    private static let keyPrefix = "ai.feature."

    /// 没存新键时的值：旧键 → 出厂值（翻译类自动、通用类本地）。
    static func defaultChoice(_ feature: AIFeature) -> AIEngineChoice {
        if let key = feature.legacyKey,
           let raw = UserDefaults.standard.string(forKey: key),
           let choice = valid(AIEngineChoice(storageValue: raw), for: feature) {
            return choice
        }
        return feature.kind == .translation ? .auto : .local
    }

    /// 存的选择；没存或读不懂 → `defaultChoice`。不检查模型还在不在、配没配好（见 `AIService.route`、`TranslationSettings.resolve`）。
    static func choice(_ feature: AIFeature) -> AIEngineChoice {
        if let raw = UserDefaults.standard.string(forKey: feature.storageKey),
           let choice = valid(AIEngineChoice(storageValue: raw), for: feature) {
            return choice
        }
        return defaultChoice(feature)
    }

    static func setChoice(_ choice: AIEngineChoice, for feature: AIFeature) {
        UserDefaults.standard.set(choice.storageValue, forKey: feature.storageKey)
        NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["id": feature.id])
    }

    /// 删了模型：选了它的功能改回默认（删掉新键）。
    static func clearChoices(usingModels ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let defaults = UserDefaults.standard
        var cleared: [String] = []
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(keyPrefix) {
            guard let raw = value as? String,
                  let id = AIEngineChoice(storageValue: raw)?.modelID, ids.contains(id) else { continue }
            defaults.removeObject(forKey: key)
            cleared.append(String(key.dropFirst(keyPrefix.count)))
        }
        for id in cleared {
            NotificationCenter.default.post(name: didChange, object: nil, userInfo: ["id": id])
        }
    }

    /// 存的值归一：通用类不认「自动」「系统翻译」；选的是这一类功能的默认本地模型时就是 `.local`（同一个东西两种写法）；
    /// 翻译专用的模型不能做通用生成（存坏了也不至于走错）。
    private static func valid(_ choice: AIEngineChoice?, for feature: AIFeature) -> AIEngineChoice? {
        guard let choice else { return nil }
        switch choice {
        case .auto, .system:
            return feature.kind == .generation ? nil : choice
        case .localModel(let id):
            if id == LocalModels.defaultEntry(for: feature.kind).id { return .local }
            guard let entry = LocalModels.entry(id) else { return nil }
            if feature.kind == .generation, entry.kind == .translation { return nil }
            return choice
        case .local, .model:
            return choice
        }
    }
}
