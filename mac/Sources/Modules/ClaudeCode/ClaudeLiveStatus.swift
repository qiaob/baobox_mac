import AppKit
import AVFoundation
import Foundation

/// Claude Code 助手 —— events.jsonl 监听、会话状态机、系统通知。
///
/// events.jsonl 由 reporter 脚本追加（见 ClaudeHooks.swift）。建文件、超限截断、启动时回放、之后增量跟随
/// 用与 Codex 助手共用的 `EventFileFollower`（Core/EventFile）。状态机把 hook 事件映射为运行中 / 等待确认 / 空闲；
/// 回合结束（Stop）与等你确认（Notification）时顺带节流刷新用量（`ClaudeUsageStore.refreshThrottledFromHook`）。
/// 通知经通知内核（NotifyCenter，桌面宠物模块）投递：宠物呈现，宠物关时由内核回退系统通知（权限也归内核管）。
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
    /// 会话开在哪个终端（hook 记下的，点通知时跳回去）。
    var terminal: TerminalLocation?
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
    static let soundNameKey = "claudecode.notificationSoundName"
    static let speechEnabledKey = "claudecode.speechEnabled"
    static let speechTextKey = "claudecode.speechText"
    static let budgetAlertKey = "claudecode.budgetAlertEnabled"
    static let budgetRestoreKey = "claudecode.budgetRestoreEnabled"

    /// 可选系统提示音(/System/Library/Sounds,NSSound(named:) 可加载)。
    static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    /// 提醒方式:三选一互斥(同时响提示音和朗读会互相干扰)。
    enum AlertStyle: String, CaseIterable {
        case none, sound, speech
    }
    static let alertStyleKey = "claudecode.alertStyle"

    /// 完成/等待通知总开关（默认关，opt-in）。
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }
    /// 当前提醒方式。新键缺失时按旧的两个布尔键迁移(语音是更明确的后设意图,优先)。
    static var alertStyle: AlertStyle {
        if let raw = UserDefaults.standard.string(forKey: alertStyleKey),
           let style = AlertStyle(rawValue: raw) {
            return style
        }
        if legacySpeechEnabled { return .speech }
        return legacySoundEnabled ? .sound : .none
    }
    /// 提示音名;空串 = 系统默认通知音。
    static var soundName: String {
        UserDefaults.standard.string(forKey: soundNameKey) ?? ""
    }
    /// 旧版独立开关,仅用于向 alertStyle 迁移。
    private static var legacySoundEnabled: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }
    private static var legacySpeechEnabled: Bool {
        UserDefaults.standard.object(forKey: speechEnabledKey) as? Bool ?? false
    }
    /// 自定义朗读文案;空串 = 朗读通知标题。支持 {project} 占位符。
    static var speechText: String {
        UserDefaults.standard.string(forKey: speechTextKey) ?? ""
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

    /// AVSpeechSynthesizer 必须常驻持有,朗读中途释放会静音。
    private let speechSynthesizer = AVSpeechSynthesizer()
    /// 自定义提示音播放中也需持有引用。
    private var currentSound: NSSound?

    /// 任务完成通知（受总开关控制）。
    /// `onOpen`：点通知卡片（或系统通知）时调用 —— 跳回会话所在的终端窗口（docs/claude-code-assistant/NOTIFY_JUMP.md）。
    func notifyStop(project: String, onOpen: (() -> Void)? = nil) {
        guard ClaudeNotifierSettings.enabled else { return }
        post(title: L("claudecode.notify.stop.title \(project)"), body: "", level: .bubble, speakProject: project, onOpen: onOpen)
    }

    /// 等待确认通知（受总开关控制），正文带 Claude 的 message。
    func notifyWaiting(project: String, message: String, onOpen: (() -> Void)? = nil) {
        guard ClaudeNotifierSettings.enabled else { return }
        post(title: L("claudecode.notify.waiting.title \(project)"), body: message, level: .alert, speakProject: project,
             onOpen: onOpen)
    }

    /// 额度 80% 提醒。
    func notifyBudget(percent: Int, windowEnd: Date) {
        post(title: L("claudecode.notify.budget.title"), body: L("claudecode.notify.budget.body \(percent)"))
    }

    /// 额度窗口重置提醒。
    func notifyBudgetRestored() {
        post(title: L("claudecode.notify.budgetRestored.title"), body: L("claudecode.notify.budgetRestored.body"))
    }

    /// 周额度 80% 提醒。
    func notifyWeeklyBudget(percent: Int, windowEnd: Date) {
        post(title: L("claudecode.notify.weeklyBudget.title"), body: L("claudecode.notify.weeklyBudget.body \(percent)"))
    }

    /// 周额度窗口重置提醒。
    func notifyWeeklyBudgetRestored() {
        post(title: L("claudecode.notify.weeklyBudgetRestored.title"), body: L("claudecode.notify.weeklyBudgetRestored.body"))
    }

    /// 设置页「试听」:按当前提醒方式演示一次。
    func preview() {
        let project = L("claudecode.notify.previewProject")
        switch ClaudeNotifierSettings.alertStyle {
        case .sound:
            playSound()
        case .speech:
            speak(title: L("claudecode.notify.stop.title \(project)"), project: project)
        case .none:
            break
        }
    }

    /// speakProject 非 nil 时,该通知参与语音朗读(完成 / 等待类)。
    /// 视觉呈现改走通知内核（DesktopPet）：宠物在场时经宠物，关时由内核回退系统通知；
    /// 声音仍按本模块 alertStyle 处理（自定义音自播，默认音交给内核在 playSound 时发）。
    private func post(title: String, body: String, level: Notice.Level = .ambient, speakProject: String? = nil,
                      onOpen: (() -> Void)? = nil) {
        var useDefaultSound = false
        switch ClaudeNotifierSettings.alertStyle {
        case .sound:
            if ClaudeNotifierSettings.soundName.isEmpty {
                useDefaultSound = true
            } else {
                playSound()
            }
        case .speech, .none:
            break
        }
        NotifyCenter.shared.post(Notice(
            source: "claudecode",
            level: level,
            title: title,
            body: body,
            playSound: useDefaultSound
        ), onAction: onOpen.map { open in { action in if action == "open" { open() } } })

        if let speakProject, ClaudeNotifierSettings.alertStyle == .speech {
            speak(title: title, project: speakProject)
        }
    }

    private func playSound() {
        let name = ClaudeNotifierSettings.soundName
        guard !name.isEmpty, let sound = NSSound(named: name) else {
            NSSound(named: "Glass")?.play()
            return
        }
        currentSound = sound
        sound.play()
    }

    /// 系统语音朗读:自定义文案({project} 占位符),留空读通知标题。
    private func speak(title: String, project: String) {
        var text = ClaudeNotifierSettings.speechText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = title
        } else {
            text = text.replacingOccurrences(of: "{project}", with: project)
        }
        guard !text.isEmpty else { return }
        speechSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: nil)   // 跟随系统默认语音
        speechSynthesizer.speak(utterance)
    }
}

// MARK: - 实时状态单例

@MainActor
final class ClaudeLiveStatus: ObservableObject {
    static let shared = ClaudeLiveStatus()

    /// sessionID → 会话状态。
    @Published private(set) var sessions: [String: ClaudeLiveSession] = [:]

    /// events.jsonl 的回放 + 跟随。
    private let follower = EventFileFollower(
        url: ClaudeEnv.supportDir.appendingPathComponent("events.jsonl"),
        limits: ClaudeLiveStatus.eventFileLimits,
        queueLabel: "com.baobox.claudecode.eventwatcher"
    )
    private var pruneTimer: Timer?

    /// 6h 无事件的会话视为失效。
    private static let staleInterval: TimeInterval = 6 * 3_600
    /// events.jsonl 超过 5 MB 则截断，保留最后 1000 行。
    nonisolated private static let eventFileLimits = EventFileLog.Limits(maxBytes: 5 * 1_024 * 1_024, keepTailLines: 1_000)

    private init() {}

    // MARK: - 生命周期

    /// 确保事件文件存在（必要时截断）→ 读入已有事件建初始状态 → 启动增量监听。已启动则直接返回。
    func start() {
        follower.start(
            replay: { [weak self] lines in
                guard let self else { return }
                // 初始回放不发通知（避免历史事件轰炸）。
                for line in lines {
                    self.apply(line: line, notify: false)
                }
                self.pruneStale()
                self.startPruneTimer()
            },
            follow: { [weak self] newLines in
                guard let self else { return }
                for line in newLines {
                    self.apply(line: line, notify: true)
                }
                self.pruneStale()
            }
        )
    }

    func stop() {
        follower.stop()
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
              let object = CLIJSONL.parseObject(data),
              let sessionID = object["session_id"] as? String,
              let event = object["hook_event_name"] as? String else { return }

        let cwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let terminal = TerminalLocation(json: object["baobox_terminal"])
        let now = Date()

        switch event {
        case "SessionStart", "UserPromptSubmit":
            update(sessionID: sessionID, state: .running, cwd: cwd, terminal: terminal, at: now)
        case "Notification":
            let message = object["message"] as? String ?? ""
            update(sessionID: sessionID, state: .waiting(message), cwd: cwd, terminal: terminal, at: now)
            if notify {
                let project = cwd.map { ClaudeSessionIndex.projectName(fromPath: $0) } ?? sessionID
                ClaudeNotifier.shared.notifyWaiting(project: project, message: message, onOpen: focusAction(sessionID))
            }
        case "Stop":
            update(sessionID: sessionID, state: .idle, cwd: cwd, terminal: terminal, at: now)
            if notify {
                let project = cwd.map { ClaudeSessionIndex.projectName(fromPath: $0) } ?? sessionID
                ClaudeNotifier.shared.notifyStop(project: project, onOpen: focusAction(sessionID))
            }
        case "SessionEnd":
            sessions.removeValue(forKey: sessionID)
        default:
            // 其他事件仅刷新时间戳（保活）。
            if var existing = sessions[sessionID] {
                existing.lastEvent = now
                if let cwd { existing.cwd = cwd }
                if let terminal { existing.terminal = terminal }
                sessions[sessionID] = existing
            }
        }

        // 回合结束 / 等你确认：刚产生了用量，节流刷新（≥ 60 秒才真刷），菜单的「今日」与额度不用等 5 分钟的定时器
        // （docs/codex-assistant/DEDUPE.md §5.1 B1、§9 D4）。不看通知开关；启动回放的旧事件不刷。
        // 不挂 UserPromptSubmit / SessionStart：那时还没有新用量，刷了反而把回合结束后的那次节流掉。
        if notify, event == "Stop" || event == "Notification" {
            ClaudeUsageStore.shared.refreshThrottledFromHook()
        }
    }

    private func update(sessionID: String, state: ClaudeSessionState, cwd: String?, terminal: TerminalLocation?, at date: Date) {
        if var existing = sessions[sessionID] {
            existing.state = state
            existing.lastEvent = date
            if let cwd { existing.cwd = cwd }
            if let terminal { existing.terminal = terminal }
            sessions[sessionID] = existing
        } else {
            sessions[sessionID] = ClaudeLiveSession(sessionID: sessionID, state: state, cwd: cwd, terminal: terminal,
                                                    lastEvent: date)
        }
    }

    /// 会话现在还占着的终端（快速切换面板续接用，docs/claude-code-assistant/NOTIFY_JUMP.md §3.1）：hook 记下的位置，
    /// 且同一个终端（tty）后来没见过别的会话。nil = 没装 hooks、6 小时内没见过它、位置里没记 tty，或那个终端已经让给了
    /// 后来的会话。会话此刻是不是还在那儿跑，由 `TerminalLauncher.focusRunningSession` 再按进程确认。
    func currentTerminal(of sessionID: String) -> TerminalLocation? {
        guard let location = sessions[sessionID]?.terminal else { return nil }
        let sightings = sessions.values.map {
            ClaudeRunningSession.Sighting(sessionID: $0.sessionID, tty: $0.terminal?.tty, lastEvent: $0.lastEvent)
        }
        return ClaudeRunningSession.ownsTerminal(sessionID, sightings: sightings) ? location : nil
    }

    /// 点通知时跳回这个会话所在的终端（docs/claude-code-assistant/NOTIFY_JUMP.md）。
    /// 终端位置在发通知这一刻取好（会话之后可能结束、被清掉），点的时候直接用：hook 记下了就精确到窗口 / 标签页 / 面板；
    /// 没记下（旧版脚本、不认识的终端）退回按进程猜。与快速切换面板续接走同一个函数（面板的位置要先确认）。
    private func focusAction(_ sessionID: String) -> () -> Void {
        let terminal = sessions[sessionID]?.terminal
        let cwd = sessions[sessionID]?.cwd
        return {
            TerminalLauncher.focusRunningSession(sessionID: sessionID, projectPath: cwd, location: terminal,
                                                 confirmRunning: false, isNewestInProject: true) { _ in }
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
}
