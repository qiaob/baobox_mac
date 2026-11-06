import Foundation

/// 专注与健康的标量设置（UserDefaults，前缀 `focus.`）。提醒项列表与运行状态在 FocusHealthStore 的 JSON 里。
enum FocusHealthSettings {
    static let remindersEnabledKey = "focus.remindersEnabled"
    static let defaultMinutesKey = "focus.defaultMinutes"
    static let shortBreakKey = "focus.shortBreakMinutes"
    static let longBreakKey = "focus.longBreakMinutes"
    static let longEveryKey = "focus.longEvery"
    static let autoNextKey = "focus.autoNext"
    static let strengthKey = "focus.strength"
    static let maxSnoozesKey = "focus.maxSnoozes"
    static let backdropKey = "focus.backdrop"
    static let backdropImageKey = "focus.backdropImage"
    static let workStartKey = "focus.workStart"
    static let workEndKey = "focus.workEnd"
    static let workdaysOnlyKey = "focus.workdaysOnly"

    private static var defaults: UserDefaults { .standard }

    private static func int(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
        let value = defaults.object(forKey: key) as? Int ?? fallback
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 健康提醒总开关（默认开）。专注计时不受它影响。
    static var remindersEnabled: Bool { defaults.object(forKey: remindersEnabledKey) as? Bool ?? true }
    static var defaultFocusMinutes: Int { int(defaultMinutesKey, 25, 5...180) }
    static var shortBreakMinutes: Int { int(shortBreakKey, 5, 1...30) }
    static var longBreakMinutes: Int { int(longBreakKey, 15, 5...60) }
    /// 每几轮来一次长休息。
    static var longEvery: Int { int(longEveryKey, 4, 2...8) }
    /// 休息结束后自动开始下一轮专注（默认关：先问一句）。
    static var autoNextRound: Bool { defaults.object(forKey: autoNextKey) as? Bool ?? false }
    static var strength: BreakStrength {
        BreakStrength(rawValue: defaults.string(forKey: strengthKey) ?? "") ?? .standard
    }
    /// 每次休息最多推迟几次。
    static var maxSnoozes: Int { int(maxSnoozesKey, 2, 0...5) }
    /// 宠物关闭时休息画面的背景：teal / dusk / forest / image。
    static var backdrop: String { defaults.string(forKey: backdropKey) ?? "teal" }
    static var backdropImagePath: String? {
        guard let path = defaults.string(forKey: backdropImageKey), !path.isEmpty else { return nil }
        return path
    }
    static var workHours: WorkHours {
        WorkHours(startMinute: int(workStartKey, 9 * 60, 0...(24 * 60 - 1)),
                  endMinute: int(workEndKey, 18 * 60, 0...(24 * 60 - 1)),
                  workdaysOnly: defaults.object(forKey: workdaysOnlyKey) as? Bool ?? true)
    }
}
