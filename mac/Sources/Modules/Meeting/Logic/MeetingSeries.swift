import Foundation

// 会议系列（docs/meeting/TECH_DESIGN.md §4）：系列键、哪些会议算同一系列、会前简报要的那几样（上一场、该系列未完成行动项）。
// 只依赖 Foundation，可脱离 App 单独编译测试。
//
// 系列键：重复事件用 `EKEvent.calendarItemExternalIdentifier`（「ext:…」），非重复按规范化标题（「title:…」，去日期、编号）。
// 「同系列」= 系列键相同，或规范化标题相同（需求：重复事件或同名）—— 但两个不同的重复事件即使同名（和不同人的「1:1」）也不算；
// 没绑日历时的默认标题（「线上会议」）不算同名。

enum MeetingSeries {
    /// 没绑日历时自动起的标题（两种界面语言都算）：这些不按同名归成一个系列。
    static let defaultTitles: Set<String> = [
        "线上会议", "线下会议", "自由听译", "实时翻译记录",
        "Online Meeting", "In-Person Meeting", "Free Listening", "Live translation",
    ]

    /// 系列键：重复事件（`recurringID` 非空）=「ext:」+ 外部 id；否则「title:」+ 规范化标题；标题也是空的为 nil。
    static func key(title: String, recurringID: String?) -> String? {
        if let id = recurringID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return "ext:" + id
        }
        let normalized = normalizedTitle(title)
        return normalized.isEmpty ? nil : "title:" + normalized
    }

    /// 规范化标题：小写，去掉日期、时刻、星期、「第 3 期」「#12」「W45」「Q4」「v2」这类编号与所有数字，标点当空格，空白并成一个。
    /// 去完什么也不剩（标题就是个日期）时退回原标题（小写、并空白）。
    static func normalizedTitle(_ title: String) -> String {
        let lowered = title.lowercased()
        var text = lowered
        for pattern in removals {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        }
        let separators = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        let scalars = text.unicodeScalars.map { separators.contains($0) ? " " : Character($0) }
        let cleaned = String(scalars).split(separator: " ").joined(separator: " ")
        if !cleaned.isEmpty { return cleaned }
        return lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let removals: [NSRegularExpression] = [
        // 第 3 期 / 第十二次 / 第2周
        #"第\s*[0-9一二三四五六七八九十百千]+\s*[期次周轮场届回版号]?"#,
        // 2026年11月6日、11月6号
        #"\d+\s*[年月日号]"#,
        // 周四、星期五、礼拜天
        #"(?:周|星期|礼拜)[一二三四五六日天]"#,
        // No.5、#12、W45、week 45、Q4、v2.1
        #"(?:\bno\.?|#|\bw|\bwk|\bweek|\bq|\bv)\s*\d+(?:\.\d+)*"#,
        // 其余所有数字（日期、时刻、编号）
        #"\d+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// `record` 和这个系列（`seriesKey` / `title`）是不是同一系列。
    static func matches(seriesKey: String?, title: String, record: MeetingRecord) -> Bool {
        let recordKey = record.meta.calendar?.seriesKey
        if let seriesKey, let recordKey {
            if seriesKey == recordKey { return true }
            // 两个不同的重复事件：即使同名也不是一个系列。
            if seriesKey.hasPrefix("ext:") && recordKey.hasPrefix("ext:") { return false }
        }
        return sameName(title, record.meta.title)
    }

    /// 规范化后同名（默认标题不算）。
    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        guard !isDefaultTitle(lhs), !isDefaultTitle(rhs) else { return false }
        let left = normalizedTitle(lhs)
        return !left.isEmpty && left == normalizedTitle(rhs)
    }

    static func isDefaultTitle(_ title: String) -> Bool {
        defaultTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 会议库里同系列的会议（只算线上 / 线下会议，自由听译不算），按开始时间正序（时间线）。
    static func records(in records: [MeetingRecord], seriesKey: String?, title: String) -> [MeetingRecord] {
        records.filter { $0.meta.type != .free && matches(seriesKey: seriesKey, title: title, record: $0) }
            .sorted { $0.meta.start < $1.meta.start }
    }

    /// 某场会议所在系列（含它自己），按开始时间正序。
    static func timeline(of record: MeetingRecord, in all: [MeetingRecord]) -> [MeetingRecord] {
        guard record.meta.type != .free else { return [record] }
        var series = records(in: all, seriesKey: record.meta.calendar?.seriesKey, title: record.meta.title)
        if !series.contains(where: { $0.id == record.id }) {
            series.append(record)
            series.sort { $0.meta.start < $1.meta.start }
        }
        return series
    }
}

/// 会前简报要的：同系列上一场 + 该系列全部未完成行动项（需求 §2）。
struct MeetingBriefing: Equatable {
    struct OpenItem: Equatable {
        var meetingID: String
        var meetingTitle: String
        var meetingStart: Date
        var item: MeetingActionItem
    }

    /// 同系列、在这一场之前的最近一场（有记录的）。
    var previous: MeetingRecord?
    /// 该系列所有未完成行动项（旧的在前）。
    var openItems: [OpenItem]

    var isEmpty: Bool { previous == nil && openItems.isEmpty }

    /// `excluding`：正在记录的那场（它自己不是「上一场」）。
    static func make(seriesKey: String?, title: String, start: Date, records: [MeetingRecord],
                     excluding: String? = nil) -> MeetingBriefing {
        let series = MeetingSeries.records(in: records, seriesKey: seriesKey, title: title)
            .filter { $0.id != excluding && $0.meta.status != .recording }
        // 提前几分钟开过的（同一场的早开）不算上一场：上一场要在这一场开始 30 分钟以前。
        let previous = series.last { $0.meta.start < start.addingTimeInterval(-30 * 60) }
        let openItems = series.flatMap { record in
            record.meta.actionItems.filter { !$0.done }.map {
                OpenItem(meetingID: record.id, meetingTitle: record.meta.title, meetingStart: record.meta.start, item: $0)
            }
        }
        return MeetingBriefing(previous: previous, openItems: openItems)
    }
}
