import Foundation

// 快速入口的功能开关（docs/launcher/TECH_DESIGN.md §11「功能开关」，第 13 步）：设置页把快速入口能做的事全部列出来，每一项一个开关，
// 关掉的不在快速入口里出现（工具本身不受影响）。
// - 一项功能 = 一个 id：快速入口自己的功能用固定 id（`LauncherBuiltInFeature`）；来源 `source/<来源 id>`；模块声明的
//   文字 / 图片 / 文件动作 `action/<命令 id>`。
// - 设置键 `launcher.disabledFeatures` 存**被关掉的** id（字符串数组），不在里面的都是开着的 —— 以后新加的功能默认开、不用迁移；
//   不认识的 id 原样留着（工具暂时没声明那一项时，开关状态不丢）。
// - 每次呼出读一次，存成 `LauncherFeatureSet`，到收起为止不变；打字路径只查这个集合。
// - 设置页的分组与次序（`LauncherFeatureLayout`）：给一批行，产出分好组、排好序的小节。
// 纯 Foundation，进 BaoboxTests。行的文案（`L()`）、从注册表收集在 App 侧 `LauncherFeatureCatalog.swift`。

// MARK: - id

enum LauncherFeatureID {
    static let sourcePrefix = "source/"
    static let actionPrefix = "action/"

    /// 一个来源（App、命令、文件，以及各模块 `launcherSources()` 交来的剪贴板历史、片段……）。
    static func source(_ sourceID: String) -> String {
        sourcePrefix + sourceID
    }

    /// 模块声明的一条文字 / 图片 / 文件动作（`LauncherCommand.id`）。
    static func action(_ commandID: String) -> String {
        actionPrefix + commandID
    }
}

/// 设置页里的六个小节，次序就是 `allCases` 的次序。
enum LauncherFeatureGroup: Int, CaseIterable, Sendable {
    /// 输入文字时在哪些地方找。
    case search
    /// 输入符合某种样子时，第一行直接给出。
    case instant
    /// 放进一段文字后的建议。
    case text
    /// 放进一张图片后的建议。
    case image
    /// 路径行后面的动作。
    case file
    /// 刚呼出、还没打字时。
    case emptyState
}

/// 快速入口自己的功能（框架的，不是哪个模块声明的）：id、属于哪一组、组内次序、图标。名字和说明在 App 侧（`L()`）。
enum LauncherBuiltInFeature: String, CaseIterable, Sendable {
    // 搜索
    case apps = "source/apps"
    case commands = "source/commands"
    case files = "source/files"
    case path = "source/path"
    // 直接给结果
    case calculator = "instant/calculator"
    case textFormat = "instant/textFormat"
    case url = "instant/url"
    case email = "instant/email"
    case color = "instant/color"
    case wordCount = "instant/wordCount"
    case reminder = "instant/reminder"
    // 文字的去处
    case runInTerminal = "suggest/runInTerminal"
    case webSearch = "suggest/webSearch"
    case fileName = "suggest/fileName"
    // 图片的去处
    case imageRecognition = "image/recognition"
    // 文件和文件夹的去处
    case openInTerminal = "path/openInTerminal"
    case copyPath = "path/copyPath"
    // 刚呼出、还没打字时
    case selection = "context/selection"
    case clipboard = "context/clipboard"
    case situational = "context/situational"
    case frequent = "context/frequent"

    var id: String { rawValue }

    var group: LauncherFeatureGroup {
        switch self {
        case .apps, .commands, .files, .path: return .search
        case .calculator, .textFormat, .url, .email, .color, .wordCount, .reminder: return .instant
        case .runInTerminal, .webSearch, .fileName: return .text
        case .imageRecognition: return .image
        case .openInTerminal, .copyPath: return .file
        case .selection, .clipboard, .situational, .frequent: return .emptyState
        }
    }

    /// 组内次序（小的在前）。「文字的去处」里和模块的动作一起按档位排（`LauncherSuggestionTraits.priority`）：
    /// 在终端里运行总是兜底建议第一条（0），上网搜 30、搜文件名 40 —— 同 `LauncherSuggestionRanking`。
    /// 「搜索」里各模块的来源排在命令和文件之间（`LauncherFeatureOrder.moduleSource`）；「图片的去处」里识别结果在所有图片动作前面；
    /// 「文件和文件夹的去处」里在终端里打开、复制路径在模块的文件动作前面（同路径行后面的次序）。
    var order: Int {
        switch self {
        case .apps: return 0
        case .commands: return 10
        case .files: return 30
        case .path: return 40
        case .calculator: return 0
        case .textFormat: return 10
        case .url: return 20
        case .email: return 30
        case .color: return 40
        case .wordCount: return 50
        case .reminder: return 60
        case .runInTerminal: return 0
        case .webSearch: return LauncherSuggestionRanking.webSearch.traits.priority
        case .fileName: return LauncherSuggestionRanking.findFiles.traits.priority
        case .imageRecognition: return 0
        case .openInTerminal: return -20
        case .copyPath: return -10
        case .selection: return 0
        case .clipboard: return 10
        case .situational: return 20
        case .frequent: return 30
        }
    }

    var symbolName: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .commands: return "command"
        case .files: return "doc.text.magnifyingglass"
        case .path: return "folder"
        case .calculator: return "function"
        case .textFormat: return "arrow.left.arrow.right"
        case .url: return "globe"
        case .email: return "envelope"
        case .color: return "paintpalette"
        case .wordCount: return "number"
        case .reminder: return "alarm"
        case .runInTerminal: return "terminal"
        case .webSearch: return "magnifyingglass"
        case .fileName: return "doc.text.magnifyingglass"
        case .imageRecognition: return "qrcode.viewfinder"
        case .openInTerminal: return "terminal"
        case .copyPath: return "doc.on.doc"
        case .selection: return "character.cursor.ibeam"
        case .clipboard: return "doc.on.clipboard"
        case .situational: return "sparkles"
        case .frequent: return "clock.arrow.circlepath"
        }
    }
}

enum LauncherFeatureOrder {
    /// 「搜索」里各模块交来的来源（剪贴板历史、片段……）：命令之后、文件之前，彼此按注册顺序。
    static let moduleSource = 20
}

// MARK: - 开关集合

/// 这次呼出时哪些功能关着（每次呼出读一次，到收起为止不变）。不在 `disabled` 里的都是开着的。
struct LauncherFeatureSet: Equatable, Sendable {
    /// 被关掉的 id（含这次没人声明的、不认识的：原样留着，写回时不丢）。
    let disabled: Set<String>

    static let allEnabled = LauncherFeatureSet()

    init(disabled: Set<String> = []) {
        self.disabled = disabled
    }

    func isEnabled(_ id: String) -> Bool {
        !disabled.contains(id)
    }

    func isEnabled(_ feature: LauncherBuiltInFeature) -> Bool {
        isEnabled(feature.id)
    }

    func isSourceEnabled(_ sourceID: String) -> Bool {
        isEnabled(LauncherFeatureID.source(sourceID))
    }

    func isActionEnabled(_ commandID: String) -> Bool {
        isEnabled(LauncherFeatureID.action(commandID))
    }

    /// 打开 / 关掉一项，返回新的集合。
    func setting(_ id: String, enabled: Bool) -> LauncherFeatureSet {
        setting([id], enabled: enabled)
    }

    /// 打开 / 关掉一批（小节标题右边的「全部打开 / 全部关闭」）。别的 id（含不认识的）不动。
    func setting<S: Sequence>(_ ids: S, enabled: Bool) -> LauncherFeatureSet where S.Element == String {
        var next = disabled
        if enabled {
            next.subtract(ids)
        } else {
            next.formUnion(ids)
        }
        return LauncherFeatureSet(disabled: next)
    }

    /// 模块声明的动作里开着的（文字、图片、文件动作都用它；呼出时收集那一步过滤一次）。保持原来的次序。
    func enabledActions(_ actions: [LauncherCatalogCommand]) -> [LauncherCatalogCommand] {
        actions.filter { isActionEnabled($0.command.id) }
    }

    /// 来源前缀（`LauncherQuery.parse` 用的）：只留这次装进来、而且开着的来源的。关掉的来源前缀跟着失效 ——
    /// 关掉文件后 `f readme` 整段当查询词。
    func prefixes(_ prefixBySource: [String: String], loadedSources: Set<String>) -> [String: String] {
        prefixBySource.filter { loadedSources.contains($0.key) && isSourceEnabled($0.key) }
    }
}

// MARK: - 设置键

enum LauncherFeatureSettings {
    /// 被关掉的功能 id（字符串数组）。不在里面的都是开着的。
    static let key = "launcher.disabledFeatures"

    /// 读。键不存在、类型不对 → 全开；数组里不是字符串的、空的跳过，不认识的 id 原样留着。
    static func load(from defaults: UserDefaults = .standard) -> LauncherFeatureSet {
        guard let raw = defaults.array(forKey: key) else { return .allEnabled }
        let ids = raw.compactMap { $0 as? String }.filter { !$0.isEmpty }
        return LauncherFeatureSet(disabled: Set(ids))
    }

    /// 写（排好序，结果稳定）。全开时删掉这个键。
    static func save(_ features: LauncherFeatureSet, to defaults: UserDefaults = .standard) {
        if features.disabled.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(features.disabled.sorted(), forKey: key)
        }
    }
}

// MARK: - 设置页的行与小节

/// 设置页里的一行：一项功能。文案已本地化（App 侧给）。
struct LauncherFeatureRow: Equatable, Sendable {
    let id: String
    let group: LauncherFeatureGroup
    let title: String
    /// 名字下面一行小字的说明；nil = 没有。
    var detail: String?
    /// 右侧次要色小字：所属工具名（模块声明的）；nil = 快速入口自己的，或和名字一样。
    var toolName: String?
    let symbolName: String
    /// 组内次序，小的在前；相同的保持传入的先后。
    var order: Int
}

/// 设置页的一个小节。
struct LauncherFeatureSection: Equatable, Sendable {
    let group: LauncherFeatureGroup
    let rows: [LauncherFeatureRow]

    var ids: [String] { rows.map(\.id) }

    /// 小节标题右边的按钮：这一节里有关着的 → 「全部打开」（true）；全开着 → 「全部关闭」（false）。
    func offersEnableAll(in features: LauncherFeatureSet) -> Bool {
        rows.contains { !features.isEnabled($0.id) }
    }
}

enum LauncherFeatureLayout {
    /// 分组、排序：组按 `LauncherFeatureGroup` 的次序，组内按 `order`（相同的保持传入的先后）；同一个 id 只留第一行；
    /// 一行都没有的组不出。
    static func sections(_ rows: [LauncherFeatureRow]) -> [LauncherFeatureSection] {
        var seen: Set<String> = []
        let unique = rows.filter { seen.insert($0.id).inserted }
        return LauncherFeatureGroup.allCases.compactMap { group in
            let members = unique.enumerated().filter { $0.element.group == group }
                .sorted { lhs, rhs in
                    lhs.element.order != rhs.element.order ? lhs.element.order < rhs.element.order : lhs.offset < rhs.offset
                }
                .map(\.element)
            return members.isEmpty ? nil : LauncherFeatureSection(group: group, rows: members)
        }
    }

    /// 模块声明的动作 → 行：文字动作进「文字的去处」，图片动作进「图片的去处」，文件动作进「文件和文件夹的去处」；
    /// 名字 = 命令的 `settingsTitle`（随状态变的标题给的固定名字），没有就是标题；右侧 = 所属工具名，图标 = 命令自己的；次序 = 默认档位（`suggestion.priority`），同档按传入的先后
    /// （模块注册顺序、模块里写的顺序）—— 和面板里默认的次序一致。
    static func actionRows(text: [LauncherCatalogCommand], image: [LauncherCatalogCommand],
                           file: [LauncherCatalogCommand]) -> [LauncherFeatureRow] {
        func rows(_ entries: [LauncherCatalogCommand], group: LauncherFeatureGroup) -> [LauncherFeatureRow] {
            entries.map { entry in
                LauncherFeatureRow(id: LauncherFeatureID.action(entry.command.id), group: group,
                                   title: entry.command.settingsTitle ?? entry.command.title,
                                   toolName: entry.toolName.isEmpty ? nil : entry.toolName,
                                   symbolName: entry.command.symbolName, order: entry.command.suggestion.priority)
            }
        }
        return rows(text, group: .text) + rows(image, group: .image) + rows(file, group: .file)
    }

    /// 模块交来的来源 → 「搜索」里的行。右侧写所属工具名，和来源名一样时不写（剪贴板历史的来源名就叫「剪贴板」）。
    static func sourceRow(sourceID: String, name: String, toolName: String, symbolName: String) -> LauncherFeatureRow {
        LauncherFeatureRow(id: LauncherFeatureID.source(sourceID), group: .search, title: name,
                           toolName: toolName.isEmpty || toolName == name ? nil : toolName,
                           symbolName: symbolName, order: LauncherFeatureOrder.moduleSource)
    }
}

// MARK: - 面板里的规则

enum LauncherFeatureRules {
    /// 兜底建议里快速入口自己的两条（上网搜、搜文件名）里开着的。搜文件名要文件来源也开着（它把输入改成 `f <文字>`）。
    static func fallbackBuiltIns(_ features: LauncherFeatureSet) -> [LauncherSuggestionCandidate] {
        var builtIns: [LauncherSuggestionCandidate] = []
        if features.isEnabled(.webSearch) { builtIns.append(LauncherSuggestionRanking.webSearch) }
        if features.isEnabled(.fileName), features.isEnabled(.files) { builtIns.append(LauncherSuggestionRanking.findFiles) }
        return builtIns
    }

    /// 「文字的去处」一项都没开着（模块的文字动作已经按开关过滤过，`textActionCount` 是剩下的条数）。
    static func allTextSuggestionsOff(textActionCount: Int, features: LauncherFeatureSet) -> Bool {
        textActionCount == 0 && fallbackBuiltIns(features).isEmpty && !features.isEnabled(.runInTerminal)
    }

    /// 非空输入在所有建议都被关掉时、列表一行都没有：「没有结果」的位置换成一行不可选的小字「建议都关掉了，可以在设置里打开」。
    /// 只在没打前缀、输入够出兜底建议的长度（`LauncherSuggestionPolicy.minimumFallbackLength`）时 —— 短输入、打了前缀时本来就没有建议，
    /// 照旧是「没有结果」。
    static func showsSuggestionsOff(query: LauncherQuery, rowCount: Int, textActionCount: Int,
                                    features: LauncherFeatureSet) -> Bool {
        guard rowCount == 0, query.isUnscoped,
              query.text.index(query.text.startIndex, offsetBy: LauncherSuggestionPolicy.minimumFallbackLength,
                               limitedBy: query.text.endIndex) != nil else { return false }
        return allTextSuggestionsOff(textActionCount: textActionCount, features: features)
    }

    /// 图片版（验证后定）：挂着图片、一行都没有，而且「图片的去处」一项都没开着 —— 图片动作过滤后为 0（`imageActionCount`）、
    /// 带 `imageTextPriority` 的文字动作过滤后为 0（`imageTextActionCount`，没有「<命令名>图里的文字」）、识别结果关着。
    /// 这时消息那一行同文字全关：「建议都关掉了，可以在设置里打开」（不管有没有打筛选词：开着的一项都没有，打什么都出不来）。
    static func showsImageSuggestionsOff(rowCount: Int, imageActionCount: Int, imageTextActionCount: Int,
                                         features: LauncherFeatureSet) -> Bool {
        rowCount == 0 && imageActionCount == 0 && imageTextActionCount == 0 && !features.isEnabled(.imageRecognition)
    }
}

// MARK: - 读选区的开关

/// 呼出时读不读选区（日志里写的是 `logLabel`）。
enum LauncherSelectionStart: Equatable, Sendable {
    /// 在后台读，读完回调。
    case reading
    /// 「带上你选中的文字」关着：不读（不做那次辅助功能调用）。
    case off
    /// 呼出前的前台就是 Baobox 自己。
    case noApp

    var logLabel: String {
        switch self {
        case .reading: return "reading"
        case .off: return "off"
        case .noApp: return "no app"
        }
    }
}

extension LauncherSelectionFetcher {
    /// 呼出时调：「带上你选中的文字」关着就**不调取词函数**（不只是不显示）；呼出前的前台是 Baobox 自己（`pid` 为 nil）也不读；
    /// 否则在后台读 `pid` 里选中的文字（`start`），读完在主线程调 `completion`。
    func begin(features: LauncherFeatureSet, pid: pid_t?,
               read: @escaping @Sendable (pid_t, TimeInterval) -> LauncherSelectionOutcome,
               completion: @escaping @MainActor (LauncherSelectionRead) -> Void) -> LauncherSelectionStart {
        guard features.isEnabled(.selection) else { return .off }
        guard let pid else { return .noApp }
        start({ budget in read(pid, budget) }, completion: completion)
        return .reading
    }
}
