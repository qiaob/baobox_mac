import AVFoundation
import Foundation
import os
import Speech

/// 实时翻译的诊断日志。排查：
/// `/usr/bin/log show --last 1h --predicate 'subsystem == "com.baobox.app" AND category BEGINSWITH "livetranslate"'`
enum LiveTranslateLog {
    static let recognition = Logger(subsystem: "com.baobox.app", category: "livetranslate.recognition")
    static let audio = Logger(subsystem: "com.baobox.app", category: "livetranslate.audio")
    static let transcript = Logger(subsystem: "com.baobox.app", category: "livetranslate.transcript")
}

/// 识别看门狗的计时：只数「有人在说、音频也真的送进识别器了」的时间（音频路由在朗读暂停识别时不更新 lastVoice）。
///
/// 以前按「距上次出字多久」算：停顿超过 6 秒（想事情、等朗读读完）后一开口，第一下就被判成卡死、重启识别器，
/// 刚说的头几个字跟着被扔掉（2026-11-05 日志：每次长停顿后都有一次 streak 1 重启，用户感觉「偶尔识别不到」）。
struct LiveTranslateStallClock {
    /// 自上次出字（或开段）以来，有人声的累计秒数。
    private(set) var voiced: TimeInterval = 0
    private var lastTick: Date?

    /// 看门狗每一拍调：最近 0.5 秒内有人声，就把这一拍记上（一拍最多记 0.5 秒，交接期间没拍也不会多算）。
    mutating func tick(now: Date, lastVoice: Date) {
        defer { lastTick = now }
        guard let lastTick, now.timeIntervalSince(lastVoice) < 0.5 else { return }
        voiced += min(now.timeIntervalSince(lastTick), 0.5)
    }

    /// 出字了 / 开了新段：清零。
    mutating func reset() {
        voiced = 0
    }
}

/// 切段交接用的音频闸门（音频路由的接收端）。
///
/// 系统的听写服务同一时间只服务一个请求：旧段 endAudio 后、final 还没回来时就开新段，新请求会把旧请求
/// 掐掉（本机识别以 1110、服务器以 209 结束，实测 2026-11-05），这一句的定稿结果（带纠错和标点）就丢了，
/// 字幕和「这句是哪种语言」都只能靠粗糙的 partial。所以切段时先 `hold()`：旧段等 final 期间音频攒着；
/// 新段开出来后 `forward(to:)` 先按顺序补喂攒下的，再接着直通 —— 一个字也不丢。
///
/// @unchecked Sendable 依据：可变状态都在 `lock` 内；`append` 在音频线程调用，其余在主线程。
final class LiveTranslateAudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    /// 直通时顺便录一份（「自动」模式要拿这一句的录音给另一种语言重认）。
    private var recorder: LiveTranslateSegmentRecorder?
    private var holding = false
    private var held: [AVAudioPCMBuffer] = []
    private var heldFrames: AVAudioFramePosition = 0
    /// 最多攒多少帧（约 15 秒 @48kHz），再多丢最早的 —— 正常交接不到 2 秒，只防意外。
    private static let maxHeldFrames: AVAudioFramePosition = 48_000 * 15

    /// 装给音频路由的接收端。在本类（无 actor 隔离）里造闭包，免得被推断成主线程隔离 —— 它在音频线程上调。
    var sink: LiveTranslateAudioRouter.Sink {
        { [self] buffer in append(buffer) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard holding else {
            for request in requests {
                request.append(buffer)
            }
            recorder?.add(buffer)
            return
        }
        // 音源回调给的缓冲区之后可能被复用，攒的时候拷一份。
        guard let copy = Self.copy(buffer) else { return }
        held.append(copy)
        heldFrames += AVAudioFramePosition(copy.frameLength)
        while heldFrames > Self.maxHeldFrames, !held.isEmpty {
            heldFrames -= AVAudioFramePosition(held.removeFirst().frameLength)
        }
    }

    /// 开始攒音频：旧段已 endAudio、新段还没开。
    func hold() {
        lock.lock()
        holding = true
        requests = []
        recorder = nil
        lock.unlock()
    }

    /// 换成这一组请求：交接中攒下的先按顺序补喂（也录进 `recorder`），然后直通。
    func forward(to requests: [SFSpeechAudioBufferRecognitionRequest], recorder: LiveTranslateSegmentRecorder? = nil) {
        lock.lock()
        for buffer in held {
            for request in requests {
                request.append(buffer)
            }
            recorder?.add(buffer)
        }
        held = []
        heldFrames = 0
        holding = false
        self.requests = requests
        self.recorder = recorder
        lock.unlock()
    }

    func clear() {
        lock.lock()
        requests = []
        recorder = nil
        held = []
        heldFrames = 0
        holding = false
        lock.unlock()
    }

    /// 深拷贝一块 PCM（音源回调给的缓冲区之后可能被复用，要留着用就得拷）。
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

/// 一句话的录音（拷贝）：「自动」模式下当前识别器认得不像这种语言时，拿它给另一种语言的识别器重认。
/// @unchecked Sendable 依据：可变状态都在 `lock` 内；`add` 在音频线程（经闸门）调用，其余在主线程。
final class LiveTranslateSegmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var frames: AVAudioFramePosition = 0
    /// 约 50 秒 @48kHz（一段最长 45 秒），再多丢最早的。
    private static let maxFrames: AVAudioFramePosition = 48_000 * 50

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let copy = LiveTranslateAudioGate.copy(buffer) else { return }
        lock.lock()
        buffers.append(copy)
        frames += AVAudioFramePosition(copy.frameLength)
        while frames > Self.maxFrames, !buffers.isEmpty {
            frames -= AVAudioFramePosition(buffers.removeFirst().frameLength)
        }
        lock.unlock()
    }

    /// 取走录到的全部，并清空。
    func take() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        let taken = buffers
        buffers = []
        frames = 0
        return taken
    }

    /// 录音时长（秒）。
    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let rate = buffers.first?.format.sampleRate, rate > 0 else { return 0 }
        return Double(frames) / rate
    }
}

/// 「自动」模式判语种的打分（双识别器、轮流识别器共用）。
enum LiveTranslateScoring {
    /// 平均置信度 ×（0.15 + 0.85 × 文字系统吻合度）。中文识别器听到英文会吐出英文单词、
    /// 英文识别器听到中文时置信度很低 —— 两者叠加足以分开中英这类差别大的语言。文字系统对不上时
    /// 只留 0.15 的底：原先留 0.5，中文识别器对英文视频吐出的乱码英文常常比英文那路的分还高（实测 2026-11-05）。
    ///
    /// `voiced`（这一句有人声的秒数，≥ 1.2 秒才看）：再乘上字数密度（封顶 1、保底 0.1）—— 英文识别器听中文常常只吐
    /// 一两个短词（"You"、"I"），置信度还挺高，光看置信度和文字系统分不出来（实测 2026-11-05：切到英文后再也切不回中文）。
    static func score(text: String, confidence: Double, language: TranslationLanguage, voiced: TimeInterval = 0) -> Double {
        guard !text.isEmpty else { return -1 }
        // 少数结果不带置信度（为 0），给个中性值，主要靠文字系统区分。
        let base = confidence > 0 ? confidence : 0.3
        var score = base * (0.15 + 0.85 * language.scriptRatio(of: text))
        if voiced >= 1.2 {
            score *= min(1, max(0.1, density(text: text, voiced: voiced, language: language)))
        }
        return score
    }

    /// 字数密度相对「最慢的正常语速」的比例（1 = 刚好够）：中文每秒 1.5 字、英文等每秒 1 个词 —— 远低于正常语速，
    /// 只为抓「说了好几秒、却几乎没出字」。
    static func density(text: String, voiced: TimeInterval, language: TranslationLanguage) -> Double {
        guard voiced > 0 else { return 1 }
        let cjk = language.isChinese || language.code == "ja" || language.code == "ko"
        return Double(units(text, cjk: cjk)) / (voiced * (cjk ? 1.5 : 1.0))
    }

    /// 字 / 词数：中日韩一个字一个；拉丁字母连成的一个词算一个。
    static func units(_ text: String, cjk: Bool) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if cjk, scalar.properties.isIdeographic || (0x3040...0x30FF).contains(value) || (0xAC00...0xD7AF).contains(value) {
                count += 1
                inWord = false
            } else if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                if !inWord { count += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return count
    }

    /// final 结果才有置信度（partial 全是 0）。
    nonisolated static func averageConfidence(_ result: SFSpeechRecognitionResult?) -> Double {
        guard let segments = result?.bestTranscription.segments, !segments.isEmpty else { return 0 }
        let total = segments.reduce(0.0) { $0 + Double($1.confidence) }
        return total / Double(segments.count)
    }
}

/// 识别引擎：把音频路由里的 PCM 变成一句句文字。见 docs/live-translate/DESIGN.md §3。
///
/// `onUpdate(id, text, isFinal)`：id 单调递增；同一 id 的多次回调是同一句的改写，isFinal 后不再变。
@MainActor
protocol LiveTranslateRecognizer: AnyObject {
    var onUpdate: ((Int, String, Bool) -> Void)? { get set }
    /// 不可恢复的失败（已自行停止）。
    var onFailure: ((String) -> Void)? { get set }
    /// 状态提示（如正在下载语音模型）；nil = 清除。
    var onStatus: ((String?) -> Void)? { get set }
    /// 某一句是哪种语言（只有双识别器报告；单识别器每句都是设置里那种）。在该句的 onUpdate 之前调用。
    var onLanguage: ((Int, TranslationLanguage) -> Void)? { get set }
    func start() async throws
    func stop()
    /// 收尾（`LiveTranslateController.finish`，docs/meeting/TECH_DESIGN.md §2.1）：不再收音频、不再开新段，
    /// 把手头这一句送去定稿，定稿经 `onUpdate(…, true)` 回调后返回。调用方限时等（最多 1.5 秒），到点直接 `stop()` ——
    /// `stop()` 也会让这里返回。默认什么也不等（到点按 `stop` 的老办法收尾）。
    func flush() async
}

extension LiveTranslateRecognizer {
    func flush() async {}
}

/// 只放行一次的闸门：`wait()` 一直等到有人 `open()`（定稿回来了 / 超时 / 停止）；先 `open()` 后 `wait()` 立刻返回，
/// 多次 `open()` 只算第一次。
/// @unchecked Sendable 依据：可变状态都在 `lock` 内。
final class LiveTranslateOnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}

// MARK: - macOS 26+：SpeechAnalyzer

#if compiler(>=6.2)
/// 新一代本地识别（SpeechAnalyzer + SpeechTranscriber）：为长音频设计，
/// 一路流到底不用切段（上下文不丢，准确率更高），volatile 结果出字更快。
@available(macOS 26.0, *)
@MainActor
final class LiveTranslateAnalyzerRecognizer: LiveTranslateRecognizer {
    var onUpdate: ((Int, String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onLanguage: ((Int, TranslationLanguage) -> Void)?

    private let locale: Locale
    private let router: LiveTranslateAudioRouter
    private let vocabulary: [String]
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var running = false
    private var lineID = 1

    init(locale: Locale, router: LiveTranslateAudioRouter, vocabulary: [String]) {
        self.locale = locale
        self.router = router
        self.vocabulary = vocabulary
    }

    static func supports(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
    }

    func start() async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LiveTranslateError.languageUnsupported
        }
        let transcriber = SpeechTranscriber(locale: supported,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])

        // 本机还没有该语言的模型 → 系统下载（一次性）。
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onStatus?(L("livetranslate.notice.downloadingModel"))
            try await request.downloadAndInstall()
            onStatus?(nil)
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveTranslateError.languageUnsupported
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            // 词表只是加分项，设置失败照常识别。
            try? await analyzer.setContext(context)
        }

        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        let converter = LiveTranslatePCMConverter(outputFormat: format)
        router.setSink { buffer in
            if let converted = converter.convert(buffer) {
                builder.yield(AnalyzerInput(buffer: converted))
            }
        }

        running = true
        self.analyzer = analyzer
        inputBuilder = builder
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.deliver(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                self?.fail(error)
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        running = false
        router.setSink(nil)
        inputBuilder?.finish()
        inputBuilder = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        analyzer = nil
    }

    /// 收尾：不再送音频，让识别器把手头没定稿的那句定稿后结束（结果照常经 `deliver` 回调），等结果流走完。
    /// 调用方限时等，到点 `stop()`。
    func flush() async {
        guard running, let analyzer else { return }
        router.setSink(nil)
        inputBuilder?.finish()
        inputBuilder = nil
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }

    private func deliver(text: String, isFinal: Bool) {
        guard running else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onUpdate?(lineID, trimmed, isFinal)
        if isFinal { lineID += 1 }
    }

    private func fail(_ error: Error) {
        guard running, !Task.isCancelled else { return }
        stop()
        onFailure?(error.localizedDescription)
    }
}
#endif

// MARK: - macOS 14–15：SFSpeechRecognizer（分段）

/// 旧接口单个请求有时长上限、且一句话说完前会反复改写，所以按段识别：
/// 停顿 1.2s 或满 45s 切段，旧段 endAudio 后继续回传 final，新段立刻接上。
@MainActor
final class LiveTranslateLegacyRecognizer: LiveTranslateRecognizer {
    var onUpdate: ((Int, String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onLanguage: ((Int, TranslationLanguage) -> Void)?

    private var recognizer: SFSpeechRecognizer
    private let router: LiveTranslateAudioRouter
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let gate = LiveTranslateAudioGate()
    /// 切段交接中：旧段已 endAudio、正等它的 final（最多 `finalWait`），新段还没开，音频由闸门攒着。
    private var handoffDeadline: Date?
    private var watchdog: Timer?
    private var running = false
    /// `flush()` 在等这一段的 final：回来了（或交接等超时）就放行，不再开新段。
    private var flushGate: LiveTranslateOnceGate?

    private var segmentID = 0
    private var segmentStart = Date()
    private var lastChange = Date()
    private var segmentHasText = false
    /// 连续「刚开就出错、没有任何文字」的段数，到 3 判定不可恢复。
    private var quickFailures = 0
    /// 最近一次收到文字的时间、连续卡死重启次数（看门狗用，见 tick）。
    private var lastTextAt = Date()
    private var restartStreak = 0
    private var stall = LiveTranslateStallClock()
    /// 这一段的统计（段结束时记一行日志，排查「识别不到」用）。
    private var segmentResults = 0
    private var segmentFirstText: TimeInterval?
    private var segmentEndReason = "final"
    /// 有人在说话、却这么久没有任何识别结果 → 判定卡死（秒；连续卡死按 2 倍退避，封顶 60）。
    private static let stallTimeout: TimeInterval = 6

    /// 每段最多持续多久（秒），防触到识别请求的时长上限。
    private static let maxSegmentDuration: TimeInterval = 45
    /// 文字多久没变化视为一句说完（秒）。
    private static let pauseThreshold: TimeInterval = 1.2
    /// 切段时等旧段 final 最多多久（秒）：本机识别通常零点几秒就回，超时就用手头的 partial 定稿。
    private static let finalWait: TimeInterval = 1.2

    init(recognizer: SFSpeechRecognizer, router: LiveTranslateAudioRouter) {
        self.recognizer = recognizer
        self.router = router
    }

    func start() async throws {
        running = true
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
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        handoffDeadline = nil
        flushGate?.open()
        flushGate = nil
    }

    /// 收尾：这一段有字就 endAudio、等它的 final（交接中就等旧段的），没字直接返回。等的期限沿用交接的
    /// `finalWait`，到点由看门狗按超时收尾。
    func flush() async {
        guard running, flushGate == nil, handoffDeadline != nil || segmentHasText else { return }
        let flushing = LiveTranslateOnceGate()
        flushGate = flushing
        if handoffDeadline == nil {
            segmentEndReason = "finish"
            gate.hold()
            request?.endAudio()
            request = nil
            handoffDeadline = Date().addingTimeInterval(Self.finalWait)
        }
        await flushing.wait()
    }

    private func beginSegment() {
        if segmentID > 0 {
            let first = segmentFirstText.map { String(format: "%.1fs", $0) } ?? "none"
            LiveTranslateLog.recognition.notice(
                "segment \(self.segmentID) done (\(self.segmentEndReason, privacy: .public)): \(self.segmentResults) results, first text \(first, privacy: .public), \(Int(Date().timeIntervalSince(self.segmentStart)))s")
        }
        segmentID += 1
        let id = segmentID
        stall.reset()
        segmentResults = 0
        segmentFirstText = nil
        segmentEndReason = "final"

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // 专有名词每段现读：设置里改完，下一句起生效。
        request.contextualStrings = SpeechSettings.vocabulary
        if LiveTranslateSettings.preferOnDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        // 交接中攒下的音频先补喂进新请求，再直通。
        gate.forward(to: [request])
        segmentStart = Date()
        lastChange = Date()
        segmentHasText = false

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // 回调线程不定：只取出值类型再回主线程。
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(segment: id, text: text, isFinal: isFinal, error: error)
                }
            }
        }
    }

    /// 结束当前段：先让旧段把 final 回完（最多 `finalWait`）再开下一段，其间音频由闸门攒着。
    /// 不能边等边开新段 —— 新请求会把还没回 final 的旧请求掐掉（见 `LiveTranslateAudioGate`）。
    private func rollSegment() {
        guard handoffDeadline == nil else { return }
        segmentEndReason = Date().timeIntervalSince(segmentStart) > Self.maxSegmentDuration ? "max length" : "pause"
        gate.hold()
        request?.endAudio()
        request = nil
        handoffDeadline = Date().addingTimeInterval(Self.finalWait)
    }

    /// 旧段的 final 回来了（或等超时）：收掉旧任务，开下一段。
    private func finishHandoff() {
        guard handoffDeadline != nil else { return }
        handoffDeadline = nil
        task?.cancel()
        task = nil
        // 收尾中：最后一句已经回来了，不再开新段。
        if let flushGate {
            self.flushGate = nil
            flushGate.open()
            return
        }
        beginSegment()
    }

    private func handle(segment id: Int, text: String?, isFinal: Bool, error: Error?) {
        guard running else { return }
        let ended = isFinal || error != nil
        if let nsError = error as NSError?, id == segmentID {
            LiveTranslateLog.recognition.error(
                "segment \(id) ended with error: \(nsError.domain, privacy: .public) \(nsError.code)")
            if handoffDeadline == nil { segmentEndReason = "error \(nsError.code)" }
        }
        if let text, !text.isEmpty {
            onUpdate?(id, text, ended)
            if id == segmentID {
                lastChange = Date()
                lastTextAt = Date()
                segmentHasText = true
                quickFailures = 0
                restartStreak = 0
                stall.reset()
                segmentResults += 1
                if segmentFirstText == nil { segmentFirstText = Date().timeIntervalSince(segmentStart) }
            }
        }
        guard id == segmentID, ended else { return }
        if handoffDeadline != nil {
            // 交接中旧段的 final 回来了：接着开下一段。
            finishHandoff()
            return
        }

        // 当前段被系统收尾或出错：判断是否不可恢复，否则接着开下一段。
        if error != nil, !segmentHasText, Date().timeIntervalSince(segmentStart) < 1 {
            quickFailures += 1
            if quickFailures >= 3 {
                let message = error?.localizedDescription ?? ""
                stop()
                onFailure?(message)
                return
            }
        }
        task = nil
        request = nil
        beginSegment()
    }

    /// 卡死重启：收掉当前与上一段的任务、重建识别器对象、重新开段。
    private func restartAfterStall(silentFor: TimeInterval) {
        restartStreak += 1
        LiveTranslateLog.recognition.error(
            "watchdog: \(Int(self.stall.voiced))s of voice but no results (\(Int(silentFor))s since last text), restarting recognizer (streak \(self.restartStreak))")
        segmentEndReason = "watchdog restart"
        handoffDeadline = nil
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if let fresh = SFSpeechRecognizer(locale: recognizer.locale) {
            recognizer = fresh
        }
        beginSegment()
    }

    /// 停顿或段过长 → 切段。只在当前段已有文字时切（没说话就让它一直听着）。
    private func tick() {
        guard running else { return }
        let now = Date()
        if let handoffDeadline {
            if now >= handoffDeadline { finishHandoff() }
            return
        }
        // 看门狗：一直有人在说、却没有任何识别结果 → 系统识别服务的连接坏了（不会回调我们），重建重来。
        // 只数有人声的时间（`LiveTranslateStallClock`），停顿、朗读暂停识别的时间不算。
        stall.tick(now: now, lastVoice: router.lastVoiceDate)
        let timeout = min(Self.stallTimeout * Double(1 << min(restartStreak, 4)), 60)
        if stall.voiced > timeout {
            restartAfterStall(silentFor: now.timeIntervalSince(max(lastTextAt, segmentStart)))
            return
        }
        guard segmentHasText else { return }
        if now.timeIntervalSince(lastChange) > Self.pauseThreshold
            || now.timeIntervalSince(segmentStart) > Self.maxSegmentDuration {
            rollSegment()
        }
    }
}
