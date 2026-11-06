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

    /// 打开记录文件夹（还没有就先建）。建目录放后台：第一次碰「文稿」时系统会弹授权框，别卡住主线程。
    static func openFolder() {
        let url = folder
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// 一次实时翻译的本地记录（Markdown）：开头是时间、音源、语言，然后「纪要」（停止后由本地 AI 整理），
/// 最后逐句的时间 + 原文 + 译文。
///
/// 说完（定稿）的句子就记下；内存里留整份，有变化时至多 1 秒后整份重写一次（原子写），中途崩溃最多丢最后 1 秒。
/// 一句都没有就不建文件。改设置引起的重启接着写同一份，并记一行「改为：…」。
@MainActor
final class LiveTranslateTranscript {
    struct Config: Equatable {
        let source: String
        let speech: String
        /// nil = 不翻译。
        let target: String?
    }

    private enum Item {
        case line(time: Date, original: String, translation: String)
        case change(time: Date, config: Config)

        var time: Date {
            switch self {
            case .line(let time, _, _), .change(let time, _): return time
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
    }

    let fileURL: URL
    /// 写盘失败（没授权「文稿」、磁盘满…）时回调一次，字幕条提示。
    var onWriteError: ((String) -> Void)?

    private let start: Date
    private let config: Config
    private var lastConfig: Config
    private var end: Date?
    private var items: [Item] = []
    /// 句子键 → `items` 下标。
    private var lineIndex: [String: Int] = [:]
    private var minutes: Minutes
    private var minutesTask: Task<Void, Never>?
    private var writeScheduled = false
    private var writeErrorShown = false

    private static let ioQueue = DispatchQueue(label: "com.baobox.app.livetranslate.transcript", qos: .utility)

    init(start: Date, config: Config) {
        self.start = start
        self.config = config
        lastConfig = config
        minutes = LiveTranslateRecordSettings.summary ? .later : .off
        fileURL = LiveTranslateRecordSettings.folder.appendingPathComponent(Self.fileName(for: start))
    }

    /// 至少记下了一句（才有文件）。
    var hasContent: Bool { !lineIndex.isEmpty }

    /// 记下 / 更新一句。`key` 在这份记录里唯一（重启后句子 id 会从头编，调用方带上第几次运行）。
    func update(key: String, time: Date, original: String, translation: String) {
        if let index = lineIndex[key] {
            if case .line(_, let oldOriginal, let oldTranslation) = items[index],
               oldOriginal == original, oldTranslation == translation { return }
            items[index] = .line(time: time, original: original, translation: translation)
        } else {
            lineIndex[key] = items.count
            items.append(.line(time: time, original: original, translation: translation))
        }
        scheduleWrite()
    }

    /// 改设置后的重启接着写：设置确实变了就记一行「改为：…」。
    func continueWith(_ config: Config, at time: Date) {
        guard config != lastConfig else { return }
        lastConfig = config
        items.append(.change(time: time, config: config))
        scheduleWrite()
    }

    /// 停止：记下结束时间、决定纪要怎么处理，写一次。`terminating` = App 正在退出：同步写，不整理纪要。
    func finish(at time: Date, terminating: Bool) {
        end = time
        if !LiveTranslateRecordSettings.summary {
            minutes = .off
        } else if terminating {
            minutes = .interrupted
        } else if !OfflineTranslator.corrector.isReady {
            minutes = .noModel
        } else if minutesInput.reduce(0, { $0 + $1.text.count }) < 40 {
            minutes = .tooShort
        } else {
            minutes = .generating
        }
        writeNow(sync: terminating)
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
    }

    // MARK: - 纪要

    private var minutesInput: [LiveTranslateMinutes.Line] {
        items.compactMap { item in
            guard case .line(let time, let original, _) = item else { return nil }
            return LiveTranslateMinutes.Line(time: time, text: original)
        }
        .sorted { $0.time < $1.time }
    }

    /// 后台整理；任务强持有本对象，开了下一次实时翻译也照样写完。
    private func generateMinutes() {
        let lines = minutesInput
        let chinese = L10n.locale.identifier.hasPrefix("zh")
        OfflineTranslator.corrector.beginKeepAlive()
        minutesTask = Task {
            let result: Minutes
            do {
                result = .done(try await LiveTranslateMinutes.generate(lines: lines, chinese: chinese))
            } catch is CancellationError {
                result = .interrupted
            } catch {
                LiveTranslateLog.transcript.error("minutes failed: \(error.localizedDescription, privacy: .public)")
                result = .failed(error.localizedDescription)
            }
            OfflineTranslator.corrector.endKeepAlive()
            minutesTask = nil
            guard case .generating = minutes else { return }
            minutes = result
            writeNow(sync: false)
            if case .done = result {
                Self.notifyMinutesReady(fileName: fileURL.lastPathComponent)
            }
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
        // 按时间排（同一时刻按记下的先后）：重启前后、改判语言后补记的句子都落在该在的位置。
        let order = items.indices.sorted { lhs, rhs in
            let left = items[lhs].time
            let right = items[rhs].time
            return left != right ? left < right : lhs < rhs
        }
        for index in order {
            switch items[index] {
            case .line(let time, let original, let translation):
                out += "**\(Self.format(time, "HH:mm:ss"))** \(original)\n"
                if !translation.isEmpty {
                    out += "> \(translation)\n"
                }
                out += "\n"
            case .change(let time, let config):
                let changed = L("livetranslate.record.doc.changed \(Self.format(time, "HH:mm:ss")) \(config.source) \(Self.languages(config))")
                out += "*\(changed)*\n\n"
            }
        }
        return out
    }

    private var minutesText: String? {
        switch minutes {
        case .off: return nil
        case .later: return L("livetranslate.record.doc.minutesLater")
        case .generating: return L("livetranslate.record.doc.minutesGenerating")
        case .done(let text): return text
        case .failed(let message): return L("livetranslate.record.doc.minutesFailed \(message)")
        case .noModel: return L("livetranslate.record.doc.minutesNoModel")
        case .tooShort: return L("livetranslate.record.doc.minutesTooShort")
        case .interrupted: return L("livetranslate.record.doc.minutesInterrupted")
        }
    }

    private static func languages(_ config: Config) -> String {
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
    }

    enum Failure: LocalizedError {
        case empty

        var errorDescription: String? { L("livetranslate.record.doc.minutesEmpty") }
    }

    /// 每次喂给模型的记录最多这么多 token（估算），给提示词和输出留余量。
    private static let inputBudget = 2200

    @MainActor
    static func generate(lines: [Line], chinese: Bool) async throws -> String {
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
        OfflinePrompt.clean(try await OfflineTranslator.corrector.respond(to: prompt, maxTokens: maxTokens,
                                                                          sampling: .summary))
    }

    /// 按行凑段，每段不超过 `inputBudget`。
    static func chunk(_ rows: [String]) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for row in rows {
            let cost = tokens(row) + 1
            if size + cost > inputBudget, !current.isEmpty {
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
    static func fit(_ notes: [String], chinese: Bool) -> String {
        let limit = max(120, inputBudget / max(1, notes.count))
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
}
