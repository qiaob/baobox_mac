import Foundation
import UserNotifications

/// Claude Code 助手 —— events.jsonl 监听、会话状态机、系统通知。
///
/// events.jsonl 由 reporter 脚本追加（见 ClaudeHooks.swift）。用 `DispatchSourceFileSystemObject`
/// 监听增量，维护读取偏移。状态机把 hook 事件映射为运行中 / 等待确认 / 空闲。
/// 通知走 UNUserNotificationCenter，未签名 dev 包可能失败，全部判空不 crash。
///
/// 用户可见文案（L key，建议中英文案）：
///   - claudecode.status.running %lld        zh:「%lld 运行中」            en:「%lld running」
///   - claudecode.status.waiting %lld        zh:「%lld 等待确认」          en:「%lld awaiting confirmation」
///   - claudecode.status.inferredActive %lld zh:「%lld 个会话活跃（推断）」 en:「%lld session(s) active (inferred)」
///   - claudecode.notify.stop.title %@       zh:「会话完成 · %@」          en:「Session finished · %@」
///   - claudecode.notify.waiting.title %@    zh:「等你确认 · %@」          en:「Awaiting confirmation · %@」
///   - claudecode.notify.budget.title        zh:「额度提醒」                en:「Usage budget alert」
///   - claudecode.notify.budget.body %lld    zh:「本额度窗口已用 %lld%% 预算」 en:「You've used %lld%% of this window's budget」
///   - claudecode.notify.budgetRestored.title zh:「额度已恢复」             en:「Budget window reset」
///   - claudecode.notify.budgetRestored.body  zh:「新的 5 小时额度窗口已开始」 en:「A new 5-hour usage window has started」

// MARK: - 会话状态

enum ClaudeSessionState: Equatable {
    case running
    case waiting(String)   // 关联 Notification 的 message
    case idle
}

/// 一个活跃会话的状态快照。
struct ClaudeLiveSession {
    let sessionID: String
    var state: ClaudeSessionState
    var cwd: String?
    var lastEvent: Date

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return sessionID }
        return ClaudeSessionIndex.projectName(fromPath: cwd)
    }
}

// MARK: - 通知设置（UserDefaults 键）

enum ClaudeNotifierSettings {
    static let enabledKey = "claudecode.notificationsEnabled"
    static let soundKey = "claudecode.notificationSound"
    static let budgetAlertKey = "claudecode.budgetAlertEnabled"
    static let budgetRestoreKey = "claudecode.budgetRestoreEnabled"

    /// 完成/等待通知总开关（默认关，opt-in）。
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }
    /// 提示音（默认开）。
    static var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }
    /// 额度 80% 提醒（默认开）。
    static var budgetAlertEnabled: Bool {
        UserDefaults.standard.object(forKey: budgetAlertKey) as? Bool ?? true
    }
    /// 额度恢复提醒（默认关）。
    static var budgetRestoreEnabled: Bool {
        UserDefaults.standard.object(forKey: budgetRestoreKey) as? Bool ?? false
    }
}

// MARK: - 通知器

/// 系统通知封装。首次开启通知时申请授权；失败静默。
@MainActor
final class ClaudeNotifier {
    static let shared = ClaudeNotifier()
    private init() {}

    /// 首次开启通知开关时调用。
    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // 授权结果无需处理；失败时后续 add 会被系统丢弃，不 crash。
        }
    }

    /// 任务完成通知（受总开关控制）。
    func notifyStop(project: String) {
        guard ClaudeNotifierSettings.enabled else { return }
        post(title: L("claudecode.notify.stop.title \(project)"), body: "")
    }

    /// 等待确认通知（受总开关控制），正文带 Claude 的 message。
    func notifyWaiting(project: String, message: String) {
        guard ClaudeNotifierSettings.enabled else { return }
        post(title: L("claudecode.notify.waiting.title \(project)"), body: message)
    }

    /// 额度 80% 提醒。
    func notifyBudget(percent: Int, windowEnd: Date) {
        post(title: L("claudecode.notify.budget.title"), body: L("claudecode.notify.budget.body \(percent)"))
    }

    /// 额度窗口重置提醒。
    func notifyBudgetRestored() {
        post(title: L("claudecode.notify.budgetRestored.title"), body: L("claudecode.notify.budgetRestored.body"))
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        if ClaudeNotifierSettings.soundEnabled { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

// MARK: - events.jsonl 增量监听器（非 @MainActor，独占后台串行队列）

/// 监听单个文件的增量写入，把新行回调出去。offset 只在自有串行队列上访问，无需锁。
final class ClaudeEventWatcher {
    private let url: URL
    private var offset: UInt64
    private let onLines: ([String]) -> Void
    private let queue = DispatchQueue(label: "com.baobox.claudecode.eventwatcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    init(url: URL, startOffset: UInt64, onLines: @escaping ([String]) -> Void) {
        self.url = url
        self.offset = startOffset
        self.onLines = onLines
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let fd = open(self.url.path, O_EVTONLY)
            guard fd >= 0 else { return }
            self.descriptor = fd
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend],
                queue: self.queue
            )
            src.setEventHandler { [weak self] in
                self?.drain()
            }
            src.setCancelHandler {
                close(fd)
            }
            self.source = src
            src.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            self?.descriptor = -1
        }
    }

    /// 从上次偏移读到文件末尾，切成行回调。
    private func drain() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            // 文件被截断（events.jsonl 超限清理）→ 偏移复位。
            if end < offset { offset = 0 }
            guard end > offset else { return }
            try handle.seek(toOffset: offset)
            let data = (try handle.read(upToCount: Int(end - offset))) ?? Data()
            offset = end
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if !lines.isEmpty {
                onLines(lines)
            }
        } catch {
            return
        }
    }
}

// MARK: - 实时状态单例

@MainActor
final class ClaudeLiveStatus: ObservableObject {
    static let shared = ClaudeLiveStatus()

    /// sessionID → 会话状态。
    @Published private(set) var sessions: [String: ClaudeLiveSession] = [:]

    private var watcher: ClaudeEventWatcher?
    private var pruneTimer: Timer?

    /// 6h 无事件的会话视为失效。
    private static let staleInterval: TimeInterval = 6 * 3_600
    /// events.jsonl 超过此大小则截断保尾。后台 nonisolated 方法读取，显式 nonisolated。
    nonisolated private static let maxEventBytes = 5 * 1_024 * 1_024
    nonisolated private static let keepTailLines = 1_000

    private init() {}

    private var eventFileURL: URL {
        ClaudeEnv.supportDir.appendingPathComponent("events.jsonl")
    }

    // MARK: - 生命周期

    /// 确保事件文件存在（必要时截断）→ 读入已有事件建初始状态 → 启动增量监听。
    func start() {
        guard watcher == nil else { return }
        let url = eventFileURL
        DispatchQueue.global(qos: .utility).async {
            Self.ensureEventFile(url: url)
            let (lines, size) = Self.readAll(url: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 初始回放不发通知（避免历史事件轰炸）。
                    for line in lines {
                        self.apply(line: line, notify: false)
                    }
                    self.pruneStale()
                    let watcher = ClaudeEventWatcher(url: url, startOffset: size) { [weak self] newLines in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self else { return }
                                for line in newLines {
                                    self.apply(line: line, notify: true)
                                }
                                self.pruneStale()
                            }
                        }
                    }
                    watcher.start()
                    self.watcher = watcher
                    self.startPruneTimer()
                }
            }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    // MARK: - 汇总展示

    var runningCount: Int {
        sessions.values.filter { $0.state == .running }.count
    }

    var waitingCount: Int {
        sessions.values.filter { if case .waiting = $0.state { return true } else { return false } }.count
    }

    /// 菜单状态行，如「2 运行中 · 1 等待确认」；无 hooks 数据时按会话文件 mtime 降级推断。
    /// 无任何可显示内容返回 nil。
    func summaryLine() -> String? {
        let running = runningCount
        let waiting = waitingCount
        if running > 0 || waiting > 0 {
            var parts: [String] = []
            if running > 0 { parts.append(L("claudecode.status.running \(running)")) }
            if waiting > 0 { parts.append(L("claudecode.status.waiting \(waiting)")) }
            return parts.joined(separator: " · ")
        }
        // 降级推断：最近 2 分钟内有活动的会话数。
        let recent = ClaudeSessionIndex.shared.sessions.filter {
            Date().timeIntervalSince($0.lastActivity) < 120
        }.count
        if recent > 0 {
            return L("claudecode.status.inferredActive \(recent)")
        }
        return nil
    }

    // MARK: - 状态机

    /// 处理一行事件 JSON。notify=false 用于初始回放。
    private func apply(line: String, notify: Bool) {
        guard let data = line.data(using: .utf8),
              let object = ClaudeJSONLParsing.parseObject(data),
              let sessionID = object["session_id"] as? String,
              let event = object["hook_event_name"] as? String else { return }

        let cwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let now = Date()

        switch event {
        case "SessionStart", "UserPromptSubmit":
            update(sessionID: sessionID, state: .running, cwd: cwd, at: now)
        case "Notification":
            let message = object["message"] as? String ?? ""
            update(sessionID: sessionID, state: .waiting(message), cwd: cwd, at: now)
            if notify {
                let project = cwd.map { ClaudeSessionIndex.projectName(fromPath: $0) } ?? sessionID
                ClaudeNotifier.shared.notifyWaiting(project: project, message: message)
            }
        case "Stop":
            update(sessionID: sessionID, state: .idle, cwd: cwd, at: now)
            if notify {
                let project = cwd.map { ClaudeSessionIndex.projectName(fromPath: $0) } ?? sessionID
                ClaudeNotifier.shared.notifyStop(project: project)
            }
        case "SessionEnd":
            sessions.removeValue(forKey: sessionID)
        default:
            // 其他事件仅刷新时间戳（保活）。
            if var existing = sessions[sessionID] {
                existing.lastEvent = now
                if let cwd { existing.cwd = cwd }
                sessions[sessionID] = existing
            }
        }
    }

    private func update(sessionID: String, state: ClaudeSessionState, cwd: String?, at date: Date) {
        if var existing = sessions[sessionID] {
            existing.state = state
            existing.lastEvent = date
            if let cwd { existing.cwd = cwd }
            sessions[sessionID] = existing
        } else {
            sessions[sessionID] = ClaudeLiveSession(sessionID: sessionID, state: state, cwd: cwd, lastEvent: date)
        }
    }

    private func pruneStale() {
        let now = Date()
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastEvent) < Self.staleInterval }
    }

    private func startPruneTimer() {
        pruneTimer?.invalidate()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pruneStale()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pruneTimer = t
    }

    // MARK: - 事件文件维护（nonisolated static）

    /// 确保文件存在；超限则截断保留尾部若干行。
    nonisolated static func ensureEventFile(url: URL) {
        ClaudeEnv.ensureSupportDir()
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data())
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > maxEventBytes else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        let tail = lines.suffix(keepTailLines)
        var rebuilt = Data()
        for line in tail {
            rebuilt.append(Data(line))
            rebuilt.append(0x0A)
        }
        try? rebuilt.write(to: url)
    }

    /// 读入全部行与当前大小（供初始建状态 + 设定监听偏移）。
    nonisolated static func readAll(url: URL) -> (lines: [String], size: UInt64) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0) }
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (lines, UInt64(data.count))
    }
}
