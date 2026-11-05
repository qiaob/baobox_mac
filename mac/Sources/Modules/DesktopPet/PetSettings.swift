import Foundation

/// 桌面宠物 / 通知中心设置（UserDefaults 键，设计 §9：前缀 `pet.` / `notify.`）。
enum PetSettings {
    static let enabledKey = "pet.enabled"
    static let roamKey = "pet.roam"
    static let sizeKey = "pet.size"
    static let quietUntilKey = "pet.quietUntil"
    static let originXKey = "pet.originX"
    static let originYKey = "pet.originY"
    static let soundKey = "notify.sound"
    static let historyLimitKey = "notify.historyLimit"

    /// 宠物启用（默认开）。关掉后通知自动回退系统通知中心。
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// 是否在桌面底部走动（默认开）。
    static var roam: Bool { UserDefaults.standard.object(forKey: roamKey) as? Bool ?? true }
    /// 体型倍率（默认 1.0）。
    static var size: Double { UserDefaults.standard.object(forKey: sizeKey) as? Double ?? 1.0 }
    /// 手动勿扰截止时间（「安静一下」）。
    static var quietUntil: Date? { UserDefaults.standard.object(forKey: quietUntilKey) as? Date }
    /// 提示音总开关（默认关；投稿方自身的声音设置另行折算在 playSound 里）。
    static var soundEnabled: Bool { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? false }
    static var historyLimit: Int { UserDefaults.standard.object(forKey: historyLimitKey) as? Int ?? 50 }

    /// 逐来源开关（内部来源 id 与外部来源名共用）。
    static func sourceEnabled(_ source: String) -> Bool {
        UserDefaults.standard.object(forKey: "notify.source.\(source)") as? Bool ?? true
    }

    static func setQuietUntil(_ date: Date?) {
        if let date {
            UserDefaults.standard.set(date, forKey: quietUntilKey)
        } else {
            UserDefaults.standard.removeObject(forKey: quietUntilKey)
        }
    }
}
