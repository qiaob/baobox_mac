import Foundation

/// 会议的标量设置（UserDefaults，前缀 `meeting.`，docs/meeting/REQUIREMENTS.md §6）。
/// 「字幕与同传」那一组仍是原来的 `livetranslate.*` 键（整组平移，键名不变）。
enum MeetingSettings {
    static let defaultTypeKey = "meeting.defaultType"
    static let templateKey = "meeting.template"
    static let retentionDaysKey = "meeting.retentionDays"
    /// 首次开始记录前的合规说明已经确认过。
    static let consentKey = "meeting.complianceAcknowledged"
    /// 旧版实时翻译记录已经导入过会议库（只做一次）。
    static let migratedLegacyKey = "meeting.migratedLegacy"
    /// 控制条的位置（`NSStringFromPoint`，左下角）。
    static let controlBarOriginKey = "meeting.controlBarOrigin"

    // 第二段：日历、提醒、检测（docs/meeting/REQUIREMENTS.md §2、§6）。
    /// 读取日历（默认关：用户在设置里打开时才申请日历权限）。
    static let calendarEnabledKey = "meeting.calendar.enabled"
    /// 不读的日历（`calendarIdentifier`）：存「不读」的，新加的日历默认也读。
    static let calendarExcludedKey = "meeting.calendar.excluded"
    /// 会前提醒提前量（分钟）：0 = 关，1（默认）/ 5。
    static let reminderLeadKey = "meeting.reminder.lead"
    /// 暂停会议提醒到这个时刻（1970 年起的秒数）；没有 = 没暂停。
    static let remindersPausedUntilKey = "meeting.reminder.pausedUntil"
    /// 菜单栏显示下一场倒计时（默认关）。
    static let menuBarCountdownKey = "meeting.menuBarCountdown"
    /// 自动检测会议（默认开：只问、不自己开始）。
    static let detectionEnabledKey = "meeting.detect.enabled"
    /// 不再检测的 App：bundle id → 显示名。
    static let detectionIgnoredKey = "meeting.detect.ignored"
    /// 命中日历会议时自动开始记录（默认关）。
    static let autoStartKey = "meeting.autoStart"
    /// 问过的日历事件（会前提醒、「已开始」检测共用）：occurrenceKey → 过期时间。
    static let promptedKey = "meeting.prompted"
    /// 点了「忽略」的日历事件：这一场不再问、不自动开始，进行期间也不按 App 检测来问。
    static let ignoredEventsKey = "meeting.ignoredEvents"

    static let reminderLeadChoices = [0, 1, 5]

    private static var defaults: UserDefaults { .standard }

    /// 手动开始时的默认类型（线上 / 线下；默认线上）。提醒、检测气泡里的「开始记录」用它。
    static var defaultType: MeetingType {
        get {
            let stored = defaults.string(forKey: defaultTypeKey).flatMap(MeetingType.init(rawValue:))
            return stored == .offline ? .offline : .online
        }
        set { defaults.set(newValue.rawValue, forKey: defaultTypeKey) }
    }

    /// 会议纪要模板（默认 / 站会 / 1:1 / 面试）。
    static var template: MeetingMinutesStyle {
        get { defaults.string(forKey: templateKey).flatMap(MeetingMinutesStyle.init(rawValue:)) ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: templateKey) }
    }

    /// 保留时长（天）；0 = 长期保留（默认）。
    static var retentionDays: Int {
        get { max(0, defaults.object(forKey: retentionDaysKey) as? Int ?? 0) }
        set { defaults.set(max(0, newValue), forKey: retentionDaysKey) }
    }

    static let retentionChoices = [0, 30, 90, 180, 365]

    static var consentAcknowledged: Bool {
        get { defaults.bool(forKey: consentKey) }
        set { defaults.set(newValue, forKey: consentKey) }
    }

    static var migratedLegacy: Bool {
        get { defaults.bool(forKey: migratedLegacyKey) }
        set { defaults.set(newValue, forKey: migratedLegacyKey) }
    }

    static var calendarEnabled: Bool {
        get { defaults.bool(forKey: calendarEnabledKey) }
        set { defaults.set(newValue, forKey: calendarEnabledKey) }
    }

    static var excludedCalendars: Set<String> {
        get { Set(defaults.stringArray(forKey: calendarExcludedKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: calendarExcludedKey) }
    }

    /// 0 = 关。
    static var reminderLead: Int {
        get {
            let stored = defaults.object(forKey: reminderLeadKey) as? Int ?? 1
            return reminderLeadChoices.contains(stored) ? stored : 1
        }
        set { defaults.set(newValue, forKey: reminderLeadKey) }
    }

    static var remindersPausedUntil: Date? {
        get {
            guard let seconds = defaults.object(forKey: remindersPausedUntilKey) as? Double, seconds.isFinite else {
                return nil
            }
            return Date(timeIntervalSince1970: seconds)
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: remindersPausedUntilKey)
            } else {
                defaults.removeObject(forKey: remindersPausedUntilKey)
            }
        }
    }

    static var menuBarCountdown: Bool {
        get { defaults.bool(forKey: menuBarCountdownKey) }
        set { defaults.set(newValue, forKey: menuBarCountdownKey) }
    }

    static var detectionEnabled: Bool {
        get { defaults.object(forKey: detectionEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: detectionEnabledKey) }
    }

    /// bundle id → 显示名（设置里的忽略名单要显示名字，不去磁盘上找 App）。
    static var ignoredApps: [String: String] {
        get {
            guard let stored = defaults.dictionary(forKey: detectionIgnoredKey) else { return [:] }
            var result: [String: String] = [:]
            for (key, value) in stored {
                result[key] = (value as? String) ?? key
            }
            return result
        }
        set { defaults.set(newValue, forKey: detectionIgnoredKey) }
    }

    static var autoStart: Bool {
        get { defaults.bool(forKey: autoStartKey) }
        set { defaults.set(newValue, forKey: autoStartKey) }
    }
}
