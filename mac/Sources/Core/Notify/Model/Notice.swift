import Foundation

/// 一条通知（内部模型，docs/desktop-pet/DESIGN.md §3）。来源模块先转成它，再由 NotifyCenter 分发呈现。
/// 和 Windows 版 `pet_notify.rs` 的 `Notice` 同名。
/// 只依赖 Foundation：和 `NotifyLedger` 一起进 BaoboxTests（docs/notify-core/DESIGN.md §4 PR 5）。
struct Notice {
    enum Level {
        case ambient    // 轻提示：气泡数秒自消
        case bubble     // 带动作：气泡 + 按钮
        case alert      // 重要：气泡 + 宠物提醒动作，可发声
    }

    /// 呈现样式（docs/desktop-pet/INTERACTION.md §2）。不指定时按级别：ambient → toast、bubble → card、alert → sticky。
    enum Style {
        case toast      // 一行字，3 秒自动消失
        case card       // 标题 + 正文（+ 按钮），8 秒自动消失，鼠标悬停时暂停计时
        case sticky     // 常驻：必须点按钮或 × 才消失，宠物隔一会儿招手提醒
    }

    struct Action {
        enum Role {
            case primary        // 品牌色实心按钮（「进入会议」）
            case secondary      // 普通按钮（「稍后」）
            case destructive    // 红字（「忽略」「取消」）
        }

        let id: String
        let label: String
        var role: Role = .secondary
    }

    var source: String
    var level: Level
    var title: String
    var body: String = ""
    var actions: [Action] = []
    var dedupeKey: String? = nil
    var ttl: TimeInterval? = nil
    /// 投稿方要求发声（其自身声音设置已折算进来）；宠物路径再受 notify.sound 总开关约束。
    var playSound: Bool = false
    /// 不指定 = 按级别决定。
    var style: Style? = nil
    /// SF Symbol；不指定 = 按来源给默认图标。
    var icon: String? = nil
    /// 用户刚做的操作的回执（环形菜单开关防休眠、暂停专注…）：人就在电脑前等着看结果，任何勿扰下（含录屏）都照常呈现，
    /// 从不攒进摘要 —— 回执只在当下有意义，事后跟着摘要冒出来既没用、按钮也早过期了。自动发出的提醒不要设。
    var isUserFeedback: Bool = false

    var resolvedStyle: Style {
        if let style { return style }
        switch level {
        case .ambient: return .toast
        case .bubble: return .card
        case .alert: return .sticky
        }
    }
}

/// `Notice` 的旧名（#108 PR 6 改名，docs/notify-core/DESIGN.md §6-1）。留一个版本，给还在用旧名的在途分支缓冲；下个版本删。
@available(*, deprecated, renamed: "Notice")
typealias PetNotification = Notice
