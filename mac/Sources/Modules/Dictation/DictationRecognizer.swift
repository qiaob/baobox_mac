import AVFoundation
import Foundation
import os
import Speech

/// 听写的诊断日志。排查：
/// `/usr/bin/log show --last 30m --style compact --predicate 'subsystem == "com.baobox.app" AND category BEGINSWITH "dictation"'`
enum DictationLog {
    static let general = Logger(subsystem: "com.baobox.app", category: "dictation")
    static let recognition = Logger(subsystem: "com.baobox.app", category: "dictation.recognition")
}

enum DictationError: LocalizedError {
    case noInputDevice
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return L("dictation.error.noInputDevice")
        case .recognizerUnavailable: return L("dictation.error.unavailable")
        }
    }
}

/// 一次听写认出来的文字（还没做后处理）。
struct DictationTranscript {
    var text: String
    /// 认出来是哪种语言（自动判别时是赢的那种）。
    var language: TranslationLanguage
}

// MARK: - 音频管道

/// 麦克风 tap（音频线程）→ 当前识别请求。顺带算电平（录音条）、记最近一次有人声的时间（停顿判断）、
/// 换段交接时攒音频、自动判别语种时录下这一段（另一种语言重认用）。
///
/// 换段时系统的听写服务一次只服务一个请求：旧段 endAudio 后、final 还没回来就开新段会把旧段掐掉
/// （同 `LiveTranslateAudioGate`）。所以换段先 `hold()` 攒着，新段开出来 `forward(to:)` 补喂，一个字也不丢。
///
/// @unchecked Sendable 依据：可变状态都在 `lock` 内；`append` 在音频线程调，其余在主线程。
final class DictationAudioPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var holding = false
    private var held: [AVAudioPCMBuffer] = []
    private var heldFrames: AVAudioFramePosition = 0
    private var recording = false
    private var recorded: [AVAudioPCMBuffer] = []
    private var recordedFrames: AVAudioFramePosition = 0
    private var levelValue: Float = 0
    private var lastVoiceAt = Date.distantPast
    private var sampleRate: Double = 48_000

    /// 约 -40 dBFS：安静房间的底噪在它之下，正常说话在它之上（同实时翻译）。
    private static let voiceRMS: Float = 0.01
    /// 交接最多攒多少秒（正常两秒内就交接完，只防意外）。
    private static let maxHeldSeconds: Double = 20
    /// 一段录音最多留多少秒（技术设计 §3：最长 2 分钟）。
    private static let maxRecordedSeconds: Double = 120

    /// 平滑后的电平（0…1），录音条的电平表用。
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return levelValue
    }

    /// 最近一次有人声（音量过阈值）的时间。
    var lastVoice: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastVoiceAt
    }

    /// 攒着的音频有多少秒。
    var heldDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate > 0 ? Double(heldFrames) / sampleRate : 0
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(buffer)
        let normalized = Self.normalizedLevel(rms)
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if buffer.format.sampleRate > 0 { sampleRate = buffer.format.sampleRate }
        // 起得快、落得慢：说话时跳得起来，停下时慢慢回落。
        levelValue = normalized > levelValue ? normalized : levelValue * 0.82 + normalized * 0.18
        if rms > Self.voiceRMS { lastVoiceAt = now }
        if holding {
            // 音源回调给的缓冲区之后可能被复用，攒的时候拷一份。
            guard let copy = LiveTranslateAudioGate.copy(buffer) else { return }
            held.append(copy)
            heldFrames += AVAudioFramePosition(copy.frameLength)
            let cap = AVAudioFramePosition(Self.maxHeldSeconds * sampleRate)
            while heldFrames > cap, !held.isEmpty {
                heldFrames -= AVAudioFramePosition(held.removeFirst().frameLength)
            }
            return
        }
        request?.append(buffer)
        guard recording, let copy = LiveTranslateAudioGate.copy(buffer) else { return }
        recorded.append(copy)
        recordedFrames += AVAudioFramePosition(copy.frameLength)
        let cap = AVAudioFramePosition(Self.maxRecordedSeconds * sampleRate)
        while recordedFrames > cap, !recorded.isEmpty {
            recordedFrames -= AVAudioFramePosition(recorded.removeFirst().frameLength)
        }
    }

    /// 换成新请求：交接中攒下的先按顺序补喂（`record` 时也算进这一段的录音），然后直通。
    func forward(to request: SFSpeechAudioBufferRecognitionRequest, record: Bool) {
        lock.lock()
        recorded = []
        recordedFrames = 0
        for buffer in held {
            request.append(buffer)
            if record {
                recorded.append(buffer)
                recordedFrames += AVAudioFramePosition(buffer.frameLength)
            }
        }
        held = []
        heldFrames = 0
        holding = false
        recording = record
        self.request = request
        lock.unlock()
    }

    /// 开始攒音频：旧段已 endAudio、新段还没开。
    func hold() {
        lock.lock()
        holding = true
        request = nil
        lock.unlock()
    }

    /// 不再往请求里送（结束听写：最后这段已 endAudio）。
    func detach() {
        lock.lock()
        request = nil
        lock.unlock()
    }

    /// 取走这一段的录音（自动判别重认用），并清空。
    func takeRecording() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        let taken = recorded
        recorded = []
        recordedFrames = 0
        return taken
    }

    func clear() {
        lock.lock()
        request = nil
        holding = false
        held = []
        heldFrames = 0
        recording = false
        recorded = []
        recordedFrames = 0
        levelValue = 0
        lock.unlock()
    }

    /// 第一声道的 RMS。非 float 格式拿不到样本就当 0。
    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let value = samples[index]
            sum += value * value
        }
        return (sum / Float(count)).squareRoot()
    }

    /// RMS → 0…1：-55 dBFS 及以下为 0，-10 dBFS 及以上为 1。
    private static func normalizedLevel(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 55) / 45, 0), 1)
    }
}

// MARK: - 麦克风

/// 默认输入设备，经 AVAudioEngine 的 inputNode tap 取 PCM。每次听写新建一个，结束即停（麦克风指示灯随之熄灭）。
@MainActor
final class DictationMicrophone {
    private let engine = AVAudioEngine()
    private let pipe: DictationAudioPipe
    private var tapInstalled = false
    private var configObserver: NSObjectProtocol?

    init(pipe: DictationAudioPipe) {
        self.pipe = pipe
    }

    func start() throws {
        try installTapAndStart()
        // 换输入设备 / 插拔耳机：系统停掉引擎、只发这个通知，不接住麦克风就此静音（同实时翻译）。
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recoverFromConfigurationChange()
            }
        }
    }

    func stop() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationError.noInputDevice
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(pipe: pipe))
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    private func recoverFromConfigurationChange() {
        guard configObserver != nil else { return }
        DictationLog.recognition.error("audio engine configuration changed, restarting microphone input")
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        do {
            try installTapAndStart()
        } catch {
            DictationLog.recognition.error("microphone restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// tap 在音频线程回调：在 nonisolated 上下文里造闭包，免得被推断成主线程隔离。
    nonisolated private static func makeTap(pipe: DictationAudioPipe) -> AVAudioNodeTapBlock {
        { buffer, _ in
            pipe.append(buffer)
        }
    }
}

// MARK: - 识别器

/// 听写的识别（docs/dictation/TECH_DESIGN.md §3）：自己的 `SFSpeechRecognizer` + 麦克风 tap，
/// 不复用实时翻译的分段识别器（那套为长时字幕设计，停下时会丢最后一句）。
///
/// - 低延迟：识别器对象在模块启用时就建好（`prewarm`）；开始时先建请求再开麦克风，音频一到就喂。
/// - 结束：停麦克风 → endAudio → 等 final（最多 2 秒，超时用最后一次 partial）。
/// - 分段：整句模式（按住说话）只在满 50 秒时换段（防触到单次请求的时长上限）；分段模式（长听写、连续听写）
///   每次停顿 ≥ 1.2 秒或满 50 秒收一段，一段段交出。
/// - 自动判别（两种语言）：每段录音留着；定稿后平均置信度 < 0.45（或有人声却没认出字）就拿录音给另一种语言重认，
///   按实时翻译的打分（置信度 × 文字系统吻合度 × 字数密度）取高的那份，并换成它接着听。
@MainActor
final class DictationRecognizer {
    enum Mode {
        /// 按住说话：结束时一次交出整段。
        case utterance
        /// 长听写（进收集面板）/ 连续听写（逐句上屏）：按停顿切段，一段段交出（`onSegment`）。
        case segmented
    }

    /// 预览变了：整句模式 = 已定稿的各段 + 正在说的这段；分段模式 = 正在说的这段。
    var onPreview: ((String) -> Void)?
    /// 分段模式：一段定稿了（已做过语种重认）。
    var onSegment: ((String, TranslationLanguage) -> Void)?
    /// 不可恢复的失败（已自行停下）。整句模式下已经定稿的那几段一并交出（不丢字），没有为 nil。
    var onFailure: ((String, DictationTranscript?) -> Void)?

    private let mode: Mode
    private let languages: [TranslationLanguage]
    private let recognizers: [SFSpeechRecognizer]
    private var active = 0
    private let preferOnDevice: Bool
    private let vocabulary: [String]
    private let pipe = DictationAudioPipe()
    private var microphone: DictationMicrophone?

    private var running = false
    private var timer: Timer?
    private var startedAt = Date()
    private var segmentID = 0
    /// 当前段还没收尾（收尾后迟到的回调一律不理）。
    private var segmentOpen = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segmentStart = Date()
    private var lastTextChange = Date()
    private var partial = ""
    private var segmentFinal: (text: String, confidence: Double)?
    private var finals: [(text: String, language: TranslationLanguage)] = []
    /// 等当前段的 final：截止时间。
    private var finalDeadline: Date?
    private var recheck: Recheck?
    private var recheckTask: SFSpeechRecognitionTask?
    private var finishing = false
    private var finishCompletion: ((DictationTranscript) -> Void)?
    /// 连续「刚开就出错、没有任何文字」的段数，到 3 判定不可恢复。
    private var quickFailures = 0

    private struct Recheck {
        let segment: Int
        let deadline: Date
        let own: (text: String, confidence: Double)
        let voiced: TimeInterval
        let other: Int
        let startedAt: Date
    }

    /// 等 final 最多多久（秒）。
    static let finalWait: TimeInterval = 2
    /// 分段模式：停顿这么久收一段（秒）。
    static let pauseCut: TimeInterval = 1.2
    /// 一段最长多久（秒）。
    static let maxSegment: TimeInterval = 50
    /// 平均置信度低于它就拿录音换一种语言重认。
    static let recheckThreshold = 0.45
    /// 重认最多等多久（秒；长录音按时长的三成放宽）。
    static let recheckWait: TimeInterval = 3

    /// - Parameter languages: 一种 = 固定；两种 = 自动判别，第一种为主。
    init?(mode: Mode, languages: [TranslationLanguage], preferOnDevice: Bool, vocabulary: [String]) {
        var usableLanguages: [TranslationLanguage] = []
        var built: [SFSpeechRecognizer] = []
        for language in languages.prefix(2) {
            guard let recognizer = Self.recognizer(for: language) else { continue }
            usableLanguages.append(language)
            built.append(recognizer)
        }
        guard !built.isEmpty else { return nil }
        self.mode = mode
        self.languages = usableLanguages
        self.recognizers = built
        self.preferOnDevice = preferOnDevice
        self.vocabulary = vocabulary
        // 主语言此刻用不了（比如只能走服务器又没网）就先用另一种。
        active = built.firstIndex(where: \.isAvailable) ?? 0
    }

    /// 已认出任何文字（停顿自动结束只在有内容之后才算）。
    var hasText: Bool { !finals.isEmpty || !partial.isEmpty }

    /// 多久没有人声、也没有新字了（秒）。
    var quietSeconds: TimeInterval {
        Date().timeIntervalSince(max(lastTextChange, pipe.lastVoice))
    }

    var level: Float { pipe.level }

    /// 开始：先建请求，再开麦克风。
    func start() throws {
        guard recognizers[active].isAvailable else { throw DictationError.recognizerUnavailable }
        running = true
        startedAt = Date()
        DictationLog.recognition.notice(
            "start \(self.mode == .segmented ? "segmented" : "utterance", privacy: .public): \(self.languages.map(\.code).joined(separator: "+"), privacy: .public), on-device \(self.preferOnDevice && self.recognizers[self.active].supportsOnDeviceRecognition)")
        beginSegment()
        let microphone = DictationMicrophone(pipe: pipe)
        do {
            try microphone.start()
        } catch {
            teardown()
            throw error
        }
        self.microphone = microphone
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 结束：`tail` 秒后停麦克风（按住说话松手时最后一个字可能还没说完），冲刷最后一段，交出整段。
    func finish(tail: TimeInterval, completion: @escaping (DictationTranscript) -> Void) {
        guard running, !finishing else { return }
        finishing = true
        finishCompletion = completion
        guard tail > 0 else {
            stopAudioAndFlush()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [weak self] in
            MainActor.assumeIsolated {
                self?.stopAudioAndFlush()
            }
        }
    }

    /// 取消：什么都不交出。
    func cancel() {
        finishCompletion = nil
        teardown()
    }

    // MARK: - 段

    private func beginSegment() {
        segmentID += 1
        let id = segmentID
        segmentOpen = true
        segmentStart = Date()
        lastTextChange = segmentStart
        partial = ""
        segmentFinal = nil
        finalDeadline = nil
        let recognizer = recognizers[active]
        let request = makeRequest(for: recognizer, partials: true)
        self.request = request
        // 交接期间攒下的音频先补喂，再直通；自动判别时这一段的录音留着。
        pipe.forward(to: request, record: languages.count > 1)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // 回调线程不定：只取出值类型再回主线程。
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let confidence = LiveTranslateScoring.averageConfidence(result)
            let nsError = error as NSError?
            let failure = nsError.map { "\($0.domain) \($0.code)" }
            let benign = nsError.map(Self.isBenign) ?? false
            let message = nsError?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(segment: id, text: text, isFinal: isFinal, confidence: confidence,
                                 failure: failure, benign: benign, message: message)
                }
            }
        }
    }

    private func makeRequest(for recognizer: SFSpeechRecognizer, partials: Bool) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = partials
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = vocabulary
        request.requiresOnDeviceRecognition = preferOnDevice && recognizer.supportsOnDeviceRecognition
        return request
    }

    private func handle(segment id: Int, text: String?, isFinal: Bool, confidence: Double,
                        failure: String?, benign: Bool, message: String?) {
        guard running, id == segmentID, segmentOpen else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            if trimmed != partial {
                partial = trimmed
                lastTextChange = Date()
            }
            quickFailures = 0
            onPreview?(previewText())
        }
        guard isFinal || failure != nil else { return }
        if let failure, !benign {
            DictationLog.recognition.error("segment \(id) ended with error: \(failure, privacy: .public)")
        }
        segmentFinal = (trimmed.isEmpty ? partial : trimmed, isFinal ? confidence : 0)
        if finalDeadline == nil, !finishing {
            // 系统自己收了这一段（出错 / 到了单次请求的上限）：刚开就出错、连续 3 次判不可恢复。
            if failure != nil, !benign, partial.isEmpty, Date().timeIntervalSince(segmentStart) < 1.5 {
                quickFailures += 1
                if quickFailures >= 3 {
                    fail(message ?? L("dictation.error.unavailable"))
                    return
                }
            }
            pipe.hold()
        }
        completeSegment()
    }

    /// 换段：先让当前段把 final 回完（最多 `finalWait`），其间音频攒着。
    private func cut() {
        guard segmentOpen, finalDeadline == nil else { return }
        pipe.hold()
        request?.endAudio()
        request = nil
        finalDeadline = Date().addingTimeInterval(Self.finalWait)
    }

    /// 当前段收尾（final 到了或等超时）：要不要换语言重认；然后定稿。
    private func completeSegment() {
        guard segmentOpen else { return }
        segmentOpen = false
        finalDeadline = nil
        task?.cancel()
        task = nil
        request = nil
        let own = segmentFinal ?? (partial, 0)
        let audio = pipe.takeRecording()
        if languages.count > 1, !audio.isEmpty {
            let voiced = LiveTranslateAudioRouter.voicedDuration(of: audio)
            // 有置信度（真的等到了 final）且偏低，或说了一阵却一个字没认出来。
            let lowConfidence = !own.text.isEmpty && own.confidence > 0 && own.confidence < Self.recheckThreshold
            let silentButVoiced = own.text.isEmpty && voiced >= 1
            if lowConfidence || silentButVoiced {
                startRecheck(own: own, audio: audio, voiced: voiced)
                return
            }
        }
        accept(text: own.text, languageIndex: active)
    }

    private func startRecheck(own: (text: String, confidence: Double), audio: [AVAudioPCMBuffer], voiced: TimeInterval) {
        let other = active == 0 ? 1 : 0
        let recognizer = recognizers[other]
        guard recognizer.isAvailable else {
            accept(text: own.text, languageIndex: active)
            return
        }
        let request = makeRequest(for: recognizer, partials: false)
        for buffer in audio {
            request.append(buffer)
        }
        request.endAudio()
        let rate = audio.first?.format.sampleRate ?? 48_000
        let frames = audio.reduce(0) { $0 + Double($1.frameLength) }
        let duration = rate > 0 ? frames / rate : 0
        let id = segmentID
        recheck = Recheck(segment: id, deadline: Date().addingTimeInterval(max(Self.recheckWait, duration * 0.3)),
                          own: own, voiced: voiced, other: other, startedAt: Date())
        recheckTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard error != nil || result?.isFinal == true else { return }
            let text = result?.bestTranscription.formattedString ?? ""
            let confidence = LiveTranslateScoring.averageConfidence(result)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.recheckDone(segment: id, text: text, confidence: confidence)
                }
            }
        }
    }

    /// 另一种语言重认的结果（超时时 text 为空）：分高的定稿；另一种赢了就换成它接着听。
    private func recheckDone(segment id: Int, text: String, confidence: Double) {
        guard running, let state = recheck, state.segment == id else { return }
        recheck = nil
        recheckTask?.cancel()
        recheckTask = nil
        let otherText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownScore = LiveTranslateScoring.score(text: state.own.text, confidence: state.own.confidence,
                                                  language: languages[active], voiced: state.voiced)
        let otherScore = LiveTranslateScoring.score(text: otherText, confidence: confidence,
                                                    language: languages[state.other], voiced: state.voiced)
        let switches = otherScore > ownScore
        DictationLog.recognition.notice(
            "recheck seg \(id) (\(String(format: "%.1f", Date().timeIntervalSince(state.startedAt)), privacy: .public)s): \(self.languages[self.active].code, privacy: .public) \(String(format: "%.2f", ownScore), privacy: .public) vs \(self.languages[state.other].code, privacy: .public) \(String(format: "%.2f", otherScore), privacy: .public) -> \(switches ? "switch" : "keep", privacy: .public)")
        if switches {
            active = state.other
            accept(text: otherText, languageIndex: state.other)
        } else {
            accept(text: state.own.text, languageIndex: active)
        }
    }

    /// 一段定稿：记下（长听写交出去）；结束中就把松手前攒下的那点音频认完再交，否则接着开下一段。
    private func accept(text: String, languageIndex: Int) {
        let language = languages[languageIndex]
        if !text.isEmpty {
            finals.append((text, language))
            if mode == .segmented { onSegment?(text, language) }
        }
        partial = ""
        onPreview?(previewText())
        guard finishing else {
            beginSegment()
            return
        }
        if pipe.heldDuration >= 0.3 {
            // 换段交接期间用户松了手：攒下的那截音频再开一段认完。
            beginSegment()
            pipe.detach()
            request?.endAudio()
            finalDeadline = Date().addingTimeInterval(Self.finalWait)
            return
        }
        deliver()
    }

    private func stopAudioAndFlush() {
        guard running else { return }
        microphone?.stop()
        microphone = nil
        // 换段交接 / 重认进行中：交给 accept() 收尾（它看得到 finishing）。
        guard segmentOpen, finalDeadline == nil else { return }
        // 从头到尾没听到人声、也没出字（误触）：不用等 final。
        if finals.isEmpty, partial.isEmpty, pipe.lastVoice < startedAt {
            segmentOpen = false
            deliver()
            return
        }
        pipe.detach()
        request?.endAudio()
        request = nil
        finalDeadline = Date().addingTimeInterval(Self.finalWait)
    }

    private func deliver() {
        let transcript = collected()
        let completion = finishCompletion
        DictationLog.recognition.notice(
            "done: \(self.finals.count) segment(s), \(transcript.text.count) chars, \(transcript.language.code, privacy: .public), \(String(format: "%.1f", Date().timeIntervalSince(self.startedAt)), privacy: .public)s")
        teardown()
        completion?(transcript)
    }

    /// 已定稿各段接起来；语言取字数最多的那段的。
    private func collected() -> DictationTranscript {
        let text = finals.map(\.text).reduce("") { DictationTextProcessor.join($0, $1) }
        let language = finals.max(by: { $0.text.count < $1.text.count })?.language ?? languages[active]
        return DictationTranscript(text: text, language: language)
    }

    private func fail(_ message: String) {
        DictationLog.recognition.error("recognition failed: \(message, privacy: .public)")
        // 分段模式的各段已经交出去了；整句模式把已经认出来的交给调用方，不丢字。
        let kept = mode == .utterance && !finals.isEmpty ? collected() : nil
        finishCompletion = nil
        teardown()
        onFailure?(message, kept)
    }

    private func teardown() {
        running = false
        timer?.invalidate()
        timer = nil
        microphone?.stop()
        microphone = nil
        pipe.clear()
        request?.endAudio()
        task?.cancel()
        recheckTask?.cancel()
        request = nil
        task = nil
        recheckTask = nil
        recheck = nil
        finalDeadline = nil
        segmentOpen = false
    }

    private func tick() {
        guard running else { return }
        let now = Date()
        if let recheck {
            if now >= recheck.deadline { recheckDone(segment: recheck.segment, text: "", confidence: 0) }
            return
        }
        if let finalDeadline {
            if now >= finalDeadline { completeSegment() }
            return
        }
        guard !finishing, segmentOpen else { return }
        let age = now.timeIntervalSince(segmentStart)
        let quiet = now.timeIntervalSince(max(lastTextChange, pipe.lastVoice))
        if age >= Self.maxSegment || (mode == .segmented && !partial.isEmpty && quiet >= Self.pauseCut) {
            cut()
        }
    }

    private func previewText() -> String {
        switch mode {
        case .segmented:
            return partial
        case .utterance:
            let done = finals.map(\.text).reduce("") { DictationTextProcessor.join($0, $1) }
            return DictationTextProcessor.join(done, partial)
        }
    }

    /// 正常收尾的「错误」：没听到话（1110）、请求被取消（216 / 301）。不算失败、不记错误日志。
    nonisolated private static func isBenign(_ error: NSError) -> Bool {
        [1110, 216, 301].contains(error.code)
    }

    // MARK: - 识别器对象缓存（低延迟）

    private static var cache: [String: SFSpeechRecognizer] = [:]

    static func recognizer(for language: TranslationLanguage) -> SFSpeechRecognizer? {
        guard let localeID = language.speechLocale else { return nil }
        if let cached = cache[localeID] { return cached }
        guard let created = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else { return nil }
        cache[localeID] = created
        return created
    }

    /// 模块启用时调用：把要用的识别器对象先建好（不录音、不申请权限）。
    static func prewarm(_ languages: [TranslationLanguage]) {
        for language in languages {
            _ = recognizer(for: language)
        }
    }

    /// 这种语言此刻能不能在本机识别（设置页显示用）。
    static func supportsOnDevice(_ language: TranslationLanguage) -> Bool {
        recognizer(for: language)?.supportsOnDeviceRecognition ?? false
    }
}
