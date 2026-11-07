import Foundation

// 专注与健康的显示文案（本地化）。与可单测的模型分开放：模型文件不依赖 L()。

extension ReminderItem {
    /// 预置名（随界面语言）；自建项为「自定义提醒」。
    var presetName: String {
        switch preset {
        case ReminderPreset.water: return L("focus.preset.water")
        case ReminderPreset.stand: return L("focus.preset.stand")
        case ReminderPreset.eye: return L("focus.preset.eye")
        case ReminderPreset.rest: return L("focus.preset.break")
        default: return L("focus.preset.custom")
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? presetName : trimmed
    }

    /// 设置页一行概要：「每 45 分钟 · 宠物提醒」「每天 09:00 · 宠物提醒」「每 50 分钟 · 休息 5 分钟」。
    var summary: String {
        let when: String
        switch schedule {
        case .interval: when = L("focus.summary.every \(intervalMinutes)")
        case .daily: when = L("focus.summary.daily \(FocusText.clock(timeOfDay))")
        }
        let how: String
        switch style {
        case .rest: how = L("focus.summary.rest \(FocusText.duration(restSeconds))")
        case .bubble: how = L("focus.summary.bubble")
        case .nudge: how = L("focus.summary.nudge")
        }
        return when + " · " + how
    }

    /// 轻提醒的一句话（标题）。
    var nudgeTitle: String {
        preset == ReminderPreset.eye ? L("focus.nudge.eyeTitle") : displayName
    }

    /// 轻提醒的小字（自建项没有）。
    var nudgeBody: String {
        preset == ReminderPreset.eye ? L("focus.nudge.eyeBody") : ""
    }

    /// 并进别的提醒里顺带说时的说法：「顺便：喝口水、起来走走」。
    var foldPhrase: String {
        switch preset {
        case ReminderPreset.water: return L("focus.fold.water")
        case ReminderPreset.stand: return L("focus.fold.stand")
        default: return displayName
        }
    }

    /// 宠物提醒的标题。
    var bubbleTitle: String {
        switch preset {
        case ReminderPreset.water: return L("focus.bubble.waterTitle")
        case ReminderPreset.stand: return L("focus.bubble.standTitle")
        case ReminderPreset.eye: return L("focus.bubble.eyeTitle")
        case ReminderPreset.rest: return L("focus.bubble.breakTitle")
        default: return displayName
        }
    }

    /// 宠物提醒的正文（自建项没有）。
    var bubbleBody: String {
        switch preset {
        case ReminderPreset.water: return L("focus.bubble.waterBody")
        case ReminderPreset.stand: return L("focus.bubble.standBody")
        case ReminderPreset.eye: return L("focus.rest.eyeMessage")
        case ReminderPreset.rest: return L("focus.rest.breakMessage")
        default: return ""
        }
    }

    /// 休息画面的标题。
    var restTitle: String {
        preset == ReminderPreset.eye ? L("focus.rest.eyeTitle") : L("focus.rest.title")
    }

    /// 休息画面的一句话。
    var restMessage: String {
        switch preset {
        case ReminderPreset.eye: return L("focus.rest.eyeMessage")
        case ReminderPreset.rest: return L("focus.rest.breakMessage")
        default: return ""
        }
    }

    /// 气泡左上角的图标（SF Symbol）。
    var icon: String {
        switch preset {
        case ReminderPreset.water: return "drop.fill"
        case ReminderPreset.stand: return "figure.walk"
        case ReminderPreset.eye: return "eye"
        case ReminderPreset.rest: return "cup.and.saucer.fill"
        default: return schedule == .daily ? "pills.fill" : "bell.fill"
        }
    }

    /// 轻松档休息气泡出来时宠物配合的动作：打个哈欠（护眼不配）。
    var restClips: [String]? {
        preset == ReminderPreset.eye ? nil : ["yawn"]
    }

    /// 宠物配合的动作（内置毛绒形象的片段名）；形象里没有这几段时宠物只跳一下。护眼：搭手远眺（VRM 的 look_up）。
    var petClips: [String]? {
        switch preset {
        case ReminderPreset.water: return ["sit_down", "sit_hold_drink", "stand_up"]
        case ReminderPreset.stand: return ["stretch"]
        case ReminderPreset.eye: return ["look_up"]
        default: return nil
        }
    }
}

enum FocusText {
    /// 「09:05」。
    static func clock(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    /// 「20 秒」「5 分钟」。
    static func duration(_ seconds: Int) -> String {
        seconds < 60 ? L("focus.duration.seconds \(seconds)") : L("focus.duration.minutes \(seconds / 60)")
    }

    /// 倒计时「24:59」（超过一小时显示成「90:00」这种分钟数）。
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 剩余分钟数（向上取整，至少 1）。
    static func minutesLeft(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded(.up)))
    }

    /// 某个时刻的钟面时间（跟随应用语言的格式）。
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
