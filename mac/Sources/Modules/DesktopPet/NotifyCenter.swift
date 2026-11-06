import AppKit
import Foundation
import UserNotifications

/// 一条通知（内部模型，设计 §3）。来源模块先转成它，再由 NotifyCenter 分发呈现。
struct PetNotification {
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

    var resolvedStyle: Style {
        if let style { return style }
        switch level {
        case .ambient: return .toast
        case .bubble: return .card
        case .alert: return .sticky
        }
    }
}

/// 呈现端（桌面宠物）。NotifyCenter 不持有窗口，只调这个协议，便于回退与测试。
@MainActor
protocol NotifyPresenting: AnyObject {
    var isReady: Bool { get }
    func present(_ n: PetNotification, onAction: @escaping (String) -> Void)
}

/// 通知内核：来源开关、去重、勿扰聚合、宠物呈现 / 系统通知回退、历史。
@MainActor
final class NotifyCenter {
    static let shared = NotifyCenter()
    private init() {}

    weak var presenter: NotifyPresenting?

    struct HistoryEntry {
        let date: Date
        let source: String
        let level: PetNotification.Level
        let title: String
        var mergeCount: Int
    }

    private(set) var history: [HistoryEntry] = []
    private var lastPostAt: [String: Date] = [:]
    private var suppressedQueue: [(PetNotification, ((String) -> Void)?)] = []
    private var flushTimer: Timer?
    private var didRequestAuth = false
    /// 回退系统通知的按钮回调（通知 id → 投稿方回调）与已登记的按钮组。
    private var systemCallbacks: [String: (String) -> Void] = [:]
    private var systemCallbackOrder: [String] = []
    private var systemCategories: [String: UNNotificationCategory] = [:]

    func post(_ n: PetNotification, onAction: ((String) -> Void)? = nil) {
        guard PetSettings.sourceEnabled(n.source) else { return }

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

        // 勿扰：alert 照常呈现（宠物路径本身不额外发声，见 deliver），其余入队待解除后合并摘要。
        if NotifyDND.shared.isSuppressed, n.level != .alert {
            suppressedQueue.append((n, onAction))
            startFlushTimerIfNeeded()
            return
        }
        deliver(n, onAction: onAction)
    }

    private func deliver(_ n: PetNotification, onAction: ((String) -> Void)?) {
        if let presenter, presenter.isReady {
            if wantsSound(n) {
                NSSound(named: "Glass")?.play()
            }
            presenter.present(n) { actionID in onAction?(actionID) }
        } else {
            postSystemNotification(n, onAction: onAction)
        }
    }

    /// 投稿方自己的声音设置（Claude Code / Codex 的提示音开关，已折算进 playSound）照旧生效；
    /// notify.sound 只给没要求发声的 alert 级补一声（设计 §9：alert 提示音，默认关）。
    private func wantsSound(_ n: PetNotification) -> Bool {
        n.playSound || (n.level == .alert && PetSettings.soundEnabled)
    }

    /// 宠物不可用时的回退：系统通知中心，保证提醒不丢（设计 §2）。气泡上的按钮照样带上
    /// （UNNotificationAction），用户点了经 SystemNotificationRouter 回到投稿方 —— 否则推迟、
    /// 「现在休息」「再来一轮」这些在宠物关着时全都点不了（2026-11-06 真机踩到）。
    private func postSystemNotification(_ n: PetNotification, onAction: ((String) -> Void)?) {
        let center = UNUserNotificationCenter.current()
        prepareSystemFallback(requestPermission: true)
        let content = UNMutableNotificationContent()
        content.title = n.title
        if !n.body.isEmpty { content.body = n.body }
        if wantsSound(n) { content.sound = .default }
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

    /// 系统通知回退的准备（宠物模块自己判断什么时候会用上，功能模块不碰系统通知）：
    /// 装上回调代理（不弹任何东西）；`requestPermission` 时顺带申请通知权限 —— 宠物关着启动、
    /// 或用户刚把宠物关掉时就问，免得第一条回退通知因为弹授权框而丢掉。已授权 / 已拒绝时系统不会再弹。
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

    private func recordHistory(_ n: PetNotification) {
        history.insert(
            HistoryEntry(date: Date(), source: n.source, level: n.level, title: n.title, mergeCount: 1),
            at: 0
        )
        if history.count > PetSettings.historyLimit {
            history.removeLast(history.count - PetSettings.historyLimit)
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
        let digest = PetNotification(
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
