import Foundation

// 会议的数据模型（docs/meeting/TECH_DESIGN.md §3、§4）。
// 本文件只依赖 Foundation，可脱离 App 单独编译测试；显示文案在 MeetingText.swift。
// meta.json 是外部可改的文件：解析全程容错，字段缺失或类型不对就用默认值，决不让 App 崩溃。

/// 会话类型：线上会议（麦克风 + 系统声音，标「我 / 对方」）/ 线下会议（仅麦克风）/ 自由听译（原实时翻译）。
enum MeetingType: String, Codable, CaseIterable {
    case online
    case offline
    case free
}

/// 纪要状态：记录中 → 仅转录（没模型 / 内容太少 / 没整理完）/ 整理中 → 已生成 / 失败。
enum MeetingStatus: String, Codable, CaseIterable {
    case recording
    case transcribed
    case summarizing
    case summarized
    case failed
}

/// 绑定的日历事件（第二段由 EventKit 填；第一段只有类型，开始记录时可传 nil）。
struct MeetingEventInfo: Equatable, Codable {
    var title: String
    var start: Date
    var end: Date
    /// 参会人显示名（按日历里的顺序）。
    var attendees: [String]
    /// 会议链接（Zoom / 腾讯会议…）。
    var url: URL?
    /// 系列键：重复事件用 `EKEvent.calendarItemExternalIdentifier`，否则规范化标题（见 TECH_DESIGN §4）。
    var seriesKey: String?
    /// `EKEvent.eventIdentifier`。
    var eventID: String?
    /// 来自哪个日历（显示名）。
    var calendarTitle: String?

    init(title: String, start: Date, end: Date, attendees: [String] = [], url: URL? = nil,
         seriesKey: String? = nil, eventID: String? = nil, calendarTitle: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.url = url
        self.seriesKey = seriesKey
        self.eventID = eventID
        self.calendarTitle = calendarTitle
    }
}

/// meta.json 里的 `calendar`：`{"eventID":"…","seriesKey":"…","calendar":"…"}`。
struct MeetingCalendarRef: Equatable, Codable {
    var eventID: String?
    var seriesKey: String?
    var calendar: String?

    init(eventID: String? = nil, seriesKey: String? = nil, calendar: String? = nil) {
        self.eventID = eventID
        self.seriesKey = seriesKey
        self.calendar = calendar
    }

    init(event: MeetingEventInfo) {
        self.init(eventID: event.eventID, seriesKey: event.seriesKey, calendar: event.calendarTitle)
    }

    private enum CodingKeys: String, CodingKey { case eventID, seriesKey, calendar }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventID = MeetingLenient.string(c, .eventID)
        seriesKey = MeetingLenient.string(c, .seriesKey)
        calendar = MeetingLenient.string(c, .calendar)
    }

    var isEmpty: Bool { eventID == nil && seriesKey == nil && calendar == nil }
}

/// 🔖 标记的重点：`t` = 距会议开始的秒数，`text` = 那一段说了什么。
struct MeetingHighlight: Equatable, Codable {
    var t: TimeInterval
    var text: String

    init(t: TimeInterval, text: String) {
        self.t = t
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case t, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = max(0, MeetingLenient.double(c, .t) ?? 0)
        text = MeetingLenient.string(c, .text) ?? ""
    }
}

/// 一条行动项（会后从纪要里解析出来，会议库里可勾选完成）。
struct MeetingActionItem: Equatable, Codable, Identifiable {
    var id: String
    var text: String
    var owner: String?
    var due: String?
    var done: Bool

    init(id: String = UUID().uuidString, text: String, owner: String? = nil, due: String? = nil, done: Bool = false) {
        self.id = id
        self.text = text
        self.owner = owner
        self.due = due
        self.done = done
    }

    private enum CodingKeys: String, CodingKey { case id, text, owner, due, done }

    /// 没有事项文字的条目不算（跳过）；其余字段缺了用默认。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let text = MeetingLenient.string(c, .text) else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "action item without text")
        }
        self.init(id: MeetingLenient.string(c, .id) ?? UUID().uuidString, text: text,
                  owner: MeetingLenient.string(c, .owner), due: MeetingLenient.string(c, .due),
                  done: MeetingLenient.bool(c, .done) ?? false)
    }
}

/// 一场会议的元信息（`Meetings/<yyyy>/<目录>/meta.json`，格式见 TECH_DESIGN §4）。
struct MeetingMeta: Equatable {
    static let currentVersion = 1

    var v: Int
    var id: String
    var type: MeetingType
    var title: String
    var start: Date
    var end: Date?
    var attendees: [String]
    var calendar: MeetingCalendarRef?
    var status: MeetingStatus
    /// 纪要模板：standard / standup / oneOnOne / interview；自由听译是 content。
    var template: String
    var highlights: [MeetingHighlight]
    var actionItems: [MeetingActionItem]
    /// 迁移进来的旧实时翻译记录：原文件的绝对路径（文件原地不动）；新记录为 nil。
    var legacyPath: String?

    init(id: String = UUID().uuidString, type: MeetingType, title: String, start: Date, end: Date? = nil,
         attendees: [String] = [], calendar: MeetingCalendarRef? = nil, status: MeetingStatus = .recording,
         template: String = "standard", highlights: [MeetingHighlight] = [], actionItems: [MeetingActionItem] = [],
         legacyPath: String? = nil) {
        v = Self.currentVersion
        self.id = id
        self.type = type
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.calendar = calendar
        self.status = status
        self.template = template
        self.highlights = highlights
        self.actionItems = actionItems
        self.legacyPath = legacyPath
    }

    var duration: TimeInterval? { end.map { max(0, $0.timeIntervalSince(start)) } }

    var openActionItemCount: Int { actionItems.filter { !$0.done }.count }
}

extension MeetingMeta: Codable {
    private enum CodingKeys: String, CodingKey {
        case v, id, type, title, start, end, attendees, calendar, status, template, highlights, actionItems, legacyPath
    }

    /// 只要是个 JSON 对象就解得出来：缺 id 时为空串、缺开始时间时为 `.distantPast`，由调用方按目录名补
    /// （见 `MeetingLibraryScanner.record`）；认不出的类型 / 状态用默认，坏掉的行动项 / 重点逐条跳过。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = MeetingLenient.int(c, .v) ?? Self.currentVersion
        id = MeetingLenient.string(c, .id) ?? ""
        type = MeetingLenient.string(c, .type).flatMap(MeetingType.init(rawValue:)) ?? .offline
        title = MeetingLenient.string(c, .title) ?? ""
        start = MeetingLenient.date(c, .start) ?? .distantPast
        end = MeetingLenient.date(c, .end)
        attendees = MeetingLenient.strings(c, .attendees)
        let calendar = (try? c.decodeIfPresent(MeetingCalendarRef.self, forKey: .calendar)) ?? nil
        self.calendar = calendar?.isEmpty == true ? nil : calendar
        status = MeetingLenient.string(c, .status).flatMap(MeetingStatus.init(rawValue:)) ?? .transcribed
        template = MeetingLenient.string(c, .template) ?? "standard"
        highlights = MeetingLenient.array(c, .highlights)
        actionItems = MeetingLenient.array(c, .actionItems)
        legacyPath = MeetingLenient.string(c, .legacyPath)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        try c.encode(MeetingDates.string(start), forKey: .start)
        try c.encode(end.map(MeetingDates.string), forKey: .end)
        try c.encode(attendees, forKey: .attendees)
        try c.encode(calendar, forKey: .calendar)
        try c.encode(status, forKey: .status)
        try c.encode(template, forKey: .template)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(actionItems, forKey: .actionItems)
        try c.encode(legacyPath, forKey: .legacyPath)
    }

    /// 读一份 meta.json；不是 JSON 对象（空文件、被截断、整个写坏了）返回 nil。
    static func decode(_ data: Data) -> MeetingMeta? {
        try? JSONDecoder().decode(MeetingMeta.self, from: data)
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }
}

/// 会议库里的一条（index.json 的一个元素）：目录（相对会议库根目录）+ 元信息。
struct MeetingRecord: Equatable, Identifiable {
    /// 「2026/2026-11-06 14-05 设计评审」。
    var dir: String
    var meta: MeetingMeta

    var id: String { meta.id }

    init(dir: String, meta: MeetingMeta) {
        self.dir = dir
        self.meta = meta
    }
}

extension MeetingRecord: Codable {
    private enum CodingKeys: String, CodingKey { case dir, meta }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let dir = MeetingLenient.string(c, .dir) else {
            throw DecodingError.dataCorruptedError(forKey: .dir, in: c, debugDescription: "record without dir")
        }
        let meta = try c.decode(MeetingMeta.self, forKey: .meta)
        guard !meta.id.isEmpty, meta.start != .distantPast else {
            throw DecodingError.dataCorruptedError(forKey: .meta, in: c, debugDescription: "record without id / start")
        }
        self.init(dir: dir, meta: meta)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dir, forKey: .dir)
        try c.encode(meta, forKey: .meta)
    }
}

/// meta.json 的时间：本地时区的 ISO 8601（`2026-11-06T14:00:05+08:00`）；读的时候带不带毫秒、是不是 UTC 都认，
/// 数字按 1970 年起的秒数。
enum MeetingDates {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    static func date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds],
                                                     [.withInternetDateTime]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

/// 容错取值：字段缺失、类型不对一律返回 nil / 空，不抛错。
enum MeetingLenient {
    static func string<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
        guard let value = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func int<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil { return value }
        if let value = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil, value.isFinite { return Int(value) }
        return string(c, key).flatMap { Int($0) }
    }

    static func double<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let value = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil, value.isFinite { return value }
        return string(c, key).flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil }
    }

    static func bool<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Bool? {
        if let value = (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? nil { return value }
        if let value = (try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil { return value != 0 }
        switch string(c, key)?.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    static func date<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let text = string(c, key) { return MeetingDates.date(text) }
        if let seconds = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil, seconds.isFinite, seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    /// 字符串数组：非字符串的元素跳过，整个不是数组时为空。
    static func strings<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [String] {
        let values = (try? c.decodeIfPresent([Element<String>].self, forKey: key)) ?? nil
        return (values ?? []).compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 对象数组：解不出来的元素跳过，整个不是数组时为空。
    static func array<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> [T] {
        let values = (try? c.decodeIfPresent([Element<T>].self, forKey: key)) ?? nil
        return (values ?? []).compactMap(\.value)
    }

    /// 数组里的一个元素：自己解不出来时为 nil，不连累整个数组。
    struct Element<T: Decodable>: Decodable {
        let value: T?

        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }
}
