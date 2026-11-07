import AppKit
import os

/// 专注与健康的编排（docs/focus-health/TECH_DESIGN.md §2–§4）：1 秒心跳、人在不在电脑前、
/// 睡眠唤醒、避让、发提醒、专注—休息循环、落盘。所有状态只在主线程读写。
@MainActor
final class FocusHealthController: ObservableObject {
    static let shared = FocusHealthController()
    private init() {}

    /// 勿扰令牌：专注中 / 休息画面在场。
    static let focusToken = "focus"
    static let breakToken = "break"
    /// 通知来源 id（宠物设置里的逐来源开关同名）。
    static let source = "focus"

    /// 键鼠空闲超过这么久算离开（看视频除外）。
    private static let presenceIdle: TimeInterval = 120
    /// 休息画面项顺延超过这么久，解除后降级为宠物提醒。
    private static let downgradeAfter: TimeInterval = 45 * 60
    private static let bubbleSnooze: TimeInterval = 10 * 60
    private static let restSnooze: TimeInterval = 5 * 60
    /// App 关着期间专注过点超过这么久：只记一轮，不补休息。
    private static let staleFocus: TimeInterval = 10 * 60
    private static let log = Logger(subsystem: "com.baobox.app", category: "focushealth")

    @Published private(set) var items: [ReminderItem] = []
    @Published private(set) var session = FocusSession()
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var offDay: String?
    private var runtime: [String: ReminderRuntime] = [:]

    let stage = BreakStageController()
    private let statusItem = FocusStatusItem()
    private let store = FocusHealthStore()
    private var timer: Timer?
    private var started = false
    private var lastTick = Date()
    private var tickCount = 0
    private(set) var present = true
    private var awayActive = false
    private var lastIdle: TimeInterval = 0
    private var videoCheckedAt = Date.distantPast
    private var videoCached = false
    private var sleepStartedAt: Date?
    /// 专注期间到点、被顺延的项：专注结束时并进休息。
    private var deferredDuringFocus: Set<String> = []
    /// 上一次真的提醒（气泡 / 轻提醒 / 休息画面）的时刻：统一节拍的最小间隔从这儿算（REQUIREMENTS.md §7）。
    private var lastPromptAt: Date?
    private var avoidanceCheckedAt = Date.distantPast
    private var avoidanceCached = false
    private var dirty = false
    private var lastSave = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        let loaded = store.load()
        items = loaded.items
        session = loaded.state.session
        runtime = loaded.state.runtime
        pausedUntil = loaded.state.pausedUntil
        offDay = loaded.state.offDay

        let now = Date()
        // 休息画面随进程没了：长休息直接结束；专注、短休息照常恢复。
        if session.phase == .longBreak { session.endBreak() }
        if session.phase == .focusing { NotifyDND.shared.setSuppressed(true, token: Self.focusToken) }
        // 新加的项（或第一次启动）从现在开始计时；删掉的项清掉进度。
        for item in items where runtime[item.id] == nil { runtime[item.id] = ReminderRuntime(anchor: now) }
        let ids = Set(items.map(\.id))
        runtime = runtime.filter { ids.contains($0.key) }

        lastTick = now
        statusItem.menuItems = { FocusHealthMenu.items(includeSettings: true) }
        observeSystem()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { FocusHealthController.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateStatusItem(now)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stage.forceTeardown()
        saveNow(sync: true)
    }

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { FocusHealthController.shared.systemWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { FocusHealthController.shared.systemDidWake() }
        })
    }

    private func systemWillSleep() {
        sleepStartedAt = Date()
        saveNow(sync: true)
    }

    /// 睡眠期间不计时；醒来按睡眠时长套用自然休息（需求 §3）。
    private func systemDidWake() {
        let now = Date()
        if let start = sleepStartedAt { applyAway(span: now.timeIntervalSince(start), now: now) }
        sleepStartedAt = nil
        lastTick = now
    }

    // MARK: - 心跳

    private func tick() {
        let now = Date()
        let dt = min(max(now.timeIntervalSince(lastTick), 0), 5)
        lastTick = now
        tickCount += 1
        if tickCount % 5 == 0 { NotifyDND.shared.refreshMicrophoneState() }

        let today = FocusDay.key(now)
        if session.roundsDay != today { session.rollDay(today) }
        if let until = pausedUntil, until <= now { pausedUntil = nil }
        if let day = offDay, day != today { offDay = nil }

        updatePresence(now)
        advanceSession(now)
        if remindersActive(at: now) {
            let input = SchedulerInput(now: now, dt: dt, present: present,
                                       inWorkHours: FocusHealthSettings.workHours.contains(now))
            let events = ReminderScheduler.advance(items, runtime: &runtime, input: input)
            dirty = true
            if !events.isEmpty { handle(events, now: now) }
        }
        updateStatusItem(now)
        if dirty, now.timeIntervalSince(lastSave) >= 30 { saveNow(sync: false) }
    }

    /// 在电脑前 = 空闲不到 2 分钟，或别的程序在阻止屏幕休眠（看视频）。离开后回来套用自然休息。
    private func updatePresence(_ now: Date) {
        let idle = UserActivity.secondsSinceInput()
        var isPresent = idle < Self.presenceIdle
        if !isPresent { isPresent = videoPlaying(now) }
        if !isPresent {
            awayActive = true
        } else if awayActive, idle < 5 {
            awayActive = false
            applyAway(span: lastIdle, now: now)
        }
        lastIdle = idle
        present = isPresent
    }

    /// 问 powerd 有没有别的进程在阻止屏幕休眠；跨进程，10 秒问一次。
    private func videoPlaying(_ now: Date) -> Bool {
        if now.timeIntervalSince(videoCheckedAt) >= 10 {
            videoCheckedAt = now
            videoCached = UserActivity.otherProcessPreventsDisplaySleep()
        }
        return videoCached
    }

    private func applyAway(span: TimeInterval, now: Date) {
        guard span >= 60 else { return }
        let reset = ReminderScheduler.applyAway(span: span, items: items, runtime: &runtime, now: now)
        if !reset.isEmpty {
            dirty = true
            Self.log.info("natural rest after \(Int(span))s away: reset \(reset.count) item(s)")
        }
    }

    // MARK: - 专注

    func startFocus(minutes: Int? = nil) {
        let now = Date()
        let length = max(1, minutes ?? FocusHealthSettings.defaultFocusMinutes)
        if session.inBreak { session.endBreak() }
        if stage.isBusy { stage.end(.skipped) }
        // 先说一声再挂勿扰（挂上之后这条轻提示会被攒起来）。
        NotifyCenter.shared.post(PetNotification(source: Self.source, level: .ambient,
                                                 title: L("focus.toast.started \(length)"), icon: "timer"))
        session.start(seconds: Double(length * 60), at: now)
        deferredDuringFocus = []
        NotifyDND.shared.setSuppressed(true, token: Self.focusToken)
        changed(now)
    }

    func pauseFocus() {
        guard session.phase == .focusing else { return }
        session.pause(at: Date())
        NotifyDND.shared.setSuppressed(false, token: Self.focusToken)
        changed()
    }

    func resumeFocus() {
        guard session.phase == .paused else { return }
        session.resume(at: Date())
        NotifyDND.shared.setSuppressed(true, token: Self.focusToken)
        changed()
    }

    /// 提前结束：记为完成（接休息）或作废（不计轮次、不接休息，顺延的提醒照常补上）。
    func endFocusEarly(countAsDone: Bool) {
        guard session.inFocus else { return }
        if countAsDone {
            finishFocus(at: Date())
        } else {
            session.discard()
            NotifyDND.shared.setSuppressed(false, token: Self.focusToken)
            deferredDuringFocus = []
            changed()
        }
    }

    /// 快捷键 / 宠物环形菜单：空闲或短休息中 → 开始；专注中 → 暂停；暂停中 → 继续。休息画面在场时不响应。
    func toggleFocus() {
        guard !stage.isBusy else { return }
        switch session.phase {
        case .idle, .shortBreak, .longBreak: startFocus()
        case .focusing: pauseFocus()
        case .paused: resumeFocus()
        }
    }

    private func advanceSession(_ now: Date) {
        switch session.phase {
        case .focusing:
            if session.remaining(at: now) <= 0 { finishFocus(at: now) }
        case .shortBreak:
            if session.breakRemaining(at: now) <= 0 { finishBreak(completed: true) }
        case .longBreak:
            // 正常由休息画面结束；画面不在了（异常）就按时结束。
            if !stage.isBusy, session.breakRemaining(at: now) <= 0 { finishBreak(completed: true) }
        case .idle, .paused:
            break
        }
    }

    private func finishFocus(at now: Date) {
        let overdue = session.plannedEnd.map { now.timeIntervalSince($0) } ?? 0
        NotifyDND.shared.setSuppressed(false, token: Self.focusToken)
        let kind = session.complete(day: FocusDay.key(now), longEvery: FocusHealthSettings.longEvery)
        let extras = foldDeferred(now: now)
        let round = session.roundsToday

        if overdue > Self.staleFocus {
            NotifyCenter.shared.post(PetNotification(source: Self.source, level: .ambient,
                                                     title: L("focus.toast.staleDone"), icon: "checkmark.circle"))
            changed(now)
            return
        }

        switch kind {
        case .short:
            let minutes = FocusHealthSettings.shortBreakMinutes
            session.startBreak(.short, seconds: Double(minutes * 60), at: now)
            postFocusDone(round: round, breakMinutes: minutes, extras: extras)
        case .long:
            let minutes = FocusHealthSettings.longBreakMinutes
            session.startBreak(.long, seconds: Double(minutes * 60), at: now)
            let strength = FocusHealthSettings.strength
            if strength == .relaxed {
                // 轻松档不出休息画面：同短休息，宠物提醒 + 菜单栏倒计时。
                postFocusDone(round: round, breakMinutes: minutes, extras: extras)
            } else {
                var message = L("focus.focusDone.longMessage \(round)")
                if !extras.isEmpty { message += "\n" + L("focus.alsoLine \(extras)") }
                var request = BreakRequest(title: L("focus.rest.longTitle \(minutes)"), message: message,
                                           seconds: Double(minutes * 60), style: Self.stageStyle(strength),
                                           lookAway: false)
                request.confirmIdentity = Self.confirmsIdentity(request.style)
                stage.present(request) { outcome in
                    FocusHealthController.shared.finishBreak(completed: outcome == .completed)
                }
            }
        }
        changed(now)
    }

    /// 专注完成的卡片：休息多久、顺延进来的事；[再来一轮][结束]。休息在菜单栏倒计时。
    private func postFocusDone(round: Int, breakMinutes: Int, extras: String) {
        var body = L("focus.focusDone.shortBody \(breakMinutes)")
        if !extras.isEmpty { body += "\n" + L("focus.alsoLine \(extras)") }
        NotifyCenter.shared.post(PetNotification(
            source: Self.source, level: .bubble, title: L("focus.focusDone.title \(round)"), body: body,
            actions: [.init(id: "next", label: L("focus.action.nextRound"), role: .primary),
                      .init(id: "end", label: L("focus.action.endCycle"), role: .destructive)],
            icon: "checkmark.circle"
        )) { action in
            let controller = FocusHealthController.shared
            switch action {
            case "next": controller.startFocus()
            case "end": controller.endCycle()
            default: break
            }
        }
    }

    /// 用户选的强度 → 休息画面的样子。轻松档平时不出休息画面（只发宠物提醒），
    /// 只有手动「现在休息」时用 gentle（不变暗、不拦截）。
    private static func stageStyle(_ strength: BreakStrength) -> BreakStageStyle {
        switch strength {
        case .relaxed: return .gentle
        case .standard: return .locked
        case .strict: return .lockedBlur
        }
    }

    /// 专注期间被顺延的提醒：算已提醒（重新计时），并把喝水这类不靠休息就能做的事列进休息文案。
    private func foldDeferred(now: Date) -> String {
        var names: [String] = []
        for id in deferredDuringFocus {
            guard let item = item(id) else { continue }
            if item.style == .bubble, !item.awayCounts { names.append(item.displayName) }
            ReminderScheduler.reset(id, runtime: &runtime, now: now)
        }
        deferredDuringFocus = []
        return names.sorted().joined(separator: L("focus.listSeparator"))
    }

    /// 专注后的休息结束（到点 / 休息画面结束）：问要不要开始下一轮，或者自动开始。
    func finishBreak(completed: Bool) {
        guard session.inBreak else { return }
        let now = Date()
        session.endBreak()
        if completed { ReminderScheduler.resetAwayItems(items, runtime: &runtime, now: now) }
        if FocusHealthSettings.autoNextRound {
            startFocus()
            return
        }
        NotifyCenter.shared.post(PetNotification(
            source: Self.source, level: .bubble, title: L("focus.breakDone.title"), body: L("focus.breakDone.body"),
            actions: [.init(id: "start", label: L("focus.action.startRound"), role: .primary),
                      .init(id: "end", label: L("focus.action.notNow"))],
            style: .sticky, icon: "cup.and.saucer.fill"
        )) { action in
            if action == "start" { FocusHealthController.shared.startFocus() }
        }
        changed(now)
    }

    /// 结束这一轮循环（短休息卡片的「结束」、菜单「结束休息」）：不再追问下一轮。
    func endCycle() {
        guard session.inBreak else { return }
        session.endBreak()
        if stage.isBusy { stage.end(.skipped) }
        changed()
    }

    // MARK: - 提醒分发（技术设计 §4）

    private func handle(_ events: [ReminderEvent], now: Date) {
        var due: [ReminderItem] = []
        var warns: [ReminderItem] = []
        for event in events {
            switch event {
            case .warn(let id):
                if let item = item(id) { warns.append(item) }
            case .due(let id):
                if let item = item(id) { due.append(item) }
            }
        }

        // 专注中、休息中、休息画面在场：顺延（专注期间的记下来，结束时并进休息）。
        if session.phase == .focusing || session.inBreak || stage.isBusy {
            for item in due {
                ReminderScheduler.markDeferred(item.id, runtime: &runtime, now: now)
                if session.phase == .focusing { deferredDuringFocus.insert(item.id) }
            }
            return
        }
        // 人不在就等人回来（不算顺延，不计入 45 分钟降级）。
        guard present else { return }
        if isAvoiding(now) {
            for item in due { ReminderScheduler.markDeferred(item.id, runtime: &runtime, now: now) }
            return
        }

        // 统一节拍：什么时候真的打扰、一次说几件事（REQUIREMENTS.md §7）。
        if !due.isEmpty, let plan = ReminderCoordinator.plan(
            due: due, items: items, runtime: runtime, now: now, lastPromptAt: lastPromptAt,
            minSpacing: TimeInterval(FocusHealthSettings.minSpacingMinutes * 60)
        ) {
            let members = plan.items.compactMap { item($0) }
            // 大的包含小的：级别更低的项这次算做过了。
            for id in plan.covered { ReminderScheduler.reset(id, runtime: &runtime, now: now) }
            if let primary = members.first {
                lastPromptAt = now
                let others = Array(members.dropFirst())
                switch primary.style {
                case .rest: fireRest(primary, alsoDue: others, now: now)
                case .bubble: fireBubbles(members, now: now)
                case .nudge: fireNudge(members, now: now)
                }
                return
            }
        }
        // 轻松档的休息提醒本身就是一个气泡，不再提前预告。
        if let warn = warns.first, FocusHealthSettings.strength != .relaxed { fireWarn(warn) }
    }

    /// 轻提醒（护眼这类）：宠物做个动作（护眼是搭手远眺），冒一个几秒后自己消失的小气泡，没有按钮；发出即算做过。
    private func fireNudge(_ due: [ReminderItem], now: Date) {
        guard let first = due.first else { return }
        for item in due { ReminderScheduler.reset(item.id, runtime: &runtime, now: now) }
        let title = due.count == 1 ? first.nudgeTitle : due.map(\.displayName).joined(separator: " · ")
        NotifyCenter.shared.post(PetNotification(source: Self.source, level: .ambient, title: title,
                                                 body: due.count == 1 ? first.nudgeBody : "", ttl: 6,
                                                 icon: first.icon))
        if let clips = due.compactMap(\.petClips).first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { _ = PetController.shared.act(clips: clips) }
            }
        }
        changed(now)
    }

    /// 避让（技术设计 §4 第 3 步）：自己挂的 focus / break 令牌不算。查全屏要遍历窗口列表，被挡住期间
    /// 每跳都会问到，所以「正在避让」缓存 5 秒；「没在避让」不缓存 —— 发提醒前一刻一定现查。
    private func isAvoiding(_ now: Date) -> Bool {
        if avoidanceCached, now.timeIntervalSince(avoidanceCheckedAt) < 5 { return true }
        avoidanceCheckedAt = now
        avoidanceCached = !NotifyDND.shared.reasons(ignoringTokens: [Self.focusToken, Self.breakToken]).isEmpty
        return avoidanceCached
    }

    /// 宠物提醒：同一跳到点的几项合成一张卡片；发出即重新计时，没点 = 错过。
    private func fireBubbles(_ due: [ReminderItem], now: Date) {
        guard let first = due.first else { return }
        for item in due { ReminderScheduler.reset(item.id, runtime: &runtime, now: now) }
        let ids = due.map(\.id)
        // 站立和喝水一起到点（统一节拍的默认）：合成一句「起来走走，喝口水」。
        let presets = Set(due.compactMap(\.preset))
        let standAndWater = due.count == 2 && presets == [ReminderPreset.stand, ReminderPreset.water]
        let title: String
        let body: String
        if standAndWater {
            title = L("focus.bubble.standWaterTitle")
            body = L("focus.bubble.standWaterBody")
        } else if due.count == 1 {
            title = first.bubbleTitle
            body = first.bubbleBody
        } else {
            title = due.map(\.displayName).joined(separator: " · ")
            body = ""
        }
        let sticky = due.contains { $0.schedule == .daily }
        NotifyCenter.shared.post(PetNotification(
            source: Self.source, level: .bubble, title: title, body: body,
            actions: [.init(id: "ok", label: L("focus.action.ok"), role: .primary),
                      .init(id: "snooze", label: L("focus.action.snooze10"))],
            style: sticky ? .sticky : .card, icon: first.icon
        )) { action in
            guard action == "snooze" else { return }
            FocusHealthController.shared.snooze(ids, seconds: Self.bubbleSnooze)
        }
        // 气泡出来时宠物先跳一下（约 0.9 秒），之后再做喝水 / 伸懒腰，免得被跳的动作打断。几项一起就一个接一个做。
        let clips = due.compactMap(\.petClips).flatMap { $0 }
        if !clips.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { _ = PetController.shared.act(clips: clips) }
            }
        }
        changed(now)
    }

    /// 休息画面预告：到点前 1 分钟（标准 / 严格档不能推迟，只能提前开始）。
    private func fireWarn(_ item: ReminderItem) {
        let id = item.id
        NotifyCenter.shared.post(PetNotification(
            source: Self.source, level: .bubble, title: L("focus.warn.title"),
            body: item.restTitle + " · " + FocusText.duration(item.restSeconds),
            actions: [.init(id: "now", label: L("focus.action.restNow"), role: .primary)],
            icon: item.icon
        )) { action in
            if action == "now" { FocusHealthController.shared.startRest(itemID: id) }
        }
    }

    /// 休息里顺带说的事（「顺便：喝口水、起来走走」）：小歇（护眼）不列，休息本来就包含它。
    private static func foldLines(_ items: [ReminderItem]) -> [String] {
        items.filter { $0.tier > 1 }.map(\.foldPhrase)
    }

    private func fireRest(_ item: ReminderItem, alsoDue: [ReminderItem], now: Date) {
        let relaxed = FocusHealthSettings.strength == .relaxed
        let deferredFor = runtime[item.id]?.deferredSince.map { now.timeIntervalSince($0) } ?? 0
        if !relaxed, deferredFor > Self.downgradeAfter {
            // 顺延太久（一直在开会 / 全屏）：不再突然盖屏，降级成宠物提醒。一起到点的事并进同一张卡片，不再另弹一张。
            ReminderScheduler.reset(item.id, runtime: &runtime, now: now)
            for other in alsoDue { ReminderScheduler.reset(other.id, runtime: &runtime, now: now) }
            var body = item.restTitle
            let extras = Self.foldLines(alsoDue)
            if !extras.isEmpty { body += "\n" + L("focus.alsoLine \(extras.joined(separator: L("focus.listSeparator")))") }
            let id = item.id
            NotifyCenter.shared.post(PetNotification(
                source: Self.source, level: .bubble, title: L("focus.downgrade.title"), body: body,
                actions: [.init(id: "ok", label: L("focus.action.ok"), role: .primary),
                          .init(id: "now", label: L("focus.action.restNow"))],
                icon: item.icon
            )) { action in
                if action == "now" { FocusHealthController.shared.startRest(itemID: id) }
            }
            changed(now)
            return
        }
        for other in alsoDue { ReminderScheduler.reset(other.id, runtime: &runtime, now: now) }
        if relaxed {
            postRestBubble(item, extras: Self.foldLines(alsoDue), now: now)
        } else {
            presentRest(item, extras: Self.foldLines(alsoDue))
        }
        changed(now)
    }

    /// 轻松档：休息提醒只是宠物气泡。[好的] = 去休息了（算一次完整休息）；[推迟 5 分钟] 受次数上限约束；
    /// 没点、气泡自己消失 = 错过（照常重新计时）。
    private func postRestBubble(_ item: ReminderItem, extras: [String], now: Date) {
        ReminderScheduler.rearm(item.id, runtime: &runtime, now: now)
        var body = item.restMessage
        if !extras.isEmpty {
            let line = L("focus.alsoLine \(extras.joined(separator: L("focus.listSeparator")))")
            body = body.isEmpty ? line : body + "\n" + line
        }
        var actions: [PetNotification.Action] = [.init(id: "ok", label: L("focus.action.ok"), role: .primary)]
        if canSnooze(item) { actions.append(.init(id: "snooze", label: L("focus.action.snooze5"))) }
        let id = item.id
        NotifyCenter.shared.post(PetNotification(
            source: Self.source, level: .bubble,
            title: item.restTitle + " · " + FocusText.duration(item.restSeconds), body: body,
            actions: actions, icon: item.icon
        )) { action in
            let controller = FocusHealthController.shared
            switch action {
            case "ok": controller.restEnded(itemID: id, outcome: .completed)
            case "snooze": controller.restEnded(itemID: id, outcome: .snoozed)
            default: break
            }
        }
        if let clips = item.restClips {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { _ = PetController.shared.act(clips: clips) }
            }
        }
    }

    private func presentRest(_ item: ReminderItem, extras: [String]) {
        guard !stage.isBusy else { return }
        var message = item.restMessage
        if !extras.isEmpty {
            let line = L("focus.alsoLine \(extras.joined(separator: L("focus.listSeparator")))")
            message = message.isEmpty ? line : message + "\n" + line
        }
        var request = BreakRequest(title: item.restTitle, message: message, seconds: TimeInterval(item.restSeconds),
                                   style: Self.stageStyle(FocusHealthSettings.strength),
                                   lookAway: item.preset == ReminderPreset.eye)
        request.confirmIdentity = Self.confirmsIdentity(request.style)
        let id = item.id
        stage.present(request) { outcome in
            FocusHealthController.shared.restEnded(itemID: id, outcome: outcome)
        }
    }

    private func restEnded(itemID: String, outcome: BreakOutcome) {
        let now = Date()
        switch outcome {
        case .completed:
            ReminderScheduler.resetAwayItems(items, runtime: &runtime, now: now)
            ReminderScheduler.reset(itemID, runtime: &runtime, now: now)
        case .skipped:
            ReminderScheduler.reset(itemID, runtime: &runtime, now: now)
        case .snoozed:
            ReminderScheduler.snooze(itemID, seconds: Self.restSnooze, runtime: &runtime, now: now)
        }
        changed(now)
    }

    private func canSnooze(_ item: ReminderItem) -> Bool {
        (runtime[item.id]?.snoozeCount ?? 0) < FocusHealthSettings.maxSnoozes
    }

    func snooze(_ ids: [String], seconds: TimeInterval) {
        let now = Date()
        for id in ids { ReminderScheduler.snooze(id, seconds: seconds, runtime: &runtime, now: now) }
        changed(now)
    }

    /// 预告 / 降级卡片上的「现在休息」。
    func startRest(itemID: String) {
        guard let item = item(itemID), !stage.isBusy, !session.inBreak, session.phase != .focusing else { return }
        presentRest(item, extras: [])
    }

    /// 菜单 / 快捷键「现在休息」：按「整段休息」项的时长（没有就 5 分钟）出画面，做完算一次完整休息。
    func breakNow() {
        guard !stage.isBusy, !session.inFocus, !session.inBreak else { return }
        let base = items.first { $0.preset == ReminderPreset.rest }
        var request = BreakRequest(title: L("focus.rest.title"), message: L("focus.rest.breakMessage"),
                                   seconds: TimeInterval(base?.restSeconds ?? 300),
                                   style: Self.stageStyle(FocusHealthSettings.strength), lookAway: false)
        request.confirmIdentity = Self.confirmsIdentity(request.style)
        stage.present(request) { outcome in
            guard outcome == .completed else { return }
            FocusHealthController.shared.manualBreakDone()
        }
    }

    /// 手动的一次完整休息做完：「离开算完成」的项都重新计时。
    private func manualBreakDone() {
        ReminderScheduler.resetAwayItems(items, runtime: &runtime, now: Date())
        changed()
    }

    /// 设置页「预览效果」：照当前强度演示一次，结果不计。轻松档发一个休息气泡；标准 / 严格档出 10 秒休息画面。
    func previewStage() {
        guard !stage.isBusy else { return }
        let strength = FocusHealthSettings.strength
        if strength == .relaxed {
            // 宠物关着时轻松档的提醒是系统通知（带同样的按钮），文案别再说「宠物冒个气泡」。
            NotifyCenter.shared.post(PetNotification(
                source: Self.source, level: .bubble, title: L("focus.preview.title"),
                body: PetController.shared.isReady ? L("focus.preview.bubbleMessage")
                                                   : L("focus.preview.notificationMessage"),
                actions: [.init(id: "ok", label: L("focus.action.ok"), role: .primary),
                          .init(id: "snooze", label: L("focus.action.snooze5"))],
                icon: "cup.and.saucer.fill"
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { _ = PetController.shared.act(clips: ["yawn"]) }
            }
            return
        }
        // 预览也走「结束前确认本人」，在设置里就能把整套流程试一遍。
        var request = BreakRequest(title: L("focus.preview.title"), message: L("focus.preview.message"),
                                   seconds: 10, style: Self.stageStyle(strength), lookAway: false)
        request.confirmIdentity = Self.confirmsIdentity(request.style)
        stage.present(request) { _ in }
    }

    /// 休息画面结束前要不要确认本人：设置开着，且是拦截键鼠的画面（标准 / 严格档）。
    private static func confirmsIdentity(_ style: BreakStageStyle) -> Bool {
        FocusHealthSettings.confirmIdentity && style != .gentle
    }

    // MARK: - 暂停提醒

    func remindersActive(at now: Date) -> Bool {
        guard FocusHealthSettings.remindersEnabled else { return false }
        if let until = pausedUntil, until > now { return false }
        if let day = offDay, day == FocusDay.key(now) { return false }
        return true
    }

    /// 总开关开着、但被「暂停提醒」停住了。
    var remindersPaused: Bool {
        FocusHealthSettings.remindersEnabled && !remindersActive(at: Date())
    }

    func pauseReminders(for seconds: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(seconds)
        offDay = nil
        changed()
    }

    func pauseRemindersForToday() {
        offDay = FocusDay.key(Date())
        changed()
    }

    func resumeReminders() {
        pausedUntil = nil
        offDay = nil
        changed()
    }

    // MARK: - 提醒项（设置页）

    func item(_ id: String) -> ReminderItem? {
        items.first { $0.id == id }
    }

    func updateItem(_ item: ReminderItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        updated.normalize()
        let old = items[index]
        guard old != updated else { return }
        items[index] = updated
        // 计时方式变了（或重新打开）就从现在重新计时；只改名字等不影响进度。
        if old.schedule != updated.schedule || old.clock != updated.clock
            || old.intervalMinutes != updated.intervalMinutes || old.timeOfDay != updated.timeOfDay
            || (!old.enabled && updated.enabled) {
            runtime[item.id] = ReminderRuntime(anchor: Date())
        }
        itemsChanged()
    }

    /// 新建一条自定义提醒，返回 id（设置页据此展开编辑）。
    @discardableResult
    func addItem() -> String {
        let item = ReminderItem(name: L("focus.newItemName"), intervalMinutes: 30, clock: .active, style: .bubble)
        items.append(item)
        runtime[item.id] = ReminderRuntime(anchor: Date())
        itemsChanged()
        return item.id
    }

    func deleteItem(_ id: String) {
        items.removeAll { $0.id == id }
        runtime[id] = nil
        itemsChanged()
    }

    /// 补回被删掉的预置项（不动自建项与已有预置项的修改）。
    func restorePresets() {
        let now = Date()
        for preset in ReminderPreset.defaults() where !items.contains(where: { $0.id == preset.id }) {
            items.append(preset)
            runtime[preset.id] = ReminderRuntime(anchor: now)
        }
        itemsChanged()
    }

    private func itemsChanged() {
        store.saveItems(items)
        changed()
    }

    // MARK: - 菜单文案

    func statusLine(at now: Date = Date()) -> String {
        switch session.phase {
        case .focusing:
            return L("focus.status.focusing \(FocusText.countdown(session.remaining(at: now)))")
        case .paused:
            return L("focus.status.paused \(FocusText.countdown(session.remaining(at: now)))")
        case .shortBreak, .longBreak:
            return L("focus.status.break \(FocusText.countdown(session.breakRemaining(at: now)))")
        case .idle:
            break
        }
        if !FocusHealthSettings.remindersEnabled { return L("focus.status.remindersOff") }
        if let day = offDay, day == FocusDay.key(now) { return L("focus.status.offToday") }
        if let until = pausedUntil, until > now { return L("focus.status.pausedUntil \(FocusText.time(until))") }
        guard let next = nextReminder(at: now) else { return L("focus.status.noReminders") }
        if next.seconds < 60 { return L("focus.status.nextNow \(next.item.displayName)") }
        return L("focus.status.next \(next.item.displayName) \(FocusText.minutesLeft(next.seconds))")
    }

    func nextReminder(at now: Date) -> (item: ReminderItem, seconds: TimeInterval)? {
        let candidates = items.filter(\.enabled).map {
            (item: $0, seconds: ReminderScheduler.timeUntilDue($0, runtime[$0.id], now: now))
        }
        return candidates.min { $0.seconds < $1.seconds }
    }

    // MARK: - 状态栏与落盘

    private func updateStatusItem(_ now: Date) {
        switch session.phase {
        case .idle:
            statusItem.update(symbol: nil, text: nil)
        case .focusing:
            statusItem.update(symbol: "timer", text: FocusText.countdown(session.remaining(at: now)))
        case .paused:
            statusItem.update(symbol: "pause.circle", text: FocusText.countdown(session.remaining(at: now)))
        case .shortBreak, .longBreak:
            statusItem.update(symbol: "cup.and.saucer", text: FocusText.countdown(session.breakRemaining(at: now)))
        }
    }

    /// 有意义的变化：马上落盘、刷新菜单栏。
    private func changed(_ now: Date = Date()) {
        dirty = true
        saveNow(sync: false)
        updateStatusItem(now)
    }

    private func saveNow(sync: Bool) {
        var state = FocusHealthState()
        state.session = session
        state.runtime = runtime
        state.pausedUntil = pausedUntil
        state.offDay = offDay
        store.saveState(state, sync: sync)
        dirty = false
        lastSave = Date()
    }
}
