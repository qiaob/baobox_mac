import Foundation
import os

/// 转录与纪要的诊断日志（#107 之前在字幕与同传那边，category `livetranslate.transcript`）。
private let transcriptLog = Logger(subsystem: "com.baobox.app", category: "meeting.transcript")

/// 一次实时翻译的本地记录（Markdown）：开头是时间、音源、语言，然后「纪要」（停止后由本地 AI 整理），
/// 最后逐句的时间 + 原文 + 译文。会议记录（`MeetingTranscriptSpec.header`）另有标题与参会人、「速记」一节、每句的说话人与 🔖 标记。
///
/// 内容与排版是纯逻辑（`MeetingTranscriptModel`，docs/meeting/ENGINE.md §5.2），这里是它的外壳：文案（`L()`）、写盘、整理纪要、通知。
/// 说完（定稿）的句子就记下；内存里留整份，有变化时至多 1 秒后整份重写一次（原子写），中途崩溃最多丢最后 1 秒。
/// 一句都没有就不建文件。改设置引起的重启接着写同一份，并记一行「改为：…」。
@MainActor
final class MeetingTranscript {
    let fileURL: URL
    /// 进度：记下第一句、收尾、纪要结果（会议库 / 会话据此更新 meta.json 与索引）。
    var onEvent: ((MeetingTranscriptEvent) -> Void)?
    /// 写盘失败（磁盘满、目录不可写…）时回调一次，参数是给用户看的一行提示（已本地化），字幕条提示。
    var onWriteError: ((String) -> Void)?

    private var spec: MeetingTranscriptSpec
    private var model: MeetingTranscriptModel
    private var minutesTask: Task<Void, Never>?
    private var writeScheduled = false
    private var writeErrorShown = false

    private static let ioQueue = DispatchQueue(label: "com.baobox.app.meeting.transcript", qos: .utility)

    /// 正在整理纪要的记录（会议的、自由听译的）：开始整理时登记、整理完注销。登记表和纪要任务都持有它们，
    /// 会话复位、开了下一场也照样写得回去；App 退出时 `abortAllMinutes()` 把它们全部标成「没整理完」。
    private static var summarizing: [MeetingTranscript] = []

    /// App 退出：还在整理的纪要全部标成「没整理完」，md 与 meta.json 都同步写完（docs/meeting/ENGINE.md §4.5.5）。
    /// 在会议与自由听译都停下之后、`OfflineTranslator.shutdownAll()` 之前调。
    static func abortAllMinutes() {
        let pending = summarizing
        summarizing = []
        for transcript in pending {
            transcript.abortMinutesIfRunning()
        }
    }

    init(start: Date, run: MeetingEngineRun, spec: MeetingTranscriptSpec) {
        self.spec = spec
        model = MeetingTranscriptModel(spec: spec, start: start, run: run, labels: Self.labels())
        fileURL = spec.fileURL
    }

    /// 至少记下了一句（或会议记了速记）才有文件。
    var hasContent: Bool { model.hasContent }

    /// 记下 / 更新一句。`key` 在这份记录里唯一，同一句再报一遍还是同一个键（`MeetingEngineLine.key`）。
    /// 说话人只在会议标说话人时写进记录。
    func update(_ line: MeetingEngineLine) {
        let hadContent = model.hasContent
        guard model.update(line) else { return }
        if !hadContent { onEvent?(.created) }
        scheduleWrite()
    }

    /// 🔖 标记重点：记一行，整理纪要时这一刻前后的句子加「【重点】」（`MeetingMinutesFormat.isHighlighted`）。
    func mark(at time: Date) {
        model.mark(at: time)
        scheduleWrite()
    }

    /// 记一行说明（会议的暂停 / 继续、单路静音）。
    func note(_ note: MeetingTranscriptNote, at time: Date) {
        model.note(note, at: time)
        scheduleWrite()
    }

    /// 会议速记（整份替换）：写在「速记」一节，整理纪要时作为上下文。
    func setNotes(_ text: String) {
        let hadContent = model.hasContent
        guard model.setNotes(text) else { return }
        if !hadContent, model.hasContent { onEvent?(.created) }
        scheduleWrite()
    }

    /// 改设置后的重启接着写：设置确实变了就记一行「改为：…」。
    func continueWith(_ run: MeetingEngineRun, at time: Date) {
        guard model.continueWith(run, at: time) else { return }
        scheduleWrite()
    }

    /// 停止：记下结束时间、决定纪要怎么处理（`MeetingTranscriptModel.decideMinutes`），写一次。
    /// `terminating` = App 正在退出：同步写，不整理纪要。
    func finish(at time: Date, terminating: Bool) {
        model.finish(at: time, summarizes: spec.summarizes, terminating: terminating, ready: MeetingMinutesGenerator.isReady)
        writeNow(sync: terminating)
        onEvent?(.finished(end: time, minutes: model.minutes.outcome, terminating: terminating))
        if case .generating = model.minutes {
            generateMinutes()
        }
    }

    /// App 退出时还在整理纪要：标成「没整理完」，同步写一次。
    private func abortMinutesIfRunning() {
        Self.summarizing.removeAll { $0 === self }
        guard case .generating = model.minutes else { return }
        minutesTask?.cancel()
        model.minutes = .interrupted
        writeNow(sync: true)
        onEvent?(.minutes(.interrupted))
    }

    // MARK: - 纪要

    /// 后台整理；任务与登记表强持有本对象，开了下一次实时翻译 / 下一场会议也照样写完。
    private func generateMinutes() {
        let lines = model.minutesInput
        let chinese = L10n.locale.identifier.hasPrefix("zh")
        let template = spec.template
        let notes = model.notes
        // 走本地时那个模型常驻到写完：`MeetingMinutesGenerator.generate` 里自己管。
        Self.summarizing.append(self)
        minutesTask = Task {
            let result: MeetingTranscriptModel.Minutes
            do {
                result = .done(try await MeetingMinutesGenerator.generate(lines: lines, chinese: chinese,
                                                                          template: template, notes: notes))
            } catch is CancellationError {
                result = .interrupted
            } catch {
                transcriptLog.error("minutes failed: \(error.localizedDescription, privacy: .public)")
                result = .failed(error.localizedDescription)
            }
            minutesTask = nil
            Self.summarizing.removeAll { $0 === self }
            guard case .generating = model.minutes else { return }
            model.minutes = result
            writeNow(sync: false)
            if case .done = result, spec.notifiesMinutes {
                Self.notifyMinutesReady(fileName: spec.displayName)
            }
            onEvent?(.minutes(result.outcome))
        }
    }

    private static func notifyMinutesReady(fileName: String) {
        // 改走通知内核（DesktopPet）：宠物呈现，宠物关时由内核回退系统通知。
        NotifyCenter.shared.post(Notice(
            source: "livetranslate",
            level: .ambient,
            title: L("livetranslate.record.notifyTitle"),
            body: L("livetranslate.record.notifyBody \(fileName)"),
            dedupeKey: "minutes.\(fileName)"
        ))
    }

    // MARK: - 写盘

    private func scheduleWrite() {
        guard model.hasContent, !writeScheduled else { return }
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
        guard model.hasContent else { return }
        let data = Data(model.render().utf8)
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
        transcriptLog.error("write failed: \(message, privacy: .public)")
        guard !writeErrorShown else { return }
        writeErrorShown = true
        onWriteError?(L("livetranslate.record.writeFailed \(message)"))
    }

    // MARK: - 文案

    /// 文档里的文案（key 与 #107 之前一样，仍是 `livetranslate.record.doc.*`）。
    private static func labels() -> MeetingTranscriptModel.Labels {
        MeetingTranscriptModel.Labels(
            title: { L("livetranslate.record.doc.title \($0)") },
            start: { L("livetranslate.record.doc.start \($0)") },
            end: { L("livetranslate.record.doc.end \($0) \($1)") },
            source: { L("livetranslate.record.doc.source \($0)") },
            languages: { L("livetranslate.record.doc.languages \($0) \($1)") },
            noTranslation: L("livetranslate.record.doc.noTranslation"),
            kind: { L("livetranslate.record.doc.kind \($0)") },
            attendees: { L("livetranslate.record.doc.attendees \($0)") },
            listSeparator: L("livetranslate.record.doc.listSeparator"),
            calendar: { L("livetranslate.record.doc.calendar \($0)") },
            minutes: L("livetranslate.record.doc.minutes"),
            notes: L("livetranslate.record.doc.notes"),
            transcript: L("livetranslate.record.doc.transcript"),
            meetingTranscript: L("livetranslate.record.doc.meetingTranscript"),
            changed: { L("livetranslate.record.doc.changed \($0) \($1) \($2)") },
            mark: L("livetranslate.record.doc.mark"),
            me: L("livetranslate.speaker.me"),
            them: L("livetranslate.speaker.them"),
            paused: L("livetranslate.record.doc.paused"),
            resumed: L("livetranslate.record.doc.resumed"),
            microphoneMuted: L("livetranslate.record.doc.micMuted"),
            microphoneUnmuted: L("livetranslate.record.doc.micUnmuted"),
            systemMuted: L("livetranslate.record.doc.systemMuted"),
            systemUnmuted: L("livetranslate.record.doc.systemUnmuted"),
            minutesLater: L("livetranslate.record.doc.minutesLater"),
            minutesLaterMeeting: L("livetranslate.record.doc.minutesLaterMeeting"),
            minutesGenerating: L("livetranslate.record.doc.minutesGenerating"),
            minutesFailed: { L("livetranslate.record.doc.minutesFailed \($0)") },
            minutesNoModel: L("livetranslate.record.doc.minutesNoModel"),
            minutesTooShort: L("livetranslate.record.doc.minutesTooShort"),
            minutesInterrupted: L("livetranslate.record.doc.minutesInterrupted"),
            locale: L10n.locale)
    }
}

// MARK: - 会议的文档（会话经 MeetingSessionLibrary.makeTranscript 拿到，docs/meeting/ENGINE.md §4.5.2）

extension MeetingTranscript: MeetingTranscriptWriting {}

// MARK: - 自由听译的记录（会议库经 FreeListeningLibrary 开出来交给引擎，docs/meeting/ENGINE.md §4.5.3）

extension MeetingTranscript: FreeListeningRecord {
    /// 「停止后整理纪要」由引擎在收尾时现读、交进来（原来是这里自己读 `livetranslate.record.summary`）。
    func finish(at time: Date, terminating: Bool, summarizes: Bool) {
        spec.summarizes = summarizes
        finish(at: time, terminating: terminating)
    }
}
