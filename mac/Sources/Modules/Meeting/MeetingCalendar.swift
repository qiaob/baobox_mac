import AppKit
import EventKit
import os

private let calendarLog = Logger(subsystem: "com.baobox.app", category: "meeting.calendar")

/// 设置里列出来的一个日历。
struct MeetingCalendarInfo: Identifiable, Equatable {
    /// `EKCalendar.calendarIdentifier`。
    let id: String
    let title: String
    /// 账户（iCloud、Google、Exchange…）。
    let source: String
    /// sRGB 颜色分量（0…1）。
    let red: Double
    let green: Double
    let blue: Double
}

/// 读本机日历（docs/meeting/TECH_DESIGN.md §5）：EventKit，只读、数据不出本机。
///
/// - 用户在设置里打开「读取日历」时才申请权限（macOS 14 `requestFullAccessToEvents`），启动时不弹。
/// - 后台串行队列查未来 24 小时（含正在进行）的事件，主线程发布缓存 `events`：菜单、提醒、检测只读它，菜单构建零磁盘 IO。
/// - `.EKEventStoreChanged`（日历同步了、改了）+ 每 60 秒 + 唤醒后各刷新一次。
@MainActor
final class MeetingCalendar: ObservableObject {
    static let shared = MeetingCalendar()

    enum Access: Equatable {
        case notDetermined
        case granted
        case denied
        case restricted
        /// 只给了「仅添加事件」：读不到。
        case writeOnly
    }

    @Published private(set) var access: Access
    /// 本机所有事件日历（按账户、名字排）；没授权时为空。
    @Published private(set) var calendars: [MeetingCalendarInfo] = []
    /// 选中的日历里未来 24 小时内、或正在进行的事件（不含全天、已取消、我已拒绝的），按开始时间。
    @Published private(set) var events: [MeetingCalendarEvent] = []
    @Published private(set) var isRequesting = false

    private let backend = MeetingCalendarBackend()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var fetching = false
    private var fetchAgain = false
    private var changeScheduled = false

    private init() {
        access = Self.currentAccess()
    }

    /// 打开了「读取日历」且有完整读取权限。
    var isActive: Bool { MeetingSettings.calendarEnabled && access == .granted }

    // MARK: - 生命周期

    func start() {
        guard !started else { return }
        started = true
        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil,
                                                                queue: .main) { _ in
            MainActor.assumeIsolated { MeetingCalendar.shared.storeChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                           object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MeetingCalendar.shared.refresh() }
        })
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingCalendar.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    // MARK: - 设置

    /// 设置里打开了「读取日历」：还没问过权限就申请（系统弹框），否则直接刷新。
    func enable() {
        access = Self.currentAccess()
        if access == .notDetermined {
            requestAccess()
        } else {
            refresh()
        }
    }

    /// 关掉「读取日历」：清掉缓存（提醒、检测、下一场都跟着没了）。
    func disable() {
        if !events.isEmpty { events = [] }
        MeetingReminder.shared.refreshCountdown()
    }

    func requestAccess() {
        guard !isRequesting else { return }
        isRequesting = true
        backend.requestAccess { granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let calendar = MeetingCalendar.shared
                    calendar.isRequesting = false
                    calendar.access = Self.currentAccess()
                    calendarLog.notice("calendar access \(granted ? "granted" : "not granted", privacy: .public)")
                    calendar.refresh()
                }
            }
        }
    }

    /// 读不读某个日历（存「不读」的，新加的日历默认也读）。
    func setCalendar(_ id: String, included: Bool) {
        var excluded = MeetingSettings.excludedCalendars
        if included { excluded.remove(id) } else { excluded.insert(id) }
        MeetingSettings.excludedCalendars = excluded
        refresh()
    }

    func isIncluded(_ id: String) -> Bool {
        !MeetingSettings.excludedCalendars.contains(id)
    }

    // MARK: - 刷新

    func refresh() {
        let current = Self.currentAccess()
        if current != access { access = current }
        guard MeetingSettings.calendarEnabled, access == .granted else {
            if !events.isEmpty { events = [] }
            if access != .granted, !calendars.isEmpty { calendars = [] }
            return
        }
        guard !fetching else {
            fetchAgain = true
            return
        }
        fetching = true
        backend.fetch(excluded: MeetingSettings.excludedCalendars, now: Date()) { calendars, events in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MeetingCalendar.shared.fetched(calendars: calendars, events: events)
                }
            }
        }
    }

    private func fetched(calendars: [MeetingCalendarInfo], events: [MeetingCalendarEvent]) {
        fetching = false
        if calendars != self.calendars { self.calendars = calendars }
        // 刷新期间关掉了日历：不发布。
        let fresh = MeetingSettings.calendarEnabled ? events : []
        if fresh != self.events { self.events = fresh }
        MeetingReminder.shared.refreshCountdown()
        if fetchAgain {
            fetchAgain = false
            refresh()
        }
    }

    /// 日历同步时会连着来好几条：攒 1 秒再刷新。
    private func storeChanged() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                MeetingCalendar.shared.changeScheduled = false
                MeetingCalendar.shared.refresh()
            }
        }
    }

    // MARK: - 查（只读内存）

    func next(at now: Date = Date()) -> MeetingCalendarEvent? {
        isActive ? MeetingSchedule.next(events, at: now) : nil
    }

    func bindingCandidate(at now: Date = Date()) -> MeetingCalendarEvent? {
        isActive ? MeetingSchedule.bindingCandidate(events, at: now) : nil
    }

    func event(occurrenceKey: String) -> MeetingCalendarEvent? {
        events.first { $0.occurrenceKey == occurrenceKey }
    }

    static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// 系统设置 › 隐私与安全性 › 日历。
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// EventKit 的同步调用都在这条串行队列上（`events(matching:)` 是同步的，可能要一会儿）。
/// @unchecked Sendable 依据：唯一的可变状态 `store` 只在 `queue` 上读写。
final class MeetingCalendarBackend: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.baobox.app.meeting.calendar", qos: .utility)
    private var store: EKEventStore?

    /// 往后看这么久。
    private static let horizon: TimeInterval = 24 * 3600
    /// 往前看这么久（正在进行的长会议）。
    private static let lookBack: TimeInterval = 6 * 3600

    private func currentStore() -> EKEventStore {
        if let store { return store }
        let created = EKEventStore()
        store = created
        return created
    }

    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            self.currentStore().requestFullAccessToEvents { granted, error in
                if let error {
                    calendarLog.error("calendar access request failed: \(error.localizedDescription, privacy: .public)")
                }
                self.queue.async {
                    // 授权前建的 store 读不到日历：换一个新的。
                    self.store = nil
                    completion(granted)
                }
            }
        }
    }

    func fetch(excluded: Set<String>, now: Date,
               completion: @escaping @Sendable ([MeetingCalendarInfo], [MeetingCalendarEvent]) -> Void) {
        queue.async {
            let store = self.currentStore()
            let all: [EKCalendar] = store.calendars(for: .event)
            let infos = Self.sorted(all.map(Self.info))
            let selected = all.filter { !excluded.contains($0.calendarIdentifier) }
            var events: [MeetingCalendarEvent] = []
            if !selected.isEmpty {
                let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-Self.lookBack),
                                                         end: now.addingTimeInterval(Self.horizon),
                                                         calendars: selected)
                let found: [EKEvent] = store.events(matching: predicate)
                events = found.compactMap { Self.event(from: $0, now: now) }
                events.sort { $0.info.start < $1.info.start }
            }
            completion(infos, events)
        }
    }

    /// 按账户、再按名字排。
    private static func sorted(_ infos: [MeetingCalendarInfo]) -> [MeetingCalendarInfo] {
        infos.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return lhs.source.localizedStandardCompare(rhs.source) == .orderedAscending
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func info(_ calendar: EKCalendar) -> MeetingCalendarInfo {
        var red = 0.5
        var green = 0.5
        var blue = 0.5
        if let cgColor = calendar.cgColor, let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) {
            red = Double(color.redComponent)
            green = Double(color.greenComponent)
            blue = Double(color.blueComponent)
        }
        return MeetingCalendarInfo(id: calendar.calendarIdentifier, title: calendar.title,
                                   source: calendar.source?.title ?? "", red: red, green: green, blue: blue)
    }

    /// EKEvent → 一场会议。全天事件（节假日、生日）、已取消的、我已拒绝的、已经结束的不要。
    private static func event(from event: EKEvent, now: Date) -> MeetingCalendarEvent? {
        guard !event.isAllDay, event.status != .canceled,
              let start = event.startDate, let end = event.endDate, end > now else { return nil }
        let participants = event.attendees ?? []
        if participants.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) {
            return nil
        }
        // 参会人：按日历里的顺序取名字，不含我自己、会议室与设备。
        var attendees: [String] = []
        for participant in participants
        where !participant.isCurrentUser && participant.participantType != .room && participant.participantType != .resource {
            let name = displayName(participant)
            if !name.isEmpty, !attendees.contains(name) { attendees.append(name) }
        }
        if attendees.isEmpty, let organizer = event.organizer, !organizer.isCurrentUser {
            let name = displayName(organizer)
            if !name.isEmpty { attendees.append(name) }
        }
        let rawTitle = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? L("meeting.calendar.untitled") : rawTitle
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = MeetingLinkParser.find(url: event.url?.absoluteString, location: location,
                                          notes: event.hasNotes ? event.notes : nil)
        // 重复事件（含改过单次的那一次）各次共用外部 id；非重复的按规范化标题。
        let recurringID: String? = event.hasRecurrenceRules || event.isDetached ? event.calendarItemExternalIdentifier : nil
        let info = MeetingEventInfo(title: title, start: start, end: end, attendees: attendees, url: link?.url,
                                    seriesKey: MeetingSeries.key(title: rawTitle, recurringID: recurringID),
                                    eventID: event.eventIdentifier, calendarTitle: event.calendar?.title)
        return MeetingCalendarEvent(info: info, link: link, calendarID: event.calendar?.calendarIdentifier ?? "",
                                    location: location?.isEmpty == false ? location : nil)
    }

    /// 名字；日历里没写名字时用邮箱 @ 前面那段。
    private static func displayName(_ participant: EKParticipant) -> String {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let raw = participant.url.absoluteString
        let address = raw.lowercased().hasPrefix("mailto:") ? String(raw.dropFirst(7)) : raw
        return address.split(separator: "@").first.map(String.init) ?? address
    }
}
