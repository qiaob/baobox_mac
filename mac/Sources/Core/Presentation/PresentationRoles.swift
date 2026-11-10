import Foundation
import os

/// 一个模块能替框架承担的呈现角色（docs/notify-core/DESIGN.md §3.3）。都可以不提供；目前只有桌面宠物提供。
/// 模块用 `ToolModule.presentationRoles()` 交出来，框架在任何模块 `activate()` 之前装进 `PresentationHub`。
@MainActor
struct PresentationRoles {
    /// 通知呈现端。没有或没就绪 → 通知内核走系统通知。
    var notifications: NotifyPresenting?
    /// 浮窗挂靠点（会议控制条挂在宠物头顶）。没有或挂不上 → 浮窗自己摆。
    var accessories: AccessoryHost?

    init(notifications: NotifyPresenting? = nil, accessories: AccessoryHost? = nil) {
        self.notifications = notifications
        self.accessories = accessories
    }
}

/// 装好的呈现角色：`ToolRegistry.activateAll()` 在调任何模块的 `activate()` 之前装一次，之后只读。
/// 只有框架装、只装一次，与注册顺序无关（宠物注册在最后，也一样先装好）。
@MainActor
final class PresentationHub {
    static let shared = PresentationHub()
    private init() {}

    private static let log = Logger(subsystem: "com.baobox.app", category: "presentation")

    /// 通知呈现端（桌面宠物的 `PetController`）。nil = 宠物模块没注册，通知一律走系统通知。
    /// 强引用：提供者本来就活到进程结束；将来交出的若是适配对象，弱引用会让它立刻变 nil。
    private(set) var notifications: NotifyPresenting?
    /// 浮窗挂靠点（也是桌面宠物，强引用同上）。nil = 宠物模块没注册：`AccessoryDock` 当场回调「没挂上」，浮窗自己摆。
    private(set) var accessories: AccessoryHost?
    private var installed = false

    /// 只给 `ToolRegistry.activateAll()` 调。每个角色取第一个提供者；两个模块提供同一个角色是配置错了，记 fault、不崩。
    /// 第二次调用忽略（也记 fault）：之后才注册的模块不会被收集，和它的 `activate()` 不会被调用一样。
    func install(from tools: [any ToolModule]) {
        guard !installed else {
            Self.log.fault("install called again, ignored")
            return
        }
        installed = true
        var notificationsOwner: String?
        var accessoriesOwner: String?
        for tool in tools {
            let roles = tool.presentationRoles()
            if let presenter = roles.notifications {
                if let owner = notificationsOwner {
                    Self.log.fault("\(tool.id, privacy: .public) also provides notifications (\(owner, privacy: .public) already does), ignored")
                } else {
                    notifications = presenter
                    notificationsOwner = tool.id
                }
            }
            if let host = roles.accessories {
                if let owner = accessoriesOwner {
                    Self.log.fault("\(tool.id, privacy: .public) also provides accessories (\(owner, privacy: .public) already does), ignored")
                } else {
                    accessories = host
                    accessoriesOwner = tool.id
                }
            }
        }
        Self.log.info("notifications: \(notificationsOwner ?? "system notifications only", privacy: .public)")
        Self.log.info("accessories: \(accessoriesOwner ?? "none, accessory windows place themselves", privacy: .public)")
        // 有呈现端：只装系统通知的回调代理，权限照旧由宠物模块按开关申请（宠物关着启动 / 刚关掉宠物）。
        // 没有呈现端（宠物模块没注册）：通知一律走系统通知，现在就申请权限，免得第一条因为弹授权框而丢掉。
        NotifyCenter.shared.prepareSystemFallback(requestPermission: notifications == nil)
    }
}
