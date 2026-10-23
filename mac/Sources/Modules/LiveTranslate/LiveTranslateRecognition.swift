import AVFoundation
import Foundation
import Speech

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
    func start() async throws
    func stop()
}

/// 用户填的专有名词：按换行 / 逗号 / 顿号拆开，去空去重，最多 100 个。
enum LiveTranslateVocabulary {
    static func parse(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: "\n,，、;；")
        var seen = Set<String>()
        var result: [String] = []
        for piece in raw.components(separatedBy: separators) {
            let word = piece.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, seen.insert(word).inserted else { continue }
            result.append(word)
            if result.count >= 100 { break }
        }
        return result
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
                try? await analyzer.cancelAndFinishNow()
            }
        }
        analyzer = nil
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

    private let recognizer: SFSpeechRecognizer
    private let router: LiveTranslateAudioRouter
    private let vocabulary: [String]
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 已 endAudio、还在回传 final 结果的上一段 task；持有它直到下一次切段。
    private var finishingTask: SFSpeechRecognitionTask?
    private var watchdog: Timer?
    private var running = false

    private var segmentID = 0
    private var segmentStart = Date()
    private var lastChange = Date()
    private var segmentHasText = false
    /// 连续「刚开就出错、没有任何文字」的段数，到 3 判定不可恢复。
    private var quickFailures = 0

    /// 每段最多持续多久（秒），防触到识别请求的时长上限。
    private static let maxSegmentDuration: TimeInterval = 45
    /// 文字多久没变化视为一句说完（秒）。
    private static let pauseThreshold: TimeInterval = 1.2

    init(recognizer: SFSpeechRecognizer, router: LiveTranslateAudioRouter, vocabulary: [String]) {
        self.recognizer = recognizer
        self.router = router
        self.vocabulary = vocabulary
    }

    func start() async throws {
        running = true
        beginSegment()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
        request?.endAudio()
        task?.cancel()
        finishingTask?.cancel()
        request = nil
        task = nil
        finishingTask = nil
    }

    private func beginSegment() {
        segmentID += 1
        let id = segmentID

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = vocabulary
        if LiveTranslateSettings.preferOnDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        router.setSink { buffer in
            request.append(buffer)
        }
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

    /// 结束当前段并立刻开下一段；旧 task 继续把 final 结果回给旧 id。
    private func rollSegment() {
        request?.endAudio()
        finishingTask?.cancel()
        finishingTask = task
        task = nil
        request = nil
        beginSegment()
    }

    private func handle(segment id: Int, text: String?, isFinal: Bool, error: Error?) {
        guard running else { return }
        let ended = isFinal || error != nil
        if let text, !text.isEmpty {
            onUpdate?(id, text, ended)
            if id == segmentID {
                lastChange = Date()
                segmentHasText = true
                quickFailures = 0
            }
        }
        guard id == segmentID, ended else { return }

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

    /// 停顿或段过长 → 切段。只在当前段已有文字时切（没说话就让它一直听着）。
    private func tick() {
        guard running, segmentHasText else { return }
        let now = Date()
        if now.timeIntervalSince(lastChange) > Self.pauseThreshold
            || now.timeIntervalSince(segmentStart) > Self.maxSegmentDuration {
            rollSegment()
        }
    }
}
