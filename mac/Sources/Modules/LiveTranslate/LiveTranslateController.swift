import AppKit
import AVFoundation
import Speech

/// 音源：麦克风 / 系统声音。
enum LiveTranslateSource: String, CaseIterable, Identifiable {
    case microphone = "mic"
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return L("livetranslate.source.mic")
        case .system: return L("livetranslate.source.system")
        }
    }
}

/// 说话的语言；译文自动取另一种。
enum LiveTranslateLanguage: String, CaseIterable, Identifiable {
    case english = "en-US"
    case chinese = "zh-CN"

    var id: String { rawValue }

    var speechLocale: Locale { Locale(identifier: rawValue) }

    /// Translation 框架用的语言代码。
    var translationCode: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh-Hans"
        }
    }

    var other: LiveTranslateLanguage {
        self == .english ? .chinese : .english
    }

    /// 语言名按惯例用各自语言书写，不随界面语言翻译。
    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }
}

/// 字幕条显示样式。
enum LiveTranslateDisplay: String, CaseIterable, Identifiable {
    case both
    case translation
    case original

    var id: String { rawValue }
}

/// 实时翻译相关的 UserDefaults 键与默认值。见 docs/live-translate/DESIGN.md §6。
enum LiveTranslateSettings {
    static let sourceKey = "livetranslate.source"
    static let languageKey = "livetranslate.language"
    static let translateKey = "livetranslate.translate"
    static let displayKey = "livetranslate.display"
    static let fontSizeKey = "livetranslate.fontSize"
    static let opacityKey = "livetranslate.opacity"
    static let onDeviceKey = "livetranslate.onDevice"
    static let barOriginKey = "livetranslate.barOrigin"

    static let defaultFontSize: Double = 24
    static let defaultOpacity: Double = 0.75

    static var source: LiveTranslateSource {
        get {
            UserDefaults.standard.string(forKey: sourceKey).flatMap(LiveTranslateSource.init(rawValue:)) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey) }
    }

    static var language: LiveTranslateLanguage {
        get {
            UserDefaults.standard.string(forKey: languageKey).flatMap(LiveTranslateLanguage.init(rawValue:)) ?? .english
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: languageKey) }
    }

    static var translateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: translateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: translateKey) }
    }

    static var preferOnDevice: Bool {
        UserDefaults.standard.object(forKey: onDeviceKey) as? Bool ?? true
    }

    /// 本机能否翻译（Translation 框架要求 macOS 15）。
    static var translationSupported: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }
}

enum LiveTranslateError: LocalizedError {
    case noInputDevice
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return L("livetranslate.error.noInputDevice")
        case .noDisplay: return L("livetranslate.error.noDisplay")
        }
    }
}

/// 实时翻译状态机：权限 → 音源 → 分段语音识别 → 翻译 → 字幕条。
@MainActor
final class LiveTranslateController: ObservableObject {
    static let shared = LiveTranslateController()

    /// 字幕条上的一句（一段识别结果）。
    struct Line: Identifiable, Equatable {
        let id: Int
        var original: String
        var translation: String
        var isFinal: Bool
    }

    @Published private(set) var isRunning = false
    @Published private(set) var lines: [Line] = []
    /// 字幕条上的状态提示（翻译不可用、识别出错等）；nil = 不显示。
    @Published private(set) var notice: String?

    let translator = LiveTranslateTranslator()

    private var isStarting = false
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 已 endAudio、还在回传 final 结果的上一段 task；持有它直到下一次切段。
    private var finishingTask: SFSpeechRecognitionTask?
    private let router = LiveTranslateAudioRouter()
    private var audioSource: LiveTranslateAudioSource?
    private var bar: LiveTranslateBarController?
    private var watchdog: Timer?

    private var segmentID = 0
    private var segmentStart = Date()
    private var lastChange = Date()
    /// 连续「刚开就出错、没有任何文字」的段数，到 3 判定不可恢复。
    private var quickFailures = 0
    private var translationErrorShown = false

    /// 每段最多持续多久（秒），防触到识别请求的时长上限。
    private static let maxSegmentDuration: TimeInterval = 45
    /// 文字多久没变化视为一句说完（秒）。
    private static let pauseThreshold: TimeInterval = 1.2
    /// 字幕条保留的段数（上一句 + 当前句）。
    private static let visibleLines = 2

    private init() {
        translator.onResult = { [weak self] id, text in
            self?.applyTranslation(id: id, text: text)
        }
        translator.onError = { [weak self] in
            self?.showTranslationErrorOnce()
        }
    }

    // MARK: - 开关

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        Task { await self.startFlow() }
    }

    /// 改了音源 / 语言 / 翻译开关等需要重建识别链路的设置后调用。
    func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        watchdog?.invalidate()
        watchdog = nil
        audioSource?.stop()
        audioSource = nil
        router.setRequest(nil)
        request?.endAudio()
        task?.cancel()
        finishingTask?.cancel()
        request = nil
        task = nil
        finishingTask = nil
        recognizer = nil
        translator.reset()
        bar?.hide()
        bar = nil
        lines = []
        notice = nil
    }

    private func startFlow() async {
        defer { isStarting = false }
        let source = LiveTranslateSettings.source
        let language = LiveTranslateSettings.language

        guard await Self.ensureSpeechPermission() else {
            presentAlert(title: L("livetranslate.alert.speechDeniedTitle"),
                         message: L("livetranslate.alert.speechDeniedMessage"),
                         settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            return
        }

        switch source {
        case .microphone:
            guard await Self.ensureMicrophonePermission() else {
                presentAlert(title: L("livetranslate.alert.micDeniedTitle"),
                             message: L("livetranslate.alert.micDeniedMessage"),
                             settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return
            }
        case .system:
            guard Permissions.hasScreenRecording else {
                Permissions.requestScreenRecording()
                presentAlert(title: L("livetranslate.alert.screenTitle"),
                             message: L("livetranslate.alert.screenMessage"),
                             settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                return
            }
        }

        guard let recognizer = SFSpeechRecognizer(locale: language.speechLocale), recognizer.isAvailable else {
            presentAlert(title: L("livetranslate.alert.unavailableTitle"),
                         message: L("livetranslate.alert.unavailableMessage"),
                         settingsURL: nil)
            return
        }

        self.recognizer = recognizer
        lines = []
        notice = nil
        quickFailures = 0
        translationErrorShown = false
        translator.reset()
        isRunning = true

        let wantsTranslation = LiveTranslateSettings.translateEnabled
        if wantsTranslation && !LiveTranslateSettings.translationSupported {
            notice = L("livetranslate.notice.needsMacOS15")
        }
        let pair: (source: String, target: String)? = wantsTranslation
            ? (source: language.translationCode, target: language.other.translationCode)
            : nil
        let bar = LiveTranslateBarController(controller: self, translationPair: pair)
        self.bar = bar
        bar.show()

        beginSegment()
        startWatchdog()

        let audio: LiveTranslateAudioSource
        switch source {
        case .microphone: audio = LiveTranslateMicSource(router: router)
        case .system: audio = LiveTranslateSystemAudioSource(router: router)
        }
        do {
            try await audio.start()
        } catch {
            stop()
            presentAlert(title: L("livetranslate.alert.audioFailedTitle"),
                         message: error.localizedDescription,
                         settingsURL: nil)
            return
        }
        // 启动音源期间用户可能已经点了停止。
        guard isRunning else {
            audio.stop()
            return
        }
        audioSource = audio
    }

    // MARK: - 分段识别

    private func beginSegment() {
        guard let recognizer else { return }
        segmentID += 1
        let id = segmentID

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if LiveTranslateSettings.preferOnDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        router.setRequest(request)
        segmentStart = Date()
        lastChange = Date()

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
        guard isRunning else { return }
        let ended = isFinal || error != nil
        if let text, !text.isEmpty {
            upsert(id: id, text: text, isFinal: ended)
            if id == segmentID {
                lastChange = Date()
                quickFailures = 0
            }
        }
        guard id == segmentID, ended else { return }

        // 当前段被系统收尾或出错：判断是否不可恢复，否则接着开下一段。
        let hasText = !(text ?? "").isEmpty || lines.contains(where: { $0.id == id })
        if error != nil, !hasText, Date().timeIntervalSince(segmentStart) < 1 {
            quickFailures += 1
            if quickFailures >= 3 {
                let message = error?.localizedDescription ?? ""
                stop()
                presentAlert(title: L("livetranslate.alert.recognitionFailedTitle"),
                             message: message, settingsURL: nil)
                return
            }
        }
        task = nil
        request = nil
        beginSegment()
    }

    private func upsert(id: Int, text: String, isFinal: Bool) {
        if let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index].original = text
            lines[index].isFinal = isFinal
        } else {
            // 已被挤出字幕条的旧段迟到的 final 结果，丢弃。
            if let first = lines.first, id < first.id, lines.count >= Self.visibleLines { return }
            lines.append(Line(id: id, original: text, translation: "", isFinal: isFinal))
            lines.sort { $0.id < $1.id }
            if lines.count > Self.visibleLines {
                lines.removeFirst(lines.count - Self.visibleLines)
            }
        }
        if bar?.translates == true {
            translator.submit(id: id, text: text, isFinal: isFinal)
        }
    }

    private func applyTranslation(id: Int, text: String) {
        guard isRunning, let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].translation = text
    }

    private func showTranslationErrorOnce() {
        guard isRunning, !translationErrorShown else { return }
        translationErrorShown = true
        notice = L("livetranslate.notice.translateFailed")
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    /// 停顿或段过长 → 切段。只在当前段已有文字时切（没说话就让它一直听着）。
    private func tick() {
        guard isRunning, let line = lines.last, line.id == segmentID, !line.isFinal else { return }
        let now = Date()
        if now.timeIntervalSince(lastChange) > Self.pauseThreshold
            || now.timeIntervalSince(segmentStart) > Self.maxSegmentDuration {
            rollSegment()
        }
    }

    // MARK: - 权限

    private static func ensureSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    private static func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// LSUIElement 应用从菜单触发时不是前台 App，先激活再弹窗，否则弹窗在别的窗口后面。
    private func presentAlert(title: String, message: String, settingsURL: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if settingsURL != nil {
            alert.addButton(withTitle: L("common.goEnable"))
            alert.addButton(withTitle: L("common.cancel"))
        } else {
            alert.addButton(withTitle: L("common.ok"))
        }
        if alert.runModal() == .alertFirstButtonReturn,
           let settingsURL, let url = URL(string: settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
