import Combine
import Foundation
import os

/// 一场会议记录的编排（docs/meeting/TECH_DESIGN.md §3）：经 `MeetingEngine` 协议驱动引擎（docs/meeting/ENGINE.md；
/// 实现是字幕与同传的适配器，装配在 `AppDelegate.meetingEngine`），记录中挂 `meeting` 勿扰、菜单栏录音指示、控制条、
/// 超时检查；暂停 / 标记 / 速记 / 字幕；结束 → 等最后一句 → 写 meta.json → 后台整理纪要 → 解析行动项、更新会议库、宠物通知。
/// 所有状态只在主线程读写。
///
/// 本场的 meeting.md 由这里驱动（docs/meeting/ENGINE.md §4.5.2）：引擎只报「开起来 / 一句 / 结束」，第一次开起来时建文档，
/// 句子、暂停 / 继续、单路静音、🔖、速记直接写，改设置重启时续写，`.ended` 里收尾。
///
/// 这里只留决策（纯逻辑，docs/meeting/ENGINE.md §5.2）：会议库、文档、App 环境（勿扰、控制条、菜单栏、Timer、通知、合规对话框、
/// 日历、设置、文案）都经 `MeetingSessionPorts.swift` 的端口，App 里的实现装配在 `MeetingSessionController.shared`
/// （MeetingSessionShell.swift），测试里换成假的。
///
/// 第二段（日历、提醒、检测、会议库窗口）只经这里开始 / 结束会议，并读这里发布的状态。
@MainActor
final class MeetingSessionController: ObservableObject, MeetingEngineHost {
    /// 会议的引擎。会话只经它开始、暂停、结束；会议菜单、快捷键、退出收尾也经它（`MeetingSessionController.shared.engine`）。
    let engine: MeetingEngine
    private let library: MeetingSessionLibrary
    private let environment: MeetingSessionEnvironment

    init(engine: MeetingEngine, library: MeetingSessionLibrary, environment: MeetingSessionEnvironment) {
        self.engine = engine
        self.library = library
        self.environment = environment
    }

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
    /// 本场的文档写成什么样（开始时定好，第一次开起来时用它建文档）。
    private var spec: MeetingTranscriptSpec?
    /// 本场的 meeting.md：第一次 `.started` 时建，改设置重启时续写同一份，`.ended` 里收尾；引擎没开起来就始终没有。
    private var transcript: MeetingTranscriptWriting?
    /// App 正在退出：文档同步写完、纪要标「没整理完」。
    private var terminating = false
    /// 定稿的句子（引擎报来的 `.line`）：算重点那段说了什么；建文档时补写开起来之前就定稿的那几句。
    private var finalLines: [String: MeetingEngineLine] = [:]
    /// 已经记下内容（转录或速记）的会议：结束时一句都没有的作废。
    private var contentIDs: Set<String> = []
    /// 本场的转录收尾了（`.finished` 到过）。
    private var transcriptFinished = false
    private var overtimeNotified = false
    private var tickCount = 0

    // MARK: - 开始

    /// 开始记录。`event`：绑定的日历事件（标题 / 参会人 / 结束时间都从它来）；nil = 手动开始 —— 线上会议这时
    /// 自动绑正在进行（或 5 分钟内开始）的日历事件（需求 §1），线下会议不绑。
    /// `.free` = 自由听译（就是实时翻译）。正在记录时再开只提示一句。第一次用先弹合规说明，确认后才开。
    func start(type: MeetingType, event: MeetingEventInfo? = nil) {
        guard phase == .idle else {
            environment.toast(.alreadyRecording)
            return
        }
        if type == .free {
            startFreeListening()
            return
        }
        let event = event ?? (type == .online ? environment.calendarBindingCandidate() : nil)
        // 自由听译 / 听写正占着麦克风（设备端识别一次只能跑一个）：先说清楚，不弹合规说明。
        if let busy = environment.captureBusyMessage() {
            environment.toast(.busy(busy))
            return
        }
        // 合规说明：告知参会人是用户自己的事，这里只提醒、不代为通知（需求 §3）。确认一次后不再问。
        guard environment.confirmConsent() else { return }
        // 对话框期间可能已经别处开了一场 / 占了麦克风。
        guard phase == .idle else { return }
        if let busy = environment.captureBusyMessage() {
            environment.toast(.busy(busy))
            return
        }
        begin(type: type, event: event)
    }

    /// 手动开始时的默认类型（设置里选）。
    func startDefault(event: MeetingEventInfo? = nil) {
        start(type: environment.defaultType, event: event)
    }

    /// 「开始自由听译」：空闲时开实时翻译；会议记录中 = 打开 / 收起字幕（不另开一个会话）。
    func startFreeListening() {
        if isRecording {
            setSubtitles(!subtitlesOn)
            return
        }
        guard phase == .idle else { return }
        engine.toggleFreeListening()
    }

    private func begin(type: MeetingType, event: MeetingEventInfo?) {
        let now = environment.now()
        let eventTitle = event?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = eventTitle.isEmpty ? environment.typeName(type) : eventTitle
        let style = environment.minutesStyle
        let record = library.createMeeting(
            type: type, title: title, start: now, event: event,
            template: MeetingMinutesTemplate.meeting(style).storageValue)
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
        spec = makeSpec(record: record, type: type, title: title, start: now, event: event, style: style)
        phase = .starting
        guard engine.start(host: self) else {
            // 麦克风被实时翻译 / 听写占着：引擎已经发了「正在 XX，先停止再开始」。
            Self.log.notice("meeting start refused: capture busy")
            library.discard(record.id)
            reset()
            return
        }
        Self.log.notice("meeting started: \(type.rawValue, privacy: .public)")
        environment.setDoNotDisturb(true)
        tickCount = 0
        environment.setHeartbeat(true)
        environment.controlBar(.show)
        environment.refreshIndicators()
    }

    /// 本场的文档：写到会议库这场会议的 meeting.md，带会议头信息；线上会议标说话人；总是整理纪要（会议模板），
    /// 纪要好了由这里发通知。
    private func makeSpec(record: MeetingRecord, type: MeetingType, title: String, start: Date,
                          event: MeetingEventInfo?, style: MeetingMinutesStyle) -> MeetingTranscriptSpec {
        var spec = MeetingTranscriptSpec(
            fileURL: library.markdownURL(for: record),
            displayName: (record.dir as NSString).lastPathComponent,
            header: MeetingTranscriptSpec.Header(title: title, kind: environment.typeName(type), start: start,
                                                 attendees: event?.attendees ?? [], calendar: event?.calendarTitle))
        spec.speakers = type == .online
        spec.template = .meeting(style)
        spec.summarizes = true
        spec.notifiesMinutes = false
        return spec
    }

    /// 交给引擎的配置（`MeetingEngineHost`）：线上 = 麦克风 + 系统声音混一路，线下 = 仅麦克风；字幕默认关，「字幕」打开后
    /// 叠加字幕条与译文。说什么语言、译成什么、纠不纠错由引擎按「字幕与同传」的设置定（适配器，docs/meeting/ENGINE.md §4.4）。
    /// 改设置引起的重启也按这里重组。文档不交给引擎（会议自己写），只告诉它标不标说话人、字幕条上「打开本次记录」打开哪个文件。
    var engineConfig: MeetingEngineConfig {
        let type = self.type ?? .offline
        return MeetingEngineConfig(
            owner: Self.source,
            label: environment.captureLabel,
            capture: type == .online ? .microphoneAndSystem : .microphone,
            subtitles: subtitlesOn,
            speakers: spec?.speakers == true,
            // 引擎只在本场开始中 / 进行中取配置，这时 `spec` 总在；会议库根目录只是空闲时的兜底，用不到。
            documentURL: spec?.fileURL ?? library.rootURL)
    }

    // MARK: - 会中

    /// 暂停 / 继续：引擎停 / 恢复送音频（字幕条「记录」按钮跟着变），文档里记一行「暂停 / 继续」。
    func pause() {
        guard phase == .recording else { return }
        phase = .paused
        engine.setPaused(true)
        transcript?.note(.paused, at: environment.now())
        environment.refreshIndicators()
        environment.controlBar(.refreshSize)
    }

    func resume() {
        guard phase == .paused else { return }
        phase = .recording
        engine.setPaused(false)
        transcript?.note(.resumed, at: environment.now())
        environment.refreshIndicators()
        environment.controlBar(.refreshSize)
    }

    func togglePause() {
        if phase == .paused { resume() } else { pause() }
    }

    /// 🔖 标记重点：记录里记一行；整理纪要时这一刻前 20 秒、后 5 秒开始的句子加「【重点】」。
    func mark() {
        guard isRecording, let startedAt else { return }
        let now = environment.now()
        let current = engine.currentText ?? ""
        marks.append(MeetingHighlight(t: now.timeIntervalSince(startedAt), text: String(current.prefix(200))))
        transcript?.mark(at: now)
        environment.controlBar(.refreshSize)
    }

    /// 速记（整份替换）：写进记录的「速记」一节，会后并入纪要的上下文。开始中还没有文档：先存着，建文档时写进去。
    func setNotes(_ text: String) {
        guard isActive, text != notes else { return }
        notes = text
        transcript?.setNotes(text)
    }

    /// 展开 / 收起控制条的速记区（展开时控制条能接收键盘输入，收起后交还焦点）。
    func toggleNotes() {
        guard isActive else { return }
        notesExpanded.toggle()
        environment.controlBar(.notesExpanded(notesExpanded))
        environment.controlBar(.refreshSize)
    }

    /// 字幕开关：打开 = 字幕条 + 译文（语言、朗读等沿用「字幕与同传」设置）。
    func setSubtitles(_ on: Bool) {
        guard isActive, phase != .finishing, subtitlesOn != on else { return }
        subtitlesOn = on
        // 开始中引擎还没跑起来：开起来时按 subtitlesOn 同步（见 engineStarted）。
        engine.setSubtitles(on)
        environment.controlBar(.refreshSize)
    }

    func toggleSubtitles() {
        setSubtitles(!subtitlesOn)
    }

    /// 点麦克风图标：不录 / 恢复录你的声音（对方的照录），文档里记一行。开始中还没有文档，不记。
    func toggleMicrophoneMuted() {
        guard isActive, phase != .finishing else { return }
        microphoneMuted.toggle()
        engine.setMuted(microphoneMuted, lane: .microphone)
        transcript?.note(microphoneMuted ? .microphoneMuted : .microphoneUnmuted, at: environment.now())
    }

    /// 点喇叭图标：不录 / 恢复录对方的声音（你的照录），文档里记一行。只有线上会议有这一路。
    func toggleSystemMuted() {
        guard isActive, phase != .finishing, type == .online else { return }
        systemMuted.toggle()
        engine.setMuted(systemMuted, lane: .system)
        transcript?.note(systemMuted ? .systemMuted : .systemUnmuted, at: environment.now())
    }

    // MARK: - 结束

    /// 结束并生成纪要：等最后一句定稿（最多 1.5 秒）→ 写 meta.json → 后台整理纪要 → 宠物通知。
    func finish() {
        switch phase {
        case .recording, .paused:
            phase = .finishing
            environment.refreshIndicators()
            environment.controlBar(.refreshSize)
            engine.finish()
        case .starting:
            finishWhenStarted = true
        case .idle, .finishing:
            break
        }
    }

    /// App 退出：转录同步写完（纪要标「没整理完」），会议库写盘也等它做完。先置 `terminating` 再让引擎停：
    /// 引擎在 `terminate()` 返回前把剩下的句子和 `.ended` 同步报回来，`ended()` 里文档、meta 都同步写；
    /// 引擎没报 `.ended`（比如正因为改设置在重启、还没开起来）就自己收尾。
    func terminate() {
        terminating = true
        if phase == .starting, let id = meetingID, !contentIDs.contains(id) {
            // 还没开起来就退出了：不留一条空会议。
            library.discard(id)
        } else if isActive {
            engine.terminate()
            if isActive { ended() }
        }
        library.flush()
    }

    // MARK: - 引擎事件（MeetingEngineHost）

    /// 引擎报来的事件：主线程、按发生顺序；可能在这里调引擎方法的过程中同步到达（退出、字幕开关）。
    /// 这一场的句子都报完才报 `.ended`（docs/meeting/ENGINE.md §4.3）。
    func meetingEngine(didReport event: MeetingEngineEvent) {
        switch event {
        case .started(let run):
            engineStarted(run)
        case .line(let line):
            finalLine(line)
        case .ended:
            ended()
        case .userAction(let action):
            userAction(action)
        }
    }

    private func engineStarted(_ run: MeetingEngineRun) {
        guard phase == .starting else {
            // 改设置引起的重启也会再报一次：同一份文档接着写（设置真变了才记「改为：…」），记录中 / 暂停中的不动。
            transcript?.continueWith(run, at: environment.now())
            return
        }
        phase = .recording
        Self.log.notice("meeting recording")
        openTranscript(run)
        if subtitlesOn {
            engine.setSubtitles(true)
        }
        environment.refreshIndicators()
        environment.controlBar(.refreshSize)
        if finishWhenStarted {
            finishWhenStarted = false
            finish()
        }
    }

    /// 第一次开起来：建本场的 meeting.md（docs/meeting/ENGINE.md §4.5.2）。开起来之前就定稿的句子（音源还在开、先开的那一路
    /// 已经出了字）与开始中写的速记一并写进去 —— 以前文档在引擎问完权限时就建了，这些当场就记下。
    private func openTranscript(_ run: MeetingEngineRun) {
        guard transcript == nil, let spec, let id = meetingID else { return }
        let transcript = library.makeTranscript(spec, start: environment.now(), run: run)
        // 文档的进度（`id` 是这份文档属于的那场 —— 纪要整理完时可能已经开了下一场）。
        transcript.onEvent = { [weak self] event in
            self?.transcriptEvent(event, meetingID: id)
        }
        // 写盘失败：提示（文档给的那一行，已本地化）放进字幕条，同一条文案、只提示一次（字幕条收着就看不到 —— 同以前）。
        let engine = self.engine
        transcript.onWriteError = { message in
            engine.showNotice(message)
        }
        self.transcript = transcript
        for line in finalLines.values.sorted(by: { $0.time != $1.time ? $0.time < $1.time : $0.key < $1.key }) {
            transcript.update(line)
        }
        if !notes.isEmpty {
            transcript.setNotes(notes)
        }
    }

    /// 会话结束（结束按钮、识别出错停了、没开起来）。先收尾文档 —— 这时这场的句子已经全到了（含停止时没定稿、强制记下的
    /// 最后几句）—— 它同步报回的 `.finished` 写 meta 或作废；再撤勿扰、停心跳、收起控制条、复位、收起录音指示。
    /// 顺序不能反：先复位的话 `.finished` 就对不上这场，有内容的会被当成没开起来作废。
    private func ended() {
        guard phase != .idle else { return }
        if let transcript {
            self.transcript = nil
            transcript.finish(at: environment.now(), terminating: terminating)
        }
        if let id = meetingID, !transcriptFinished {
            // 没开起来（权限被拒、识别不可用、音源打不开），从没建过文档：这一场作废。
            library.discard(id)
        }
        Self.log.notice("meeting ended")
        environment.setDoNotDisturb(false)
        environment.setHeartbeat(false)
        environment.controlBar(.hide)
        reset()
        environment.refreshIndicators()
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
        spec = nil
        transcript = nil
        finalLines = [:]
        finishWhenStarted = false
        levels.reset()
    }

    /// 用户在引擎自己的界面上点的：字幕条 ✕ = 收起字幕（照常记录）；字幕条「记录」= 暂停 / 继续；
    /// 「开始自由听译」开关（会议中）= 打开 / 收起字幕。
    private func userAction(_ action: MeetingEngineUserAction) {
        switch action {
        case .subtitleBarClosed: setSubtitles(false)
        case .recordButtonPressed: togglePause()
        case .freeListeningTogglePressed: toggleSubtitles()
        }
    }

    /// 一句定稿（之后纠错 / 译文回来同一 `key` 再报，后到的覆盖先到的）：记下来算重点，写进文档。
    private func finalLine(_ line: MeetingEngineLine) {
        finalLines[line.key] = line
        transcript?.update(line)
    }

    /// 转录的进度（`meetingID` 是这份转录属于的那场 —— 纪要整理完时可能已经开了下一场）。事件来自会议自己的文档。
    private func transcriptEvent(_ event: MeetingTranscriptEvent, meetingID id: String) {
        switch event {
        case .created:
            contentIDs.insert(id)
        case .finished(let end, let minutes, let terminating):
            let current = id == meetingID
            if current { transcriptFinished = true }
            guard contentIDs.contains(id) else {
                // 一句都没记下：不留一条空会议。
                library.discard(id)
                if !terminating { environment.toast(.nothingRecorded) }
                return
            }
            let highlights = current ? resolvedHighlights() : nil
            library.update(id, sync: terminating) { meta in
                meta.end = end
                meta.status = MeetingStatus.after(minutes)
                if let highlights { meta.highlights = highlights }
            }
            if current { lastMeetingID = id }
            if minutes != .generating {
                library.finishWriting(id)
                contentIDs.remove(id)
                if !terminating { postSaved(id, outcome: minutes) }
            }
        case .minutes(let outcome):
            var items: [MeetingActionItem]?
            if case .done(let text) = outcome {
                items = MeetingMinutesFormat.parseActionItems(text).map {
                    MeetingActionItem(text: $0.text, owner: $0.owner, due: $0.due, done: $0.done)
                }
            }
            library.update(id, sync: outcome == .interrupted) { meta in
                meta.status = MeetingStatus.after(outcome)
                if let items { meta.actionItems = items }
            }
            library.finishWriting(id)
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
            let text = lines.filter { MeetingMinutesFormat.isHighlighted($0.time, marks: [time]) }
                .map(\.original).joined(separator: " ")
            return MeetingHighlight(t: mark.t, text: text.isEmpty ? mark.text : String(text.prefix(200)))
        }
    }

    /// 纪要好了 / 没整理成 / 只存了转录：宠物通知，[打开] 打开这场的记录（会议库里已经没有这一条就不发）。
    private func postSaved(_ id: String, outcome: MeetingMinutesOutcome) {
        guard let record = library.record(id) else { return }
        environment.notifySaved(record, outcome: outcome)
    }

    // MARK: - 心跳（电平、录音指示、超时）

    /// 外壳的 Timer 每 0.25 秒调一次（`setHeartbeat`）：电平点；每秒刷新菜单栏指示、查超时。
    func tick() {
        tickCount += 1
        if let input = engine.takeInputLevels() {
            levels.update(input, paused: phase == .paused)
        }
        guard tickCount % 4 == 0 else { return }
        environment.refreshIndicators()
        checkOvertime()
    }

    /// 绑了日历事件：超过预定结束时间 5 分钟，轻提示一次。
    private func checkOvertime() {
        guard isRecording, !overtimeNotified, let end = event?.end,
              environment.now().timeIntervalSince(end) > Self.overtimeGrace else { return }
        overtimeNotified = true
        environment.toast(.overtime)
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
