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

/// 说话的语言：固定一种，或在两种之间逐句自动判别（双识别器）。
/// 见 docs/translation-engine/DESIGN.md §3.2。
enum LiveTranslateSpeech: Equatable {
    case fixed(TranslationLanguage)
    case auto(TranslationLanguage, TranslationLanguage)

    /// 这次会出现的语言（固定 = 一种，自动 = 两种）。
    var languages: [TranslationLanguage] {
        switch self {
        case .fixed(let language): return [language]
        case .auto(let first, let second): return [first, second]
        }
    }

    var title: String {
        switch self {
        case .fixed(let language): return language.endonym
        case .auto(let first, let second): return L("livetranslate.language.auto \(first.endonym) \(second.endonym)")
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
/// 一种语言此刻的识别方式（设置页「当前识别方式」显示用）。
struct LiveTranslateRecognitionRoute: Identifiable, Equatable {
    enum Kind: Equatable {
        /// 本机识别，声音不离开这台 Mac。
        case onDevice
        /// 这台 Mac 没有这种语言的本地模型（走 Apple 服务器）。
        case noModel
        /// 「自动」模式下两种语言都装了本机模型：轮流在本机识别（系统一次只能本机识别一种）。
        case switching
    }

    let language: TranslationLanguage
    let kind: Kind

    var id: String { language.code }
}

/// 一种语言此刻实际的识别方式（字幕条状态行显示用）。
struct LiveTranslateChannelState: Equatable {
    enum Mode: Equatable {
        case onDevice
        case server
        /// 反复出错被停用了。
        case disabled
        /// 轮流识别时没在听的那一种（这一句像它时才拿录音给它重认）。
        case standby
    }

    let language: TranslationLanguage
    let mode: Mode
}

enum LiveTranslateSettings {
    static let sourceKey = "livetranslate.source"
    static let languageKey = "livetranslate.language"
    static let translateKey = "livetranslate.translate"
    /// AI 纠正识别错字（中文；要先下载纠错模型）。
    static let aiCorrectionKey = "livetranslate.aiCorrection"
    static let displayKey = "livetranslate.display"
    static let fontSizeKey = "livetranslate.fontSize"
    static let opacityKey = "livetranslate.opacity"
    static let onDeviceKey = "livetranslate.onDevice"
    /// 旧版只记位置；现在记位置 + 大小（`barFrameKey`），旧值只在没有新值时用一次。
    static let barOriginKey = "livetranslate.barOrigin"
    static let barFrameKey = "livetranslate.barFrame"
    static let vocabularyKey = "livetranslate.vocabulary"
    static let targetKey = "livetranslate.target"
    static let autoAKey = "livetranslate.autoA"
    static let autoBKey = "livetranslate.autoB"
    /// `languageKey` 存这个值 = 自动（双识别器）；否则存识别 locale（`en-US`、`zh-CN`…，与旧版兼容）。
    static let autoValue = "auto"

    static let defaultFontSize: Double = 24
    static let defaultOpacity: Double = 0.75

    static var source: LiveTranslateSource {
        get {
            UserDefaults.standard.string(forKey: sourceKey).flatMap(LiveTranslateSource.init(rawValue:)) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey) }
    }

    /// 实时翻译能选的说话语言：语言表里有识别 locale、且本机识别器支持的（只算一次）。
    static let speechLanguages: [TranslationLanguage] = {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map {
            $0.identifier.replacingOccurrences(of: "_", with: "-")
        })
        let available = TranslationLanguage.all.filter { language in
            language.speechLocale.map { supported.contains($0) } ?? false
        }
        return available.isEmpty ? [.simplifiedChinese, .english] : available
    }()

    static var speech: LiveTranslateSpeech {
        let raw = UserDefaults.standard.string(forKey: languageKey) ?? "en-US"
        if raw == autoValue { return .auto(autoA, autoB) }
        return .fixed(TranslationLanguage.from(speechLocale: raw) ?? .english)
    }

    /// 设为固定某种语言。
    static func setSpeech(_ language: TranslationLanguage) {
        guard let locale = language.speechLocale else { return }
        UserDefaults.standard.set(locale, forKey: languageKey)
    }

    static func setAutoSpeech() {
        UserDefaults.standard.set(autoValue, forKey: languageKey)
    }

    static var autoA: TranslationLanguage {
        TranslationLanguage.from(code: UserDefaults.standard.string(forKey: autoAKey)) ?? .simplifiedChinese
    }

    /// 与 A 相同时自动换成另一种（中英互为兜底）。
    static var autoB: TranslationLanguage {
        let stored = TranslationLanguage.from(code: UserDefaults.standard.string(forKey: autoBKey)) ?? .english
        guard stored.isSameLanguage(as: autoA) else { return stored }
        return autoA.isSameLanguage(as: .english) ? .simplifiedChinese : .english
    }

    /// 译成什么（默认：说的是中文 → 英文，否则 → 中文，与旧版「英中互译」一致）。
    static var target: TranslationLanguage {
        get {
            if let stored = TranslationLanguage.from(code: UserDefaults.standard.string(forKey: targetKey)) {
                return stored
            }
            if case .fixed(let language) = speech, language.isChinese { return .english }
            return .simplifiedChinese
        }
        set { UserDefaults.standard.set(newValue.code, forKey: targetKey) }
    }

    /// 一句话（语言 `language`）译成什么。它本来就是「译成」的那种 → nil：不翻，只显示原文
    /// （2026-11-05 用户：「译成 English」时说英文就不该出中文；以前会反过来译成另一种）。
    static func target(for language: TranslationLanguage, target: TranslationLanguage) -> TranslationLanguage? {
        language.isSameLanguage(as: target) ? nil : target
    }

    static var aiCorrection: Bool {
        get { UserDefaults.standard.object(forKey: aiCorrectionKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: aiCorrectionKey) }
    }

    static var translateEnabled: Bool {
        get { UserDefaults.standard.object(forKey: translateKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: translateKey) }
    }

    static var preferOnDevice: Bool {
        UserDefaults.standard.object(forKey: onDeviceKey) as? Bool ?? true
    }

    /// 设置页「当前识别方式」：每种在听的语言此刻走本机还是 Apple 服务器、为什么。
    static func recognitionRoutes(for speech: LiveTranslateSpeech) -> [LiveTranslateRecognitionRoute] {
        let languages = speech.languages
        let supports = languages.map { language -> Bool in
            guard let localeID = language.speechLocale,
                  let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else { return false }
            return recognizer.supportsOnDeviceRecognition
        }
        // 「自动」且两种都装了本机模型 → 轮流识别（见 LiveTranslateSwitchingRecognizer）；否则各走各的。
        let switching = languages.count > 1 && supports.allSatisfy { $0 }
        return languages.indices.map { index in
            let kind: LiveTranslateRecognitionRoute.Kind
            if switching {
                kind = .switching
            } else {
                kind = supports[index] ? .onDevice : .noModel
            }
            return LiveTranslateRecognitionRoute(language: languages[index], kind: kind)
        }
    }

    /// 专有名词表（设置页编辑，存成文本，格式见 `TranslationGlossary`）。
    static var glossary: [GlossaryEntry] {
        TranslationGlossary.parse(UserDefaults.standard.string(forKey: vocabularyKey) ?? "")
    }

    /// 识别器的提示词：专有名词的原文与译名。识别器每段现读，改完从下一句起生效。
    static var vocabulary: [String] {
        TranslationGlossary.recognitionHints(glossary)
    }

    /// 本机能否用新一代识别引擎（SpeechAnalyzer，macOS 26，且需 Xcode 26 编译）。
    static var analyzerSupported: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
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
        /// 显示用的原文：识别原文里说完的单元换成 AI 纠正后的（有的话）。
        var original: String
        /// 显示用的整句译文：各单元译文拼起来，再接上最后那截的草稿。
        var translation: String
        var isFinal: Bool
        /// false = 这句本来就是「译成」的语言，不翻（字幕条把原文当主字幕显示）。
        var translates = true
        /// 识别器给的原文（切单元按它切）。
        var raw = ""
        /// AI 纠正结果（键 = 单元序号），只在 `correctionSources` 与当前单元原文一致时有效。
        var corrections: [Int: String] = [:]
        var correctionSources: [Int: String] = [:]
        /// 已经朗读过的单元（每个单元只读一次，后来译文改了也不再读）。
        var spokenUnits: Set<Int> = []
        /// 逐单元翻译（`LiveTranslateUnits`）：已说完的各单元原文与译文（键 = 单元序号）；
        /// 最后那截还在说的原文与它的草稿译文。
        var units: [String] = []
        var unitTranslations: [Int: String] = [:]
        var tail = ""
        var tailTranslation = ""
        /// `tailTranslation` 翻的是哪段原文（草稿结果回来时记下，可能比当前那截旧）。
        var tailTranslationSource = ""
        /// 译文直接沿用了草稿的单元：草稿翻的正好就是这一整截，不用再正式翻一遍。
        var draftUnits: Set<Int> = []
        /// 这句第一次出字的时刻（记录里的时间）。
        var startedAt = Date()
    }

    /// 翻译任务 id = 句 id × 1000 + 单元序号；999 = 最后那截还在说的（草稿）。
    private static let unitsPerLine = 1000
    private static let tailUnit = 999

    @Published private(set) var isRunning = false
    @Published private(set) var lines: [Line] = []
    /// 字幕条上的状态提示（翻译不可用、下载模型、识别出错等）；nil = 不显示。
    @Published private(set) var notice: String?
    /// 字幕条状态行：每种语言此刻实际的识别方式。
    @Published private(set) var channelStates: [LiveTranslateChannelState] = []
    /// 字幕条状态行：本次用的翻译引擎；nil = 不翻译。
    @Published private(set) var sessionEngine: TranslationEngineKind?
    /// 本次在用 AI 纠正识别错字（开着开关、模型已下载、在翻译）。
    @Published private(set) var correcting = false

    let corrector = LiveTranslateCorrector()
    /// 朗读译文（docs/live-translate-voice/DESIGN.md）。
    let voice = LiveTranslateVoiceOutput()
    /// 本次在朗读译文。
    @Published private(set) var speaksTranslations = false
    /// 能送会议的虚拟声卡：开始时查一次，字幕条朗读菜单用（重画时不再去系统里枚举）。
    @Published private(set) var virtualDevices: [LiveTranslateAudioDevice] = []

    /// 字幕条右上角的延迟监控：识别 = 停顿后开口到出字；翻译 = 一截说完到译文出来（开了 AI 纠错含纠错）。
    /// 都是最近 5 次的中位数；nil = 还没测到。
    @Published private(set) var recognitionLatency: TimeInterval?
    @Published private(set) var translationLatency: TimeInterval?
    /// 最早一截还没等到译文的提交时刻：字幕条据此显示「已等 x 秒」，翻译卡住时一眼看得出。
    @Published private(set) var translationPendingSince: Date?
    private var recognitionSamples = LiveTranslateLatencySamples()
    private var translationSamples = LiveTranslateLatencySamples()
    /// 各单元（任务编号）说完、提交去纠错 / 翻译的时刻；译文回来时算延迟。
    private var unitSubmittedAt: [Int: Date] = [:]

    /// 心跳日志：运行中每 10 秒记一行各环节的进度（音频、识别、纠错、翻译、朗读），「卡住了」时看是哪一环停了。
    private var heartbeatTimer: Timer?
    private var beat = Beat()
    private struct Beat {
        var updates = 0
        var newLines = 0
        var corrected = 0
        var translated = 0
    }
    /// 麦克风 + 外放：读译文期间暂停识别，防回授（戴耳机可在设置里关掉，见 `keepListening`）。
    private var muteWhileSpeaking = false
    /// 正在朗读、识别暂停着：字幕条上提示，免得以为没识别到。
    @Published private(set) var listeningPaused = false
    private var pausedAt: Date?

    let translator = LiveTranslateTranslator()

    private var isStarting = false
    private var recognizer: LiveTranslateRecognizer?
    private let router = LiveTranslateAudioRouter()
    private var audioSource: LiveTranslateAudioSource?
    private var bar: LiveTranslateBarController?
    private var translationErrorShown = false

    // 本次运行的语言配置（开始时定下，运行中改设置会重启）。
    private var sessionTarget: TranslationLanguage = .simplifiedChinese
    /// 单识别器时每句的语言；双识别器逐句报告（`lineLanguages`）。
    private var defaultLineLanguage: TranslationLanguage = .english
    private var lineLanguages: [Int: TranslationLanguage] = [:]
    /// 离线模型翻译循环（系统翻译时由字幕条上的翻译会话驱动，不用它）。
    private var offlineTask: Task<Void, Never>?
    private var keepsOfflineAlive = false

    /// 字幕条保留的句数：拉高字幕条可以往上翻（完整的在本地记录里）。
    private static let historyLines = 200

    /// 本次的本地记录（docs/live-translate/DESIGN.md §6）；没开记录为 nil。
    private var transcript: LiveTranslateTranscript?
    /// 字幕条「记录」菜单里「打开本次记录」用；还没记下任何一句时为 nil（文件还没建）。
    @Published private(set) var transcriptURL: URL?
    /// 这一次正在记录（字幕条「记录」菜单里的开关）。
    @Published private(set) var recording = false
    /// 本次的音源、语言（中途打开记录时新建记录要用）。
    private var transcriptConfig: LiveTranslateTranscript.Config?
    /// 最近一次的记录：菜单栏「打开最近一次记录」、App 退出时收尾纪要用。
    private(set) var lastTranscript: LiveTranslateTranscript?
    /// 第几次开始：改设置重启后接着写同一份记录，而句子 id 会从头编，记录里按「第几次 + id」区分。
    private var run = 0
    /// 正在因为改设置而重启：停止时不收尾记录、不清字幕历史，接着写 / 接着显示。
    private var restarting = false
    /// 识别器的句子 id 每次开始都从头编；改设置重启后字幕历史还留着，新句子的 id 加上这个偏移，免得和旧句子撞号。
    private var lineIDBase = 0
    /// App 正在退出：记录同步写完，不整理纪要。
    private var terminating = false

    private init() {
        translator.onResult = { [weak self] job, source, target, text in
            self?.applyTranslation(job: job, source: source, target: target, text: text)
        }
        corrector.onResult = { [weak self] key, source, corrected in
            self?.applyCorrection(key: key, source: source, corrected: corrected)
        }
        voice.onSpeakingChanged = { [weak self] speaking in
            guard let self, self.muteWhileSpeaking else { return }
            self.router.setMuted(speaking)
            self.listeningPaused = speaking
            if speaking {
                self.pausedAt = Date()
            } else if let pausedAt = self.pausedAt {
                let seconds = String(format: "%.1f", Date().timeIntervalSince(pausedAt))
                LiveTranslateLog.audio.notice("read-aloud paused recognition for \(seconds, privacy: .public)s")
                self.pausedAt = nil
            }
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

    /// 改了音源 / 语言 / 翻译开关等需要重建识别链路的设置后调用。本地记录接着写同一份。
    func restartIfRunning() {
        guard isRunning else { return }
        restarting = true
        stop()
        restarting = false
        start()
    }

    /// App 退出：停下来，记录同步写完；上一次还在整理的纪要标成「没整理完」。
    func terminate() {
        terminating = true
        stop()
        finishTranscript()
        lastTranscript?.abortMinutesIfRunning()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        // 记录：最后那句还没定稿也记上；改设置重启时接着写，否则收尾（结束时间、整理纪要）。
        for line in lines {
            record(line, force: true)
        }
        if !restarting {
            finishTranscript()
        }
        audioSource?.stop()
        audioSource = nil
        recognizer?.stop()
        recognizer = nil
        router.setSink(nil)
        translator.reset()
        corrector.reset()
        offlineTask?.cancel()
        offlineTask = nil
        if keepsOfflineAlive {
            OfflineTranslator.shared.endKeepAlive()
            keepsOfflineAlive = false
        }
        if correcting {
            OfflineTranslator.corrector.endKeepAlive()
            correcting = false
        }
        voice.stop()
        router.setMonitor(nil)
        router.setMuted(false)
        speaksTranslations = false
        muteWhileSpeaking = false
        listeningPaused = false
        pausedAt = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        resetLatency()
        bar?.hide()
        bar = nil
        if restarting {
            // 改设置引起的重启（2026-11-05 用户：切换语言 / 音源后历史记录就没了）：字幕历史留着，新开的字幕条接着显示。
            // 旧句子不会再变了，按定稿显示。
            for index in lines.indices {
                lines[index].isFinal = true
            }
        } else {
            lines = []
        }
        lineLanguages = [:]
        notice = nil
        channelStates = []
        sessionEngine = nil
    }

    private func startFlow() async {
        // 没能开起来（权限被拒、识别不可用…）：改设置重启时留着的记录也就此收尾。
        defer {
            isStarting = false
            if !isRunning {
                finishTranscript()
                lines = []
            }
        }
        let source = LiveTranslateSettings.source
        let speech = LiveTranslateSettings.speech
        let target = LiveTranslateSettings.target

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

        // 翻译引擎与方向：每种可能出现的语言各一个方向（自动模式两个）；本来就是「译成」那种的不用翻。
        let directions = speech.languages.compactMap { language -> (source: TranslationLanguage,
                                                                   target: TranslationLanguage)? in
            LiveTranslateSettings.target(for: language, target: target).map { (source: language, target: $0) }
        }
        var engine: TranslationEngineKind? = LiveTranslateSettings.translateEnabled ? TranslationSettings.resolve() : nil
        if engine == .system, TranslationSettings.canFallBackToOffline,
           await !TranslationSettings.systemSupports(directions) {
            engine = .offline
        }

        // 字幕历史：手动停止时已经清空；改设置重启时留着（见 stop）。新句子的 id 排在留下的后面。
        lineIDBase = (lines.map(\.id).max() ?? 0) + 1
        lineLanguages = [:]
        notice = nil
        translationErrorShown = false
        translator.reset()
        resetLatency()
        sessionTarget = target
        sessionEngine = engine
        channelStates = []
        corrector.reset()
        // 纠错跟着翻译走（按单元纠、纠完再翻）；模型常驻，免得每句都等加载。
        correcting = engine != nil && LiveTranslateSettings.aiCorrection && OfflineTranslator.corrector.isReady
        if correcting {
            OfflineTranslator.corrector.beginKeepAlive()
        }
        // 朗读译文：送会议（虚拟声卡）/ 外放。只有音源是麦克风（说话的是我）才送会议 —— 音源是系统声音时说话的是
        // 会议里的别人，再送回会议，对方会听到自己的话被译过来读回去。原声混入同理只在麦克风时有。
        virtualDevices = LiveTranslateAudioDevice.virtualDevices()
        if engine != nil, LiveTranslateVoiceSettings.enabled {
            let meeting = source == .microphone
                ? LiveTranslateAudioDevice.device(uid: LiveTranslateVoiceSettings.meetingDeviceUID) : nil
            let mixOriginal = source == .microphone && meeting != nil && LiveTranslateVoiceSettings.mixOriginal
            // 不送会议就只能外放：「同时从音响播放」只在送会议时才有得选（2026-11-05 两个都关着 = 朗读没声音）。
            let speakers = meeting == nil || LiveTranslateVoiceSettings.speakers
            voice.start(meetingDevice: meeting, speakers: speakers, mixOriginal: mixOriginal)
            voice.prewarm(target)
            router.setMonitor(voice.originalSink)
            speaksTranslations = voice.isActive
            muteWhileSpeaking = source == .microphone && speakers && !LiveTranslateVoiceSettings.keepListening
        }
        defaultLineLanguage = speech.languages.first ?? .english
        run += 1
        let config = LiveTranslateTranscript.Config(
            source: source.title, speech: speech.title,
            target: LiveTranslateSettings.translateEnabled && engine != nil ? target.endonym : nil)
        transcriptConfig = config
        startTranscript(config)
        isRunning = true
        beat = Beat()
        _ = router.takeStats()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logHeartbeat()
            }
        }

        if LiveTranslateSettings.translateEnabled && engine == nil {
            notice = L("livetranslate.notice.needsOfflineModel")
        } else if engine != nil, directions.isEmpty {
            // 说的就是「译成」的语言：只显示原文，提示一下免得以为坏了。
            notice = L("livetranslate.notice.sameLanguage \(target.endonym)")
        }
        let bar = LiveTranslateBarController(controller: self, translates: engine != nil,
                                             systemPairs: engine == .system ? directions : [])
        self.bar = bar
        bar.show()
        if engine == .offline {
            OfflineTranslator.shared.beginKeepAlive()
            keepsOfflineAlive = true
            offlineTask = Task { [translator] in
                await translator.serveOffline()
            }
        }

        // 识别引擎先就绪（新引擎可能要下载模型），再开音源。
        guard let recognizer = await startRecognizer(speech: speech) else {
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

    /// 自动模式：双识别器；某一种语言的识别器不可用就退回单语言。
    private func startRecognizer(speech: LiveTranslateSpeech) async -> LiveTranslateRecognizer? {
        switch speech {
        case .fixed(let language):
            return await startSingleRecognizer(language: language)
        case .auto(let first, let second):
            if let dual = LiveTranslateDualRecognizer(languages: [first, second], router: router) {
                wire(dual)
                dual.onRouting = { [weak self] states in
                    guard let self, self.isRunning else { return }
                    self.channelStates = states
                }
                do {
                    try await dual.start()
                    return dual
                } catch {
                    dual.stop()
                }
            }
            // 两种都装了本机模型（系统一次只能本机识别一种，没法让其中一种走云端）：轮流识别，并提示原因。
            if let switching = LiveTranslateSwitchingRecognizer(languages: [first, second], router: router) {
                wire(switching)
                switching.onRouting = { [weak self] states in
                    guard let self, self.isRunning else { return }
                    self.channelStates = states
                }
                do {
                    try await switching.start()
                    notice = L("livetranslate.notice.autoSwitching")
                    return switching
                } catch {
                    switching.stop()
                }
            }
            // 识别器不可用（比如没网、又没有本机模型）：退回单语言并提示。
            for language in [first, second] {
                if let single = await startSingleRecognizer(language: language) {
                    notice = L("livetranslate.notice.autoUnavailable \(language.endonym)")
                    return single
                }
            }
            return nil
        }
    }

    /// macOS 26 优先用 SpeechAnalyzer（更快更准）；不支持或启动失败自动回退到 SFSpeechRecognizer。
    private func startSingleRecognizer(language: TranslationLanguage) async -> LiveTranslateRecognizer? {
        guard let localeID = language.speechLocale else { return nil }
        let locale = Locale(identifier: localeID)
        defaultLineLanguage = language
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if await LiveTranslateAnalyzerRecognizer.supports(locale) {
                // 新引擎一路流到底，提示词只在开始时给（改了专有名词要重新开始才生效）。
                let analyzer = LiveTranslateAnalyzerRecognizer(locale: locale, router: router,
                                                               vocabulary: LiveTranslateSettings.vocabulary)
                wire(analyzer)
                do {
                    try await analyzer.start()
                    channelStates = [LiveTranslateChannelState(language: language, mode: .onDevice)]
                    return analyzer
                } catch {
                    // 模型下载失败等 → 回退旧引擎，清掉「正在下载」提示。
                    analyzer.stop()
                    if isRunning { notice = nil }
                }
            }
        }
        #endif
        guard let speech = SFSpeechRecognizer(locale: locale), speech.isAvailable else {
            return nil
        }
        let legacy = LiveTranslateLegacyRecognizer(recognizer: speech, router: router)
        wire(legacy)
        do {
            try await legacy.start()
        } catch {
            return nil
        }
        // 装了本机模型就走本机（不要求本机也一样：系统只要有本机模型就用它，实测 2026-11-05）。
        channelStates = [LiveTranslateChannelState(language: language,
                                                   mode: speech.supportsOnDeviceRecognition ? .onDevice : .server)]
        return legacy
    }

    private func wire(_ recognizer: LiveTranslateRecognizer) {
        recognizer.onUpdate = { [weak self] id, text, isFinal in
            guard let self else { return }
            self.upsert(id: self.lineIDBase + id, text: text, isFinal: isFinal)
        }
        recognizer.onLanguage = { [weak self] id, language in
            guard let self else { return }
            self.setLanguage(language, forLine: self.lineIDBase + id)
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
        beat.updates += 1
        // 识别延迟：最新那句多出了字 → 取走「停顿后开口」的时刻（旧句迟到的定稿不算）。
        let shownBefore = lines.last.map { $0.id == id ? $0.raw.count : ($0.id < id ? 0 : Int.max) } ?? 0
        if text.count > shownBefore, let onset = router.takeOnset(maxAge: 6) {
            recognitionLatency = recognitionSamples.add(Date().timeIntervalSince(onset))
        }
        if let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index].raw = text
            lines[index].original = text
            lines[index].isFinal = isFinal
        } else {
            // 已被挤出字幕条的旧句迟到的结果，丢弃。
            if let first = lines.first, id < first.id, lines.count >= Self.historyLines { return }
            // 新的一句开始了：之前没收到 final 的句子也不会再变，按定稿显示（也就可以记下了）。
            for index in lines.indices where lines[index].id < id && !lines[index].isFinal {
                lines[index].isFinal = true
                record(lines[index])
            }
            beat.newLines += 1
            lines.append(Line(id: id, original: text, translation: "", isFinal: isFinal, raw: text))
            lines.sort { $0.id < $1.id }
            if lines.count > Self.historyLines {
                lines.removeFirst(lines.count - Self.historyLines)
            }
        }
        if notice == L("livetranslate.notice.downloadingModel") { notice = nil }
        if let index = lines.firstIndex(where: { $0.id == id }) {
            if bar?.translates == true {
                submitUnits(lineIndex: index)
            }
            record(lines[index])
        }
    }

    // MARK: - 本地记录

    /// 开始：新建一份记录；改设置后的重启接着写原来那份（设置变了记一行「改为：…」）。
    private func startTranscript(_ config: LiveTranslateTranscript.Config) {
        if let transcript {
            transcript.continueWith(config, at: Date())
            return
        }
        guard LiveTranslateRecordSettings.enabled else { return }
        let transcript = LiveTranslateTranscript(start: Date(), config: config)
        transcript.onWriteError = { [weak self] message in
            guard let self, self.isRunning else { return }
            self.notice = L("livetranslate.record.writeFailed \(message)")
        }
        self.transcript = transcript
        lastTranscript = transcript
        transcriptURL = nil
        recording = true
    }

    /// 停止：写结束时间、整理纪要（App 退出时同步写完、不整理）。
    private func finishTranscript() {
        guard let transcript else { return }
        self.transcript = nil
        transcriptURL = nil
        recording = false
        transcript.finish(at: Date(), terminating: terminating)
    }

    /// 手动开 / 关记录（字幕条「记录」菜单、设置页）：记住选择；正在实时翻译时立刻生效 ——
    /// 开：从现在起记，字幕条上已经有的几句也补进去；关：这一份就此收尾（写结束时间、整理纪要）。
    func setRecording(_ on: Bool) {
        if LiveTranslateRecordSettings.enabled != on {
            LiveTranslateRecordSettings.enabled = on
        }
        guard isRunning else { return }
        if on {
            guard transcript == nil, let transcriptConfig else { return }
            startTranscript(transcriptConfig)
            for line in lines {
                record(line)
            }
        } else if transcript != nil {
            for line in lines {
                record(line, force: true)
            }
            finishTranscript()
        }
    }

    /// 记进本地记录：说完（定稿）的句子；停止时 `force` 把最后那句没定稿的也记上。
    private func record(_ line: Line, force: Bool = false) {
        guard let transcript, line.isFinal || force else { return }
        let original = line.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        transcript.update(key: "\(run)-\(line.id)", time: line.startedAt, original: original,
                          translation: line.translates ? line.translation : "")
        if transcriptURL == nil, isRunning { transcriptURL = transcript.fileURL }
    }

    /// 这句此刻译成什么语言；nil = 它本来就是「译成」的语言，不翻。
    private func target(forLine id: Int) -> TranslationLanguage? {
        let language = lineLanguages[id] ?? defaultLineLanguage
        return LiveTranslateSettings.target(for: language, target: sessionTarget)
    }

    /// 边说边翻（docs/live-translate/DESIGN.md §3.2）：说完的单元有变化才提交（按定稿排队，各翻一次）；
    /// 最后那截还在说的按草稿提交（只留最新的一条）。每次翻译都很短，长段落也跟得上语速。
    private func submitUnits(lineIndex index: Int) {
        var line = lines[index]
        let language = lineLanguages[line.id] ?? defaultLineLanguage
        let target = self.target(forLine: line.id)
        let cjk = language.isChinese || language.code == "ja" || language.code == "ko"
        let pieces = LiveTranslateUnits.split(line.raw, cjk: cjk)
        // 中文单元先纠错、纠完再翻（`applyCorrection`）；其余直接翻。纠错模型还在加载（第一次要 9 秒左右，比翻译模型还慢，
        // 实测 2026-11-05）时先不纠、直接翻，第一句不用陪着等它。
        let corrects = correcting && language.isChinese && !OfflineTranslator.corrector.isStartingServer
        let complete = Array((line.isFinal ? pieces : pieces.dropLast()).prefix(Self.tailUnit))
        let tail = line.isFinal ? "" : (pieces.last ?? "")

        var tailBecameUnit = false
        for (unit, text) in complete.enumerated() {
            var draftCovers = false
            if unit < line.units.count {
                guard line.units[unit] != text else { continue }
                line.units[unit] = text
                line.draftUnits.remove(unit)
            } else {
                line.units.append(text)
                // 刚说完的这截此前当草稿翻过：先拿草稿译文顶着，正式译文回来再换，字幕不闪。
                if !line.tail.isEmpty, text.hasPrefix(line.tail) || line.tail.hasPrefix(text) {
                    line.unitTranslations[unit] = line.tailTranslation
                    tailBecameUnit = true
                    draftCovers = !line.tailTranslation.isEmpty && Self.sameWords(line.tailTranslationSource, text)
                }
            }
            let key = line.id * Self.unitsPerLine + unit
            if draftCovers, let target {
                // 草稿翻的正好就是这一整截（不计标点空格）：草稿就是它的译文，现在就读 —— 不等纠错和正式翻译
                // （2026-11-05 用户：译文都出来了，过几秒才有声音）。不纠错时连正式翻译也省了，模型少排一条，
                // 后面的句子也快；纠错照常，纠完没改字就沿用草稿（`applyCorrection`）。
                line.draftUnits.insert(unit)
                speak(&line, unit: unit, text: line.tailTranslation, language: target)
                translationLatency = translationSamples.add(0)
                if corrects {
                    corrector.submit(key: key, text: text, context: correctionContext(line, before: unit))
                }
                continue
            }
            if target != nil { unitSubmittedAt[key] = Date() }
            if corrects {
                // 不翻的中文句也纠错：纠正后的原文就是这句的字幕。
                corrector.submit(key: key, text: text, context: correctionContext(line, before: unit))
            } else if let target {
                translator.submit(id: key, text: text, isFinal: true, target: target.code)
            }
        }
        if line.units.count > complete.count {
            for unit in complete.count..<line.units.count {
                line.unitTranslations[unit] = nil
                line.corrections[unit] = nil
                line.correctionSources[unit] = nil
                line.draftUnits.remove(unit)
            }
            line.units.removeLast(line.units.count - complete.count)
        }
        // 草稿已经挪给了单元：清掉，免得同一截译文在字幕上出现两遍（实测 2026-11-05 的重复译文）。
        if tailBecameUnit {
            line.tailTranslation = ""
            line.tailTranslationSource = ""
        }
        if tail != line.tail {
            line.tail = tail
            if let target, !tail.isEmpty {
                translator.submit(id: line.id * Self.unitsPerLine + Self.tailUnit, text: tail,
                                  isFinal: false, target: target.code)
            } else {
                line.tailTranslation = ""
                line.tailTranslationSource = ""
            }
        }
        line.translates = target != nil
        line.translation = target.map { Self.compose(line, target: $0) } ?? ""
        line.original = Self.composeOriginal(line)
        lines[index] = line
        refreshPendingTranslation()
    }

    // MARK: - 心跳日志

    /// 一行看全链路：音频没来 → 采集的问题；有人声却没有识别更新 → 识别卡了；排着的翻译只增不减 → 翻译卡了；
    /// 朗读积压越来越多 → 朗读卡了。只记数字，不记内容。
    private func logHeartbeat() {
        guard isRunning else { return }
        let audio = router.takeStats()
        let oldest = translationPendingSince.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "-"
        let beat = self.beat
        self.beat = Beat()
        LiveTranslateLog.recognition.notice(
            "heartbeat: audio \(audio.buffers) buffers \(String(format: "%.1f", audio.seconds), privacy: .public)s (voiced \(String(format: "%.1f", audio.voiced), privacy: .public)s, paused for read-aloud \(String(format: "%.1f", audio.muted), privacy: .public)s) | recognition \(beat.updates) updates, \(beat.newLines) new lines | corrected \(beat.corrected), translated \(beat.translated), waiting \(self.unitSubmittedAt.count) (oldest \(oldest, privacy: .public)) | read-aloud backlog \(self.voice.backlog)")
    }

    // MARK: - 延迟监控

    private func resetLatency() {
        recognitionLatency = nil
        translationLatency = nil
        translationPendingSince = nil
        recognitionSamples = LiveTranslateLatencySamples()
        translationSamples = LiveTranslateLatencySamples()
        unitSubmittedAt = [:]
    }

    /// 等译文的单元里去掉已经不在的（句子被挤出字幕条、单元被改判重切），再更新「最早在等的」。
    private func refreshPendingTranslation() {
        var unitCounts: [Int: Int] = [:]
        for line in lines { unitCounts[line.id] = line.units.count }
        unitSubmittedAt = unitSubmittedAt.filter { key, _ in
            guard let count = unitCounts[key / Self.unitsPerLine] else { return false }
            return key % Self.unitsPerLine < count
        }
        let oldest = unitSubmittedAt.values.min()
        if oldest != translationPendingSince { translationPendingSince = oldest }
    }

    /// 某单元此刻用来翻译的原文：有对得上的 AI 纠正结果就用它，否则用识别原文。
    private static func effectiveText(_ line: Line, unit: Int) -> String {
        let text = line.units[unit]
        guard line.correctionSources[unit] == text, let corrected = line.corrections[unit] else { return text }
        return corrected
    }

    /// 显示用的原文：没有任何纠正时就是识别原文；有的话按单元拼（纠正只对中文，直接连写）+ 还在说的那截。
    private static func composeOriginal(_ line: Line) -> String {
        let changed = line.units.indices.contains { effectiveText(line, unit: $0) != line.units[$0] }
        guard changed else { return line.raw }
        let parts = line.units.indices.map { effectiveText(line, unit: $0) }
        return (parts + (line.tail.isEmpty ? [] : [line.tail])).joined()
    }

    /// 纠错的上文：这句前面已说完的单元（用纠正后的），不够长再接上一句，最多 100 字。
    private func correctionContext(_ line: Line, before unit: Int) -> String {
        var context = (0..<unit).map { Self.effectiveText(line, unit: $0) }.joined()
        if context.count < 60, let previous = lines.last(where: { $0.id < line.id }) {
            context = previous.original + context
        }
        return String(context.suffix(100))
    }

    /// AI 纠正结果回来了：这一单元没再变就记下、换掉显示的原文，再按纠正后的文字翻译。
    private func applyCorrection(key: Int, source: String, corrected: String) {
        let id = key / Self.unitsPerLine
        let unit = key % Self.unitsPerLine
        guard isRunning, let index = lines.firstIndex(where: { $0.id == id }) else { return }
        var line = lines[index]
        guard unit < line.units.count, line.units[unit] == source else { return }
        beat.corrected += 1
        line.correctionSources[unit] = source
        line.corrections[unit] = corrected
        line.original = Self.composeOriginal(line)
        lines[index] = line
        if corrected != source {
            LiveTranslateLog.recognition.notice("ai correction changed a \(source.count)-char unit")
        }
        record(line)
        // 没改字、草稿已经是这段原文的译文（也已经读过了）：不用再翻一遍。
        if corrected == source, line.draftUnits.contains(unit) { return }
        if let target = target(forLine: id) {
            translator.submit(id: key, text: corrected, isFinal: true, target: target.code)
        }
    }

    /// 朗读：每个单元只读一次。
    private func speak(_ line: inout Line, unit: Int, text: String, language: TranslationLanguage) {
        guard speaksTranslations, !text.isEmpty, !line.spokenUnits.contains(unit) else { return }
        line.spokenUnits.insert(unit)
        voice.speak(text, language: language)
    }

    /// 两段文字去掉标点、空格、大小写后是否一样（草稿是不是正好翻的这一整截）。
    private static func sameWords(_ lhs: String, _ rhs: String) -> Bool {
        func words(_ text: String) -> String {
            String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }))
        }
        let left = words(lhs)
        return !left.isEmpty && left == words(rhs)
    }

    private static func compose(_ line: Line, target: TranslationLanguage) -> String {
        let joiner = target.isChinese || target.code == "ja" ? "" : " "
        var parts = line.units.indices.compactMap { line.unitTranslations[$0] }.filter { !$0.isEmpty }
        if !line.tail.isEmpty, !line.tailTranslation.isEmpty {
            parts.append(line.tailTranslation)
        }
        return parts.joined(separator: joiner)
    }

    /// 双识别器报告某句是哪种语言（定稿时可能改判）：改判后旧方向的译文作废，等新译文。
    private func setLanguage(_ language: TranslationLanguage, forLine id: Int) {
        guard isRunning else { return }
        if let old = lineLanguages[id], old != language,
           let index = lines.firstIndex(where: { $0.id == id }) {
            // 改判了语言 = 换了翻译方向：已翻的单元全部作废，紧接着的 upsert 会按新方向重提。
            lines[index].translation = ""
            lines[index].units = []
            lines[index].unitTranslations = [:]
            lines[index].tail = ""
            lines[index].tailTranslation = ""
            lines[index].corrections = [:]
            lines[index].correctionSources = [:]
            lines[index].tailTranslationSource = ""
            lines[index].draftUnits = []
            refreshPendingTranslation()
        }
        lineLanguages[id] = language
        // 只留最近几句的记录。
        if lineLanguages.count > 16, let oldest = lineLanguages.keys.min() {
            lineLanguages[oldest] = nil
        }
    }

    private func applyTranslation(job: Int, source: String, target: String, text: String) {
        let id = job / Self.unitsPerLine
        let unit = job % Self.unitsPerLine
        guard isRunning, let index = lines.firstIndex(where: { $0.id == id }) else { return }
        // 这句后来改判了语言（换了方向，或成了不用翻的）：旧方向的结果不要。
        guard let lineTarget = self.target(forLine: id), lineTarget.code == target else { return }
        var line = lines[index]
        if unit == Self.tailUnit {
            // 草稿：那截还在说就用（略旧也比空着强）；已经说完了就不要了。
            guard !line.tail.isEmpty else { return }
            line.tailTranslation = text
            line.tailTranslationSource = source
        } else {
            // 这一单元后来又改了（或换成了纠正后的文字）：等新提交的那次结果。
            guard unit < line.units.count, Self.effectiveText(line, unit: unit) == source else { return }
            line.unitTranslations[unit] = text
            beat.translated += 1
            if let submitted = unitSubmittedAt.removeValue(forKey: job) {
                translationLatency = translationSamples.add(Date().timeIntervalSince(submitted))
            }
            // 朗读：每个说完的单元读一次（正式译文；草稿只在正好翻的是这一整截时、说完那一刻读，见 submitUnits）。
            speak(&line, unit: unit, text: text, language: lineTarget)
        }
        line.translation = Self.compose(line, target: lineTarget)
        lines[index] = line
        refreshPendingTranslation()
        record(line)
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

/// 延迟监控的一个指标：最近 5 次的中位数（偶尔一次离群的不让数字乱跳）。
struct LiveTranslateLatencySamples {
    private var recent: [TimeInterval] = []

    mutating func add(_ value: TimeInterval) -> TimeInterval {
        recent.append(max(0, value))
        if recent.count > 5 { recent.removeFirst(recent.count - 5) }
        let sorted = recent.sorted()
        return sorted[sorted.count / 2]
    }
}
