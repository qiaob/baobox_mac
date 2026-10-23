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
    static let vocabularyKey = "livetranslate.vocabulary"

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

    static var vocabulary: [String] {
        LiveTranslateVocabulary.parse(UserDefaults.standard.string(forKey: vocabularyKey) ?? "")
    }

    /// 本机能否用新一代识别引擎（SpeechAnalyzer，macOS 26，且需 Xcode 26 编译）。
    static var analyzerSupported: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
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
    case languageUnsupported

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return L("livetranslate.error.noInputDevice")
        case .noDisplay: return L("livetranslate.error.noDisplay")
        case .languageUnsupported: return L("livetranslate.alert.unavailableMessage")
        }
    }
}

/// 实时翻译状态机：权限 → 识别引擎 → 音源 → 翻译 → 字幕条。
@MainActor
final class LiveTranslateController: ObservableObject {
    static let shared = LiveTranslateController()

    /// 字幕条上的一句（识别引擎给出的一句）。
    struct Line: Identifiable, Equatable {
        let id: Int
        var original: String
        var translation: String
        var isFinal: Bool
    }

    @Published private(set) var isRunning = false
    @Published private(set) var lines: [Line] = []
    /// 字幕条上的状态提示（翻译不可用、下载模型、识别出错等）；nil = 不显示。
    @Published private(set) var notice: String?

    let translator = LiveTranslateTranslator()

    private var isStarting = false
    private var recognizer: LiveTranslateRecognizer?
    private let router = LiveTranslateAudioRouter()
    private var audioSource: LiveTranslateAudioSource?
    private var bar: LiveTranslateBarController?
    private var translationErrorShown = false

    /// 字幕条保留的句数（上一句 + 当前句）。
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
        audioSource?.stop()
        audioSource = nil
        recognizer?.stop()
        recognizer = nil
        router.setSink(nil)
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

        // 新引擎本身不一定要这项授权，但回退到旧引擎时要；统一先问，免得运行中途弹窗。
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

        lines = []
        notice = nil
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

        // 识别引擎先就绪（新引擎可能要下载模型），再开音源。
        guard let recognizer = await startRecognizer(language: language) else {
            stop()
            presentAlert(title: L("livetranslate.alert.unavailableTitle"),
                         message: L("livetranslate.alert.unavailableMessage"),
                         settingsURL: nil)
            return
        }
        guard isRunning else {
            recognizer.stop()
            return
        }
        self.recognizer = recognizer

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

    /// macOS 26 优先用 SpeechAnalyzer（更快更准）；不支持或启动失败自动回退到 SFSpeechRecognizer。
    private func startRecognizer(language: LiveTranslateLanguage) async -> LiveTranslateRecognizer? {
        let vocabulary = LiveTranslateSettings.vocabulary
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if await LiveTranslateAnalyzerRecognizer.supports(language.speechLocale) {
                let analyzer = LiveTranslateAnalyzerRecognizer(locale: language.speechLocale,
                                                               router: router, vocabulary: vocabulary)
                wire(analyzer)
                do {
                    try await analyzer.start()
                    return analyzer
                } catch {
                    // 模型下载失败等 → 回退旧引擎，清掉「正在下载」提示。
                    analyzer.stop()
                    if isRunning { notice = nil }
                }
            }
        }
        #endif
        guard let speech = SFSpeechRecognizer(locale: language.speechLocale), speech.isAvailable else {
            return nil
        }
        let legacy = LiveTranslateLegacyRecognizer(recognizer: speech, router: router, vocabulary: vocabulary)
        wire(legacy)
        do {
            try await legacy.start()
        } catch {
            return nil
        }
        return legacy
    }

    private func wire(_ recognizer: LiveTranslateRecognizer) {
        recognizer.onUpdate = { [weak self] id, text, isFinal in
            self?.upsert(id: id, text: text, isFinal: isFinal)
        }
        recognizer.onStatus = { [weak self] message in
            guard let self, self.isRunning else { return }
            self.notice = message
        }
        recognizer.onFailure = { [weak self] message in
            guard let self, self.isRunning else { return }
            self.stop()
            self.presentAlert(title: L("livetranslate.alert.recognitionFailedTitle"),
                              message: message, settingsURL: nil)
        }
    }

    // MARK: - 字幕

    private func upsert(id: Int, text: String, isFinal: Bool) {
        guard isRunning else { return }
        if let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index].original = text
            lines[index].isFinal = isFinal
        } else {
            // 已被挤出字幕条的旧句迟到的结果，丢弃。
            if let first = lines.first, id < first.id, lines.count >= Self.visibleLines { return }
            // 新的一句开始了：之前没收到 final 的句子也不会再变，按定稿显示。
            for index in lines.indices where lines[index].id < id {
                lines[index].isFinal = true
            }
            lines.append(Line(id: id, original: text, translation: "", isFinal: isFinal))
            lines.sort { $0.id < $1.id }
            if lines.count > Self.visibleLines {
                lines.removeFirst(lines.count - Self.visibleLines)
            }
        }
        if notice == L("livetranslate.notice.downloadingModel") { notice = nil }
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
