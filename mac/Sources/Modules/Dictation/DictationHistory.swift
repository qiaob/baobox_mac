import Foundation

/// 一条听写历史（docs/dictation/TECH_DESIGN.md §8）：只存文字、时间、目标 App，不存音频。
struct DictationRecord: Identifiable, Equatable {
    struct App: Codable, Equatable {
        var bundleID: String?
        var name: String?
    }

    let id: UUID
    var date: Date
    var app: App?
    var text: String

    init(id: UUID = UUID(), date: Date = Date(), app: App? = nil, text: String) {
        self.id = id
        self.date = date
        self.app = app
        self.text = text
    }
}

/// 解析全程容错：缺字段 / 类型不对只降级（没有 id 补一个、日期坏了记成很久以前、App 坏了当没有），
/// 只有正文缺了的那条才跳过 —— 一条坏记录不连累整个文件。
extension DictationRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, date, app, text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        date = DictationHistoryCodec.decodeDate(in: container, forKey: .date) ?? .distantPast
        app = try? container.decode(App.self, forKey: .app)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(DictationHistoryCodec.dateString(date), forKey: .date)
        try container.encodeIfPresent(app, forKey: .app)
        try container.encode(text, forKey: .text)
    }
}

/// `history.json` 的编解码与增删规则（纯逻辑，可单测）。文件里是新的在前的数组。
enum DictationHistoryCodec {
    static let defaultLimit = 50
    static let limitRange = 10...500

    /// 整个文件读不成数组时返回 nil（调用方把坏文件改名留底）；数组里的坏条目逐条跳过。
    static func decode(_ data: Data) -> [DictationRecord]? {
        guard let items = try? JSONDecoder().decode([LossyRecord].self, from: data) else { return nil }
        var seen = Set<UUID>()
        return items.compactMap(\.record).filter { seen.insert($0.id).inserted }
    }

    static func encode(_ records: [DictationRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(records)
    }

    /// 加一条到最前面，按上限截断。
    static func adding(_ record: DictationRecord, to records: [DictationRecord], limit: Int) -> [DictationRecord] {
        var result = [record] + records.filter { $0.id != record.id }
        let cap = clampLimit(limit)
        if result.count > cap { result.removeLast(result.count - cap) }
        return result
    }

    /// 启动时读盘慢一拍：读到之前已经新加了几条，就把读到的接在后面（去重、截断）。
    static func merging(current: [DictationRecord], loaded: [DictationRecord], limit: Int) -> [DictationRecord] {
        let ids = Set(current.map(\.id))
        var result = current + loaded.filter { !ids.contains($0.id) }
        let cap = clampLimit(limit)
        if result.count > cap { result.removeLast(result.count - cap) }
        return result
    }

    static func clampLimit(_ limit: Int) -> Int {
        min(max(limit, limitRange.lowerBound), limitRange.upperBound)
    }

    // MARK: - 日期：ISO 8601 字符串；也认带小数秒的、以及秒数（1970 起）

    private static let plainFormatter = ISO8601DateFormatter()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func dateString(_ date: Date) -> String {
        plainFormatter.string(from: date)
    }

    static func decodeDate<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, forKey key: Key) -> Date? {
        if let string = try? container.decode(String.self, forKey: key) {
            return plainFormatter.date(from: string) ?? fractionalFormatter.date(from: string)
        }
        if let seconds = try? container.decode(Double.self, forKey: key), seconds.isFinite {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// 数组里的一项：解不出来就是 nil，不让整个数组失败。
    private struct LossyRecord: Decodable {
        let record: DictationRecord?

        init(from decoder: Decoder) throws {
            record = try? DictationRecord(from: decoder)
        }
    }
}

/// 听写历史相关的 UserDefaults 键（设置页与历史窗口共用）。
enum DictationHistoryDefaults {
    static let enabledKey = "dictation.historyEnabled"
    static let limitKey = "dictation.historyLimit"
}
