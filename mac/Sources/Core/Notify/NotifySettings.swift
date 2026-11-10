import Foundation

/// 通知内核的设置（UserDefaults，docs/notify-core/DESIGN.md §3.2）：提示音、历史条数、逐来源开关、「安静一下」。
/// 从宠物模块的设置里原样搬来（#108），键名**一个字都不能改**（改了用户升级后设置就丢了）：「安静一下」沿用老键 `pet.quietUntil`。
/// 这里只管读写；设置页的「通知」一组开关和「安静一下」入口仍在宠物模块（宠物设置页 / 宠物菜单）。
enum NotifySettings {
    static let soundKey = "notify.sound"
    static let historyLimitKey = "notify.historyLimit"
    static let quietUntilKey = "pet.quietUntil"

    /// 提示音总开关（默认关；投稿方自身的声音设置另行折算在 playSound 里）。
    static var soundEnabled: Bool { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? false }
    static var historyLimit: Int { UserDefaults.standard.object(forKey: historyLimitKey) as? Int ?? 50 }

    /// 逐来源开关（内部来源 id 与外部来源名共用）。
    static func sourceEnabled(_ source: String) -> Bool {
        UserDefaults.standard.object(forKey: "notify.source.\(source)") as? Bool ?? true
    }

    /// 手动勿扰截止时间（「安静一下」）。是勿扰信号之一，由 `NotifyDND` 读。
    static var quietUntil: Date? { UserDefaults.standard.object(forKey: quietUntilKey) as? Date }

    static func setQuietUntil(_ date: Date?) {
        if let date {
            UserDefaults.standard.set(date, forKey: quietUntilKey)
        } else {
            UserDefaults.standard.removeObject(forKey: quietUntilKey)
        }
    }
}
