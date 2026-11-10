import AppKit
import Foundation

/// 实时翻译的本地记录与纪要设置（前缀 `livetranslate.record.`）。见 docs/live-translate/DESIGN.md §6。
enum LiveTranslateRecordSettings {
    static let enabledKey = "livetranslate.record.enabled"
    static let folderKey = "livetranslate.record.folder"
    static let summaryKey = "livetranslate.record.summary"

    /// 保存记录（默认关，2026-11-05 用户要求）：设置页或字幕条「记录」菜单里手动开，开了以后每次开始都记。
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 停止后用本地 AI 整理纪要（默认开；没下载模型时只存原文和译文）。
    static var summary: Bool {
        UserDefaults.standard.object(forKey: summaryKey) as? Bool ?? true
    }

    /// 默认：~/Documents/Baobox 实时翻译记录。
    static var defaultFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent(L("livetranslate.record.defaultFolderName"), isDirectory: true)
    }

    static var folder: URL {
        let path = UserDefaults.standard.string(forKey: folderKey) ?? ""
        return path.isEmpty ? defaultFolder : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 新记录实际写到哪：会议模块装上了就是会议库（docs/meeting/TECH_DESIGN.md §2.3），否则是上面这个文件夹。
    /// `folder` 设置保留，只用于首次启动把旧记录迁进会议库。
    @MainActor
    static var effectiveFolder: URL {
        LiveTranslateController.recordLibrary?.folderURL ?? folder
    }

    /// 打开记录文件夹（还没有就先建）。建目录放后台：第一次碰「文稿」时系统会弹授权框，别卡住主线程。
    @MainActor
    static func openFolder() {
        let url = effectiveFolder
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// 会议库（Meeting 模块）接管自由听译的新记录（docs/meeting/TECH_DESIGN.md §2.3）。
@MainActor
protocol LiveTranslateRecordLibrary: AnyObject {
    /// 会议库根目录（设置页「保存位置」、字幕条「打开记录文件夹」）。
    var folderURL: URL { get }
    /// 新开一份自由听译记录写到哪（会议库里新的一条；记下第一句时才登记进索引）。
    func freeListeningDestination(start: Date) -> LiveTranslateTranscript.Destination
}

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
    func abortMinutesIfRunning() {
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

    /// 后台整理；任务强持有本对象，开了下一次实时翻译也照样写完。
    private func generateMinutes() {
        let lines = minutesInput
        let chinese = L10n.locale.identifier.hasPrefix("zh")
        let template = destination.template
        let notes = self.notes
        // 走本地（内置或本机大模型）时那个模型常驻到写完；给纪要选了云端模型就不加载本地模型（出错退回时才现加载）。
        let kept = AIService.shared.localBackend(for: AIService.shared.route(for: .meetingMinutes), local: .generation)
        kept?.beginKeepAlive()
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

/// 停止后整理纪要（本地 Qwen3-1.7B，上下文 4096）：记录短就一次整理；长了按段先各提要点，再合并成一份。
enum LiveTranslateMinutes {
    struct Line {
        let time: Date
        let text: String
        /// 会议标说话人时的「我 / 对方」（已本地化）；没有为 nil。
        var speaker: String?
        /// 🔖 标记的那段：输入里加「【重点】」前缀加权。
        var highlighted = false
    }

    enum Failure: LocalizedError {
        case empty

        var errorDescription: String? { L("livetranslate.record.doc.minutesEmpty") }
    }

    /// 每次喂给模型的记录最多这么多 token（估算），给提示词和输出留余量。
    private static let inputBudget = 2200

    /// `template`：`.content`（自由听译）就是原来的要点 / 结论 / 待办；`.meeting` 出固定格式的会议纪要
    /// （摘要 / 决议 / 行动项 / 重点，见 `LiveTranslateMeetingMinutes`），`notes`（会议速记）作为上下文附在前面。
    @MainActor
    static func generate(lines: [Line], chinese: Bool, template: LiveTranslateMinutesTemplate = .content,
                         notes: String = "") async throws -> String {
        if case .meeting(let style) = template {
            return try await generateMeeting(lines: lines, chinese: chinese, style: style, notes: notes)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let rows = lines.map { "[\(formatter.string(from: $0.time))] \($0.text)" }
        let chunks = chunk(rows)
        var body = chunks.first ?? ""
        var fromNotes = false
        if chunks.count > 1 {
            var notes: [String] = []
            for (index, part) in chunks.enumerated() {
                try Task.checkCancellation()
                notes.append(try await ask(notesPrompt(part, part: index + 1, of: chunks.count, chinese: chinese),
                                           maxTokens: 500))
            }
            body = fit(notes, chinese: chinese)
            fromNotes = true
        }
        try Task.checkCancellation()
        let result = tidy(try await ask(minutesPrompt(body, fromNotes: fromNotes, chinese: chinese), maxTokens: 900))
        guard !result.isEmpty else { throw Failure.empty }
        return result
    }

    @MainActor
    private static func ask(_ prompt: String, maxTokens: Int) async throws -> String {
        // 走哪个模型按「会议纪要」这个功能选的（默认本地，docs/ai-service/DESIGN.md §5.4）；云端每段最多等 120 秒。
        try await AIService.shared.generate(prompt, maxTokens: maxTokens, sampling: .summary,
                                            route: AIService.shared.route(for: .meetingMinutes), timeout: 120).text
    }

    /// 会议纪要：每行带说话人与【重点】；长了先逐段提要点（重点必留），再按会议类型整理成固定的四节。
    @MainActor
    private static func generateMeeting(lines: [Line], chinese: Bool, style: LiveTranslateMeetingStyle,
                                        notes: String) async throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let rows = lines.map {
            LiveTranslateMeetingMinutes.row(clock: formatter.string(from: $0.time), text: $0.text,
                                            speaker: $0.speaker, highlighted: $0.highlighted)
        }
        // 速记占一部分预算（最多约 400 token），记录相应少放一点，整份仍在上下文 4096 以内。
        let context = clip(notes, budget: notesBudget)
        let budget = max(800, inputBudget - tokens(context))
        let chunks = chunk(rows, budget: budget)
        var body = chunks.first ?? ""
        var fromNotes = false
        if chunks.count > 1 {
            var parts: [String] = []
            for (index, part) in chunks.enumerated() {
                try Task.checkCancellation()
                parts.append(try await ask(meetingNotesPrompt(part, part: index + 1, of: chunks.count, chinese: chinese),
                                           maxTokens: 500))
            }
            body = fit(parts, chinese: chinese, budget: budget)
            fromNotes = true
        }
        try Task.checkCancellation()
        let result = tidy(try await ask(meetingPrompt(body, fromNotes: fromNotes, notes: context, style: style,
                                                      chinese: chinese), maxTokens: 900))
        guard !result.isEmpty else { throw Failure.empty }
        return result
    }

    /// 会议速记最多占这么多 token。
    private static let notesBudget = 400

    /// 截到预算以内（按行，超出的行不要）。
    static func clip(_ text: String, budget: Int) -> String {
        var kept: [String] = []
        var size = 0
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let cost = tokens(line) + 1
            guard size + cost <= budget else { break }
            kept.append(line)
            size += cost
        }
        return kept.joined(separator: "\n")
    }

    /// 按行凑段，每段不超过 `budget`（默认 `inputBudget`）。
    static func chunk(_ rows: [String], budget: Int = inputBudget) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for row in rows {
            let cost = tokens(row) + 1
            if size + cost > budget, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(row)
            size += cost
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }

    /// 各段要点合起来再超预算：每段只留前面的几条，按段平分预算。
    static func fit(_ notes: [String], chinese: Bool, budget: Int = inputBudget) -> String {
        let limit = max(120, budget / max(1, notes.count))
        return notes.enumerated().map { index, note in
            var kept: [String] = []
            var size = 0
            for line in note.components(separatedBy: .newlines)
            where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let cost = tokens(line) + 1
                guard size + cost <= limit else { break }
                kept.append(line)
                size += cost
            }
            let title = chinese ? "第 \(index + 1) 段：" : "Part \(index + 1):"
            return title + "\n" + kept.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// 粗估 token 数：中日韩一字约一个，其余约 3.5 个字符一个（Qwen 分词的大致比例），宁多勿少。
    static func tokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF: cjk += 1
            default: other += 1
            }
        }
        return cjk + (other * 2 + 6) / 7
    }

    /// 模型偶尔自己加个大标题（「# 会议纪要」）：去掉；「## 」降成「### 」，和记录文件的层级对上。
    static func tidy(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("# ") }
            .map { $0.hasPrefix("## ") ? "#" + $0 : $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 提示词是给模型看的，不是界面文案：按纪要语言写死两套。末尾的 /no_think 关掉 Qwen3 的「思考」。

    private static func notesPrompt(_ part: String, part index: Int, of count: Int, chinese: Bool) -> String {
        if chinese {
            return """
            你是会议记录助手。下面是一场会议 / 对话实时字幕记录的第 \(index)/\(count) 段（语音识别结果，可能有错字、中英混杂）。
            请用简体中文列出这一段讲到的要点、决定和待办，每条一行、以「- 」开头，最多 10 条。
            只写记录里有的内容，不要编造，不要输出别的内容。

            记录：
            \(part)
            /no_think
            """
        }
        return """
        You are a meeting-notes assistant. Below is part \(index) of \(count) of a live transcript of a meeting or \
        conversation (speech recognition output; it may contain errors and mixed Chinese/English).
        List the key points, decisions and action items in this part in English, one per line starting with "- ", \
        at most 10. Only include what the transcript says; do not make things up and output nothing else.

        Transcript:
        \(part)
        /no_think
        """
    }

    private static func minutesPrompt(_ body: String, fromNotes: Bool, chinese: Bool) -> String {
        if chinese {
            let intro = fromNotes
                ? "下面是一场会议 / 对话按时间顺序分段整理出的要点。"
                : "下面是一场会议 / 对话的实时字幕记录（语音识别结果，可能有错字、中英混杂）。"
            return """
            你是会议记录助手。\(intro)请整理成简体中文的会议纪要，严格按下面的格式输出，只写记录里出现过的内容，不要编造，不要输出别的内容：

            ### 要点
            - 最重要的几条内容，每条一句
            ### 结论
            - 达成的共识、做出的决定；没有就写「无」
            ### 待办
            - 谁要做什么、什么时候；没有就写「无」

            \(fromNotes ? "分段要点" : "记录")：
            \(body)
            /no_think
            """
        }
        let intro = fromNotes
            ? "Below are notes taken part by part, in order, from a meeting or conversation."
            : "Below is a live transcript of a meeting or conversation (speech recognition output; it may contain errors and mixed Chinese/English)."
        return """
        You are a meeting-notes assistant. \(intro) Write meeting minutes in English using exactly this format. \
        Only include what the \(fromNotes ? "notes say" : "transcript says"); do not make things up and output nothing else:

        ### Key points
        - the most important points, one sentence each
        ### Decisions
        - agreements and decisions made; write "None" if there are none
        ### Action items
        - who does what, by when; write "None" if there are none

        \(fromNotes ? "Notes" : "Transcript"):
        \(body)
        /no_think
        """
    }

    // MARK: 会议纪要（docs/meeting/TECH_DESIGN.md §2.3）

    private static func meetingNotesPrompt(_ part: String, part index: Int, of count: Int, chinese: Bool) -> String {
        if chinese {
            return """
            你是会议记录助手。下面是一场会议实时转录的第 \(index)/\(count) 段（语音识别结果，可能有错字、中英混杂；「我」是记录者本人，\
            「对方」是会上的其他人，按声音来源判的、可能不准；带「【重点】」的是记录者标记的重点）。
            请用简体中文列出这一段的要点、决定和行动项（谁、做什么、什么时候），标了【重点】的一定要保留，每条一行、以「- 」开头，最多 10 条。
            只写记录里有的内容，不要编造，不要输出别的内容。

            记录：
            \(part)
            /no_think
            """
        }
        return """
        You are a meeting-notes assistant. Below is part \(index) of \(count) of a live meeting transcript (speech \
        recognition output; it may contain errors and mixed Chinese/English). "我"/"Me" is the note taker and "对方"/"Them" \
        is someone else in the meeting (guessed from the audio source, may be wrong); lines marked 【重点】 were \
        highlighted by the note taker.
        List the key points, decisions and action items (who, what, by when) in this part in English, one per line \
        starting with "- ", at most 10, always keeping the highlighted ones. Only include what the transcript says; do not \
        make things up and output nothing else.

        Transcript:
        \(part)
        /no_think
        """
    }

    /// 输出固定为「## 摘要 / ## 决议 / ## 行动项 / ## 重点」四节，行动项每条「- [ ] 负责人：事项（截止：…）」；
    /// 会议类型只换各节写什么。
    private static func meetingPrompt(_ body: String, fromNotes: Bool, notes: String, style: LiveTranslateMeetingStyle,
                                      chinese: Bool) -> String {
        let headings = LiveTranslateMeetingMinutes.headings(chinese: chinese)
        if chinese {
            let intro = fromNotes
                ? "下面是一场会议按时间顺序分段整理出的要点。"
                : "下面是一场会议的实时转录（语音识别结果，可能有错字、中英混杂）。"
            let focus: String
            switch style {
            case .standard: focus = ""
            case .standup: focus = "这是一场站会：摘要按人写每个人昨天做了什么、今天打算做什么、遇到了什么阻碍；行动项写需要跟进的阻碍和答应要做的事。\n"
            case .oneOnOne: focus = "这是一场一对一沟通：摘要写聊到的话题、双方的反馈与想法；决议写达成的共识；行动项写双方各自答应要做的事。\n"
            case .interview: focus = "这是一场面试：摘要写候选人的背景、对各个问题的回答与表现；决议只写记录里明确说到的面试结论或下一步安排；重点写候选人的亮点与顾虑。\n"
            }
            let context = notes.isEmpty ? "" : "会议速记（记录者在会上手记的，可作参考）：\n\(notes)\n\n"
            return """
            你是会议纪要助手。\(intro)「我」是记录者本人，「对方」是会上的其他人（按声音来源判的，可能不准）；\
            带「【重点】」的是记录者标记的重点，请优先写进纪要。
            \(focus)请整理成简体中文的会议纪要，严格按下面的格式输出这四节，只写记录里出现过的内容，不要编造，不要输出别的内容：

            ## \(headings[0])
            - 会议的主要内容，3～6 条，每条一句
            ## \(headings[1])
            - 达成的共识、做出的决定；没有就写「- 无」
            ## \(headings[2])
            - [ ] 负责人：事项（截止：…）
            ## \(headings[3])
            - 标了【重点】的内容和其他关键信息；没有就写「- 无」

            行动项每条一行，都以「- [ ] 」开头，把「负责人」「事项」「…」换成记录里的人名、要做的事和时间；\
            记录里没说负责人或截止时间就省掉那部分；没有行动项就写「- 无」。

            \(context)\(fromNotes ? "分段要点" : "记录")：
            \(body)
            /no_think
            """
        }
        let intro = fromNotes
            ? "Below are notes taken part by part, in order, from a meeting."
            : "Below is a live meeting transcript (speech recognition output; it may contain errors and mixed Chinese/English)."
        let focus: String
        switch style {
        case .standard: focus = ""
        case .standup: focus = "This is a stand-up: in the summary, give each person's yesterday, today and blockers; action items are blockers to follow up and commitments.\n"
        case .oneOnOne: focus = "This is a one-on-one: the summary covers the topics discussed and each side's feedback; decisions are what both agreed on; action items are what each side committed to.\n"
        case .interview: focus = "This is an interview: the summary covers the candidate's background and answers; decisions only include an outcome or next step the transcript states; highlights are the candidate's strengths and concerns.\n"
        }
        let context = notes.isEmpty ? "" : "Meeting notes (typed by the note taker during the meeting, for reference):\n\(notes)\n\n"
        return """
        You are a meeting-minutes assistant. \(intro) "我"/"Me" is the note taker and "对方"/"Them" is someone else in the \
        meeting (guessed from the audio source, may be wrong); lines marked 【重点】 were highlighted by the note taker, so \
        give them priority.
        \(focus)Write the minutes in English using exactly these four sections. Only include what the \
        \(fromNotes ? "notes say" : "transcript says"); do not make things up and output nothing else:

        ## \(headings[0])
        - the main points, 3-6 bullets, one sentence each
        ## \(headings[1])
        - agreements and decisions; write "- None" if there are none
        ## \(headings[2])
        - [ ] Owner: task (due: …)
        ## \(headings[3])
        - highlighted content and other key information; write "- None" if there is none

        Write each action item on its own line starting with "- [ ] ", replacing "Owner", "task" and "…" with the \
        person, the thing to do and the date from the transcript. Leave out the owner or due date if the transcript \
        doesn't say; write "- None" if there are no action items.

        \(context)\(fromNotes ? "Notes" : "Transcript"):
        \(body)
        /no_think
        """
    }
}
