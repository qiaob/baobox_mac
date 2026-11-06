import AppKit
import os

private let detectorLog = Logger(subsystem: "com.baobox.app", category: "meeting.detect")

/// 会议检测（docs/meeting/REQUIREMENTS.md §2、TECH_DESIGN §5 / §10）：满足任一条件就问要不要记录。
///
/// 1. 日历事件已开始（15 分钟内）、带会议链接、还没在记录 → 气泡 [加入并记录][开始记录][忽略]。会前提醒问过的那场不再问。
/// 2. 会议 App 正在开会 → 气泡 [开始记录][忽略][不再检测此 App]。「正在开会」= 它开会时才起的进程开着（钉钉的 Tblive，
///    静音也算），或按进程查出来是它在用麦克风（`MeetingMicrophoneProbe`）；浏览器在用麦克风、窗口标题又是会议网站
///    （Google Meet 等，`MeetingWebSites`）算这个网站在开会。每个 App / 网站一场只问一次（`MeetingDetectionMachine`）；
///    正在进行的日历会议被「忽略」过就不问。
///
/// 「命中日历会议时自动开始记录」（默认关）开着时，上面两种碰到日历会议都不问、直接开始（绑这场），并说一声。
///
/// 采样节奏（借鉴 Notion）：默认输入设备一被占用 / 松开、或会议进程刚起，马上采样（`MeetingMicListener`）；
/// 有人在用麦克风（及刚变过的 10 秒内）每秒采样，平时 5 秒。麦克风按进程查要读 CoreAudio，放到后台，读完马上判断。
/// 询问都是 alert 级：会议软件全屏时勿扰是开着的，攒起来补发就没有按钮了。
@MainActor
final class MeetingDetector {
    static let shared = MeetingDetector()
    private init() {}

    private var machine = MeetingDetectionMachine()
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var started = false
    /// 最近一次在后台读到的「谁在用麦克风」。
    private var microphoneUsage = MeetingMicrophoneUsage()
    private var microphoneRefreshing = false
    /// 采样进行中又要查（麦克风刚被占用）：这次读完马上再读一次 —— 进行中那次可能是占用之前读的。
    private var sampleAgain = false
    /// 浏览器这一轮用麦克风期间认出过的会议网站。
    private var webLatch = MeetingWebLatch()
    private var lastWebMeetings: Set<String> = []
    /// 上一次采样是否在避让（诊断日志只记变化）。
    private var lastHoldOff = false
    /// 麦克风刚变过 / 会议进程刚起：到这个时候之前每秒采样。
    private var fastUntil = Date.distantPast
    private var micListener: MeetingMicListener?
    private var launchObserver: NSObjectProtocol?

    private static let fastInterval: TimeInterval = 1
    private static let slowInterval: TimeInterval = 5
    /// 麦克风刚变过之后每秒采样多久（之后看还有没有人在用）。
    private static let fastWindow: TimeInterval = 10

    func start() {
        guard !started else { return }
        started = true
        schedule(Self.slowInterval)
        let listener = MeetingMicListener {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MeetingDetector.shared.microphoneChanged() }
            }
        }
        listener.start()
        micListener = listener
        // 钉钉开会起的 Tblive 一出来就查（入会就静音时它可能根本不用麦克风）。
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = app?.bundleIdentifier, MeetingDetectionApps.meetingProcesses[bundleID] != nil else { return }
            MainActor.assumeIsolated { MeetingDetector.shared.microphoneChanged() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        timerInterval = 0
        micListener?.stop()
        micListener = nil
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        started = false
    }

    /// 麦克风刚被占用 / 松开，或会议进程刚起：马上查，接下来一段时间每秒查。
    private func microphoneChanged() {
        guard started else { return }
        fastUntil = Date().addingTimeInterval(Self.fastWindow)
        schedule(Self.fastInterval)
        tick()
    }

    private func schedule(_ interval: TimeInterval) {
        guard interval != timerInterval || timer == nil else { return }
        timer?.invalidate()
        timerInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingDetector.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 有人在用麦克风、或麦克风刚变过，每秒采样；否则回到 5 秒。
    private func updatePace(now: Date) {
        let busy = !microphoneUsage.apps.isEmpty || microphoneUsage.unattributed || now < fastUntil
        schedule(busy ? Self.fastInterval : Self.slowInterval)
    }

    private func tick() {
        let now = Date()
        let paused = MeetingReminder.shared.isPaused(at: now)
        checkCalendar(at: now, paused: paused)
        checkApps(at: now, paused: paused)
    }

    /// 后台读一次谁在用麦克风，读完回主线程马上判断（`sampled`）。
    private func requestSample(frontmost: String?) {
        guard !microphoneRefreshing else {
            sampleAgain = true
            return
        }
        microphoneRefreshing = true
        DispatchQueue.global(qos: .utility).async {
            let usage = MeetingMicrophoneProbe.sample(frontmost: frontmost)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MeetingDetector.shared.sampled(usage) }
            }
        }
    }

    private func sampled(_ usage: MeetingMicrophoneUsage) {
        microphoneRefreshing = false
        if usage != microphoneUsage { Self.logUsage(usage) }
        microphoneUsage = usage
        let now = Date()
        updatePace(now: now)
        evaluateApps(at: now, paused: MeetingReminder.shared.isPaused(at: now))
        if sampleAgain {
            sampleAgain = false
            requestSample(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
    }

    /// 谁在用麦克风变了就记一笔：只记 bundle id、每个在录音的浏览器读到几个窗口标题、认出的会议网站，不记标题内容。
    /// 真机上「开了会却没问」时靠这条看卡在哪一步（没认出是谁在录 / 标题读不到 / 标题没认出来）。
    private static func logUsage(_ usage: MeetingMicrophoneUsage) {
        let apps = usage.apps.sorted().joined(separator: ",")
        let titles = usage.browserTitleCounts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let web = usage.sitesByBrowser.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.sorted().joined(separator: "+"))" }.joined(separator: ",")
        detectorLog.notice("""
            mic in use: [\(apps, privacy: .public)] unattributed=\(usage.unattributed, privacy: .public) \
            browser titles: [\(titles, privacy: .public)] web: [\(web, privacy: .public)]
            """)
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

    /// 有会议 App 或浏览器在跑就去后台采样，读完再判断；都没在跑就不读 CoreAudio，直接判断（让问过的记录按时过期）。
    private func checkApps(at now: Date, paused: Bool) {
        let workspace = NSWorkspace.shared
        let runningIDs = workspace.runningApplications.compactMap(\.bundleIdentifier)
        let enabled = MeetingSettings.detectionEnabled || MeetingSettings.autoStart
        if enabled, runningIDs.contains(where: { MeetingDetectionApps.isMeetingApp($0) || MeetingWebSites.browsers.contains($0) }) {
            requestSample(frontmost: workspace.frontmostApplication?.bundleIdentifier)
            return
        }
        microphoneUsage = MeetingMicrophoneUsage()
        updatePace(now: now)
        evaluateApps(at: now, paused: paused)
    }

    private func evaluateApps(at now: Date, paused: Bool) {
        let session = MeetingSessionController.shared
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications
        let runningIDs = running.compactMap(\.bundleIdentifier)
        let frontmost = workspace.frontmostApplication?.bundleIdentifier
        let enabled = MeetingSettings.detectionEnabled || MeetingSettings.autoStart
        // 浏览器这一轮录音里认出过的会议网站一直算（切了标签页、标题变了也算），松开麦克风才忘。
        let webMeetings = webLatch.update(recordingBrowsers: microphoneUsage.apps.intersection(MeetingWebSites.browsers),
                                          unattributed: microphoneUsage.unattributed,
                                          matches: microphoneUsage.sitesByBrowser)
        if webMeetings != lastWebMeetings {
            lastWebMeetings = webMeetings
            detectorLog.notice("web meetings: [\(webMeetings.sorted().joined(separator: ","), privacy: .public)]")
        }
        var signals: [String: MeetingSignal] = [:]
        if enabled {
            signals = MeetingDetectionApps.signals(runningBundleIDs: runningIDs,
                                                   microphoneApps: microphoneUsage.apps,
                                                   unattributedMicrophone: microphoneUsage.unattributed,
                                                   webMeetings: webMeetings,
                                                   frontmost: frontmost,
                                                   ignored: Set(MeetingSettings.ignoredApps.keys))
        }
        // Baobox 在记录会议：正在开的会算问过；在用麦克风做别的（听写、字幕、自检）或在录屏：先不问，结束后再问。
        let holdOff = AudioCaptureCoordinator.shared.current != nil || NotifyDND.shared.hasToken("recording")
        if holdOff != lastHoldOff {
            lastHoldOff = holdOff
            detectorLog.notice("hold off: \(holdOff, privacy: .public)")
        }
        guard let bundleID = machine.step(now: now, signals: signals, frontmost: frontmost,
                                          recordingMeeting: session.isActive, holdOff: holdOff) else { return }
        // 暂停期间不问（这一段占用也就算问过了）。
        guard !paused else {
            detectorLog.notice("meeting in \(bundleID, privacy: .public), not asked: reminders paused")
            return
        }
        let calendarEvent = MeetingCalendar.shared.bindingCandidate(at: now)
        if let calendarEvent, MeetingPromptBook.shared.isIgnored(calendarEvent.occurrenceKey, now: now) {
            detectorLog.notice("meeting in \(bundleID, privacy: .public), not asked: its calendar event was ignored")
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
