import Foundation

// 快速入口的使用记录（docs/launcher/TECH_DESIGN.md §5.3）：哪一行用了几次、最近一次是什么时候，
// 「这个输入上次选了谁」，别名，隐藏的行。这里只有模型和纯函数 —— 当前时间由调用方传入，不读写磁盘；
// 落盘（`usage.json`、防抖、`StorageWriteFailure`）在 App 侧另做。只依赖 Foundation，进 BaoboxTests。
//
// 条目键 = 「来源 id/条目 id」（`LauncherCandidate.key(sourceID:entryID:)`），来源 id 里没有 `/`。

/// 使用记录的全部内容，整个编码成一个 JSON。
struct LauncherUsageRecords: Equatable, Sendable {

    /// 一个条目的使用情况。
    struct Usage: Equatable, Sendable {
        /// 用过的次数（≥ 1）。
        var count: Int
        /// 最近一次使用的时间。
        var last: Date
    }

    /// 一个输入上次选的条目。
    struct Choice: Equatable, Sendable {
        var key: String
        /// 选的时间（裁剪时删最久的）。
        var last: Date
    }

    static let currentVersion = 1
    /// `usage` 与 `choices` 各自的上限，超出删最久没用的。
    static let maxEntries = 2000
    /// 使用分的半衰期：14 天。
    static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    /// 使用分上限。
    static let usageScoreCap = 300.0
    /// 次数每翻一倍加多少分：用 1 次 100、3 次 200、7 次及以上 300（封顶）。
    static let usagePointsPerDoubling = 100.0
    /// 「输入 → 选了谁」只记输入的前多少个字符。
    static let inputPrefixLength = 20
    /// 不记使用次数的来源：剪贴板条目本来就按时间排（§5.3）。
    static let untrackedSourceIDs: Set<String> = ["clipboard"]
    /// 次数的上限，防溢出。
    static let maxCount = 1_000_000

    /// 读进来的文件的格式版本（新建的就是 `currentVersion`）；写出去总是 `currentVersion`。
    private(set) var version = LauncherUsageRecords.currentVersion
    /// 条目键 → 使用情况。
    private(set) var usage: [String: Usage] = [:]
    /// 归一化后的输入（`normalizedInput`）→ 上次选的条目。
    private(set) var choices: [String: Choice] = [:]
    /// 条目键 → 别名（保留用户输入的大小写，比较时不分大小写）。别名在所有条目里唯一。
    private(set) var aliases: [String: String] = [:]
    /// 隐藏的条目键。
    private(set) var hidden: Set<String> = []

    init() {}

    /// 条目键里的来源 id（第一个 `/` 之前；没有 `/` 时是整个键）。
    static func sourceID(ofKey key: String) -> String {
        guard let slash = key.firstIndex(of: "/") else { return key }
        return String(key[..<slash])
    }

    // MARK: - 使用次数

    /// 记一次使用：次数 +1、最近一次 = `now`。`untrackedSourceIDs` 里的来源不记。超过上限时删最久没用的。
    mutating func recordUse(of key: String, at now: Date) {
        guard !key.isEmpty, !Self.untrackedSourceIDs.contains(Self.sourceID(ofKey: key)) else { return }
        let count = min((usage[key]?.count ?? 0) + 1, Self.maxCount)
        usage[key] = Usage(count: count, last: now)
        if usage.count > Self.maxEntries {
            usage = Self.pruned(usage, limit: Self.maxEntries, keeping: key, date: \.last)
        }
    }

    /// 这个条目此刻的使用分（0…300）。没记录为 0。
    func usageScore(for key: String, now: Date) -> Double {
        guard let entry = usage[key] else { return 0 }
        return Self.usageScore(count: entry.count, last: entry.last, now: now)
    }

    /// 使用分 = min(300, 100 × log2(1 + 次数)) × 0.5 ^ (距最近一次的天数 / 14)。
    /// 先封顶再衰减，所以不管用过多少次，14 天没用就是一半。最近一次在 `now` 之后（改过系统时间）按刚用过算。
    static func usageScore(count: Int, last: Date, now: Date) -> Double {
        guard count > 0 else { return 0 }
        let base = min(usageScoreCap, usagePointsPerDoubling * log2(1 + Double(count)))
        let age = max(0, now.timeIntervalSince(last))
        return base * pow(0.5, age / halfLife)
    }

    // MARK: - 输入 → 选了谁

    /// 输入归一化：去首尾空白、转小写、只取前 20 个字符。
    static func normalizedInput(_ input: String) -> String {
        String(input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(inputPrefixLength))
    }

    /// 记「这个输入选了这个条目」。归一化后为空的输入不记。超过上限时删最久的。
    mutating func recordChoice(_ key: String, forInput input: String, at now: Date) {
        let normalized = Self.normalizedInput(input)
        guard !normalized.isEmpty, !key.isEmpty else { return }
        choices[normalized] = Choice(key: key, last: now)
        if choices.count > Self.maxEntries {
            choices = Self.pruned(choices, limit: Self.maxEntries, keeping: normalized, date: \.last)
        }
    }

    /// 这个输入上次选的条目键；没有为 nil。
    func rememberedKey(forInput input: String) -> String? {
        let normalized = Self.normalizedInput(input)
        guard !normalized.isEmpty else { return nil }
        return choices[normalized]?.key
    }

    // MARK: - 别名

    /// 别名比较用的形式：去首尾空白、转小写。
    static func normalizedAlias(_ alias: String) -> String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 设别名；nil 或空白 = 删掉这个条目的别名。别名唯一：别的条目已经用了同一个别名（不分大小写）时，从那个条目上拿掉。
    mutating func setAlias(_ alias: String?, for key: String) {
        guard !key.isEmpty else { return }
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            aliases[key] = nil
            return
        }
        let normalized = trimmed.lowercased()
        for (other, existing) in aliases where other != key && Self.normalizedAlias(existing) == normalized {
            aliases[other] = nil
        }
        aliases[key] = trimmed
    }

    /// 查询完全等于哪个条目的别名（去首尾空白、不分大小写）；没有为 nil。
    /// 坏数据里同一个别名挂在几个条目上时取键最小的，结果稳定。
    func key(forAlias query: String) -> String? {
        let normalized = Self.normalizedAlias(query)
        guard !normalized.isEmpty else { return nil }
        return aliases.filter { Self.normalizedAlias($0.value) == normalized }.keys.min()
    }

    // MARK: - 隐藏

    mutating func hide(_ key: String) {
        guard !key.isEmpty else { return }
        hidden.insert(key)
    }

    mutating func unhide(_ key: String) {
        hidden.remove(key)
    }

    func isHidden(_ key: String) -> Bool {
        hidden.contains(key)
    }

    // MARK: - 清空与裁剪

    /// 清除使用记录（设置页的按钮）：次数和「输入 → 选了谁」清空；别名和隐藏的行是用户设的，保留。
    mutating func clearUsage() {
        usage = [:]
        choices = [:]
    }

    /// 把 `usage`、`choices` 各裁到 `limit` 条以内，删最久没用的。记录时超限会自动裁，这里给读进来的旧文件用。
    mutating func prune(limit: Int = LauncherUsageRecords.maxEntries) {
        usage = Self.pruned(usage, limit: limit, keeping: nil, date: \.last)
        choices = Self.pruned(choices, limit: limit, keeping: nil, date: \.last)
    }

    /// 留下最近的 `limit` 条；时间相同按键排，结果稳定。`keeping` 是刚写进去的那条，改过系统时间时也不删它。
    private static func pruned<Value>(_ entries: [String: Value], limit: Int, keeping: String?,
                                      date: (Value) -> Date) -> [String: Value] {
        let limit = max(0, limit)
        guard entries.count > limit else { return entries }
        let newestFirst = entries.sorted { lhs, rhs in
            if lhs.key == keeping { return rhs.key != keeping }
            if rhs.key == keeping { return false }
            let (l, r) = (date(lhs.value), date(rhs.value))
            return l != r ? l > r : lhs.key < rhs.key
        }
        return Dictionary(uniqueKeysWithValues: newestFirst.prefix(limit).map { ($0.key, $0.value) })
    }
}

// MARK: - 编解码

// 格式：{"version":1,"usage":{"apps/…":{"count":3,"last":1700000000}},"choices":{"saf":{"key":"apps/…","last":…}},
//        "aliases":{"commands/…":"ocr"},"hidden":["clipboard/…"]}
// 时间写成 1970 年起的秒数（不依赖 JSONEncoder 的日期策略）。
// 解码全程容错：缺字段、类型不对、单个条目坏了都只跳过那一处，永不抛错（顶层不是对象时得到空记录）；版本号比当前新也照读认得的字段。

extension LauncherUsageRecords: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, usage, choices, aliases, hidden
    }

    init(from decoder: Decoder) throws {
        self.init()
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        if let version = try? container.decodeIfPresent(Int.self, forKey: .version) {
            self.version = version
        }
        if let raw = try? container.decodeIfPresent([String: LauncherLossy<Usage>].self, forKey: .usage) {
            for (key, entry) in raw where !key.isEmpty {
                if let value = entry.value { usage[key] = value }
            }
        }
        if let raw = try? container.decodeIfPresent([String: LauncherLossy<Choice>].self, forKey: .choices) {
            for (input, entry) in raw where !input.isEmpty {
                if let value = entry.value { choices[input] = value }
            }
        }
        if let raw = try? container.decodeIfPresent([String: LauncherLossy<String>].self, forKey: .aliases) {
            for (key, entry) in raw where !key.isEmpty {
                let alias = entry.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !alias.isEmpty { aliases[key] = alias }
            }
        }
        if let raw = try? container.decodeIfPresent([LauncherLossy<String>].self, forKey: .hidden) {
            hidden = Set(raw.compactMap(\.value).filter { !$0.isEmpty })
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(usage, forKey: .usage)
        try container.encode(choices, forKey: .choices)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(hidden.sorted(), forKey: .hidden)
    }
}

extension LauncherUsageRecords.Usage: Codable {
    private enum CodingKeys: String, CodingKey {
        case count, last
    }

    /// 次数必须 ≥ 1（写成 3.0 也认），时间必须是有限的秒数；不合格就抛错，由外层跳过这一条。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let count: Int
        if let integer = try? container.decode(Int.self, forKey: .count) {
            count = integer
        } else {
            let number = try container.decode(Double.self, forKey: .count)
            guard number.isFinite, number < Double(LauncherUsageRecords.maxCount) else {
                throw DecodingError.dataCorruptedError(forKey: .count, in: container, debugDescription: "count")
            }
            count = Int(number)
        }
        guard count >= 1 else {
            throw DecodingError.dataCorruptedError(forKey: .count, in: container, debugDescription: "count < 1")
        }
        self.count = min(count, LauncherUsageRecords.maxCount)
        self.last = try LauncherUsageRecords.decodeDate(from: container, forKey: .last)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        try container.encode(last.timeIntervalSince1970, forKey: .last)
    }
}

extension LauncherUsageRecords.Choice: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, last
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        guard !key.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "empty key")
        }
        self.key = key
        self.last = try LauncherUsageRecords.decodeDate(from: container, forKey: .last)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(last.timeIntervalSince1970, forKey: .last)
    }
}

extension LauncherUsageRecords {
    /// 1970 年起的秒数 → Date；不是有限数就抛错。
    fileprivate static func decodeDate<Key: CodingKey>(from container: KeyedDecodingContainer<Key>,
                                                       forKey key: Key) throws -> Date {
        let seconds = try container.decode(Double.self, forKey: key)
        guard seconds.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "date")
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// 解码失败时不抛错、得到 nil 的包装：字典或数组里一个坏元素只丢它自己。
private struct LauncherLossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
