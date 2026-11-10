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

/// 走动方式（docs/desktop-pet/SETTLE.md §2）。
enum PetActivity: String, CaseIterable {
    /// 不走动：停在原地（原来「溜达」关掉的样子）。挡住正在用的窗口时仍会让开（见「不挡我」）。
    case still
    /// 安静（默认）：走到一个不碍事的地方待着，以原地动作为主，隔一两分钟挪一两步。
    case calm
    /// 适中：也找空地待着，但更常走动，隔几分钟换个地方。
    case normal
    /// 活泼：原来的到处溜达、隔几分钟跳上窗口。
    case lively
}

/// 桌面宠物设置（UserDefaults 键，设计 §9：前缀 `pet.`）。通知内核的设置（`notify.*` 与「安静一下」的
/// `pet.quietUntil`）在 `Core/Notify/NotifySettings.swift`，设置页和菜单里的入口仍在这个模块。
enum PetSettings {
    static let enabledKey = "pet.enabled"
    /// 老版本的「溜达」开关，只在没选过走动方式时读一次（关着的沿用「不走动」）。
    static let roamKey = "pet.roam"
    static let activityKey = "pet.activity"
    static let avoidKey = "pet.avoid"
    static let contentAwareKey = "pet.contentAware"
    static let sizeKey = "pet.size"
    static let originXKey = "pet.originX"
    static let originYKey = "pet.originY"
    static let characterKey = "pet.character"
    static let rangeKey = "pet.range"
    static let rangeRectKey = "pet.rangeRect"
    static let entranceKey = "pet.entrance"

    /// 宠物启用（默认开）。关掉后通知自动回退系统通知中心。
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// 走动方式（默认「安静」）。老版本关过「溜达」的沿用「不走动」。
    static var activity: PetActivity {
        if let raw = UserDefaults.standard.string(forKey: activityKey), let value = PetActivity(rawValue: raw) {
            return value
        }
        return UserDefaults.standard.object(forKey: roamKey) as? Bool == false ? .still : .calm
    }
    /// 会不会自己走动（「不走动」以外都会）。
    static var roam: Bool { activity != .still }
    /// 不挡我：挡住正在用的窗口时自动让开（默认开）。
    static var avoidsActiveWindow: Bool { UserDefaults.standard.object(forKey: avoidKey) as? Bool ?? true }
    /// 识别屏幕内容找空白处（默认开；没有屏幕录制权限时自动不用，不弹授权）。
    static var contentAware: Bool { UserDefaults.standard.object(forKey: contentAwareKey) as? Bool ?? true }
    /// 出场 / 退场动画（#54，默认开）。系统「减弱动态效果」打开时只淡入淡出。
    static var entranceAnimation: Bool { UserDefaults.standard.object(forKey: entranceKey) as? Bool ?? true }
    /// 体型倍率（默认 1.0）。
    static var size: Double { UserDefaults.standard.object(forKey: sizeKey) as? Double ?? 1.0 }
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
}
