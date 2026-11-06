import AppKit

/// 宠物在哪儿活动（docs/desktop-pet/ROAM.md §1）。
enum PetRange: String, CaseIterable {
    /// 随意放：停在被放下的高度左右溜达（原来的行为）。
    case screen
    /// 屏幕底边：一直站在可见区底边，被拖到半空松手会掉下来。
    case bottom
    /// 自定义区域：只在框选的矩形底边溜达，拖出去松手会跳回来。
    case custom
    /// 窗口上：地面之外，隔几分钟会跳到别的 App 窗口顶边上走、趴着。
    case windows
}

/// 桌面宠物 / 通知中心设置（UserDefaults 键，设计 §9：前缀 `pet.` / `notify.`）。
enum PetSettings {
    static let enabledKey = "pet.enabled"
    static let roamKey = "pet.roam"
    static let sizeKey = "pet.size"
    static let quietUntilKey = "pet.quietUntil"
    static let originXKey = "pet.originX"
    static let originYKey = "pet.originY"
    static let characterKey = "pet.character"
    static let rangeKey = "pet.range"
    static let rangeRectKey = "pet.rangeRect"
    static let entranceKey = "pet.entrance"
    static let soundKey = "notify.sound"
    static let historyLimitKey = "notify.historyLimit"

    /// 宠物启用（默认开）。关掉后通知自动回退系统通知中心。
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// 是否在桌面底部走动（默认开）。
    static var roam: Bool { UserDefaults.standard.object(forKey: roamKey) as? Bool ?? true }
    /// 出场 / 退场动画（#54，默认开）。系统「减弱动态效果」打开时只淡入淡出。
    static var entranceAnimation: Bool { UserDefaults.standard.object(forKey: entranceKey) as? Bool ?? true }
    /// 体型倍率（默认 1.0）。
    static var size: Double { UserDefaults.standard.object(forKey: sizeKey) as? Double ?? 1.0 }
    /// 手动勿扰截止时间（「安静一下」）。
    static var quietUntil: Date? { UserDefaults.standard.object(forKey: quietUntilKey) as? Date }
    /// 当前形象 id（素材包文件夹名）；空 = 第一个可用包。
    static var character: String { UserDefaults.standard.string(forKey: characterKey) ?? "" }

    /// 活动范围（docs/desktop-pet/ROAM.md §1）。默认屏幕底边：试用反馈「感觉是飘在空中的」—— 随意放的宠物常停在半空。
    static var range: PetRange { PetRange(rawValue: UserDefaults.standard.string(forKey: rangeKey) ?? "") ?? .bottom }

    /// 自定义区域（屏幕坐标，左下角原点）；没框选过为 nil。
    static var rangeRect: NSRect? {
        guard let values = UserDefaults.standard.array(forKey: rangeRectKey) as? [Double], values.count == 4,
              values[2] >= 1, values[3] >= 1 else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    static func setRangeRect(_ rect: NSRect) {
        UserDefaults.standard.set([rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }, forKey: rangeRectKey)
    }

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
