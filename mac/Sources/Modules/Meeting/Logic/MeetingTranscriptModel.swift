import Foundation

/// 一份 meeting.md 的内容与排版（docs/meeting/ENGINE.md §5.2）：逐句（键 → 行，后到的覆盖先到的）、「改为：…」、🔖、说明行、速记、
/// 纪要的状态，两种版式（自由听译 / 会议，docs/meeting/TECH_DESIGN.md §2.3）的整份排版，以及停止时纪要怎么处理。
///
/// 纯逻辑：只依赖 Foundation，文案经 `Labels` 传入（同 `MeetingWeeklyReport.Labels`），可脱离 App 单独编译测试。
/// 写盘、整理纪要、通知在 App 侧的 `MeetingTranscript`；会议库按同一版式读回（`MeetingMarkdown`）。
struct MeetingTranscriptModel {
    /// 文档里用到的文案（调用方按界面语言给；纯逻辑不碰本地化）。带参数的是「把参数填进那句话」。
    struct Labels {
        /// 自由听译的标题「实时翻译记录 2026-11-10 10:00」。
        var title: (String) -> String
        /// 「开始：2026-11-10 10:00:00」。
        var start: (String) -> String
        /// 「结束：2026-11-10 10:30:00（30分钟）」：结束时刻、时长。
        var end: (String, String) -> String
        /// 「音源：麦克风 + 系统声音」。
        var source: (String) -> String
        /// 「说：简体中文 · 译成：English」：说什么、译成什么。
        var languages: (String, String) -> String
        /// 「不翻译」（`languages` 的第二个参数）。
        var noTranslation: String
        /// 会议：「类型：线上会议」。
        var kind: (String) -> String
        /// 会议：「参会人：张三、李四」。
        var attendees: (String) -> String
        /// 参会人之间的分隔（「、」/「, 」）。
        var listSeparator: String
        /// 会议：「日历：工作」。
        var calendar: (String) -> String
        /// 「纪要」一节的标题。
        var minutes: String
        /// 会议「速记」一节的标题。
        var notes: String
        /// 自由听译「记录」一节的标题。
        var transcript: String
        /// 会议「转录」一节的标题。
        var meetingTranscript: String
        /// 「10:05:00 改为：麦克风 · 说：English · 译成：不翻译」：时刻、音源、语言。
        var changed: (String, String, String) -> String
        /// 🔖 那一行的说明「标记重点」。
        var mark: String
        /// 说话人「我」「对方」（会议的转录行，也喂给纪要）。
        var me: String
        var them: String
        /// 说明行：暂停 / 继续、麦克风 / 系统声音的静音与恢复。
        var paused: String
        var resumed: String
        var microphoneMuted: String
        var microphoneUnmuted: String
        var systemMuted: String
        var systemUnmuted: String
        /// 纪要一节在各状态下的占位。
        var minutesLater: String
        var minutesLaterMeeting: String
        var minutesGenerating: String
        var minutesFailed: (String) -> String
        var minutesNoModel: String
        var minutesTooShort: String
        var minutesInterrupted: String
        /// 时长（「18秒」「1小时5分钟」）用哪种语言。
        var locale: Locale
    }

    /// 纪要一节现在的状态。
    enum Minutes: Equatable {
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

        var outcome: MeetingMinutesOutcome {
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

    private enum Item {
        case line(time: Date, original: String, translation: String, speaker: MeetingSpeaker?)
        case change(time: Date, config: MeetingEngineRun)
        /// 🔖 标记重点（会议）。
        case mark(time: Date)
        /// 一行说明（会议的暂停 / 继续、单路静音）。
        case note(time: Date, note: MeetingTranscriptNote)

        var time: Date {
            switch self {
            case .line(let time, _, _, _), .change(let time, _), .mark(let time), .note(let time, _): return time
            }
        }
    }

    /// 少于这么多字（原文 + 速记）不整理纪要。
    static let minutesMinimumLength = 40

    let labels: Labels
    /// 开始记的时刻（自由听译的标题与开始时间；会议的开始时间在 `header` 里）。
    let start: Date
    /// 开始时这次怎么跑的（开头的音源、语言）；之后的改动是「改为：…」行。
    let run: MeetingEngineRun
    let header: MeetingTranscriptSpec.Header?
    let speakers: Bool
    let template: MeetingMinutesTemplate
    var minutes: Minutes
    private(set) var end: Date?
    /// 会议：🔖 标记的时刻、速记。
    private(set) var marks: [Date] = []
    private(set) var notes = ""
    private var lastRun: MeetingEngineRun
    private var items: [Item] = []
    /// 句子键 → `items` 下标。
    private var lineIndex: [String: Int] = [:]

    init(spec: MeetingTranscriptSpec, start: Date, run: MeetingEngineRun, labels: Labels) {
        self.labels = labels
        self.start = start
        self.run = run
        header = spec.header
        speakers = spec.speakers
        template = spec.template
        minutes = spec.summarizes ? .later : .off
        lastRun = run
    }

    /// 至少记下了一句（或会议记了速记）才有文件。
    var hasContent: Bool { !lineIndex.isEmpty || !notes.isEmpty }

    /// 记下 / 更新一句。`key` 在这份记录里唯一，同一句再报一遍还是同一个键（`MeetingEngineLine.key`）。
    /// 返回有没有变（同一 key、原文 / 译文 / 说话人都没变就是没变）。说话人只在会议标说话人时写进记录。
    @discardableResult
    mutating func update(_ line: MeetingEngineLine) -> Bool {
        if let index = lineIndex[line.key] {
            if case .line(_, let oldOriginal, let oldTranslation, let oldSpeaker) = items[index],
               oldOriginal == line.original, oldTranslation == line.translation, oldSpeaker == line.speaker { return false }
            items[index] = .line(time: line.time, original: line.original, translation: line.translation, speaker: line.speaker)
        } else {
            lineIndex[line.key] = items.count
            items.append(.line(time: line.time, original: line.original, translation: line.translation, speaker: line.speaker))
        }
        return true
    }

    /// 🔖 标记重点：记一行，整理纪要时这一刻前后的句子加「【重点】」（`MeetingMinutesFormat.isHighlighted`）。
    mutating func mark(at time: Date) {
        marks.append(time)
        items.append(.mark(time: time))
    }

    /// 记一行说明（会议的暂停 / 继续、单路静音）。
    mutating func note(_ note: MeetingTranscriptNote, at time: Date) {
        items.append(.note(time: time, note: note))
    }

    /// 会议速记（整份替换，去掉首尾空白）：写在「速记」一节，整理纪要时作为上下文。返回有没有变。
    @discardableResult
    mutating func setNotes(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != notes else { return false }
        notes = trimmed
        return true
    }

    /// 改设置后的重启接着写：设置确实变了就记一行「改为：…」，返回有没有记。
    @discardableResult
    mutating func continueWith(_ run: MeetingEngineRun, at time: Date) -> Bool {
        guard run != lastRun else { return false }
        lastRun = run
        items.append(.change(time: time, config: run))
        return true
    }

    /// 停止时纪要怎么处理：没开纪要 → 不写；App 退出 → 没整理完；「会议纪要」的模型不能用 → 只存原文；
    /// 原文加速记不到 40 字 → 太短；否则整理。`ready` = 此刻「会议纪要」的模型能不能用（`MeetingMinutesGenerator.isReady`）。
    func decideMinutes(summarizes: Bool, terminating: Bool, ready: Bool) -> Minutes {
        if !summarizes {
            return .off
        } else if terminating {
            return .interrupted
        } else if !ready {
            return .noModel
        } else if minutesInput.reduce(0, { $0 + $1.text.count }) + notes.count < Self.minutesMinimumLength {
            return .tooShort
        } else {
            return .generating
        }
    }

    /// 停止：记下结束时间，按 `decideMinutes` 定纪要怎么处理。
    mutating func finish(at time: Date, summarizes: Bool, terminating: Bool, ready: Bool) {
        end = time
        minutes = decideMinutes(summarizes: summarizes, terminating: terminating, ready: ready)
    }

    // MARK: - 纪要的输入

    /// 喂给模型的句子（按时间）：标说话人时带「我 / 对方」，🔖 前 20 秒、后 5 秒开始的句子标重点。
    var minutesInput: [MeetingMinutesPrompts.Line] {
        let speakers = self.speakers
        let marks = self.marks
        return items.compactMap { item in
            guard case .line(let time, let original, _, let speaker) = item else { return nil }
            return MeetingMinutesPrompts.Line(time: time, text: original,
                                              speaker: speakers ? speaker.map(speakerLabel) : nil,
                                              highlighted: MeetingMinutesFormat.isHighlighted(time, marks: marks))
        }
        .sorted { $0.time < $1.time }
    }

    // MARK: - 排版

    /// 整份 Markdown。
    func render() -> String {
        if let header {
            return renderMeeting(header)
        }
        var out = "# " + labels.title(Self.format(start, "yyyy-MM-dd HH:mm")) + "\n\n"
        var meta = [labels.start(Self.format(start, "yyyy-MM-dd HH:mm:ss"))]
        if let end {
            meta.append(labels.end(Self.format(end, "yyyy-MM-dd HH:mm:ss"), Self.duration(from: start, to: end, locale: labels.locale)))
        }
        meta.append(labels.source(run.source))
        meta.append(languages(run))
        out += meta.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        if let section = minutesText {
            out += "## " + labels.minutes + "\n\n" + section + "\n\n"
        }
        out += "## " + labels.transcript + "\n\n"
        out += renderItems()
        return out
    }

    /// 会议的版式（docs/meeting/TECH_DESIGN.md §2.3）：标题、类型 / 时间 / 参会人 / 日历 / 音源 / 语言，
    /// 然后「纪要」「速记」「转录」三节。
    private func renderMeeting(_ header: MeetingTranscriptSpec.Header) -> String {
        var out = "# " + header.title + "\n\n"
        var meta = [labels.kind(header.kind),
                    labels.start(Self.format(header.start, "yyyy-MM-dd HH:mm:ss"))]
        if let end {
            meta.append(labels.end(Self.format(end, "yyyy-MM-dd HH:mm:ss"),
                                   Self.duration(from: header.start, to: end, locale: labels.locale)))
        }
        if !header.attendees.isEmpty {
            meta.append(labels.attendees(header.attendees.joined(separator: labels.listSeparator)))
        }
        if let calendar = header.calendar, !calendar.isEmpty {
            meta.append(labels.calendar(calendar))
        }
        meta.append(labels.source(run.source))
        meta.append(languages(run))
        out += meta.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        if let section = minutesText {
            out += "## " + labels.minutes + "\n\n" + section + "\n\n"
        }
        if !notes.isEmpty {
            out += "## " + labels.notes + "\n\n" + notes + "\n\n"
        }
        out += "## " + labels.meetingTranscript + "\n\n"
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
                if speakers, let speaker {
                    out += "**\(Self.format(time, "HH:mm:ss")) \(speakerLabel(speaker))** \(original)\n"
                } else {
                    out += "**\(Self.format(time, "HH:mm:ss"))** \(original)\n"
                }
                if !translation.isEmpty {
                    out += "> \(translation)\n"
                }
                out += "\n"
            case .change(let time, let config):
                let changed = labels.changed(Self.format(time, "HH:mm:ss"), config.source, languages(config))
                out += "*\(changed)*\n\n"
            case .mark(let time):
                out += "🔖 **\(Self.format(time, "HH:mm:ss"))** " + labels.mark + "\n\n"
            case .note(let time, let note):
                out += "*\(Self.format(time, "HH:mm:ss")) \(text(for: note))*\n\n"
            }
        }
        return out
    }

    /// 「我」/「对方」。
    func speakerLabel(_ speaker: MeetingSpeaker) -> String {
        switch speaker {
        case .me: return labels.me
        case .them: return labels.them
        }
    }

    /// 说明行的文案。
    func text(for note: MeetingTranscriptNote) -> String {
        switch note {
        case .paused: return labels.paused
        case .resumed: return labels.resumed
        case .microphoneMuted: return labels.microphoneMuted
        case .microphoneUnmuted: return labels.microphoneUnmuted
        case .systemMuted: return labels.systemMuted
        case .systemUnmuted: return labels.systemUnmuted
        }
    }

    private var minutesText: String? {
        switch minutes {
        case .off: return nil
        case .later:
            if case .meeting = template { return labels.minutesLaterMeeting }
            return labels.minutesLater
        case .generating: return labels.minutesGenerating
        case .done(let text): return text
        case .failed(let message): return labels.minutesFailed(message)
        case .noModel: return labels.minutesNoModel
        case .tooShort: return labels.minutesTooShort
        case .interrupted: return labels.minutesInterrupted
        }
    }

    private func languages(_ config: MeetingEngineRun) -> String {
        let target = config.target ?? labels.noTranslation
        return labels.languages(config.speech, target)
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private static func duration(from start: Date, to end: Date, locale: Locale) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: seconds) ?? ""
    }
}
