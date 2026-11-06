import AVFoundation
import Foundation
import os
import Speech

/// 双识别器：两种语言的 `SFSpeechRecognizer` 同时听同一路音频、共用同一套切段，
/// 每句结束后按打分挑一种语言作为这一句的定稿。见 docs/translation-engine/DESIGN.md §3.2。
///
/// 语音识别必须先指定语言、系统没有语种识别 —— 这是「自动识别说的是哪种语言」的曲线救国。
///
/// 自愈（§3.3）：某一路的任务出错就不再给它喂音频；有人在说话却连续几秒没有任何识别结果 →
/// 判定卡死，重建识别器重新开段（退避重试）；某一路反复刚开就出错 → 停用这一路并提示。
@MainActor
final class LiveTranslateDualRecognizer: LiveTranslateRecognizer {
    var onUpdate: ((Int, String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onLanguage: ((Int, TranslationLanguage) -> Void)?
    /// 各路此刻实际的识别方式（本机 / 服务器 / 停用），变了才报（字幕条状态行用）。
    var onRouting: (([LiveTranslateChannelState]) -> Void)?

    /// 一路识别（一种语言）。
    private final class Channel {
        let language: TranslationLanguage
        var recognizer: SFSpeechRecognizer
        /// 当前段的请求；这一路在当前段收尾 / 出错后置 nil（不再喂音频）。
        var request: SFSpeechAudioBufferRecognitionRequest?
        /// 当前段这一路已收尾（final / 出错），不再有新结果。
        var segmentEnded = false
        /// 连续「刚开就出错、没有任何文字」的段数，到 3 停用这一路。
        var quickFailures = 0
        var alive = true

        init(language: TranslationLanguage, recognizer: SFSpeechRecognizer) {
            self.language = language
            self.recognizer = recognizer
        }
    }

    /// 一段（一句）的收集状态。
    private struct Segment {
        /// 参与这一段的通道。
        let expected: Set<Int>
        var tasks: [SFSpeechRecognitionTask] = []
        /// 每路最新的 partial（final 没来时兜底用）与更新时间。
        var partials: [Int: String] = [:]
        var updatedAt: [Int: Date] = [:]
        /// 每路的定稿与得分。
        var results: [Int: (text: String, score: Double)] = [:]
        /// 已切走：最晚等到这个时间就用手头的结果定稿。
        var deadline: Date?
    }

    private let channels: [Channel]
    private let router: LiveTranslateAudioRouter
    private let gate = LiveTranslateAudioGate()
    /// 切段交接中：当前段已 endAudio、正等两路的 final（最多 `finalWait`），下一段还没开，音频由闸门攒着。
    private var handingOff = false
    private var watchdog: Timer?
    private var running = false
    /// `flush()` 在等最后一段两路的 final：定稿了（或等超时）就放行，不再开新段。
    private var flushGate: LiveTranslateOnceGate?

    private var segmentID = 0
    private var segments: [Int: Segment] = [:]
    private var segmentStart = Date()
    /// 当前段文字最近一次**变化**的时间（判断停顿用）。
    private var lastChange = Date()
    /// 当前段最近一次收到任何文字的时间（判断卡死用）。
    private var lastResultAt = Date()
    private var segmentHasText = false
    /// partial 优先显示哪一路：上一句胜出的那种语言（说话人通常连着说同一种）。
    private var leader = 0
    /// 连续卡死重启的次数（有文字回来就清零），用于退避。
    private var restartStreak = 0
    private var stall = LiveTranslateStallClock()
    /// 上次记进日志的「哪一路本机、哪一路走服务器」，变了才再记。
    private var loggedRouting: String?

    /// 每段最多持续多久（秒），防触到识别请求的时长上限。
    private static let maxSegmentDuration: TimeInterval = 45
    /// 两路文字都多久没变化视为一句说完（秒）。
    private static let pauseThreshold: TimeInterval = 1.2
    /// 切段后最多等两路 final 多久（秒）。
    private static let finalWait: TimeInterval = 1.2
    /// 有人在说话、却这么久没有任何识别结果 → 判定卡死（秒；连续卡死按 2 倍退避，封顶 60）。
    private static let stallTimeout: TimeInterval = 6

    /// 两种语言的识别器都可用、且最多一种装了本机模型才建得起来，否则返回 nil。
    ///
    /// 系统的本机识别同一时间只能跑一路：两路都在本机时，后开的会把先开的挤掉（先开那路的录音一开就
    /// `speechRecordingDidFail 1101`、随后以 1110 结束）；而且只要装了本机模型就一定走本机，App 没法让它走服务器
    /// （`requiresOnDeviceRecognition = false` 挡不住，`supportsOnDeviceRecognition` 设成 false 会被改回来，实测 2026-11-05）。
    /// 所以这里只处理「一路本机 + 一路服务器」（用户的选择：中文本机、美式英文走云端 —— 要先删掉英文本机模型）；
    /// 两种都装了本机模型时由调用方改用轮流识别（`LiveTranslateSwitchingRecognizer`）。
    init?(languages: [TranslationLanguage], router: LiveTranslateAudioRouter) {
        var built: [Channel] = []
        for language in languages {
            guard let recognizer = Self.makeRecognizer(for: language), recognizer.isAvailable else { continue }
            built.append(Channel(language: language, recognizer: recognizer))
        }
        guard built.count == 2, built.filter({ $0.recognizer.supportsOnDeviceRecognition }).count <= 1 else { return nil }
        channels = built
        self.router = router
    }

    private static func makeRecognizer(for language: TranslationLanguage) -> SFSpeechRecognizer? {
        guard let localeID = language.speechLocale else { return nil }
        return SFSpeechRecognizer(locale: Locale(identifier: localeID))
    }

    func start() async throws {
        running = true
        LiveTranslateLog.recognition.info(
            "dual recognizer start: \(self.channels.map(\.language.code).joined(separator: "+"), privacy: .public)")
        router.setSink(gate.sink)
        beginSegment()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    func stop() {
        running = false
        watchdog?.invalidate()
        watchdog = nil
        router.setSink(nil)
        gate.clear()
        handingOff = false
        for channel in channels {
            channel.request?.endAudio()
            channel.request = nil
        }
        for segment in segments.values {
            segment.tasks.forEach { $0.cancel() }
        }
        segments = [:]
        flushGate?.open()
        flushGate = nil
    }

    /// 收尾：当前段有字就照切段那样 endAudio、等两路的 final（最多 `finalWait`，到点由看门狗定稿）；交接中就等交接完；
    /// 没字时只把之前还在等 final 的段按手头结果定稿。之后不再开新段。
    func flush() async {
        guard running, flushGate == nil else { return }
        guard handingOff || segmentHasText else {
            decideOlderSegments()
            return
        }
        let flushing = LiveTranslateOnceGate()
        flushGate = flushing
        if !handingOff {
            rollSegment()
        }
        await flushing.wait()
    }

    /// 之前切走、还在等 final 的段：按手头的结果定稿。
    private func decideOlderSegments() {
        for id in segments.keys.sorted() where id != segmentID {
            decide(id)
        }
    }

    // MARK: - 切段

    private func beginSegment() {
        segmentID += 1
        let id = segmentID
        segmentStart = Date()
        lastChange = segmentStart
        lastResultAt = segmentStart
        segmentHasText = false
        stall.reset()

        var segment = Segment(expected: Set(channels.indices.filter { channels[$0].alive }))
        // 专有名词每段现读：设置里改完，下一句起生效。
        let hints = LiveTranslateSettings.vocabulary
        let onDeviceIndex = onDeviceChannel()
        logRouting(onDeviceIndex: onDeviceIndex)
        for index in channels.indices where channels[index].alive {
            let channel = channels[index]
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true
            request.contextualStrings = hints
            request.requiresOnDeviceRecognition = index == onDeviceIndex
            channel.request = request
            channel.segmentEnded = false
            let task = channel.recognizer.recognitionTask(with: request) { [weak self] result, error in
                // 回调线程不定：只取出值类型再回主线程。
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let confidence = LiveTranslateScoring.averageConfidence(result)
                let failure = (error as NSError?).map { "\($0.domain) \($0.code)" }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handle(segment: id, channel: index, text: text, isFinal: isFinal,
                                     confidence: confidence, failure: failure)
                    }
                }
            }
            segment.tasks.append(task)
        }
        segments[id] = segment
        refreshSink()
    }

    /// 哪一路用本机识别：装了本机模型的那一路（最多一路，见 init）。
    private func onDeviceChannel() -> Int? {
        guard LiveTranslateSettings.preferOnDevice else { return nil }
        return channels.indices.first { channels[$0].alive && channels[$0].recognizer.supportsOnDeviceRecognition }
    }

    private func logRouting(onDeviceIndex: Int?) {
        let routing = channels.indices.map { index -> String in
            let channel = channels[index]
            let mode = !channel.alive ? "disabled" : (channel.recognizer.supportsOnDeviceRecognition ? "on-device" : "server")
            return "\(channel.language.code) \(mode) (\(channel.recognizer.locale.identifier))"
        }.joined(separator: ", ")
        guard routing != loggedRouting else { return }
        loggedRouting = routing
        LiveTranslateLog.recognition.notice("dual routing: \(routing, privacy: .public)")
        reportRouting()
    }

    /// 装了本机模型的那路就是本机（不要求本机也一样，见 init 的说明）。
    private func reportRouting() {
        onRouting?(channels.map { channel in
            let mode: LiveTranslateChannelState.Mode = !channel.alive
                ? .disabled : (channel.recognizer.supportsOnDeviceRecognition ? .onDevice : .server)
            return LiveTranslateChannelState(language: channel.language, mode: mode)
        })
    }

    /// 音频只喂给当前段里还在工作的那几路（出错 / 收尾的那一路不再喂）；同一块 PCM 同时喂给各路。
    /// 交接中由闸门攒着，不动。
    private func refreshSink() {
        guard !handingOff else { return }
        gate.forward(to: channels.compactMap(\.request))
    }

    /// 结束当前段：先等两路把 final 回完（最多 `finalWait`）再开下一段，其间音频由闸门攒着。
    /// 不能边等边开新段 —— 新请求会把还没回 final 的旧请求掐掉（见 `LiveTranslateAudioGate`）。
    private func rollSegment() {
        guard !handingOff else { return }
        handingOff = true
        gate.hold()
        let id = segmentID
        for channel in channels {
            channel.request?.endAudio()
            channel.request = nil
        }
        segments[id]?.deadline = Date().addingTimeInterval(Self.finalWait)
        if let segment = segments[id], segment.expected.isSubset(of: Set(segment.results.keys)) {
            finishHandoff()
        }
    }

    /// 两路的 final 都回来了（或等超时）：定稿这一段，开下一段（闸门把攒下的音频补喂进去）。
    private func finishHandoff() {
        guard handingOff else { return }
        decide(segmentID)
        handingOff = false
        // 收尾中：最后一句定稿了，不再开新段。
        if let flushGate {
            self.flushGate = nil
            decideOlderSegments()
            flushGate.open()
            return
        }
        guard running else { return }
        beginSegment()
    }

    // MARK: - 结果

    private func handle(segment id: Int, channel index: Int, text: String?, isFinal: Bool,
                        confidence: Double, failure: String?) {
        guard running, segments[id] != nil else { return }
        let channel = channels[index]
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let failed = failure != nil
        let ended = isFinal || failed
        if let failure {
            LiveTranslateLog.recognition.error(
                "\(channel.language.code, privacy: .public) segment \(id) ended with error: \(failure, privacy: .public)")
        }

        let previous = segments[id]?.partials[index]
        if !trimmed.isEmpty {
            segments[id]?.partials[index] = trimmed
            segments[id]?.updatedAt[index] = Date()
        }

        if id == segmentID {
            if !trimmed.isEmpty {
                lastResultAt = Date()
                segmentHasText = true
                channel.quickFailures = 0
                restartStreak = 0
                stall.reset()
                if trimmed != previous { lastChange = Date() }
            }
            if ended {
                channel.segmentEnded = true
                channel.request = nil
                refreshSink()
                // 刚开就出错、没有任何文字：多半是这一路用不了（听写被关、服务不可用、请求超限）。
                if failed, trimmed.isEmpty, Date().timeIntervalSince(segmentStart) < 1 {
                    channel.quickFailures += 1
                    if channel.quickFailures >= 3 {
                        disable(index)
                        guard running else { return }
                    }
                }
            } else if !trimmed.isEmpty {
                emitPartial(id)
            }
        }

        guard ended else { return }
        segments[id]?.results[index] = (trimmed, LiveTranslateScoring.score(text: trimmed, confidence: confidence,
                                                             language: channel.language))
        guard let segment = segments[id] else { return }
        let allIn = segment.expected.isSubset(of: Set(segment.results.keys))
        if id == segmentID {
            // 交接中两路都回完了 → 开下一段；没在交接却都被系统收尾了（如长时间没说话超时）→ 直接切段。
            if allIn {
                if handingOff { finishHandoff() } else { rollSegment() }
            }
        } else if allIn {
            decide(id)
        }
    }

    /// 当前段的 partial：只看还在工作的那几路；优先 leader，否则取最近更新的一路。
    /// （已出错的那一路留下的旧文字不能再显示，否则字幕看起来就「卡住」了。）
    private func emitPartial(_ id: Int) {
        guard let segment = segments[id] else { return }
        let active = channels.indices.filter { !channels[$0].segmentEnded && !(segment.partials[$0] ?? "").isEmpty }
        guard !active.isEmpty else { return }
        // 文字系统对得上自己语言的那几路优先（中文识别器听英文吐出的英文单词不显示）。
        let fitting = active.filter { channels[$0].language.scriptRatio(of: segment.partials[$0] ?? "") >= 0.5 }
        let pool = fitting.isEmpty ? active : fitting
        let chosen = pool.contains(leader)
            ? leader
            : pool.max { (segment.updatedAt[$0] ?? .distantPast) < (segment.updatedAt[$1] ?? .distantPast) } ?? leader
        guard let text = segment.partials[chosen] else { return }
        onLanguage?(id, language(of: text, recognizedBy: chosen))
        onUpdate?(id, text, false)
    }

    /// 这段文字实际是哪种语言。多数时候就是识别它的那一路；但中文识别器听到英文时会直接吐出英文单词
    /// （它本来就支持中英混说），这时按文字系统改判成另一路的语言 —— 否则英文会被当成中文、再「译成英文」
    /// （实测 2026-11-05：英文视频的字幕原文是乱的英文、译文也是英文）。
    private func language(of text: String, recognizedBy index: Int) -> TranslationLanguage {
        let own = channels[index].language
        guard own.scriptRatio(of: text) < 0.3 else { return own }
        let others = channels.indices.filter { $0 != index }.map { channels[$0].language }
        if let better = others.max(by: { $0.scriptRatio(of: text) < $1.scriptRatio(of: text) }),
           better.scriptRatio(of: text) > 0.6 {
            return better
        }
        return own
    }

    /// 定稿：两路里得分高的那一路胜出；没有 final 的一路用它最后的 partial 低分兜底。
    private func decide(_ id: Int) {
        guard let segment = segments.removeValue(forKey: id) else { return }
        segment.tasks.forEach { $0.cancel() }
        var best: (index: Int, text: String, score: Double)?
        for index in segment.expected {
            var candidate: (text: String, score: Double)?
            if let result = segment.results[index], !result.text.isEmpty {
                candidate = result
            } else if let partial = segment.partials[index], !partial.isEmpty {
                candidate = (partial, 0.2 * channels[index].language.scriptRatio(of: partial))
            }
            guard let candidate else { continue }
            if let current = best, current.score >= candidate.score { continue }
            best = (index, candidate.text, candidate.score)
        }
        guard let best else { return }
        leader = best.index
        onLanguage?(id, language(of: best.text, recognizedBy: best.index))
        onUpdate?(id, best.text, true)
    }

    /// 停用反复出错的一路；两路都停了就按不可恢复处理。
    private func disable(_ index: Int) {
        let channel = channels[index]
        guard channel.alive else { return }
        channel.alive = false
        LiveTranslateLog.recognition.error("disabling \(channel.language.code, privacy: .public) after repeated failures")
        loggedRouting = nil
        reportRouting()
        if let other = channels.first(where: { $0.alive }) {
            onStatus?(L("livetranslate.notice.channelDisabled \(channel.language.endonym) \(other.language.endonym)"))
        } else {
            stop()
            onFailure?(L("livetranslate.alert.unavailableMessage"))
        }
    }

    /// 有人在说话却一直没有识别结果：系统识别服务的连接坏了也不会回调我们（实测会在进程里刷海量
    /// kAFAssistantErrorDomain 1101 而不出字）。收掉所有段、重建识别器对象、重新开段；停用的一路也再给一次机会。
    private func restartAfterStall(silentFor: TimeInterval) {
        restartStreak += 1
        LiveTranslateLog.recognition.error(
            "watchdog: \(Int(self.stall.voiced))s of voice but no results (\(Int(silentFor))s since last result), restarting recognizers (streak \(self.restartStreak))")
        handingOff = false
        for id in segments.keys.sorted() {
            decide(id)
        }
        for channel in channels {
            channel.request?.endAudio()
            channel.request = nil
            channel.quickFailures = 0
            channel.alive = true
            if let fresh = SFSpeechRecognizer(locale: channel.recognizer.locale) {
                channel.recognizer = fresh
            }
        }
        beginSegment()
    }

    /// 停顿或段过长 → 切段（只在当前段已有文字时切）；旧段等 final 超时 → 用手头结果定稿；
    /// 有声音却长时间没结果 → 卡死重启。
    private func tick() {
        guard running else { return }
        let now = Date()
        if handingOff {
            if (segments[segmentID]?.deadline).map({ now >= $0 }) ?? true { finishHandoff() }
            return
        }
        for (id, segment) in segments where id != segmentID {
            if let deadline = segment.deadline, now >= deadline {
                decide(id)
            }
        }
        // 只数有人声的时间（`LiveTranslateStallClock`）：停顿、朗读暂停识别的时间不算。
        stall.tick(now: now, lastVoice: router.lastVoiceDate)
        let timeout = min(Self.stallTimeout * Double(1 << min(restartStreak, 4)), 60)
        if stall.voiced > timeout {
            restartAfterStall(silentFor: now.timeIntervalSince(lastResultAt))
            return
        }
        guard segmentHasText else { return }
        if now.timeIntervalSince(lastChange) > Self.pauseThreshold
            || now.timeIntervalSince(segmentStart) > Self.maxSegmentDuration {
            rollSegment()
        }
    }
}
