import Foundation

/// 会议的显示文案（模型在 MeetingModels.swift，只依赖 Foundation）。
enum MeetingText {
    /// 「线上会议」「线下会议」「自由听译」。
    static func typeName(_ type: MeetingType) -> String {
        switch type {
        case .online: return L("meeting.type.online")
        case .offline: return L("meeting.type.offline")
        case .free: return L("meeting.type.free")
        }
    }

    /// 控制条上的类型徽标：「线上」「线下」「自由」。
    static func typeBadge(_ type: MeetingType) -> String {
        switch type {
        case .online: return L("meeting.badge.online")
        case .offline: return L("meeting.badge.offline")
        case .free: return L("meeting.badge.free")
        }
    }

    /// 纪要状态：「记录中」「仅转录」「整理中」「已生成」「失败」。
    static func statusName(_ status: MeetingStatus) -> String {
        switch status {
        case .recording: return L("meeting.status.recording")
        case .transcribed: return L("meeting.status.transcribed")
        case .summarizing: return L("meeting.status.summarizing")
        case .summarized: return L("meeting.status.summarized")
        case .failed: return L("meeting.status.failed")
        }
    }

    static func templateName(_ style: MeetingMinutesStyle) -> String {
        switch style {
        case .standard: return L("meeting.template.standard")
        case .standup: return L("meeting.template.standup")
        case .oneOnOne: return L("meeting.template.oneOnOne")
        case .interview: return L("meeting.template.interview")
        }
    }

    static func retentionName(_ days: Int) -> String {
        days <= 0 ? L("meeting.retention.forever") : L("meeting.retention.days \(days)")
    }

    /// 计时「32:15」/「1:02:03」（等宽数字显示）。
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    // MARK: - 第二段：日历与会议库的时间文案

    /// 距开始还有多久（会前提醒标题、菜单状态行）：「马上开始」「5 分钟后」「1 小时 5 分钟后」「16:00」「明天 09:30」；
    /// 已开始的：「已开始 3 分钟」。
    static func relative(_ start: Date, now: Date = Date()) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 0 {
            let minutes = Int(-seconds / 60)
            return minutes < 1 ? L("meeting.time.started") : L("meeting.time.startedAgo \(minutes)")
        }
        if seconds < 60 { return L("meeting.time.now") }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return L("meeting.time.inMinutes \(minutes)") }
        if minutes < 3 * 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? L("meeting.time.inHours \(hours)") : L("meeting.time.inHoursMinutes \(hours) \(rest)")
        }
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: now) { return clockTime(start) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) {
            return L("meeting.time.tomorrowAt \(clockTime(start))")
        }
        return dateTime(start)
    }

    /// 暂停到什么时候：「15:00」「明天 00:00」「11月8日 周日 00:00」。
    static func untilTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return clockTime(date) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return L("meeting.time.tomorrowAt \(clockTime(date))")
        }
        return dateTime(date)
    }

    /// 「14:00–15:00」；不是今天的前面带日期。
    static func timeRange(_ start: Date, _ end: Date, now: Date = Date()) -> String {
        let range = clockTime(start) + "–" + clockTime(end)
        if Calendar.current.isDate(start, inSameDayAs: now) { return range }
        return shortDay(start) + " " + range
    }

    /// 「14:00」（24 小时制，跟随应用语言）。
    static func clockTime(_ date: Date) -> String {
        format(date, template: "HHmm")
    }

    /// 「11月6日 周五 14:00」/「Fri, Nov 6, 14:00」。
    static func dateTime(_ date: Date) -> String {
        format(date, template: "MMMdEEEHHmm")
    }

    /// 「11月6日 周五」/「Fri, Nov 6」。
    static func shortDay(_ date: Date) -> String {
        format(date, template: "MMMdEEE")
    }

    /// 「2026年11月6日」/「Nov 6, 2026」。
    static func longDay(_ date: Date) -> String {
        format(date, template: "yMMMd")
    }

    private static func format(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// 参会人前 3 位：「张三、李四、王五 等 6 人」。
    static func attendeesPreview(_ names: [String], limit: Int = 3) -> String {
        let shown = names.prefix(limit).joined(separator: L("livetranslate.record.doc.listSeparator"))
        guard names.count > limit else { return shown }
        return L("meeting.attendees.more \(shown) \(names.count)")
    }

    /// 菜单栏倒计时：「设计评审 · 25 分钟后」（标题过长截断）。
    static func countdown(_ event: MeetingCalendarEvent, now: Date = Date()) -> String {
        let title = event.info.title
        let short = title.count > 12 ? String(title.prefix(11)) + "…" : title
        return short + " · " + relative(event.info.start, now: now)
    }

    /// 会议链接是哪家：「Zoom」「腾讯会议」…
    static func providerName(_ provider: MeetingLinkProvider) -> String {
        switch provider {
        case .zoom: return "Zoom"
        case .tencent: return L("meeting.provider.tencent")
        case .dingtalk: return L("meeting.provider.dingtalk")
        case .googleMeet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        case .feishu: return L("meeting.provider.feishu")
        case .webex: return "Webex"
        }
    }

    /// 时长「45 分钟」「1 小时 5 分钟」（跟随应用语言）。
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute] : [.second])
        return formatter.string(from: max(0, seconds)) ?? ""
    }
}
