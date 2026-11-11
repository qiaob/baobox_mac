import AppKit
import Foundation
import UserNotifications

/// 一条通知（内部模型，docs/desktop-pet/DESIGN.md §3）。来源模块先转成它，再由 NotifyCenter 分发呈现。
/// 和 Windows 版 `pet_notify.rs` 的 `Notice` 同名。
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

/// 呈现端（桌面宠物）。NotifyCenter 不持有窗口，只调这个协议，便于回退与测试。
/// 模块用 `ToolModule.presentationRoles()` 交出来，框架在启动时装进 `PresentationHub`（docs/notify-core/DESIGN.md §3.3）。
@MainActor
protocol NotifyPresenting: AnyObject {
    var isReady: Bool { get }
    func present(_ n: Notice, onAction: @escaping (String) -> Void)
    /// 配合提醒做个动作（喝水、伸懒腰、远眺），按片段名播；做不了返回 false。默认做不了。
    func performGesture(_ clips: [String]) -> Bool
}

extension NotifyPresenting {
    func performGesture(_ clips: [String]) -> Bool { false }
}

/// 通知内核：来源开关、去重、勿扰聚合、宠物呈现 / 系统通知回退、历史、启动期间先攒着。
@MainActor
final class NotifyCenter {
    static let shared = NotifyCenter()
    private init() {}

    struct HistoryEntry {
        let date: Date
        let source: String
        let level: Notice.Level
        let title: String
        var mergeCount: Int
    }

    private(set) var history: [HistoryEntry] = []
    private var lastPostAt: [String: Date] = [:]
    private var suppressedQueue: [(Notice, ((String) -> Void)?)] = []
    private var flushTimer: Timer?
    private var didRequestAuth = false
    /// 回退系统通知的按钮回调（通知 id → 投稿方回调）与已登记的按钮组。
    private var systemCallbacks: [String: (String) -> Void] = [:]
    private var systemCallbackOrder: [String] = []
    private var systemCategories: [String: UNNotificationCategory] = [:]
    /// 启动期间攒着的通知，按投递顺序；nil = 没在攒（见 holdDuringLaunch）。
    private var launchHeld: [(Notice, ((String) -> Void)?)]?

    func post(_ n: Notice, onAction: ((String) -> Void)? = nil) {
        // 启动期间原样攒着：来源开关、去重、勿扰都等放行时再从头判一遍。
        if launchHeld != nil {
            launchHeld?.append((n, onAction))
            return
        }
        guard NotifySettings.sourceEnabled(n.source) else { return }

        // 去重：同来源同 key 30 秒内只呈现一次，其余合并进历史计数。
        if let key = n.dedupeKey {
            let id = n.source + "|" + key
            if let last = lastPostAt[id], Date().timeIntervalSince(last) < 30 {
                if let idx = history.firstIndex(where: { $0.source == n.source && $0.title == n.title }) {
                    history[idx].mergeCount += 1
                }
                return
            }
            lastPostAt[id] = Date()
        }
        recordHistory(n)

        // 勿扰：alert 照常呈现（宠物路径本身不额外发声，见 deliver）；操作回执也照常呈现，录屏中同样 ——
        // 起初录屏时把回执也攒了起来（免得录进视频），结果录屏中暂停专注什么都看不到，录完才跟着摘要一起冒出来
        // （2026-11-08 用户反馈）。环形菜单本身就会被录进去，跟着出一句回执不算多。其余入队待解除后合并摘要。
        let showsAnyway = n.level == .alert || n.isUserFeedback
        if NotifyDND.shared.isSuppressed, !showsAnyway {
            suppressedQueue.append((n, onAction))
            startFlushTimerIfNeeded()
            return
        }
        deliver(n, onAction: onAction)
    }

    /// 现在发一条会不会由呈现端（宠物气泡）呈现；false = 走系统通知（宠物关着、宠物模块没注册）。设置页预览文案用。
    var presenterIsReady: Bool {
        PresentationHub.shared.notifications?.isReady ?? false
    }

    /// 配合提醒做个动作（喝水、伸懒腰、远眺），转给呈现端；没有呈现端或做不了返回 false。
    @discardableResult
    func performGesture(_ clips: [String]) -> Bool {
        PresentationHub.shared.notifications?.performGesture(clips) ?? false
    }

    /// 呈现端没了（关掉宠物）时还挂着 / 还在排队的通知：转成系统通知，按钮照样能点（#144）。哪些要转由呈现端按
    /// `Notice.handsOver` 挑。它们已经过了来源开关、去重与勿扰，记过历史，宠物路径上也响过声：这里不再判、不再响。
    func handOver(_ items: [(Notice, (String) -> Void)]) {
        for (n, onAction) in items {
            postSystemNotification(n, onAction: onAction, silent: true)
        }
    }

    private func deliver(_ n: Notice, onAction: ((String) -> Void)?) {
        if let presenter = PresentationHub.shared.notifications, presenter.isReady {
            if wantsSound(n) {
                NSSound(named: "Glass")?.play()
            }
            presenter.present(n) { actionID in onAction?(actionID) }
        } else {
            postSystemNotification(n, onAction: onAction)
        }
    }

    /// 投稿方自己的声音设置（Claude Code / Codex 的提示音开关，已折算进 playSound）照旧生效；
    /// notify.sound 只给没要求发声的 alert 级补一声（docs/desktop-pet/DESIGN.md §9：alert 提示音，默认关）。
    private func wantsSound(_ n: Notice) -> Bool {
        n.playSound || (n.level == .alert && NotifySettings.soundEnabled)
    }

    /// 宠物不可用时的回退：系统通知中心，保证提醒不丢（docs/desktop-pet/DESIGN.md §2）。气泡上的按钮照样带上
    /// （UNNotificationAction），用户点了经 SystemNotificationRouter 回到投稿方 —— 否则推迟、
    /// 「现在休息」「再来一轮」这些在宠物关着时全都点不了（2026-11-06 真机踩到）。
    private func postSystemNotification(_ n: Notice, onAction: ((String) -> Void)?, silent: Bool = false) {
        let center = UNUserNotificationCenter.current()
        prepareSystemFallback(requestPermission: true)
        let content = UNMutableNotificationContent()
        content.title = n.title
        if !n.body.isEmpty { content.body = n.body }
        if !silent, wantsSound(n) { content.sound = .default }
        let id = UUID().uuidString
        if let onAction {
            systemCallbacks[id] = onAction
            systemCallbackOrder.append(id)
            // 只留最近这些：通知被系统收起 / 用户不理时不会回调，别让闭包越攒越多。
            while systemCallbackOrder.count > 60 {
                systemCallbacks[systemCallbackOrder.removeFirst()] = nil
            }
        }
        guard !n.actions.isEmpty else {
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
            return
        }
        let categoryID = "baobox." + n.actions.map { $0.id + "=" + $0.label }.joined(separator: "|")
        content.categoryIdentifier = categoryID
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        if systemCategories[categoryID] != nil {
            center.add(request) { _ in }
            return
        }
        systemCategories[categoryID] = UNNotificationCategory(
            identifier: categoryID,
            actions: n.actions.map {
                UNNotificationAction(identifier: $0.id, title: $0.label,
                                     options: $0.role == .destructive ? [.destructive] : [])
            },
            intentIdentifiers: [], options: []
        )
        // setNotificationCategories 是整组替换；登记完（get 回来）再投递，否则第一条可能不带按钮。
        center.setNotificationCategories(Set(systemCategories.values))
        center.getNotificationCategories { _ in
            center.add(request) { _ in }
        }
    }

    /// 系统通知回退的准备（功能模块不碰系统通知）：装上回调代理（不弹任何东西）；`requestPermission` 时顺带申请通知权限，
    /// 免得第一条回退通知因为弹授权框而丢掉。已授权 / 已拒绝时系统不会再弹。谁来调：
    /// - 框架装呈现端时（`PresentationHub.install`，启动时、任何模块 activate() 之前）：没有呈现端（宠物模块没注册）就申请，有就只装代理；
    /// - 宠物模块自己判断什么时候会用上：宠物关着启动、或用户刚把宠物关掉时申请。
    func prepareSystemFallback(requestPermission: Bool) {
        let center = UNUserNotificationCenter.current()
        if center.delegate !== SystemNotificationRouter.shared {
            center.delegate = SystemNotificationRouter.shared
        }
        guard requestPermission, !didRequestAuth else { return }
        didRequestAuth = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 系统通知上的按钮 / 点击（宠物关着时的回退路径）回到投稿方。点通知本体 = "open"（同气泡）。
    func handleSystemResponse(requestID: String, actionID: String) {
        guard actionID != UNNotificationDismissActionIdentifier,
              let callback = systemCallbacks.removeValue(forKey: requestID) else { return }
        systemCallbackOrder.removeAll { $0 == requestID }
        callback(actionID == UNNotificationDefaultActionIdentifier ? "open" : actionID)
    }

    private func recordHistory(_ n: Notice) {
        history.insert(
            HistoryEntry(date: Date(), source: n.source, level: n.level, title: n.title, mergeCount: 1),
            at: 0
        )
        if history.count > NotifySettings.historyLimit {
            history.removeLast(history.count - NotifySettings.historyLimit)
        }
    }

    // MARK: - 启动期间先攒着

    /// 只给 `ToolRegistry.activateAll()` 调：从现在起投递的通知先攒着，等 `releaseAfterLaunch()`。
    /// 呈现端在所有模块 activate() 之前就装好了，但宠物要等它自己的 activate() 里 start() 之后才就绪；不攒的话，
    /// 排在宠物前面注册的模块在 activate() 里发的通知会因为注册顺序掉到系统通知（docs/notify-core/DESIGN.md §3.3）。
    func holdDuringLaunch() {
        guard launchHeld == nil else { return }
        launchHeld = []
    }

    /// 全部 activate() 跑完：攒着的按投递顺序逐条走 `post`（宠物开着进气泡；宠物关着、宠物模块没注册走系统通知），
    /// 之后的通知照常直接走。先清掉再发，`post` 才不会把它们又攒回去。
    func releaseAfterLaunch() {
        guard let held = launchHeld else { return }
        launchHeld = nil
        for (n, onAction) in held {
            post(n, onAction: onAction)
        }
    }

    // MARK: - 勿扰解除后的聚合补呈

    private func startFlushTimerIfNeeded() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushIfPossible() }
        }
    }

    private func flushIfPossible() {
        guard !NotifyDND.shared.isSuppressed, !suppressedQueue.isEmpty else {
            if suppressedQueue.isEmpty {
                flushTimer?.invalidate()
                flushTimer = nil
            }
            return
        }
        let queued = suppressedQueue
        suppressedQueue.removeAll()
        flushTimer?.invalidate()
        flushTimer = nil
        // 摘要不带动作按钮（原动作多已过期），只汇总标题。
        let titles = queued.prefix(3).map { $0.0.title }.joined(separator: "、")
        let digest = Notice(
            source: "digest",
            level: .bubble,
            title: L("notify.digest.title \(queued.count)"),
            body: titles
        )
        deliver(digest, onAction: nil)
    }
}

/// 系统通知的回调（UNUserNotificationCenterDelegate）：按钮 / 点击回到 NotifyCenter；
/// Baobox 在前台（比如设置窗口开着）时也照常弹横幅 —— 不实现 willPresent 的话，
/// 系统只把它悄悄塞进通知中心，看起来像点了没反应。
final class SystemNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let requestID = response.notification.request.identifier
        let actionID = response.actionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NotifyCenter.shared.handleSystemResponse(requestID: requestID, actionID: actionID)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
