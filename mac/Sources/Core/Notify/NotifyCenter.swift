import AppKit
import Foundation
import UserNotifications

/// 呈现端（桌面宠物）。NotifyCenter 不持有窗口，只调这个协议，便于回退与测试。
/// 模块用 `ToolModule.presentationRoles()` 交出来，框架在启动时装进 `PresentationHub`（docs/notify-core/DESIGN.md §3.3）。
@MainActor
protocol NotifyPresenting: AnyObject {
    var isReady: Bool { get }
    func present(_ n: Notice, onAction: @escaping (String) -> Void)
    /// 配合提醒做个动作（喝水、伸懒腰、远眺），按片段名播；做不了返回 false。默认做不了。
    func performGesture(_ clips: [String]) -> Bool
    /// 还挂着、还在排队、还收着没放出的通知条数（「清除所有通知」菜单项的条数）。默认 0。
    var pendingCount: Int { get }
    /// 一键清除：挂着的、排队的、收着的全部收起，不回调投稿方（同点 ×）。默认什么都不做。
    func dismissAll()
}

extension NotifyPresenting {
    func performGesture(_ clips: [String]) -> Bool { false }
    var pendingCount: Int { 0 }
    func dismissAll() {}
}

/// 通知内核：来源开关、去重、勿扰聚合、宠物呈现 / 系统通知回退、历史、启动期间先攒着。
/// 判断和记账（来源开关、去重、历史、勿扰时攒不攒、摘要）在 `NotifyLedger`，和通知模型 `Notice` 一起放在 Model/（纯逻辑，有单测）；
/// 这里给它接上时间、设置和勿扰判定，管呈现、声音、系统通知、定时器和文案。
@MainActor
final class NotifyCenter {
    static let shared = NotifyCenter()
    private init() {}

    typealias HistoryEntry = NotifyLedger.HistoryEntry

    /// 最近的通知，新的在前，最多 notify.historyLimit 条。macOS 上还没有界面读它（docs/notify-core/DESIGN.md §8）。
    var history: [HistoryEntry] { ledger.history }

    private var ledger = NotifyLedger()
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
        // 来源开关 → 去重（同来源同 key 30 秒内只呈现一次，其余并进历史计数）→ 记历史 → 勿扰时攒不攒（alert 和操作回执照常呈现）：
        // 规则都在 NotifyLedger.post。勿扰要查窗口列表，只在走到最后一步时才查。
        switch ledger.post(n, onAction: onAction, at: Date(),
                           sourceEnabled: NotifySettings.sourceEnabled(n.source),
                           historyLimit: NotifySettings.historyLimit,
                           isSuppressed: { NotifyDND.shared.isSuppressed }) {
        case .deliver:
            deliver(n, onAction: onAction)
        case .hold:
            startFlushTimerIfNeeded()
        case .drop:
            break
        }
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
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in NotifyCenter.refreshDeliveredCount() }
            return
        }
        let categoryID = "baobox." + n.actions.map { $0.id + "=" + $0.label }.joined(separator: "|")
        content.categoryIdentifier = categoryID
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        if systemCategories[categoryID] != nil {
            center.add(request) { _ in NotifyCenter.refreshDeliveredCount() }
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
            center.add(request) { _ in NotifyCenter.refreshDeliveredCount() }
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

    // MARK: - 一键清除

    /// 没处理的到这么多条才给「清除所有通知」（气泡一次叠 3 条，再多就开始排队了）。少的时候一条条点 × 就行，不多占地方。
    static let clearAllThreshold = 4

    /// 系统通知中心里 Baobox 发的还剩几条：异步查的缓存（投递后、菜单打开时刷新，见 refreshDeliveredCount）。
    private var deliveredSystemCount = 0

    /// 还没处理的通知条数：呈现端挂着 / 排队的 + 勿扰时攒着的 + 系统通知中心里的（缓存值）。
    /// 只读内存，菜单构建时可以调。
    var pendingCount: Int {
        (PresentationHub.shared.notifications?.pendingCount ?? 0) + ledger.held.count + deliveredSystemCount
    }

    /// 多到值得一键清除了（菜单项、环形菜单格据此显示）。
    var offersClearAll: Bool { pendingCount >= Self.clearAllThreshold }

    /// 后台查一次系统通知中心里还剩几条，回主线程写缓存。菜单构建时调：这次用旧值，下次打开就准了。
    nonisolated static func refreshDeliveredCount() {
        UNUserNotificationCenter.current().getDeliveredNotifications { list in
            let count = list.count
            DispatchQueue.main.async {
                MainActor.assumeIsolated { NotifyCenter.shared.deliveredSystemCount = count }
            }
        }
    }

    /// 一键清除所有通知（锁屏 / 离开一会儿回来攒了几十条时用）：宠物气泡全部收起、勿扰时攒着的丢掉（不再出摘要）、
    /// 系统通知中心里 Baobox 发的也一并移走。都不回调投稿方，同点 ×。历史不动。
    func clearAll() {
        PresentationHub.shared.notifications?.dismissAll()
        ledger.discardHeld()
        flushTimer?.invalidate()
        flushTimer = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        deliveredSystemCount = 0
        systemCallbacks.removeAll()
        systemCallbackOrder.removeAll()
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
        switch ledger.flush(isSuppressed: NotifyDND.shared.isSuppressed) {
        case .stillSuppressed:
            return
        case .nothingHeld:
            flushTimer?.invalidate()
            flushTimer = nil
        case .digest(let digest):
            flushTimer?.invalidate()
            flushTimer = nil
            // 摘要不带动作按钮（原动作多已过期），只汇总标题。
            let notice = Notice(
                source: "digest",
                level: .bubble,
                title: L("notify.digest.title \(digest.count)"),
                body: digest.body
            )
            deliver(notice, onAction: nil)
        }
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
