import Foundation

// 数据导出与导入（docs/data-export/DESIGN.md）：备份文件的格式、编解码与合并规则。
// 纯逻辑：只依赖 Foundation 和几个模块的模型文件（ClipboardItem、DictationHistory、FocusHealthModels、
// FocusHealthSettings、FocusHistory），不碰界面和单例，可脱离 App 单独编译测试。
// 面板、弹窗、从各模块取数据和写回去在 PersonalDataTransfer.swift。

/// 备份里的一条文本片段 = 一条文本类收藏（docs/snippets/DESIGN.md：片段就是收藏条目）。
struct BackupSnippet: Equatable {
    var id: UUID
    var title: String?
    var content: String
    var keyword: String?
    var createdAt: Date
    /// 剪贴板里记成链接（`ClipboardItemType.link`）的。
    var isLink: Bool

    init(id: UUID, title: String?, content: String, keyword: String?, createdAt: Date, isLink: Bool) {
        self.id = id
        self.title = title
        self.content = content
        self.keyword = keyword
        self.createdAt = createdAt
        self.isLink = isLink
    }

    init(item: ClipboardItem) {
        self.init(id: item.id, title: item.title, content: item.text ?? "", keyword: item.keyword,
                  createdAt: item.createdAt, isLink: item.type == .link)
    }
}

/// 只有正文缺了的那条才跳过；没有 id 补一个，时间坏了记成导入那一刻。
extension BackupSnippet: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, content, keyword, createdAt, type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decode(String.self, forKey: .content)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        keyword = (try? c.decodeIfPresent(String.self, forKey: .keyword)) ?? nil
        createdAt = FocusHistoryCodec.decodeDate(in: c, forKey: .createdAt) ?? Date()
        isLink = ((try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil) == ClipboardItemType.link.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(keyword, forKey: .keyword)
        try c.encode(FocusHistoryCodec.dateString(createdAt), forKey: .createdAt)
        try c.encode(isLink ? ClipboardItemType.link.rawValue : ClipboardItemType.text.rawValue, forKey: .type)
    }
}

/// 一个设置值（UserDefaults 里存的只有这三种）。
enum BackupSettingValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)

    /// 写回 UserDefaults 用。
    var storedObject: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Int.self) {
            self = .int(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported setting value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try c.encode(value)
        case .int(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        }
    }
}

/// 一个能进备份的设置键：类型、出厂值、合法范围。
struct BackupSettingSpec {
    enum Kind {
        case bool
        case int(ClosedRange<Int>)
        case string([String])
    }

    let key: String
    let kind: Kind
    let factory: BackupSettingValue

    /// 类型对、在范围里。
    func accepts(_ value: BackupSettingValue) -> Bool {
        switch (kind, value) {
        case (.bool, .bool): return true
        case (.int(let range), .int(let number)): return range.contains(number)
        case (.string(let allowed), .string(let text)): return allowed.contains(text)
        default: return false
        }
    }

    /// UserDefaults 里读出来的对象（NSNumber / String）按本键的类型转过来；类型不对返回 nil。
    func value(fromStored object: Any) -> BackupSettingValue? {
        switch kind {
        case .bool: return (object as? Bool).map { .bool($0) }
        case .int: return (object as? Int).map { .int($0) }
        case .string: return (object as? String).map { .string($0) }
        }
    }
}

struct BackupFocusHealth: Equatable {
    var items: [ReminderItem] = []
    /// 本机设过的专注与健康设置键（没设过 = 出厂值，不写进来）。
    var settings: [String: BackupSettingValue] = [:]
}

/// 整个备份文件（docs/data-export/DESIGN.md §2）。
struct BaoboxBackup: Equatable {
    static let format = "baobox-export"
    static let currentVersion = 1

    var version = BaoboxBackup.currentVersion
    var exportedAt: Date
    var app: String
    var snippets: [BackupSnippet] = []
    var dictationHistory: [DictationRecord] = []
    var focusHealth = BackupFocusHealth()
    var focusHistory: [FocusHistoryRecord] = []

    /// 专注与健康进备份的设置键。出厂值和范围同 FocusHealthSettings 的读法（探针逐个核对过）。
    /// 宠物关闭时的背景图片是这台 Mac 上的文件路径，不进备份；背景选了「图片」的那一项也就不导出、不导入。
    static let focusSettingSpecs: [BackupSettingSpec] = [
        BackupSettingSpec(key: FocusHealthSettings.remindersEnabledKey, kind: .bool, factory: .bool(true)),
        BackupSettingSpec(key: FocusHealthSettings.defaultMinutesKey, kind: .int(5...180), factory: .int(25)),
        BackupSettingSpec(key: FocusHealthSettings.shortBreakKey, kind: .int(1...30), factory: .int(5)),
        BackupSettingSpec(key: FocusHealthSettings.longBreakKey, kind: .int(5...60), factory: .int(15)),
        BackupSettingSpec(key: FocusHealthSettings.longEveryKey, kind: .int(2...8), factory: .int(4)),
        BackupSettingSpec(key: FocusHealthSettings.autoNextKey, kind: .bool, factory: .bool(false)),
        BackupSettingSpec(key: FocusHealthSettings.strengthKey, kind: .string(BreakStrength.allCases.map(\.rawValue)),
                          factory: .string(BreakStrength.standard.rawValue)),
        BackupSettingSpec(key: FocusHealthSettings.maxSnoozesKey, kind: .int(0...5), factory: .int(2)),
        BackupSettingSpec(key: FocusHealthSettings.backdropKey, kind: .string(["teal", "dusk", "forest"]),
                          factory: .string("teal")),
        BackupSettingSpec(key: FocusHealthSettings.workStartKey, kind: .int(0...(24 * 60 - 1)), factory: .int(9 * 60)),
        BackupSettingSpec(key: FocusHealthSettings.workEndKey, kind: .int(0...(24 * 60 - 1)), factory: .int(18 * 60)),
        BackupSettingSpec(key: FocusHealthSettings.workdaysOnlyKey, kind: .bool, factory: .bool(true)),
        BackupSettingSpec(key: FocusHealthSettings.minSpacingKey, kind: .int(10...30), factory: .int(15)),
        BackupSettingSpec(key: FocusHealthSettings.confirmIdentityKey, kind: .bool, factory: .bool(true)),
    ]
}

/// 读不了的文件：什么都不改，提示一句。
enum BackupReadError: Error, Equatable {
    /// 不是 JSON、不是 Baobox 导出的文件、没有版本号。
    case unreadable
    /// 更新版本的 Baobox 导出的（版本号比这一版认识的高）。
    case newerVersion(Int)
}

/// 备份文件的编解码。解析全程容错：某一节缺了或类型不对当它是空的，数组里的坏条目逐条跳过。
enum BaoboxBackupCodec {
    static func encode(_ backup: BaoboxBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) -> Result<BaoboxBackup, BackupReadError> {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data),
              header.format == BaoboxBackup.format, let version = header.version, version >= 1 else {
            return .failure(.unreadable)
        }
        guard version <= BaoboxBackup.currentVersion else { return .failure(.newerVersion(version)) }
        guard let backup = try? decoder.decode(BaoboxBackup.self, from: data) else { return .failure(.unreadable) }
        return .success(backup)
    }

    private struct Header: Decodable {
        let format: String?
        let version: Int?
    }
}

extension BaoboxBackup: Codable {
    private enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, app, snippets, dictationHistory, focusHealth, focusHistory
    }

    private enum FocusHealthKeys: String, CodingKey {
        case items, settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? BaoboxBackup.currentVersion
        exportedAt = FocusHistoryCodec.decodeDate(in: c, forKey: .exportedAt) ?? .distantPast
        app = ((try? c.decodeIfPresent(String.self, forKey: .app)) ?? nil) ?? ""
        snippets = Self.lossy(BackupSnippet.self, in: c, forKey: .snippets)
        dictationHistory = Self.lossy(DictationRecord.self, in: c, forKey: .dictationHistory)
        focusHistory = Self.lossy(FocusHistoryRecord.self, in: c, forKey: .focusHistory)
        focusHealth = BackupFocusHealth()
        if let health = try? c.nestedContainer(keyedBy: FocusHealthKeys.self, forKey: .focusHealth) {
            focusHealth.items = Self.lossy(ReminderItem.self, in: health, forKey: .items)
            let settings = (try? health.decodeIfPresent([String: Lossy<BackupSettingValue>].self, forKey: .settings))
                ?? nil
            focusHealth.settings = (settings ?? [:]).compactMapValues(\.value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(BaoboxBackup.format, forKey: .format)
        try c.encode(version, forKey: .version)
        try c.encode(FocusHistoryCodec.dateString(exportedAt), forKey: .exportedAt)
        try c.encode(app, forKey: .app)
        try c.encode(snippets, forKey: .snippets)
        try c.encode(dictationHistory, forKey: .dictationHistory)
        var health = c.nestedContainer(keyedBy: FocusHealthKeys.self, forKey: .focusHealth)
        try health.encode(focusHealth.items, forKey: .items)
        try health.encode(focusHealth.settings, forKey: .settings)
        try c.encode(focusHistory, forKey: .focusHistory)
    }

    private static func lossy<T: Decodable, Key: CodingKey>(_ type: T.Type, in container: KeyedDecodingContainer<Key>,
                                                            forKey key: Key) -> [T] {
        let items = (try? container.decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil
        return (items ?? []).compactMap(\.value)
    }
}

/// 数组 / 字典里的一项：解不出来就是 nil，不让整节失败（同 DictationHistoryCodec 的 LossyRecord）。
private struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// 这台 Mac 上已有的东西（导出读它，导入拿它比对）。主线程从各模块抄一份进来。
struct BackupLocalState {
    var clipboardItems: [ClipboardItem] = []
    var dictation: [DictationRecord] = []
    var dictationLimit = DictationHistoryCodec.defaultLimit
    var reminders: [ReminderItem] = []
    var focusHistory: [FocusHistoryRecord] = []
    /// 本机设过的专注与健康设置（`BackupMerge.storedFocusSettings` 读出来的）。
    var focusSettings: [String: BackupSettingValue] = [:]
    /// 剪贴板模块在不在：不在就既不导出也不导入片段。
    var snippetsAvailable = true
}

/// 导入摘要与要写回去的东西（docs/data-export/DESIGN.md §3）。
struct BackupImportPlan: Equatable {
    var snippetsInFile = 0
    var newSnippets: [ClipboardItem] = []
    /// 和本机片段撞了、导入的那条去掉的关键字（不含前缀，按文件里的顺序）。
    var keywordConflicts: [String] = []
    var dictationInFile = 0
    /// 合并好的整份听写历史（新的在前、已按上限截断）。
    var dictationMerged: [DictationRecord] = []
    var dictationAdded = 0
    /// 合并后超过听写历史的条数上限，最旧的截掉了。
    var dictationCapped = false
    var remindersInFile = 0
    var newReminders: [ReminderItem] = []
    var historyInFile = 0
    var historyAdded = 0
    /// 只改本机还是出厂值的那几项。
    var settingsToApply: [String: BackupSettingValue] = [:]

    var hasChanges: Bool {
        !newSnippets.isEmpty || dictationAdded > 0 || !newReminders.isEmpty || historyAdded > 0
            || !settingsToApply.isEmpty
    }
}

/// 导出取哪些、导入怎么合并（纯函数）。
enum BackupMerge {
    /// 进备份的片段：设置 → 剪贴板 → 文本片段里列的那些（文本类收藏）；来源标成敏感的（密码管理器复制的）不导出。
    static func isExportableSnippet(_ item: ClipboardItem) -> Bool {
        item.isPinned && (item.type == .text || item.type == .link) && !item.isConcealed
    }

    /// 本机设过的专注与健康设置：UserDefaults 里有这个键、类型对、在范围里。`stored` 一般是 `UserDefaults.object(forKey:)`。
    static func storedFocusSettings(_ stored: (String) -> Any?) -> [String: BackupSettingValue] {
        var result: [String: BackupSettingValue] = [:]
        for spec in BaoboxBackup.focusSettingSpecs {
            guard let object = stored(spec.key), let value = spec.value(fromStored: object), spec.accepts(value) else {
                continue
            }
            result[spec.key] = value
        }
        return result
    }

    static func export(local: BackupLocalState, exportedAt: Date, app: String) -> BaoboxBackup {
        BaoboxBackup(
            exportedAt: exportedAt, app: app,
            snippets: local.snippetsAvailable
                ? local.clipboardItems.filter(isExportableSnippet).map(BackupSnippet.init(item:)) : [],
            dictationHistory: local.dictation,
            focusHealth: BackupFocusHealth(items: local.reminders, settings: local.focusSettings),
            focusHistory: local.focusHistory)
    }

    static func plan(_ backup: BaoboxBackup, local: BackupLocalState, now: Date,
                     calendar: Calendar = .current) -> BackupImportPlan {
        var plan = BackupImportPlan()

        plan.snippetsInFile = backup.snippets.count
        if local.snippetsAvailable {
            let merged = snippets(backup.snippets, into: local.clipboardItems)
            plan.newSnippets = merged.added
            plan.keywordConflicts = merged.conflicts
        }

        plan.dictationInFile = backup.dictationHistory.count
        let dictation = DictationHistoryCodec.importing(backup.dictationHistory, into: local.dictation,
                                                        limit: local.dictationLimit)
        plan.dictationMerged = dictation.records
        plan.dictationAdded = dictation.added
        plan.dictationCapped = dictation.capped

        plan.remindersInFile = backup.focusHealth.items.count
        var reminderIDs = Set(local.reminders.map(\.id))
        plan.newReminders = backup.focusHealth.items.filter { reminderIDs.insert($0.id).inserted }

        plan.historyInFile = backup.focusHistory.count
        let localHistory = Set(local.focusHistory.map(\.identity))
        let history = FocusHistoryCodec.merged(local.focusHistory, backup.focusHistory, now: now, calendar: calendar)
        plan.historyAdded = history.filter { !localHistory.contains($0.identity) }.count

        plan.settingsToApply = settings(backup.focusHealth.settings, local: local.focusSettings)
        return plan
    }

    /// 片段：id 相同（和剪贴板里任何一条）或内容相同（和本机的文本类收藏、和文件里前面的片段）的跳过，其余加进来、都是收藏；
    /// 关键字和本机收藏撞了，导入的那条去掉关键字，撞了的关键字列出来。文件里自己重名的关键字照原样（匹配时取最新的一条）。
    static func snippets(_ incoming: [BackupSnippet],
                         into existing: [ClipboardItem]) -> (added: [ClipboardItem], conflicts: [String]) {
        var ids = Set(existing.map(\.id))
        var contents = Set(existing.filter { $0.isPinned && ($0.type == .text || $0.type == .link) }
            .map { $0.text ?? "" })
        let usedKeywords = Set(existing.filter(\.isPinned).compactMap(\.keyword))
        var added: [ClipboardItem] = []
        var conflicts: [String] = []
        for snippet in incoming {
            guard !ids.contains(snippet.id), !contents.contains(snippet.content) else { continue }
            ids.insert(snippet.id)
            contents.insert(snippet.content)
            var keyword = trimmed(snippet.keyword)
            if let taken = keyword, usedKeywords.contains(taken) {
                if !conflicts.contains(taken) { conflicts.append(taken) }
                keyword = nil
            }
            added.append(ClipboardItem(id: snippet.id, type: snippet.isLink ? .link : .text, text: snippet.content,
                                       imageFilename: nil, sourceAppName: nil, sourceBundleID: nil,
                                       createdAt: snippet.createdAt, isPinned: true, isConcealed: false,
                                       title: trimmed(snippet.title), keyword: keyword))
        }
        return (added, conflicts)
    }

    /// 设置键：只在本机还是出厂值（没设过，或设的就是出厂值）时用导入的值；类型不对、超出范围的跳过；一样的不用写。
    static func settings(_ imported: [String: BackupSettingValue],
                         local: [String: BackupSettingValue]) -> [String: BackupSettingValue] {
        var apply: [String: BackupSettingValue] = [:]
        for spec in BaoboxBackup.focusSettingSpecs {
            guard let value = imported[spec.key], spec.accepts(value) else { continue }
            let current = local[spec.key] ?? spec.factory
            guard current == spec.factory, value != current else { continue }
            apply[spec.key] = value
        }
        return apply
    }

    private static func trimmed(_ raw: String?) -> String? {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
