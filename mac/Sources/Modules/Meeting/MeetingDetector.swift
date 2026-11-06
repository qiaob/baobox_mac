import AppKit
import os

private let detectorLog = Logger(subsystem: "com.baobox.app", category: "meeting.detect")

/// 会议检测（docs/meeting/REQUIREMENTS.md §2、TECH_DESIGN §5）：每 5 秒采样一次，满足任一条件就问要不要记录。
///
/// 1. 日历事件已开始（15 分钟内）、带会议链接、还没在记录 → 气泡 [加入并记录][开始记录][忽略]。会前提醒问过的那场不再问。
/// 2. 会议 App 正在开会 → 气泡 [开始记录][忽略][不再检测此 App]。「正在开会」= 它开会时才起的进程开着（钉钉的 Tblive，
///    静音也算），或按进程查出来是它在用麦克风（`MeetingMicrophoneProbe`）；浏览器在用麦克风、窗口标题又是会议网站
///    （Google Meet 等，`MeetingWebSites`）算这个网站在开会。每个 App / 网站一场只问一次（`MeetingDetectionMachine`）；
///    正在进行的日历会议被「忽略」过就不问。
///
/// 「命中日历会议时自动开始记录」（默认关）开着时，上面两种碰到日历会议都不问、直接开始（绑这场），并说一声。
/// 麦克风按进程查要读 CoreAudio，放到后台，每次采样用上一次读到的结果（晚 5 秒无所谓）。询问都是 alert 级：
/// 会议软件全屏时勿扰是开着的，攒起来补发就没有按钮了。
@MainActor
final class MeetingDetector {
    static let shared = MeetingDetector()
    private init() {}

    private var machine = MeetingDetectionMachine()
    private var timer: Timer?
    private var started = false
    /// 上一次在后台读到的「谁在用麦克风」。
    private var microphoneUsage = MeetingMicrophoneUsage()
    private var microphoneRefreshing = false

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
        let now = Date()
        let paused = MeetingReminder.shared.isPaused(at: now)
        checkCalendar(at: now, paused: paused)
        checkApps(at: now, paused: paused)
    }

    /// 后台读一次谁在用麦克风，结果回主线程缓存（下一次采样用）。
    private func refreshMicrophoneUsage(frontmost: String?) {
        guard !microphoneRefreshing else { return }
        microphoneRefreshing = true
        DispatchQueue.global(qos: .utility).async {
            let usage = MeetingMicrophoneProbe.sample(frontmost: frontmost)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let detector = MeetingDetector.shared
                    detector.microphoneUsage = usage
                    detector.microphoneRefreshing = false
                }
            }
        }
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

    private func checkApps(at now: Date, paused: Bool) {
        let session = MeetingSessionController.shared
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications
        let runningIDs = running.compactMap(\.bundleIdentifier)
        let frontmost = workspace.frontmostApplication?.bundleIdentifier
        let enabled = MeetingSettings.detectionEnabled || MeetingSettings.autoStart
        var signals: [String: MeetingSignal] = [:]
        if enabled {
            // 没有会议 App、也没有浏览器在跑就不去读 CoreAudio。
            if runningIDs.contains(where: { MeetingDetectionApps.isMeetingApp($0) || MeetingWebSites.browsers.contains($0) }) {
                refreshMicrophoneUsage(frontmost: frontmost)
            } else {
                microphoneUsage = MeetingMicrophoneUsage()
            }
            signals = MeetingDetectionApps.signals(runningBundleIDs: runningIDs,
                                                   microphoneApps: microphoneUsage.apps,
                                                   unattributedMicrophone: microphoneUsage.unattributed,
                                                   webMeetings: microphoneUsage.webMeetings,
                                                   frontmost: frontmost,
                                                   ignored: Set(MeetingSettings.ignoredApps.keys))
        }
        // Baobox 在记录会议：正在开的会算问过；在用麦克风做别的（听写、字幕、自检）或在录屏：先不问，结束后再问。
        let holdOff = AudioCaptureCoordinator.shared.current != nil || NotifyDND.shared.hasToken("recording")
        guard let bundleID = machine.step(now: now, signals: signals, frontmost: frontmost,
                                          recordingMeeting: session.isActive, holdOff: holdOff) else { return }
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
        let name = Self.webSiteName(bundleID)
            ?? running.first(where: { $0.bundleIdentifier == bundleID })?.localizedName
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

    /// 浏览器里的会议网站（`MeetingWebSites` 的 key）的显示名；不是网站返回 nil。
    static func webSiteName(_ key: String) -> String? {
        switch key {
        case MeetingWebSites.meet: return L("meeting.web.meet")
        case MeetingWebSites.teams: return L("meeting.web.teams")
        case MeetingWebSites.zoom: return L("meeting.web.zoom")
        case MeetingWebSites.tencent: return L("meeting.web.tencent")
        case MeetingWebSites.feishu: return L("meeting.web.feishu")
        case MeetingWebSites.webex: return L("meeting.web.webex")
        case MeetingWebSites.jitsi: return L("meeting.web.jitsi")
        default: return nil
        }
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
