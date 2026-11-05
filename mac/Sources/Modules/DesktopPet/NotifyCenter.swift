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

    struct Action {
        let id: String
        let label: String
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
            postSystemNotification(n)
        }
    }

    /// 投稿方自己的声音设置（Claude Code / Codex 的提示音开关，已折算进 playSound）照旧生效；
    /// notify.sound 只给没要求发声的 alert 级补一声（设计 §9：alert 提示音，默认关）。
    private func wantsSound(_ n: PetNotification) -> Bool {
        n.playSound || (n.level == .alert && PetSettings.soundEnabled)
    }

    /// 宠物不可用时的回退：系统通知中心，保证提醒不丢（设计 §2）。
    private func postSystemNotification(_ n: PetNotification) {
        if !didRequestAuth {
            didRequestAuth = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = n.title
        if !n.body.isEmpty { content.body = n.body }
        if wantsSound(n) { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
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
