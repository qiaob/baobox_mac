import Foundation

// 日历事件的时间判断（docs/meeting/TECH_DESIGN.md §5）：下一场是哪场、手动开始时绑哪场、提醒 / 「已开始」什么时候该问、
// 暂停到什么时候、问过的记一笔。纯函数，只依赖 Foundation，可脱离 App 单独编译测试；EventKit 在 MeetingCalendar.swift。

/// 日历里的一场（未来 24 小时内、或正在进行）。重复事件的每一次各是一条（`occurrenceKey` 不同）。
struct MeetingCalendarEvent: Equatable, Identifiable {
    var info: MeetingEventInfo
    var link: MeetingLink?
    /// `EKCalendar.calendarIdentifier`。
    var calendarID: String
    /// 地点（会议室等；没有为 nil）。
    var location: String?

    init(info: MeetingEventInfo, link: MeetingLink? = nil, calendarID: String = "", location: String? = nil) {
        self.info = info
        self.link = link
        self.calendarID = calendarID
        self.location = location
    }

    /// 这一次的唯一键：重复事件的各次共用 `eventIdentifier`，所以再带上开始时间。
    var occurrenceKey: String { MeetingSchedule.occurrenceKey(eventID: info.eventID, title: info.title, start: info.start) }
    var id: String { occurrenceKey }

    func isOngoing(at now: Date) -> Bool { info.start <= now && now < info.end }
}

enum MeetingSchedule {
    /// 开始了这么久以内还算「下一场」（迟到入会、「已开始」检测都看这个窗口）。
    static let recentStart: TimeInterval = 15 * 60
    /// 提前这么久手动开始，也算这一场（开会前点了「开始线上会议记录」）。
    static let earlyStart: TimeInterval = 5 * 60
    /// 到点后这么久以内还补会前提醒（刚从睡眠醒来）；再晚交给「已开始」检测。
    static let reminderLateGrace: TimeInterval = 2 * 60

    static func occurrenceKey(eventID: String?, title: String, start: Date) -> String {
        let base = eventID.flatMap { $0.isEmpty ? nil : $0 } ?? ("title:" + title)
        return base + "|" + String(Int(start.timeIntervalSince1970.rounded()))
    }

    /// 正在进行的（开始 ≤ 现在 < 结束），按开始时间。
    static func ongoing(_ events: [MeetingCalendarEvent], at now: Date) -> [MeetingCalendarEvent] {
        events.filter { $0.isOngoing(at: now) }.sorted { $0.info.start < $1.info.start }
    }

    /// 还没开始的，按开始时间。
    static func upcoming(_ events: [MeetingCalendarEvent], at now: Date) -> [MeetingCalendarEvent] {
        events.filter { $0.info.start > now }.sorted { $0.info.start < $1.info.start }
    }

    /// 「下一场」：刚开始不到 15 分钟的（迟到了也要能一键入会）优先，有链接的优先、开始得晚的优先；否则最近的一场还没开始的。
    static func next(_ events: [MeetingCalendarEvent], at now: Date) -> MeetingCalendarEvent? {
        let recent = events.filter { $0.isOngoing(at: now) && now.timeIntervalSince($0.info.start) < recentStart }
        if let pick = recent.max(by: { lhs, rhs in
            if (lhs.link != nil) != (rhs.link != nil) { return rhs.link != nil }
            return lhs.info.start < rhs.info.start
        }) {
            return pick
        }
        return upcoming(events, at: now).first
    }

    /// 手动开始记录时绑哪场：正在进行的、或 5 分钟内就要开始的；有链接的优先，离现在近的优先。
    static func bindingCandidate(_ events: [MeetingCalendarEvent], at now: Date) -> MeetingCalendarEvent? {
        let candidates = events.filter { event in
            event.info.end > now && event.info.start.timeIntervalSince(now) <= earlyStart
        }
        return candidates.min { lhs, rhs in
            if (lhs.link != nil) != (rhs.link != nil) { return lhs.link != nil }
            return abs(lhs.info.start.timeIntervalSince(now)) < abs(rhs.info.start.timeIntervalSince(now))
        }
    }

    /// 该发会前提醒的：开始前 `leadMinutes` 分钟到开始后 2 分钟之间、还没提醒过。`leadMinutes` ≤ 0 = 关。
    static func reminderDue(_ events: [MeetingCalendarEvent], at now: Date, leadMinutes: Int,
                            prompted: (String) -> Bool) -> [MeetingCalendarEvent] {
        guard leadMinutes > 0 else { return [] }
        let lead = TimeInterval(leadMinutes * 60)
        return events.filter { event in
            let untilStart = event.info.start.timeIntervalSince(now)
            return untilStart <= lead && untilStart > -reminderLateGrace && event.info.end > now
                && !prompted(event.occurrenceKey)
        }
        .sorted { $0.info.start < $1.info.start }
    }

    /// 「日历事件已开始且带会议链接」（检测规则 1）：开始了、不到 15 分钟、带链接、还没问过。
    static func startedWithLink(_ events: [MeetingCalendarEvent], at now: Date,
                                prompted: (String) -> Bool) -> [MeetingCalendarEvent] {
        events.filter { event in
            event.link != nil && event.isOngoing(at: now) && now.timeIntervalSince(event.info.start) < recentStart
                && !prompted(event.occurrenceKey)
        }
        .sorted { $0.info.start < $1.info.start }
    }

    // MARK: - 暂停会议提醒

    enum Pause: String, CaseIterable {
        /// 1 小时。
        case hour
        /// 到今天结束（明天 0 点恢复）。
        case today
        /// 到明天结束（今天和明天都不提醒，后天 0 点恢复）。
        case untilTomorrow
    }

    static func pausedUntil(_ pause: Pause, from now: Date, calendar: Calendar = .current) -> Date {
        switch pause {
        case .hour:
            return now.addingTimeInterval(3600)
        case .today:
            return startOfDay(after: now, days: 1, calendar: calendar)
        case .untilTomorrow:
            return startOfDay(after: now, days: 2, calendar: calendar)
        }
    }

    private static func startOfDay(after now: Date, days: Int, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: days, to: today) ?? today.addingTimeInterval(Double(days) * 86_400)
    }
}

/// 问过 / 忽略过的事件（键 → 过期时间）。会前提醒与「已开始」检测共用：同一场只问一次。
struct MeetingPromptLedger: Equatable {
    private(set) var entries: [String: Date]

    init(entries: [String: Date] = [:]) {
        self.entries = entries
    }

    func contains(_ key: String, at now: Date) -> Bool {
        guard let expiry = entries[key] else { return false }
        return expiry > now
    }

    mutating func insert(_ key: String, until expiry: Date) {
        if let existing = entries[key], existing >= expiry { return }
        entries[key] = expiry
    }

    /// 去掉过期的；返回有没有变。
    @discardableResult
    mutating func prune(at now: Date) -> Bool {
        let before = entries.count
        entries = entries.filter { $0.value > now }
        return entries.count != before
    }

    /// 存 UserDefaults 用：键 → 过期时间（1970 年起的秒数）。
    var storage: [String: Double] { entries.mapValues { $0.timeIntervalSince1970 } }

    init(storage: Any?) {
        var entries: [String: Date] = [:]
        if let dictionary = storage as? [String: Any] {
            for (key, value) in dictionary {
                if let seconds = value as? Double, seconds.isFinite {
                    entries[key] = Date(timeIntervalSince1970: seconds)
                } else if let seconds = value as? Int {
                    entries[key] = Date(timeIntervalSince1970: TimeInterval(seconds))
                }
            }
        }
        self.entries = entries
    }
}
