import AppKit
import os

private let detectorLog = Logger(subsystem: "com.baobox.app", category: "meeting.detect")

/// 会议检测（docs/meeting/REQUIREMENTS.md §2、TECH_DESIGN §5）：每 5 秒采样一次，满足任一条件就问要不要记录。
///
/// 1. 日历事件已开始（15 分钟内）、带会议链接、还没在记录 → 气泡 [加入并记录][开始记录][忽略]。会前提醒问过的那场不再问。
/// 2. 会议 App 在运行 + 麦克风被占用 ≥ 10 秒 + 不是 Baobox 自己在用 → 气泡 [开始记录][忽略][不再检测此 App]。
///    同一段占用只问一次（`MeetingDetectionMachine`）；正在进行的日历会议被「忽略」过就不问。
///
/// 「命中日历会议时自动开始记录」（默认关）开着时，上面两种碰到日历会议都不问、直接开始（绑这场），并说一声。
/// 麦克风占用读 `NotifyDND.shared.microphoneInUse`（后台刷新的缓存，每次采样顺手刷新一次）。询问都是 alert 级：
/// 会议软件全屏时勿扰是开着的，攒起来补发就没有按钮了。
@MainActor
final class MeetingDetector {
    static let shared = MeetingDetector()
    private init() {}

    private var machine = MeetingDetectionMachine()
    private var timer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingDetector.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let dnd = NotifyDND.shared
        // 刷新缓存（后台读 CoreAudio）；这一次用的是上一次读到的值，晚 5 秒无所谓（要持续 10 秒才问）。
        dnd.refreshMicrophoneState()
        let now = Date()
        let paused = MeetingReminder.shared.isPaused(at: now)
        checkCalendar(at: now, paused: paused)
        checkApps(at: now, paused: paused, microphoneInUse: dnd.microphoneInUse)
    }

    // MARK: - 规则 1：日历事件已开始

    private func checkCalendar(at now: Date, paused: Bool) {
        let calendar = MeetingCalendar.shared
        guard calendar.isActive, !paused, !MeetingSessionController.shared.isActive,
              AudioCaptureCoordinator.shared.current == nil else { return }
        let book = MeetingPromptBook.shared
        let started = MeetingSchedule.startedWithLink(calendar.events, at: now, prompted: { _ in false })
        for event in started where !book.isIgnored(event.occurrenceKey, now: now) {
            if MeetingSettings.autoStart {
                let key = MeetingPromptBook.autoStartKey(event)
                guard !book.wasPrompted(key, now: now) else { continue }
                book.markPrompted(key, event: event)
                book.markPrompted(event.occurrenceKey, event: event)
                autoStart(event)
                return
            }
            guard MeetingSettings.detectionEnabled, !book.wasPrompted(event.occurrenceKey, now: now) else { continue }
            book.markPrompted(event.occurrenceKey, event: event)
            askStarted(event)
            return
        }
    }

    private func askStarted(_ event: MeetingCalendarEvent) {
        let info = event.info
        var lines = [MeetingText.timeRange(info.start, info.end)]
        if !info.attendees.isEmpty {
            lines.append(MeetingText.attendeesPreview(info.attendees))
        }
        lines.append(L("meeting.detect.startedBody"))
        detectorLog.notice("calendar meeting started without recording")
        NotifyCenter.shared.post(PetNotification(
            source: MeetingSessionController.source,
            level: .alert,
            title: L("meeting.detect.startedTitle \(info.title)"),
            body: lines.joined(separator: "\n"),
            actions: [.init(id: "joinRecord", label: L("meeting.action.joinAndRecord"), role: .primary),
                      .init(id: "record", label: L("meeting.action.record")),
                      .init(id: "ignore", label: L("meeting.action.ignore"), role: .destructive)],
            dedupeKey: "started." + event.occurrenceKey,
            style: .sticky,
            icon: "calendar.badge.clock"
        )) { action in
            MeetingActions.handle(action, event: event)
        }
    }

    // MARK: - 规则 2：会议 App + 麦克风

    private func checkApps(at now: Date, paused: Bool, microphoneInUse: Bool) {
        let session = MeetingSessionController.shared
        let workspace = NSWorkspace.shared
        let ignored = Set(MeetingSettings.ignoredApps.keys)
        let running = workspace.runningApplications.compactMap(\.bundleIdentifier)
        let candidates = MeetingDetectionApps.candidates(running: running,
                                                         frontmost: workspace.frontmostApplication?.bundleIdentifier,
                                                         ignored: ignored)
        // Baobox 自己在用麦克风（会议记录、自由听译、听写、设备自检）或在录屏：分不清是谁在用，这一段算问过。
        let capturing = AudioCaptureCoordinator.shared.isBaoboxUsingMicrophone || session.isActive
            || NotifyDND.shared.hasToken("recording")
        let enabled = MeetingSettings.detectionEnabled || MeetingSettings.autoStart
        guard let bundleID = machine.step(now: now, micBusy: microphoneInUse && enabled, baoboxCapturing: capturing,
                                          candidates: candidates) else { return }
        // 暂停期间不问（这一段占用也就算问过了）。
        guard !paused else { return }
        let calendarEvent = MeetingCalendar.shared.bindingCandidate(at: now)
        if let calendarEvent, MeetingPromptBook.shared.isIgnored(calendarEvent.occurrenceKey, now: now) {
            return
        }
        if let calendarEvent, MeetingSettings.autoStart {
            let key = MeetingPromptBook.autoStartKey(calendarEvent)
            if !MeetingPromptBook.shared.wasPrompted(key, now: now) {
                MeetingPromptBook.shared.markPrompted(key, event: calendarEvent)
                autoStart(calendarEvent)
                return
            }
        }
        guard MeetingSettings.detectionEnabled else { return }
        let name = running.contains(bundleID)
            ? workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.localizedName
            : nil
        askApp(bundleID: bundleID, name: name ?? bundleID, event: calendarEvent)
    }

    private func askApp(bundleID: String, name: String, event: MeetingCalendarEvent?) {
        detectorLog.notice("meeting app with microphone: \(bundleID, privacy: .public)")
        let body = event.map { L("meeting.detect.appBodyEvent \($0.info.title)") } ?? L("meeting.detect.appBody")
        NotifyCenter.shared.post(PetNotification(
            source: MeetingSessionController.source,
            level: .alert,
            title: L("meeting.detect.appTitle \(name)"),
            body: body,
            actions: [.init(id: "record", label: L("meeting.action.record"), role: .primary),
                      .init(id: "ignore", label: L("meeting.action.ignore")),
                      .init(id: "never", label: L("meeting.action.neverApp"), role: .destructive)],
            dedupeKey: "app." + bundleID,
            style: .sticky,
            icon: "mic.fill"
        )) { action in
            switch action {
            case "record":
                MeetingSessionController.shared.start(type: .online, event: event?.info)
            case "ignore":
                // 问的是一场日历会议：这一场也不再问、不自动开始。
                if let event { MeetingPromptBook.shared.markIgnored(event) }
            case "never":
                MeetingDetector.shared.ignore(bundleID: bundleID, name: name)
            default:
                break
            }
        }
    }

    // MARK: - 自动开始、忽略名单

    private func autoStart(_ event: MeetingCalendarEvent) {
        detectorLog.notice("auto-starting a calendar meeting recording")
        NotifyCenter.shared.post(PetNotification(source: MeetingSessionController.source, level: .alert,
                                                 title: L("meeting.detect.autoStarted \(event.info.title)"),
                                                 style: .toast, icon: "record.circle"))
        MeetingSessionController.shared.start(type: .online, event: event.info)
    }

    /// 「不再检测此 App」/ 设置里移除。
    func ignore(bundleID: String, name: String) {
        var ignored = MeetingSettings.ignoredApps
        ignored[bundleID] = name
        MeetingSettings.ignoredApps = ignored
    }

    func unignore(bundleID: String) {
        var ignored = MeetingSettings.ignoredApps
        ignored[bundleID] = nil
        MeetingSettings.ignoredApps = ignored
    }
}
