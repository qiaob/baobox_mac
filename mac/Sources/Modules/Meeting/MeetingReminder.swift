import AppKit

/// 问过 / 忽略过的日历事件（docs/meeting/TECH_DESIGN.md §5）：会前提醒、「已开始」检测、自动开始共用，存 UserDefaults
/// （App 重启后同一场也不再问）。过期时间 = 事件结束后一天。
@MainActor
final class MeetingPromptBook {
    static let shared = MeetingPromptBook()

    private var prompted: MeetingPromptLedger
    private var ignored: MeetingPromptLedger

    private init() {
        let defaults = UserDefaults.standard
        prompted = MeetingPromptLedger(storage: defaults.dictionary(forKey: MeetingSettings.promptedKey))
        ignored = MeetingPromptLedger(storage: defaults.dictionary(forKey: MeetingSettings.ignoredEventsKey))
        let now = Date()
        if prompted.prune(at: now) || ignored.prune(at: now) { save() }
    }

    func wasPrompted(_ key: String, now: Date = Date()) -> Bool {
        prompted.contains(key, at: now)
    }

    func markPrompted(_ key: String, event: MeetingCalendarEvent) {
        prompted.insert(key, until: Self.expiry(event))
        save()
    }

    /// 用户对这一场点了「忽略」：不再问、不自动开始，进行期间也不按 App 检测来问。
    func isIgnored(_ key: String, now: Date = Date()) -> Bool {
        ignored.contains(key, at: now)
    }

    func markIgnored(_ event: MeetingCalendarEvent) {
        ignored.insert(event.occurrenceKey, until: Self.expiry(event))
        prompted.insert(event.occurrenceKey, until: Self.expiry(event))
        save()
    }

    /// 「自动开始」的记账键（与提醒分开记：提醒过的那场照样可以自动开始）。
    static func autoStartKey(_ event: MeetingCalendarEvent) -> String {
        "auto|" + event.occurrenceKey
    }

    private static func expiry(_ event: MeetingCalendarEvent) -> Date {
        max(event.info.end, Date()).addingTimeInterval(86_400)
    }

    private func save() {
        let now = Date()
        prompted.prune(at: now)
        ignored.prune(at: now)
        let defaults = UserDefaults.standard
        defaults.set(prompted.storage, forKey: MeetingSettings.promptedKey)
        defaults.set(ignored.storage, forKey: MeetingSettings.ignoredEventsKey)
    }
}

/// 会前提醒（需求 §2）：每 15 秒看一眼日历缓存，到提前量（关 / 1 / 5 分钟，默认 1）发宠物常驻气泡：
/// 标题、时间、参会人前 3 位、「来自日历」、同系列未完成行动项；按钮 [加入并记录]（有链接，主按钮）或 [开始记录]、
/// [看简报]（有简报时）、[忽略]。同一场只提醒一次。也顺带刷新菜单栏的下一场倒计时。
///
/// 提醒是要赶时间的：用 alert 级发（勿扰时内核会把非 alert 的攒起来、补发时不带按钮 —— 等勿扰结束会议早开始了），
/// 与桌面宠物的设计一致（docs/desktop-pet/INTERACTION.md：会议提醒 = sticky）。不想被打扰就「暂停会议提醒」。
@MainActor
final class MeetingReminder: ObservableObject {
    static let shared = MeetingReminder()

    /// 暂停到这个时刻（菜单「暂停会议提醒」）；nil = 没暂停。
    @Published private(set) var pausedUntil: Date?

    private var timer: Timer?
    private var started = false

    private init() {
        pausedUntil = MeetingSettings.remindersPausedUntil.flatMap { $0 > Date() ? $0 : nil }
    }

    func start() {
        guard !started else { return }
        started = true
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingReminder.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 暂停

    /// 会议提醒（会前提醒与检测的询问、自动开始）暂停中。
    func isPaused(at now: Date = Date()) -> Bool {
        pausedUntil.map { $0 > now } ?? false
    }

    func pause(_ pause: MeetingSchedule.Pause) {
        let until = MeetingSchedule.pausedUntil(pause, from: Date())
        pausedUntil = until
        MeetingSettings.remindersPausedUntil = until
    }

    func resume() {
        pausedUntil = nil
        MeetingSettings.remindersPausedUntil = nil
    }

    // MARK: - 心跳

    func tick() {
        let now = Date()
        if let until = pausedUntil, until <= now {
            resume()
        }
        refreshCountdown(now)
        let calendar = MeetingCalendar.shared
        guard calendar.isActive, !isPaused(at: now) else { return }
        let book = MeetingPromptBook.shared
        let due = MeetingSchedule.reminderDue(calendar.events, at: now, leadMinutes: MeetingSettings.reminderLead,
                                              prompted: { book.wasPrompted($0, now: now) })
        let current = MeetingSessionController.shared.event
        for event in due {
            // 已经在记这一场（提前开始、自动绑上了）：不用再提醒。
            if let current, current.eventID == event.info.eventID, current.start == event.info.start {
                book.markPrompted(event.occurrenceKey, event: event)
                continue
            }
            post(event, now: now)
        }
    }

    /// 菜单栏的下一场倒计时（默认关）：开着、读着日历、接下来有会才显示。
    func refreshCountdown(_ now: Date = Date()) {
        var text: String?
        if MeetingSettings.menuBarCountdown, let next = MeetingCalendar.shared.next(at: now) {
            text = MeetingText.countdown(next, now: now)
        }
        MeetingSessionController.shared.setCountdown(text)
    }

    // MARK: - 气泡

    private func post(_ event: MeetingCalendarEvent, now: Date) {
        MeetingPromptBook.shared.markPrompted(event.occurrenceKey, event: event)
        let info = event.info
        let session = MeetingSessionController.shared
        let briefing = MeetingActions.briefing(for: event)

        var lines = [MeetingText.timeRange(info.start, info.end, now: now)]
        if !info.attendees.isEmpty {
            lines.append(MeetingText.attendeesPreview(info.attendees))
        }
        if let calendarTitle = info.calendarTitle, !calendarTitle.isEmpty {
            lines.append(L("meeting.reminder.fromCalendarNamed \(calendarTitle)"))
        } else {
            lines.append(L("meeting.reminder.fromCalendar"))
        }
        if !briefing.openItems.isEmpty {
            lines.append(L("meeting.reminder.openItems \(briefing.openItems.count)"))
        }

        var actions: [PetNotification.Action] = []
        if event.link != nil {
            // 已经在记录（上一场还没结束）：只入会，不另开记录。
            actions.append(session.isActive
                           ? .init(id: "join", label: L("meeting.action.join"), role: .primary)
                           : .init(id: "joinRecord", label: L("meeting.action.joinAndRecord"), role: .primary))
        } else if !session.isActive {
            actions.append(.init(id: "record", label: L("meeting.action.record"), role: .primary))
        }
        if !briefing.isEmpty {
            actions.append(.init(id: "brief", label: L("meeting.action.brief")))
        }
        actions.append(.init(id: "ignore", label: L("meeting.action.ignore"), role: .destructive))

        NotifyCenter.shared.post(PetNotification(
            source: MeetingSessionController.source,
            level: .alert,
            title: L("meeting.reminder.title \(info.title) \(MeetingText.relative(info.start, now: now))"),
            body: lines.joined(separator: "\n"),
            actions: actions,
            dedupeKey: "remind." + event.occurrenceKey,
            style: .sticky,
            icon: "calendar"
        )) { action in
            MeetingActions.handle(action, event: event)
        }
    }
}
