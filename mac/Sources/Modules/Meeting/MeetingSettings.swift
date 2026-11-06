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
    static var template: LiveTranslateMeetingStyle {
        get { defaults.string(forKey: templateKey).flatMap(LiveTranslateMeetingStyle.init(rawValue:)) ?? .standard }
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
}
