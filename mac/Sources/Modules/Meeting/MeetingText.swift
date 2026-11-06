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

    static func templateName(_ style: LiveTranslateMeetingStyle) -> String {
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
