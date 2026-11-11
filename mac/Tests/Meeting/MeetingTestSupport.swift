import Foundation
import XCTest

// 会议测试的共用件（docs/meeting/ENGINE.md §5.3）：假引擎、假文档、假会议库、假 App 环境，一本按先后记副作用的账，
// 固定的中文文案（逐字取自 Localizable.xcstrings 的 zh-Hans，金样就是 App 在中文界面下写出来的样子），以及造时间、造句子的小工具。

// MARK: - 时间与句子

/// 2026-11-10 的某个本地时刻（用 `Calendar.current` 造：meeting.md 按本机时区排时刻，这样在哪个时区跑都是「10:00:02」）。
func localDate(_ hour: Int, _ minute: Int, _ second: Int, day: Int = 10,
               file: StaticString = #filePath, line: UInt = #line) -> Date {
    let components = DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second)
    guard let date = Calendar.current.date(from: components) else {
        XCTFail("造不出的时刻：\(components)", file: file, line: line)
        return .distantPast
    }
    return date
}

/// 一句定稿。
func engineLine(_ key: String, _ text: String, at time: Date, translation: String = "",
                speaker: MeetingSpeaker? = nil) -> MeetingEngineLine {
    MeetingEngineLine(key: key, time: time, original: text, translation: translation, speaker: speaker)
}

/// 线上会议开起来时引擎报的「这次怎么跑的」。
let onlineRun = MeetingEngineRun(source: "麦克风 + 系统声音", speech: "简体中文", target: nil)
/// 会中改了说话语言之后的。
let englishRun = MeetingEngineRun(source: "麦克风 + 系统声音", speech: "English", target: nil)

/// 探针（金样）里说的三句话。
enum Speech {
    static let one = "大家好，今天主要过一下 0.0.9 的发布计划，还有上周遗留的几个问题。"
    static let two = "好的，我先说一下进度：设置页改完了，会议纪要的模型选择也已经接上。"
    static let three = "那我们周五发布，张三负责整理发布说明，下周一再复盘一次。"
    /// 探针里本地模型「整理」出来的纪要。
    static let minutes = """
    ### 摘要
    回顾了上周进度，确定本周五发布。
    ### 决议
    - 周五发布 0.0.9
    ### 行动项
    - [ ] 张三：整理发布说明（截止：周五）
    ### 重点
    - 发布时间定在周五
    """
}

// MARK: - 固定文案

extension MeetingTranscriptModel.Labels {
    /// 中文界面下的文案（Localizable.xcstrings 的 zh-Hans，逐字）。
    static var zhHans: MeetingTranscriptModel.Labels { MeetingTranscriptModel.Labels(
        title: { "实时翻译记录 \($0)" },
        start: { "开始：\($0)" },
        end: { "结束：\($0)（\($1)）" },
        source: { "音源：\($0)" },
        languages: { "说：\($0) · 译成：\($1)" },
        noTranslation: "不翻译",
        kind: { "类型：\($0)" },
        attendees: { "参会人：\($0)" },
        listSeparator: "、",
        calendar: { "日历：\($0)" },
        minutes: "纪要",
        notes: "速记",
        transcript: "记录",
        meetingTranscript: "转录",
        changed: { "\($0) 改为：\($1) · \($2)" },
        mark: "标记重点",
        me: "我",
        them: "对方",
        paused: "暂停记录",
        resumed: "继续记录",
        microphoneMuted: "麦克风静音（不录你的声音）",
        microphoneUnmuted: "麦克风恢复",
        systemMuted: "系统声音静音（不录对方的声音）",
        systemUnmuted: "系统声音恢复",
        minutesLater: "停止后用本地 AI 整理（要点、结论、待办），写在这里。",
        minutesLaterMeeting: "会议结束后用本地 AI 整理（摘要、决议、行动项、重点），写在这里。",
        minutesGenerating: "正在用本地 AI 整理纪要…",
        minutesFailed: { "纪要没整理出来：\($0)" },
        minutesNoModel: "「会议纪要」用的模型还不能用，这次只保存了原文和译文。在 设置 › AI 里给它选一个能用的模型，以后的记录会自动整理纪要。",
        minutesTooShort: "内容太少，没有整理纪要。",
        minutesInterrupted: "纪要没整理完（Baobox 退出了）。",
        locale: Locale(identifier: "zh-Hans")) }
}

/// 中文界面下的会议类型名（`MeetingText.typeName`）。
func zhTypeName(_ type: MeetingType) -> String {
    switch type {
    case .online: return "线上会议"
    case .offline: return "线下会议"
    case .free: return "自由听译"
    }
}

// MARK: - 一本账

/// 会话测试里所有假对象共用的一本账：按发生顺序记下引擎、会议库、文档、环境收到的调用，用来断言副作用的先后
/// （docs/meeting/ENGINE.md §7.1 R16：「逐方法按原顺序调端口；测试断言调用序列」）。
@MainActor
final class MeetingCallLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }

    func clear() {
        entries = []
    }

    /// 只看以这些前缀开头的（如 `["engine.", "env."]`）。
    func entries(_ prefixes: String...) -> [String] {
        entries.filter { entry in prefixes.contains { entry.hasPrefix($0) } }
    }
}

// MARK: - 假引擎

/// 测试里扮演引擎。默认按 §4.3 的约定报事件：`start` 不同步报（I2），`end` 先报完句子再报 `.ended`（I4）。
@MainActor
final class FakeMeetingEngine: MeetingEngine {
    enum Call: Equatable {
        case setPaused(Bool)
        case setMuted(Bool, MeetingAudioLane)
        case setSubtitles(Bool)
        case showNotice(String)
        case finish
        case toggleFreeListening
        case terminate
    }

    var acceptsStart = true
    var currentText: String?
    var levels: MeetingInputLevels?
    var activity: MeetingEngineActivity = .idle
    /// `terminate()` 里要同步做的（真引擎：托管会话进行中时把剩下的句子和 `.ended` 报完，I5）。默认什么也不报。
    var onTerminate: ((FakeMeetingEngine) -> Void)?
    private(set) weak var host: MeetingEngineHost?
    /// 每次开始 / 重启时从托管方取到的配置。
    private(set) var starts: [MeetingEngineConfig] = []
    private(set) var calls: [Call] = []
    private(set) var levelReads = 0
    private let log: MeetingCallLog

    init(log: MeetingCallLog) {
        self.log = log
    }

    func start(host: MeetingEngineHost) -> Bool {
        log.record("engine.start")
        guard acceptsStart else { return false }
        self.host = host
        starts.append(host.engineConfig)
        return true
    }

    func setPaused(_ paused: Bool) { note(.setPaused(paused), "engine.setPaused(\(paused))") }
    func setMuted(_ muted: Bool, lane: MeetingAudioLane) { note(.setMuted(muted, lane), "engine.setMuted(\(muted), \(lane))") }
    func setSubtitles(_ visible: Bool) { note(.setSubtitles(visible), "engine.setSubtitles(\(visible))") }
    func showNotice(_ text: String) { note(.showNotice(text), "engine.showNotice") }
    func finish() { note(.finish, "engine.finish") }
    func toggleFreeListening() { note(.toggleFreeListening, "engine.toggleFreeListening") }

    func terminate() {
        note(.terminate, "engine.terminate")
        onTerminate?(self)
    }

    func takeInputLevels() -> MeetingInputLevels? {
        levelReads += 1
        return levels
    }

    private func note(_ call: Call, _ entry: String) {
        calls.append(call)
        log.record(entry)
    }

    // MARK: 测试里扮演引擎

    func report(_ event: MeetingEngineEvent) {
        host?.meetingEngine(didReport: event)
    }

    /// 改设置引起的重启（I9）：再取一次配置、带新的 run 再报一次 started。
    func restart(_ run: MeetingEngineRun) {
        guard let host else { return }
        starts.append(host.engineConfig)
        host.meetingEngine(didReport: .started(run))
    }

    /// 收尾（I4）：最后几句报完再报 ended。
    func end(lines: [MeetingEngineLine] = []) {
        lines.forEach { report(.line($0)) }
        report(.ended)
    }
}

// MARK: - 假文档

/// 一场会议的 meeting.md：记下每次调用，并把它们喂给一份真的 `MeetingTranscriptModel`（固定中文文案），
/// 断言能直接看文档长什么样。第一笔内容时报 `.created`；`finish` 里同步报 `.finished`（纪要结果可设，默认 `.generating`；
/// App 退出时同真文档一样是 `.interrupted`）；`completeMinutes` 再报 `.minutes`。
@MainActor
final class FakeMeetingTranscript: MeetingTranscriptWriting {
    enum Call: Equatable {
        case update(MeetingEngineLine)
        case mark(Date)
        case note(MeetingTranscriptNote, Date)
        case setNotes(String)
        case continueWith(MeetingEngineRun, Date)
        case finish(Date, terminating: Bool)
    }

    let spec: MeetingTranscriptSpec
    let start: Date
    let run: MeetingEngineRun
    var onEvent: ((MeetingTranscriptEvent) -> Void)?
    var onWriteError: ((String) -> Void)?
    /// `finish` 里同步报的纪要结果（不退出时）。
    var minutesOnFinish: MeetingMinutesOutcome = .generating
    private(set) var calls: [Call] = []
    private(set) var model: MeetingTranscriptModel
    private let log: MeetingCallLog

    init(spec: MeetingTranscriptSpec, start: Date, run: MeetingEngineRun, log: MeetingCallLog) {
        self.spec = spec
        self.start = start
        self.run = run
        self.log = log
        model = MeetingTranscriptModel(spec: spec, start: start, run: run, labels: .zhHans)
    }

    /// 这份文档此刻整份的样子。
    var markdown: String { model.render() }

    func update(_ line: MeetingEngineLine) {
        record(.update(line), "transcript.update(\(line.key))")
        let hadContent = model.hasContent
        guard model.update(line) else { return }
        if !hadContent { onEvent?(.created) }
    }

    func mark(at time: Date) {
        record(.mark(time), "transcript.mark")
        model.mark(at: time)
    }

    func note(_ note: MeetingTranscriptNote, at time: Date) {
        record(.note(note, time), "transcript.note(\(note))")
        model.note(note, at: time)
    }

    func setNotes(_ text: String) {
        record(.setNotes(text), "transcript.setNotes")
        let hadContent = model.hasContent
        guard model.setNotes(text) else { return }
        if !hadContent, model.hasContent { onEvent?(.created) }
    }

    func continueWith(_ run: MeetingEngineRun, at time: Date) {
        record(.continueWith(run, time), "transcript.continueWith")
        model.continueWith(run, at: time)
    }

    func finish(at time: Date, terminating: Bool) {
        record(.finish(time, terminating: terminating), "transcript.finish(terminating: \(terminating))")
        let outcome = terminating ? MeetingMinutesOutcome.interrupted : minutesOnFinish
        model.finish(at: time, summarizes: spec.summarizes, terminating: terminating, ready: true)
        onEvent?(.finished(end: time, minutes: outcome, terminating: terminating))
    }

    /// 纪要整理完 / 失败 / 没整理完（只在 `.finished` 报了 `.generating` 之后）。
    func completeMinutes(_ outcome: MeetingMinutesOutcome) {
        log.record("transcript.minutes")
        onEvent?(.minutes(outcome))
    }

    /// 写盘失败（真文档：回调一次，参数是给用户看的那行提示）。
    func failWrite(_ message: String) {
        onWriteError?(message)
    }

    private func record(_ call: Call, _ entry: String) {
        calls.append(call)
        log.record(entry)
    }
}

// MARK: - 假会议库

@MainActor
final class FakeMeetingLibrary: MeetingSessionLibrary {
    let rootURL = URL(fileURLWithPath: "/Meetings", isDirectory: true)
    /// 还在库里的（`discard` 了就没了）。
    private(set) var records: [String: MeetingRecord] = [:]
    private(set) var created: [MeetingRecord] = []
    private(set) var discarded: [String] = []
    private(set) var finishedWriting: [String] = []
    /// 每次 `update`：哪一条、要不要同步写。
    private(set) var updates: [(id: String, sync: Bool)] = []
    private(set) var flushes = 0
    /// 会话建过的文档（一场一份）。
    private(set) var transcripts: [FakeMeetingTranscript] = []
    /// 新建的文档 `finish` 时报的纪要结果。
    var minutesOnFinish: MeetingMinutesOutcome = .generating
    private let log: MeetingCallLog

    init(log: MeetingCallLog) {
        self.log = log
    }

    func createMeeting(type: MeetingType, title: String, start: Date, event: MeetingEventInfo?,
                       template: String) -> MeetingRecord {
        log.record("library.create")
        let meta = MeetingMeta(id: "M\(created.count + 1)", type: type, title: title, start: start,
                               attendees: event?.attendees ?? [], status: .recording, template: template)
        let dir = MeetingLibraryLayout.yearFolder(for: start) + "/" + MeetingLibraryLayout.folderName(start: start, title: title)
        let record = MeetingRecord(dir: dir, meta: meta)
        created.append(record)
        records[meta.id] = record
        return record
    }

    func markdownURL(for record: MeetingRecord) -> URL {
        rootURL.appendingPathComponent(record.dir, isDirectory: true)
            .appendingPathComponent(MeetingLibraryLayout.markdownFileName)
    }

    func record(_ id: String) -> MeetingRecord? {
        records[id]
    }

    func update(_ id: String, sync: Bool, _ change: (inout MeetingMeta) -> Void) {
        log.record("library.update(\(id), sync: \(sync))")
        updates.append((id, sync))
        guard var record = records[id] else { return }
        change(&record.meta)
        records[id] = record
    }

    func finishWriting(_ id: String) {
        log.record("library.finishWriting(\(id))")
        finishedWriting.append(id)
    }

    func discard(_ id: String) {
        log.record("library.discard(\(id))")
        discarded.append(id)
        records[id] = nil
    }

    func flush() {
        log.record("library.flush")
        flushes += 1
    }

    func makeTranscript(_ spec: MeetingTranscriptSpec, start: Date, run: MeetingEngineRun) -> MeetingTranscriptWriting {
        log.record("library.makeTranscript")
        let transcript = FakeMeetingTranscript(spec: spec, start: start, run: run, log: log)
        transcript.minutesOnFinish = minutesOnFinish
        transcripts.append(transcript)
        return transcript
    }
}

// MARK: - 假 App 环境

/// 合规默认已确认、麦克风没被占、时钟可拨；记下提示、勿扰、心跳、控制条、菜单栏刷新与通知。
@MainActor
final class FakeMeetingEnvironment: MeetingSessionEnvironment {
    var clock: Date
    /// 每次问「麦克风被占着吗」时给的答案（默认没占）。
    var busyMessage: () -> String? = { nil }
    /// 合规对话框的结果（默认已确认过）。
    var consent: () -> Bool = { true }
    var candidate: MeetingEventInfo?
    var defaultType: MeetingType = .online
    var minutesStyle: MeetingMinutesStyle = .standard
    let captureLabel = "会议记录"
    private(set) var toasts: [MeetingSessionToast] = []
    private(set) var doNotDisturb: [Bool] = []
    private(set) var heartbeat: [Bool] = []
    private(set) var controlBarChanges: [MeetingControlBarChange] = []
    private(set) var indicatorRefreshes = 0
    private(set) var consentRequests = 0
    private(set) var candidateRequests = 0
    private(set) var saved: [(record: MeetingRecord, outcome: MeetingMinutesOutcome)] = []
    private let log: MeetingCallLog

    init(log: MeetingCallLog, clock: Date) {
        self.log = log
        self.clock = clock
    }

    func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    func now() -> Date { clock }

    func captureBusyMessage() -> String? { busyMessage() }

    func confirmConsent() -> Bool {
        log.record("env.consent")
        consentRequests += 1
        return consent()
    }

    func calendarBindingCandidate() -> MeetingEventInfo? {
        candidateRequests += 1
        return candidate
    }

    func typeName(_ type: MeetingType) -> String { zhTypeName(type) }

    func setDoNotDisturb(_ on: Bool) {
        log.record("env.dnd(\(on))")
        doNotDisturb.append(on)
    }

    func setHeartbeat(_ running: Bool) {
        log.record("env.heartbeat(\(running))")
        heartbeat.append(running)
    }

    func controlBar(_ change: MeetingControlBarChange) {
        log.record("env.controlBar(\(change))")
        controlBarChanges.append(change)
    }

    func refreshIndicators() {
        log.record("env.indicators")
        indicatorRefreshes += 1
    }

    func toast(_ toast: MeetingSessionToast) {
        log.record("env.toast(\(toast))")
        toasts.append(toast)
    }

    func notifySaved(_ record: MeetingRecord, outcome: MeetingMinutesOutcome) {
        log.record("env.notifySaved(\(record.id))")
        saved.append((record, outcome))
    }
}

// MARK: - 一场会话

/// 一个会话和它的四个假邻居（时钟从 10:00:00 开始）。
@MainActor
struct MeetingSessionFixture {
    let session: MeetingSessionController
    let engine: FakeMeetingEngine
    let library: FakeMeetingLibrary
    let environment: FakeMeetingEnvironment
    let log: MeetingCallLog

    init(clock: Date? = nil) {
        let log = MeetingCallLog()
        let engine = FakeMeetingEngine(log: log)
        let library = FakeMeetingLibrary(log: log)
        let environment = FakeMeetingEnvironment(log: log, clock: clock ?? localDate(10, 0, 0))
        self.log = log
        self.engine = engine
        self.library = library
        self.environment = environment
        session = MeetingSessionController(engine: engine, library: library, environment: environment)
    }

    /// 本场的文档（第一次 `.started` 时建的那份）。
    var transcript: FakeMeetingTranscript? { library.transcripts.last }

    /// 开一场并让引擎开起来：返回会议库里的 id。
    @discardableResult
    func startRecording(_ type: MeetingType = .online, event: MeetingEventInfo? = nil, run: MeetingEngineRun = onlineRun,
                        file: StaticString = #filePath, line: UInt = #line) -> String {
        session.start(type: type, event: event)
        engine.report(.started(run))
        XCTAssertEqual(session.phase, .recording, file: file, line: line)
        return session.meetingID ?? ""
    }

    /// 过 `seconds` 秒后引擎报一句（时刻 = 那时的时钟）。
    func say(_ key: String, _ text: String, after seconds: TimeInterval = 1, speaker: MeetingSpeaker? = nil,
             translation: String = "") {
        environment.advance(seconds)
        engine.report(.line(engineLine(key, text, at: environment.clock, translation: translation, speaker: speaker)))
    }
}
