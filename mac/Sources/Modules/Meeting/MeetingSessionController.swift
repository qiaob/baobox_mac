import AppKit
import os

/// 一场会议记录的编排（docs/meeting/TECH_DESIGN.md §3）：组引擎配置交给 `LiveTranslateController`，
/// 记录中挂 `meeting` 勿扰、菜单栏录音指示、控制条、超时检查；暂停 / 标记 / 速记 / 字幕；结束 → 等最后一句 →
/// 写 meta.json → 后台整理纪要 → 解析行动项、更新会议库、宠物通知。所有状态只在主线程读写。
///
/// 第二段（日历、提醒、检测、会议库窗口）只经这里开始 / 结束会议，并读这里发布的状态。
@MainActor
final class MeetingSessionController: ObservableObject {
    static let shared = MeetingSessionController()
    private init() {}

    /// 通知来源、占用登记的 owner。
    static let source = "meeting"
    /// 记录中挂的勿扰令牌（宠物安静、非重要通知攒批、专注与健康的提醒顺延）。
    static let dndToken = "meeting"
    private static let log = Logger(subsystem: "com.baobox.app", category: "meeting")
    /// 超过日历预定结束时间这么久，宠物轻提示一次。
    private static let overtimeGrace: TimeInterval = 5 * 60

    enum Phase: Equatable {
        case idle
        /// 已交给引擎，在等它开起来（权限、识别器、音源）。
        case starting
        case recording
        case paused
        /// 在等最后一句定稿、收尾。
        case finishing
    }

    @Published private(set) var phase: Phase = .idle
    /// 本场的类型 / 绑定的日历事件 / 会议库里的 id / 标题 / 开始时间；空闲时为 nil / 空。
    @Published private(set) var type: MeetingType?
    @Published private(set) var event: MeetingEventInfo?
    @Published private(set) var meetingID: String?
    @Published private(set) var title = ""
    @Published private(set) var startedAt: Date?
    /// 字幕条（+ 译文）开着；与字幕条上的 ✕、实时翻译的开关同步。
    @Published private(set) var subtitlesOn = false
    /// 单独不录你的声音 / 对方的声音（控制条上点麦克风 / 喇叭图标）。只是 Baobox 不录，会议软件里照样听得到。
    @Published private(set) var microphoneMuted = false
    @Published private(set) var systemMuted = false
    /// 🔖 标记（`t` = 距开始的秒数）。
    @Published private(set) var marks: [MeetingHighlight] = []
    /// 速记全文。
    @Published private(set) var notes = ""
    /// 控制条的速记区展开着。
    @Published private(set) var notesExpanded = false
    /// 最近一场结束、留下了记录的会议（通知里的「打开」等）。
    @Published private(set) var lastMeetingID: String?
    /// 两路电平点（单独一个对象：每秒刷几次，不让观察会话状态的视图跟着重画）。
    let levels = MeetingLevelMeter()

    /// 开始到结束之间（含开始中、收尾中）。
    var isActive: Bool { phase != .idle }
    /// 记录中或暂停中（能标记、速记、开关字幕、暂停 / 继续）。
    var isRecording: Bool { phase == .recording || phase == .paused }

    /// 从开始到现在（暂停的时间也算：这是会议本身的时长）。
    func elapsed(at now: Date = Date()) -> TimeInterval {
        startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    /// 还在开始中就点了结束：开起来马上收尾。
    private var finishWhenStarted = false
    /// 本场的转录去向（引擎重启时沿用同一份）。
    private var destination: LiveTranslateTranscript.Destination?
    /// 定稿的句子（`onFinalLine`）：算重点那段说了什么。
    private var finalLines: [String: MeetingEngineLine] = [:]
    /// 已经记下内容（转录或速记）的会议：结束时一句都没有的作废。
    private var contentIDs: Set<String> = []
    /// 本场的转录收尾了（`.finished` 到过）。
    private var transcriptFinished = false
    private var overtimeNotified = false
    private var timer: Timer?
    private var tickCount = 0
    private let controlBar = MeetingControlBarController()
    private let statusItem = MeetingStatusItem()

    // MARK: - 开始

    /// 开始记录。`event`：绑定的日历事件（标题 / 参会人 / 结束时间都从它来）；nil = 手动开始 —— 线上会议这时
    /// 自动绑正在进行（或 5 分钟内开始）的日历事件（需求 §1），线下会议不绑。
    /// `.free` = 自由听译（就是实时翻译）。正在记录时再开只提示一句。第一次用先弹合规说明，确认后才开。
    func start(type: MeetingType, event: MeetingEventInfo? = nil) {
        guard phase == .idle else {
            postToast(L("meeting.toast.alreadyRecording"))
            return
        }
        if type == .free {
            startFreeListening()
            return
        }
        let event = event ?? (type == .online ? MeetingCalendar.shared.bindingCandidate()?.info : nil)
        // 自由听译 / 听写正占着麦克风（设备端识别一次只能跑一个）：先说清楚，不弹合规说明。
        if let busy = AudioCaptureCoordinator.shared.busyMessage() {
            postToast(busy)
            return
        }
        guard MeetingSettings.consentAcknowledged || askConsent() else { return }
        // 对话框期间可能已经别处开了一场 / 占了麦克风。
        guard phase == .idle else { return }
        if let busy = AudioCaptureCoordinator.shared.busyMessage() {
            postToast(busy)
            return
        }
        begin(type: type, event: event)
    }

    /// 手动开始时的默认类型（设置里选）。
    func startDefault(event: MeetingEventInfo? = nil) {
        start(type: MeetingSettings.defaultType, event: event)
    }

    /// 「开始自由听译」：空闲时开实时翻译；会议记录中 = 打开 / 收起字幕（不另开一个会话）。
    func startFreeListening() {
        if isRecording {
            setSubtitles(!subtitlesOn)
            return
        }
        guard phase == .idle else { return }
        LiveTranslateController.shared.toggle()
    }

    /// 合规说明：告知参会人是用户自己的事，这里只提醒、不代为通知（需求 §3）。确认一次后不再问；返回是否确认。
    ///
    /// 用模态对话框、不走通知：这是点了「开始」之后必须先回答的一步。宠物关着时通知会退成系统横幅，
    /// 按钮藏在「选项」里、一闪就没，看起来就像点了没反应（2026-11-06 真机）。
    private func askConsent() -> Bool {
        let previous = NSWorkspace.shared.frontmostApplication
        // LSUIElement 应用不先激活，对话框会排在别的 App 窗口后面，主线程却已进了模态循环（见 CaffeinateController）。
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("meeting.consent.title")
        alert.informativeText = L("meeting.consent.body")
        alert.addButton(withTitle: L("meeting.consent.ack"))
        alert.addButton(withTitle: L("meeting.consent.cancel"))
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        // 焦点还给原来的 App（多半是会议软件）。
        if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !previous.isTerminated {
            previous.activate()
        }
        if confirmed { MeetingSettings.consentAcknowledged = true }
        return confirmed
    }

    private func begin(type: MeetingType, event: MeetingEventInfo?) {
        let now = Date()
        let eventTitle = event?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = eventTitle.isEmpty ? MeetingText.typeName(type) : eventTitle
        let style = MeetingSettings.template
        let record = MeetingStore.shared.createMeeting(
            type: type, title: title, start: now, event: event,
            template: LiveTranslateMinutesTemplate.meeting(style).storageValue)
        self.type = type
        self.event = event
        meetingID = record.id
        self.title = title
        startedAt = now
        subtitlesOn = false
        microphoneMuted = false
        systemMuted = false
        marks = []
        notes = ""
        notesExpanded = false
        finalLines = [:]
        transcriptFinished = false
        overtimeNotified = false
        finishWhenStarted = false
        destination = makeDestination(record: record, type: type, title: title, start: now, event: event, style: style)
        phase = .starting
        guard LiveTranslateController.shared.start(config: engineConfig()) else {
            // 麦克风被实时翻译 / 听写占着：引擎已经发了「正在 XX，先停止再开始」。
            Self.log.notice("meeting start refused: capture busy")
            MeetingStore.shared.discard(record.id)
            reset()
            return
        }
        Self.log.notice("meeting started: \(type.rawValue, privacy: .public)")
        NotifyDND.shared.setSuppressed(true, token: Self.dndToken)
        startTimer()
        controlBar.show()
        refreshIndicators()
    }

    /// 本场的转录：写到会议库这场会议的 meeting.md，带会议头信息；线上会议标说话人；总是整理纪要（会议模板），
    /// 纪要好了由这里发通知。
    private func makeDestination(record: MeetingRecord, type: MeetingType, title: String, start: Date,
                                 event: MeetingEventInfo?, style: LiveTranslateMeetingStyle)
        -> LiveTranslateTranscript.Destination {
        let store = MeetingStore.shared
        var destination = LiveTranslateTranscript.Destination(
            fileURL: store.markdownURL(for: record),
            displayName: (record.dir as NSString).lastPathComponent,
            header: LiveTranslateTranscript.Header(title: title, kind: MeetingText.typeName(type), start: start,
                                                   attendees: event?.attendees ?? [], calendar: event?.calendarTitle))
        destination.speakers = type == .online
        destination.template = .meeting(style)
        destination.summaryFollowsSetting = false
        destination.notifiesMinutes = false
        let id = record.id
        destination.onEvent = { event in
            MeetingSessionController.shared.transcriptEvent(event, meetingID: id)
        }
        return destination
    }

    /// 引擎配置：线上 = 麦克风 + 系统声音混一路，线下 = 仅麦克风；语言、纠错沿用「字幕与同传」设置；
    /// 默认只转录原文、不翻译、不出字幕条，「字幕」打开后叠加字幕条与译文（同实时翻译）。改设置引起的重启也按这里重组。
    private func engineConfig() -> LiveTranslateSessionConfig {
        let type = self.type ?? .offline
        var config = LiveTranslateSessionConfig(
            owner: Self.source,
            label: L("meeting.captureLabel"),
            sources: type == .online ? .mixed : .microphone,
            speech: SpeechSettings.speech,
            target: LiveTranslateSettings.target,
            translate: subtitlesOn && LiveTranslateSettings.translateEnabled,
            showsBar: subtitlesOn,
            correction: LiveTranslateSettings.aiCorrection ? .always : .off,
            transcript: destination)
        config.usesMixer = true
        config.onFinalLine = { line in
            MeetingSessionController.shared.finalLine(line)
        }
        config.onLifecycle = { lifecycle in
            MeetingSessionController.shared.engineLifecycle(lifecycle)
        }
        config.onUserRequest = { request in
            MeetingSessionController.shared.userRequest(request)
        }
        config.rebuild = {
            MeetingSessionController.shared.engineConfig()
        }
        return config
    }

    // MARK: - 会中

    func pause() {
        guard phase == .recording else { return }
        phase = .paused
        LiveTranslateController.shared.setPaused(true)
        refreshIndicators()
        controlBar.refreshSize()
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .recording
        LiveTranslateController.shared.setPaused(false)
        refreshIndicators()
        controlBar.refreshSize()
    }

    func togglePause() {
        if phase == .paused { resume() } else { pause() }
    }

    /// 🔖 标记重点：记录里记一行；整理纪要时这一刻前 20 秒、后 5 秒开始的句子加「【重点】」。
    func mark() {
        guard isRecording, let startedAt else { return }
        let now = Date()
        let current = LiveTranslateController.shared.lines.last?.original ?? ""
        marks.append(MeetingHighlight(t: now.timeIntervalSince(startedAt), text: String(current.prefix(200))))
        LiveTranslateController.shared.addTranscriptMark(at: now)
        controlBar.refreshSize()
    }

    /// 速记（整份替换）：写进记录的「速记」一节，会后并入纪要的上下文。
    func setNotes(_ text: String) {
        guard isActive, text != notes else { return }
        notes = text
        LiveTranslateController.shared.setTranscriptNotes(text)
    }

    /// 展开 / 收起控制条的速记区（展开时控制条能接收键盘输入，收起后交还焦点）。
    func toggleNotes() {
        guard isActive else { return }
        notesExpanded.toggle()
        controlBar.setNotesExpanded(notesExpanded)
        controlBar.refreshSize()
    }

    /// 字幕开关：打开 = 字幕条 + 译文（语言、朗读等沿用「字幕与同传」设置）。
    func setSubtitles(_ on: Bool) {
        guard isActive, phase != .finishing, subtitlesOn != on else { return }
        subtitlesOn = on
        // 开始中引擎还没跑起来：开起来时按 subtitlesOn 同步（见 engineLifecycle）。
        LiveTranslateController.shared.setBarVisible(on, translate: LiveTranslateSettings.translateEnabled)
        controlBar.refreshSize()
    }

    func toggleSubtitles() {
        setSubtitles(!subtitlesOn)
    }

    /// 点麦克风图标：不录 / 恢复录你的声音（对方的照录）。
    func toggleMicrophoneMuted() {
        guard isActive, phase != .finishing else { return }
        microphoneMuted.toggle()
        LiveTranslateController.shared.setLaneMuted(microphoneMuted, lane: LiveTranslateMixerCore.microphoneLane)
    }

    /// 点喇叭图标：不录 / 恢复录对方的声音（你的照录）。只有线上会议有这一路。
    func toggleSystemMuted() {
        guard isActive, phase != .finishing, type == .online else { return }
        systemMuted.toggle()
        LiveTranslateController.shared.setLaneMuted(systemMuted, lane: LiveTranslateMixerCore.systemLane)
    }

    // MARK: - 结束

    /// 结束并生成纪要：等最后一句定稿（最多 1.5 秒）→ 写 meta.json → 后台整理纪要 → 宠物通知。
    func finish() {
        switch phase {
        case .recording, .paused:
            phase = .finishing
            refreshIndicators()
            controlBar.refreshSize()
            Task { await LiveTranslateController.shared.finish() }
        case .starting:
            finishWhenStarted = true
        case .idle, .finishing:
            break
        }
    }

    /// App 退出：转录同步写完（纪要标「没整理完」），会议库写盘也等它做完。
    func terminate() {
        if phase == .starting, let id = meetingID, !contentIDs.contains(id) {
            // 还没开起来就退出了：不留一条空会议。
            MeetingStore.shared.discard(id)
        } else if isActive {
            LiveTranslateController.shared.terminate()
        }
        MeetingStore.shared.flush()
    }

    // MARK: - 引擎回调

    private func engineLifecycle(_ lifecycle: LiveTranslateSessionConfig.Lifecycle) {
        switch lifecycle {
        case .started:
            // 改设置引起的重启也会再报一次：记录中 / 暂停中的不动。
            guard phase == .starting else { return }
            phase = .recording
            Self.log.notice("meeting recording")
            if !notes.isEmpty {
                LiveTranslateController.shared.setTranscriptNotes(notes)
            }
            if subtitlesOn {
                LiveTranslateController.shared.setBarVisible(true, translate: LiveTranslateSettings.translateEnabled)
            }
            refreshIndicators()
            controlBar.refreshSize()
            if finishWhenStarted {
                finishWhenStarted = false
                finish()
            }
        case .ended:
            ended()
        }
    }

    /// 会话结束（结束按钮、识别出错停了、没开起来）：收起控制条与录音指示、撤勿扰。
    private func ended() {
        guard phase != .idle else { return }
        if let id = meetingID, !transcriptFinished {
            // 没开起来（权限被拒、识别不可用、音源打不开），什么也没记下：这一场作废。
            MeetingStore.shared.discard(id)
        }
        Self.log.notice("meeting ended")
        NotifyDND.shared.setSuppressed(false, token: Self.dndToken)
        stopTimer()
        controlBar.hide()
        statusItem.update(text: nil, paused: false)
        reset()
    }

    private func reset() {
        phase = .idle
        type = nil
        event = nil
        meetingID = nil
        title = ""
        startedAt = nil
        subtitlesOn = false
        microphoneMuted = false
        systemMuted = false
        marks = []
        notes = ""
        notesExpanded = false
        destination = nil
        finalLines = [:]
        finishWhenStarted = false
        levels.reset()
    }

    private func userRequest(_ request: LiveTranslateSessionConfig.UserRequest) {
        switch request {
        case .closeBar: setSubtitles(false)
        case .toggleRecording: togglePause()
        case .toggle: toggleSubtitles()
        }
    }

    private func finalLine(_ line: MeetingEngineLine) {
        finalLines[line.key] = line
    }

    /// 转录的进度（`meetingID` 是这份转录属于的那场 —— 纪要整理完时可能已经开了下一场）。
    private func transcriptEvent(_ event: LiveTranslateTranscript.Event, meetingID id: String) {
        let store = MeetingStore.shared
        switch event {
        case .created:
            contentIDs.insert(id)
        case .finished(let end, let minutes, let terminating):
            let current = id == meetingID
            if current { transcriptFinished = true }
            guard contentIDs.contains(id) else {
                // 一句都没记下：不留一条空会议。
                store.discard(id)
                if !terminating { postLater(toast: L("meeting.toast.nothingRecorded")) }
                return
            }
            let highlights = current ? resolvedHighlights() : nil
            store.update(id, sync: terminating) { meta in
                meta.end = end
                meta.status = MeetingStore.status(after: minutes)
                if let highlights { meta.highlights = highlights }
            }
            if current { lastMeetingID = id }
            if minutes != .generating {
                store.finishWriting(id)
                contentIDs.remove(id)
                if !terminating { postSaved(id, outcome: minutes) }
            }
        case .minutes(let outcome):
            var items: [MeetingActionItem]?
            if case .done(let text) = outcome {
                items = LiveTranslateMeetingMinutes.parseActionItems(text).map {
                    MeetingActionItem(text: $0.text, owner: $0.owner, due: $0.due, done: $0.done)
                }
            }
            store.update(id, sync: outcome == .interrupted) { meta in
                meta.status = MeetingStore.status(after: outcome)
                if let items { meta.actionItems = items }
            }
            store.finishWriting(id)
            contentIDs.remove(id)
            if outcome != .interrupted { postSaved(id, outcome: outcome) }
        }
    }

    /// 每个 🔖 那段说了什么：标记前 20 秒、后 5 秒开始的定稿句子连起来（最多 200 字）；没有就用标记时屏幕上那句。
    private func resolvedHighlights() -> [MeetingHighlight] {
        guard let startedAt else { return marks }
        let lines = finalLines.values.sorted { $0.time < $1.time }
        return marks.map { mark in
            let time = startedAt.addingTimeInterval(mark.t)
            let text = lines.filter { LiveTranslateMeetingMinutes.isHighlighted($0.time, marks: [time]) }
                .map(\.original).joined(separator: " ")
            return MeetingHighlight(t: mark.t, text: text.isEmpty ? mark.text : String(text.prefix(200)))
        }
    }

    // MARK: - 通知

    /// 纪要好了 / 没整理成 / 只存了转录：宠物通知，[打开] 打开这场的记录。
    private func postSaved(_ id: String, outcome: LiveTranslateTranscript.MinutesOutcome) {
        guard let record = MeetingStore.shared.record(id) else { return }
        let title: String
        switch outcome {
        case .done: title = L("meeting.notify.minutesReady")
        case .failed: title = L("meeting.notify.minutesFailed")
        case .generating, .interrupted: return
        case .off, .noModel, .tooShort: title = L("meeting.notify.transcriptOnly")
        }
        var body = record.meta.title
        if let duration = record.meta.duration {
            body += " · " + MeetingText.duration(duration)
        }
        if outcome == .noModel {
            body += "\n" + L("meeting.notify.noModelHint")
        }
        var summarized = false
        if case .done = outcome { summarized = true }
        let notification = PetNotification(
            source: Self.source, level: .bubble, title: title, body: body,
            actions: [.init(id: "open", label: L("meeting.notify.open"), role: .primary)],
            dedupeKey: "saved.\(id)", icon: summarized ? "doc.text" : "waveform")
        // 结束时转录收尾在撤勿扰之前：晚一拍再发，免得被会议自己的勿扰攒起来。
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NotifyCenter.shared.post(notification) { action in
                    guard action == "open" else { return }
                    MeetingWindowController.shared.showLibrary(select: id)
                }
            }
        }
    }

    private func postLater(toast text: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                MeetingSessionController.shared.postToast(text)
            }
        }
    }

    /// 一行轻提示。记录中挂着会议自己的勿扰，普通提示会被攒起来，所以用 alert 级、toast 样式（宠物不会出声）。
    private func postToast(_ text: String) {
        NotifyCenter.shared.post(PetNotification(source: Self.source, level: .alert, title: text, style: .toast,
                                                 icon: "waveform"))
    }

    // MARK: - 心跳（电平、录音指示、超时）

    private func startTimer() {
        stopTimer()
        tickCount = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingSessionController.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        tickCount += 1
        if let input = LiveTranslateController.shared.takeInputLevels() {
            levels.update(input, paused: phase == .paused)
        }
        guard tickCount % 4 == 0 else { return }
        refreshIndicators()
        checkOvertime()
    }

    /// 菜单栏的下一场倒计时（MeetingReminder 每 15 秒给一次；nil = 不显示）。记录中录音指示优先。
    func setCountdown(_ text: String?) {
        statusItem.menuItems = { MeetingMenu.items(includeSettings: true) }
        statusItem.setCountdown(text)
    }

    /// 菜单栏「● 32:15」。
    private func refreshIndicators() {
        switch phase {
        case .recording, .paused, .finishing:
            statusItem.menuItems = { MeetingMenu.items(includeSettings: true) }
            statusItem.update(text: MeetingText.clock(elapsed()), paused: phase == .paused)
        case .starting:
            statusItem.menuItems = { MeetingMenu.items(includeSettings: true) }
            statusItem.update(text: "…", paused: false)
        case .idle:
            statusItem.update(text: nil, paused: false)
        }
    }

    /// 绑了日历事件：超过预定结束时间 5 分钟，轻提示一次。
    private func checkOvertime() {
        guard isRecording, !overtimeNotified, let end = event?.end,
              Date().timeIntervalSince(end) > Self.overtimeGrace else { return }
        overtimeNotified = true
        postToast(L("meeting.toast.overtime"))
    }

    // MARK: - 菜单状态行

    /// 「● 记录中 32:15 · 线上会议」「正在开始记录…」；空闲时「下一场：设计评审 · 25 分钟后」（读着日历、接下来有会时）。
    func statusLine() -> String {
        let kind = type.map(MeetingText.typeName) ?? ""
        switch phase {
        case .starting: return L("meeting.statusLine.starting")
        case .recording: return L("meeting.statusLine.recording \(MeetingText.clock(elapsed())) \(kind)")
        case .paused: return L("meeting.statusLine.paused \(MeetingText.clock(elapsed())) \(kind)")
        case .finishing: return L("meeting.statusLine.finishing")
        case .idle:
            let engine = LiveTranslateController.shared
            if engine.isRunning, !engine.isHostedSession {
                return L("meeting.statusLine.freeListening")
            }
            let now = Date()
            if let next = MeetingCalendar.shared.next(at: now) {
                return L("meeting.statusLine.next \(next.info.title) \(MeetingText.relative(next.info.start, now: now))")
            }
            if let summarizing = MeetingStore.shared.records.first(where: { $0.meta.status == .summarizing }) {
                return L("meeting.statusLine.summarizing \(summarizing.meta.title)")
            }
            return L("meeting.statusLine.idle")
        }
    }
}

/// 控制条的两路电平点：有声音 = 亮，静音 / 暂停 = 灰。只在亮灭变了时发布。
@MainActor
final class MeetingLevelMeter: ObservableObject {
    /// nil = 没有这一路（线下会议没有系统声音）。
    @Published private(set) var microphoneActive: Bool?
    @Published private(set) var systemActive: Bool?

    /// 比判「有人在说话」的阈值低一点：小声说话、远一点的麦克风也亮。
    private static let threshold: Float = 0.006

    func update(_ levels: MeetingInputLevels, paused: Bool) {
        let microphone = levels.microphone.map { !paused && $0 > Self.threshold }
        let system = levels.system.map { !paused && $0 > Self.threshold }
        if microphone != microphoneActive { microphoneActive = microphone }
        if system != systemActive { systemActive = system }
    }

    func reset() {
        microphoneActive = nil
        systemActive = nil
    }
}
