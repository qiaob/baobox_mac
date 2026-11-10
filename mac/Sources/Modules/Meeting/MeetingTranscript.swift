import AppKit
import Foundation

/// 一次实时翻译的本地记录（Markdown）：开头是时间、音源、语言，然后「纪要」（停止后由本地 AI 整理），
/// 最后逐句的时间 + 原文 + 译文。会议记录（`Destination.header`）另有标题与参会人、「速记」一节、每句的说话人与 🔖 标记。
///
/// 说完（定稿）的句子就记下；内存里留整份，有变化时至多 1 秒后整份重写一次（原子写），中途崩溃最多丢最后 1 秒。
/// 一句都没有就不建文件。改设置引起的重启接着写同一份，并记一行「改为：…」。
@MainActor
final class LiveTranslateTranscript {
    /// 会议的文件头；nil（实时翻译）= 原来的版式。
    struct Header: Equatable {
        var title: String
        /// 「线上会议」「线下会议」（已本地化）。
        var kind: String
        var start: Date
        var attendees: [String] = []
        /// 绑定的日历事件来自哪个日历。
        var calendar: String?
    }

    /// 记到哪、记成什么样（docs/meeting/TECH_DESIGN.md §2.3）。
    struct Destination {
        /// 记录文件（整份重写）。
        var fileURL: URL
        /// 「纪要已整理好」通知里提到的名字。
        var displayName: String
        var header: Header?
        /// 每句标说话人（线上会议）。
        var speakers = false
        var template: LiveTranslateMinutesTemplate = .content
        /// 停止后整理纪要跟着 `livetranslate.record.summary` 开关走（自由听译）；false = 总是整理（会议）。
        var summaryFollowsSetting = true
        /// 纪要整理好后发「实时翻译纪要已整理好」（自由听译原来的行为）；会议自己发。
        var notifiesMinutes = true
        /// 进度：记下第一句、收尾、纪要结果（会议库据此更新 meta.json 与索引）。
        var onEvent: ((Event) -> Void)?

        init(fileURL: URL, displayName: String, header: Header? = nil) {
            self.fileURL = fileURL
            self.displayName = displayName
            self.header = header
        }

        /// 实时翻译原来的去处：`livetranslate.record.folder` 下的「yyyy-MM-dd HH-mm-ss.md」。
        @MainActor
        static func legacy(start: Date) -> Destination {
            let fileName = LiveTranslateTranscript.fileName(for: start)
            return Destination(fileURL: LiveTranslateRecordSettings.folder.appendingPathComponent(fileName),
                               displayName: fileName)
        }

        var summaryEnabled: Bool {
            summaryFollowsSetting ? LiveTranslateRecordSettings.summary : true
        }
    }

    /// 纪要怎么样了（给会议库更新状态）。
    enum MinutesOutcome: Equatable {
        /// 没开纪要。
        case off
        case generating
        case done(String)
        case failed(String)
        case noModel
        case tooShort
        /// App 退出了，没整理完。
        case interrupted
    }

    enum Event {
        /// 记下了第一句（或第一笔速记）：文件马上就要建起来了。
        case created
        /// 停止：结束时间、纪要怎么处理；`terminating` = App 正在退出（调用方要同步写完）。
        case finished(end: Date, minutes: MinutesOutcome, terminating: Bool)
        /// 纪要整理完 / 失败 / 没整理完（只在 `.finished` 报了 `.generating` 之后）。
        case minutes(MinutesOutcome)
    }

    private enum Item {
        case line(time: Date, original: String, translation: String, speaker: MeetingSpeaker?)
        case change(time: Date, config: MeetingEngineRun)
        /// 🔖 标记重点（会议）。
        case mark(time: Date)
        /// 一行说明（会议的暂停 / 继续）。
        case note(time: Date, text: String)

        var time: Date {
            switch self {
            case .line(let time, _, _, _), .change(let time, _), .mark(let time), .note(let time, _): return time
            }
        }
    }

    private enum Minutes {
        /// 没开纪要：不写这一节。
        case off
        /// 还在记录：停止后整理。
        case later
        case generating
        case done(String)
        case failed(String)
        case noModel
        case tooShort
        /// App 退出了，没整理完。
        case interrupted

        var outcome: MinutesOutcome {
            switch self {
            case .off: return .off
            case .later, .generating: return .generating
            case .done(let text): return .done(text)
            case .failed(let message): return .failed(message)
            case .noModel: return .noModel
            case .tooShort: return .tooShort
            case .interrupted: return .interrupted
            }
        }
    }

    let fileURL: URL
    /// 写盘失败（没授权「文稿」、磁盘满…）时回调一次，字幕条提示。
    var onWriteError: ((String) -> Void)?

    private let start: Date
    private let config: MeetingEngineRun
    private let destination: Destination
    private var lastConfig: MeetingEngineRun
    private var end: Date?
    private var items: [Item] = []
    /// 句子键 → `items` 下标。
    private var lineIndex: [String: Int] = [:]
    /// 会议：🔖 标记的时刻、速记。
    private var marks: [Date] = []
    private var notes = ""
    private var minutes: Minutes
    private var minutesTask: Task<Void, Never>?
    private var writeScheduled = false
    private var writeErrorShown = false

    private static let ioQueue = DispatchQueue(label: "com.baobox.app.livetranslate.transcript", qos: .utility)

    /// 正在整理纪要的记录（会议的、自由听译的）：开始整理时登记、整理完注销。登记表和纪要任务都持有它们，
    /// 会话复位、开了下一场也照样写得回去；App 退出时 `abortAllMinutes()` 把它们全部标成「没整理完」。
    private static var summarizing: [LiveTranslateTranscript] = []

    /// App 退出：还在整理的纪要全部标成「没整理完」，md 与 meta.json 都同步写完（docs/meeting/ENGINE.md §4.5.5）。
    /// 在会议与自由听译都停下之后、`OfflineTranslator.shutdownAll()` 之前调。
    static func abortAllMinutes() {
        let pending = summarizing
        summarizing = []
        for transcript in pending {
            transcript.abortMinutesIfRunning()
        }
    }

    init(start: Date, config: MeetingEngineRun, destination: Destination) {
        self.start = start
        self.config = config
        self.destination = destination
        lastConfig = config
        minutes = destination.summaryEnabled ? .later : .off
        fileURL = destination.fileURL
    }

    /// 写到实时翻译原来的文件夹。
    convenience init(start: Date, config: MeetingEngineRun) {
        self.init(start: start, config: config, destination: .legacy(start: start))
    }

    /// 至少记下了一句（或会议记了速记）才有文件。
    var hasContent: Bool { !lineIndex.isEmpty || !notes.isEmpty }

    /// 记下 / 更新一句。`key` 在这份记录里唯一（重启后句子 id 会从头编，调用方带上第几次运行）。
    /// `speaker` 只在会议标说话人时写进记录。
    func update(key: String, time: Date, original: String, translation: String, speaker: MeetingSpeaker? = nil) {
        let hadContent = hasContent
        if let index = lineIndex[key] {
            if case .line(_, let oldOriginal, let oldTranslation, let oldSpeaker) = items[index],
               oldOriginal == original, oldTranslation == translation, oldSpeaker == speaker { return }
            items[index] = .line(time: time, original: original, translation: translation, speaker: speaker)
        } else {
            lineIndex[key] = items.count
            items.append(.line(time: time, original: original, translation: translation, speaker: speaker))
        }
        if !hadContent { destination.onEvent?(.created) }
        scheduleWrite()
    }

    /// 🔖 标记重点：记一行，整理纪要时这一刻前后的句子加「【重点】」（`LiveTranslateMeetingMinutes.isHighlighted`）。
    func mark(at time: Date) {
        marks.append(time)
        items.append(.mark(time: time))
        scheduleWrite()
    }

    /// 记一行说明（会议的暂停 / 继续）。
    func note(_ text: String, at time: Date) {
        items.append(.note(time: time, text: text))
        scheduleWrite()
    }

    /// 会议速记（整份替换）：写在「速记」一节，整理纪要时作为上下文。
    func setNotes(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != notes else { return }
        let hadContent = hasContent
        notes = trimmed
        if !hadContent, hasContent { destination.onEvent?(.created) }
        scheduleWrite()
    }

    /// 改设置后的重启接着写：设置确实变了就记一行「改为：…」。
    func continueWith(_ config: MeetingEngineRun, at time: Date) {
        guard config != lastConfig else { return }
        lastConfig = config
        items.append(.change(time: time, config: config))
        scheduleWrite()
    }

    /// 停止：记下结束时间、决定纪要怎么处理，写一次。`terminating` = App 正在退出：同步写，不整理纪要。
    func finish(at time: Date, terminating: Bool) {
        end = time
        if !destination.summaryEnabled {
            minutes = .off
        } else if terminating {
            minutes = .interrupted
        } else if !AIService.shared.isReady(AIService.shared.route(for: .meetingMinutes), local: .generation) {
            minutes = .noModel
        } else if minutesInput.reduce(0, { $0 + $1.text.count }) + notes.count < 40 {
            minutes = .tooShort
        } else {
            minutes = .generating
        }
        writeNow(sync: terminating)
        destination.onEvent?(.finished(end: time, minutes: minutes.outcome, terminating: terminating))
        if case .generating = minutes {
            generateMinutes()
        }
    }

    /// App 退出时还在整理纪要：标成「没整理完」，同步写一次。
    private func abortMinutesIfRunning() {
        Self.summarizing.removeAll { $0 === self }
        guard case .generating = minutes else { return }
        minutesTask?.cancel()
        minutes = .interrupted
        writeNow(sync: true)
        destination.onEvent?(.minutes(.interrupted))
    }

    // MARK: - 纪要

    private var minutesInput: [LiveTranslateMinutes.Line] {
        let speakers = destination.speakers
        let marks = self.marks
        return items.compactMap { item in
            guard case .line(let time, let original, _, let speaker) = item else { return nil }
            return LiveTranslateMinutes.Line(time: time, text: original,
                                             speaker: speakers ? speaker.map(Self.speakerLabel) : nil,
                                             highlighted: LiveTranslateMeetingMinutes.isHighlighted(time, marks: marks))
        }
        .sorted { $0.time < $1.time }
    }

    /// 后台整理；任务与登记表强持有本对象，开了下一次实时翻译 / 下一场会议也照样写完。
    private func generateMinutes() {
        let lines = minutesInput
        let chinese = L10n.locale.identifier.hasPrefix("zh")
        let template = destination.template
        let notes = self.notes
        // 走本地（内置或本机大模型）时那个模型常驻到写完；给纪要选了云端模型就不加载本地模型（出错退回时才现加载）。
        let kept = AIService.shared.localBackend(for: AIService.shared.route(for: .meetingMinutes), local: .generation)
        kept?.beginKeepAlive()
        Self.summarizing.append(self)
        minutesTask = Task {
            let result: Minutes
            do {
                result = .done(try await LiveTranslateMinutes.generate(lines: lines, chinese: chinese,
                                                                       template: template, notes: notes))
            } catch is CancellationError {
                result = .interrupted
            } catch {
                LiveTranslateLog.transcript.error("minutes failed: \(error.localizedDescription, privacy: .public)")
                result = .failed(error.localizedDescription)
            }
            kept?.endKeepAlive()
            minutesTask = nil
            Self.summarizing.removeAll { $0 === self }
            guard case .generating = minutes else { return }
            minutes = result
            writeNow(sync: false)
            if case .done = result, destination.notifiesMinutes {
                Self.notifyMinutesReady(fileName: destination.displayName)
            }
            destination.onEvent?(.minutes(result.outcome))
        }
    }

    private static func notifyMinutesReady(fileName: String) {
        // 改走通知内核（DesktopPet）：宠物呈现，宠物关时由内核回退系统通知。
        NotifyCenter.shared.post(PetNotification(
            source: "livetranslate",
            level: .ambient,
            title: L("livetranslate.record.notifyTitle"),
            body: L("livetranslate.record.notifyBody \(fileName)"),
            dedupeKey: "minutes.\(fileName)"
        ))
    }

    // MARK: - 写盘

    private func scheduleWrite() {
        guard hasContent, !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.writeScheduled else { return }
                self.writeNow(sync: false)
            }
        }
    }

    /// 整份重写。串行队列保证先排的先写，最后一次写的就是最新状态；`sync` 时等前面排着的写完再写。
    private func writeNow(sync: Bool) {
        writeScheduled = false
        guard hasContent else { return }
        let data = Data(render().utf8)
        let url = fileURL
        if sync {
            let error = Self.ioQueue.sync { Self.write(data, to: url) }
            if let error { reportWriteError(error) }
            return
        }
        Self.ioQueue.async {
            guard let error = Self.write(data, to: url) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reportWriteError(error)
                }
            }
        }
    }

    /// nil = 写好了；否则是出错说明。
    nonisolated private static func write(_ data: Data, to url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func reportWriteError(_ message: String) {
        LiveTranslateLog.transcript.error("write failed: \(message, privacy: .public)")
        guard !writeErrorShown else { return }
        writeErrorShown = true
        onWriteError?(message)
    }

    // MARK: - 排版

    private func render() -> String {
        if let header = destination.header {
            return renderMeeting(header)
        }
        var out = "# " + L("livetranslate.record.doc.title \(Self.format(start, "yyyy-MM-dd HH:mm"))") + "\n\n"
        var meta = [L("livetranslate.record.doc.start \(Self.format(start, "yyyy-MM-dd HH:mm:ss"))")]
        if let end {
            meta.append(L("livetranslate.record.doc.end \(Self.format(end, "yyyy-MM-dd HH:mm:ss")) \(Self.duration(from: start, to: end))"))
        }
        meta.append(L("livetranslate.record.doc.source \(config.source)"))
        meta.append(Self.languages(config))
        out += meta.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        if let section = minutesText {
            out += "## " + L("livetranslate.record.doc.minutes") + "\n\n" + section + "\n\n"
        }
        out += "## " + L("livetranslate.record.doc.transcript") + "\n\n"
        out += renderItems()
        return out
    }

    /// 会议的版式（docs/meeting/TECH_DESIGN.md §2.3）：标题、类型 / 时间 / 参会人 / 日历 / 音源 / 语言，
    /// 然后「纪要」「速记」「转录」三节。
    private func renderMeeting(_ header: Header) -> String {
        var out = "# " + header.title + "\n\n"
        var meta = [L("livetranslate.record.doc.kind \(header.kind)"),
                    L("livetranslate.record.doc.start \(Self.format(header.start, "yyyy-MM-dd HH:mm:ss"))")]
        if let end {
            meta.append(L("livetranslate.record.doc.end \(Self.format(end, "yyyy-MM-dd HH:mm:ss")) \(Self.duration(from: header.start, to: end))"))
        }
        if !header.attendees.isEmpty {
            meta.append(L("livetranslate.record.doc.attendees \(header.attendees.joined(separator: L("livetranslate.record.doc.listSeparator")))"))
        }
        if let calendar = header.calendar, !calendar.isEmpty {
            meta.append(L("livetranslate.record.doc.calendar \(calendar)"))
        }
        meta.append(L("livetranslate.record.doc.source \(config.source)"))
        meta.append(Self.languages(config))
        out += meta.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        if let section = minutesText {
            out += "## " + L("livetranslate.record.doc.minutes") + "\n\n" + section + "\n\n"
        }
        if !notes.isEmpty {
            out += "## " + L("livetranslate.record.doc.notes") + "\n\n" + notes + "\n\n"
        }
        out += "## " + L("livetranslate.record.doc.meetingTranscript") + "\n\n"
        out += renderItems()
        return out
    }

    /// 逐句（与改设置、🔖、暂停 / 继续的说明行）。
    private func renderItems() -> String {
        var out = ""
        // 按时间排（同一时刻按记下的先后）：重启前后、改判语言后补记的句子都落在该在的位置。
        let order = items.indices.sorted { lhs, rhs in
            let left = items[lhs].time
            let right = items[rhs].time
            return left != right ? left < right : lhs < rhs
        }
        for index in order {
            switch items[index] {
            case .line(let time, let original, let translation, let speaker):
                if destination.speakers, let speaker {
                    out += "**\(Self.format(time, "HH:mm:ss")) \(Self.speakerLabel(speaker))** \(original)\n"
                } else {
                    out += "**\(Self.format(time, "HH:mm:ss"))** \(original)\n"
                }
                if !translation.isEmpty {
                    out += "> \(translation)\n"
                }
                out += "\n"
            case .change(let time, let config):
                let changed = L("livetranslate.record.doc.changed \(Self.format(time, "HH:mm:ss")) \(config.source) \(Self.languages(config))")
                out += "*\(changed)*\n\n"
            case .mark(let time):
                out += "🔖 **\(Self.format(time, "HH:mm:ss"))** " + L("livetranslate.record.doc.mark") + "\n\n"
            case .note(let time, let text):
                out += "*\(Self.format(time, "HH:mm:ss")) \(text)*\n\n"
            }
        }
        return out
    }

    /// 「我」/「对方」。
    static func speakerLabel(_ speaker: MeetingSpeaker) -> String {
        switch speaker {
        case .me: return L("livetranslate.speaker.me")
        case .them: return L("livetranslate.speaker.them")
        }
    }

    private var minutesText: String? {
        switch minutes {
        case .off: return nil
        case .later:
            if case .meeting = destination.template { return L("livetranslate.record.doc.minutesLaterMeeting") }
            return L("livetranslate.record.doc.minutesLater")
        case .generating: return L("livetranslate.record.doc.minutesGenerating")
        case .done(let text): return text
        case .failed(let message): return L("livetranslate.record.doc.minutesFailed \(message)")
        case .noModel: return L("livetranslate.record.doc.minutesNoModel")
        case .tooShort: return L("livetranslate.record.doc.minutesTooShort")
        case .interrupted: return L("livetranslate.record.doc.minutesInterrupted")
        }
    }

    private static func languages(_ config: MeetingEngineRun) -> String {
        let target = config.target ?? L("livetranslate.record.doc.noTranslation")
        return L("livetranslate.record.doc.languages \(config.speech) \(target)")
    }

    private static func fileName(for date: Date) -> String {
        format(date, "yyyy-MM-dd HH-mm-ss") + ".md"
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = L10n.locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: seconds) ?? ""
    }
}
