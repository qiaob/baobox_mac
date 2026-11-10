import AppKit
import AVFoundation
import Speech

extension AIFeature {
    /// 字幕与同传、会议的翻译用哪个引擎 / 模型（docs/ai-service/DESIGN.md §3.3）。新键没值时读旧的共用键 `translation.engine`。
    static let liveTranslate = AIFeature(id: "livetranslate.translate", kind: .translation,
                                         legacyKey: TranslationSettings.legacyEngineKey)
    /// 中文识别纠错用哪个模型（出厂本地）。会议只转录时也按它走（docs/ai-service/DESIGN.md §5.3）。
    static let liveCorrection = AIFeature(id: "livetranslate.correct", kind: .generation)
}

extension AIFeatureDefinition {
    static var liveTranslate: AIFeatureDefinition {
        AIFeatureDefinition(feature: .liveTranslate, title: L("livetranslate.ai.translate"),
                            sends: L("livetranslate.ai.translateSends"), shortTitle: L("livetranslate.ai.translateShort"))
    }

    static var liveCorrection: AIFeatureDefinition {
        // 边说边纠，每句要一秒内：建议最快的。
        AIFeatureDefinition(feature: .liveCorrection, title: L("livetranslate.ai.correct"),
                            sends: L("livetranslate.ai.correctSends"), advice: .fastest,
                            shortTitle: L("livetranslate.ai.correctShort"))
    }
}

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

/// 说话语言的显示名（设置页、字幕条、记录头信息）。类型与设置在 Core（`SpeechLanguages` / `SpeechSettings`），
/// 显示名用 `L()`，留在这边。
extension SpeechLanguages {
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

/// 说话语言（含自动 A / B）与专有名词表不在这里：字幕与同传、会议、听写共用，键与读写在 `SpeechSettings`（Core/Translation）。
enum LiveTranslateSettings {
    static let sourceKey = "livetranslate.source"
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
    static let targetKey = "livetranslate.target"

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

    /// 译成什么（默认：说的是中文 → 英文，否则 → 中文，与旧版「英中互译」一致）。
    static var target: TranslationLanguage {
        get {
            if let stored = TranslationLanguage.from(code: UserDefaults.standard.string(forKey: targetKey)) {
                return stored
            }
            if case .fixed(let language) = SpeechSettings.speech, language.isChinese { return .english }
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
    static func recognitionRoutes(for speech: SpeechLanguages) -> [LiveTranslateRecognitionRoute] {
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
        /// 线上会议定稿时按两路音量判的「我 / 对方」（`speakerSettled` 之后不再变；判不准为 nil）。
        var speaker: MeetingSpeaker?
        var speakerSettled = false
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
    /// `finish()` 正在等最后一句定稿：这期间不因改设置重启。
    private var isFinishing = false
    private var recognizer: LiveTranslateRecognizer?
    private let router = LiveTranslateAudioRouter()
    private var audioSource: LiveTranslateAudioSource?
    private var bar: LiveTranslateBarController?
    private var translationErrorShown = false
    private var cloudFallbackShown = false

    // 本次运行的语言配置（开始时定下，运行中改设置会重启）。
    private var sessionTarget: TranslationLanguage = .simplifiedChinese
    /// 单识别器时每句的语言；双识别器逐句报告（`lineLanguages`）。
    private var defaultLineLanguage: TranslationLanguage = .english
    private var lineLanguages: [Int: TranslationLanguage] = [:]
    /// 离线模型 / 云端服务的翻译循环（系统翻译时由字幕条上的翻译会话驱动，不用它）。
    private var offlineTask: Task<Void, Never>?
    /// 本次翻译让哪个本地推理进程常驻（内置离线模型或本机大模型；云端为 nil）。
    private var translationKeepAlive: OfflineTranslator?
    /// 本次 AI 纠错走哪边；走本地（内置或本机大模型）时那个模型常驻。
    private var correctionRoute: AIRoute = .local
    private var correctionKeepAlive: OfflineTranslator?
    /// 在「AI」页或模块页改了这两个功能用的模型：运行中就重启，按新设置跑。
    private var featureObserver: NSObjectProtocol?

    /// 字幕条保留的句数：拉高字幕条可以往上翻（完整的在本地记录里）。
    private static let historyLines = 200

    /// 自由听译的本地记录（docs/live-translate/DESIGN.md §6）：会议库开的一份（`FreeListeningLibrary`），写成什么样、写到哪由它定；
    /// 没开记录为 nil。托管会话（会议）从不建：会议的文档由会议自己写。
    private var transcript: FreeListeningRecord?
    /// 字幕条「记录」菜单里「打开本次记录」用；还没记下任何一句时为 nil（文件还没建）。托管会话是配置里的 `documentURL`。
    @Published private(set) var transcriptURL: URL?
    /// 这一次正在记录（字幕条「记录」按钮）：自由听译 = 在保存记录；托管会话 = 会议没暂停。
    @Published private(set) var recording = false
    /// 本次的音源、语言（中途打开记录时新建记录要用）。
    private var transcriptConfig: MeetingEngineRun?
    /// 托管会话（会议）这一场开到了「开始记」那一步（第一次 `startFlow` 问完权限）：从这时到会话结束，字幕条的「记录」按钮
    /// 跟着会议的暂停走，记下第一句后「打开本次记录」指向 `documentURL`；改设置重启时不动（docs/meeting/ENGINE.md §4.5.2）。
    private var hostedRecording = false
    /// 第几次开始：改设置重启后接着写同一份记录，而句子 id 会从头编，记录里按「第几次 + id」区分。
    private var run = 0
    /// 正在因为改设置而重启：停止时不收尾记录、不清字幕历史，接着写 / 接着显示。
    private var restarting = false
    /// 识别器的句子 id 每次开始都从头编；改设置重启后字幕历史还留着，新句子的 id 加上这个偏移，免得和旧句子撞号。
    private var lineIDBase = 0
    /// App 正在退出：记录同步写完，不整理纪要。
    private var terminating = false

    // MARK: 会话配置（docs/meeting/TECH_DESIGN.md §2.1）

    /// 本次会话的配置（开始时定下；改设置重启时按 `rebuild` 重组）。开过会话之前是个占位，不拿它开会话：
    /// 会话都由适配器给配置（带着会议库），见 `toggle(startingWith:)`、`start(config:)`。
    private var sessionConfig = LiveTranslateSessionConfig.fromSettings(recordLibrary: nil)
    /// 本次会话还没报过 `.ended`（改设置引起的重启不算结束）。
    private var sessionOpen = false
    /// 会议的混音链路（电平、说话人能量、暂停）；实时翻译的单路音源时为 nil。
    private var mixedSource: LiveTranslateMixedSource?
    /// 会议暂停中：不往识别器送音频（会话不停）。跨改设置的重启保留。
    private var audioPaused = false
    /// 会议里单独不录的那几路（`LiveTranslateMixerCore` 的 lane），跟暂停一样跨「改设置引起的重启」保留。
    private var mutedLanes: Set<Int> = []
    /// 上一句定稿时两路的累计人声时长：这一句的说话人按「定稿时 − 它」判。
    private var speakerBaseline = LiveTranslateLaneStats()
    /// 字幕条此刻显示着（会议的「字幕」开关据此同步）。
    @Published private(set) var barVisible = false
    /// 运行中切字幕条：后来的切换让还在路上的那次作废。
    private var barGeneration = 0

    private init() {
        translator.onResult = { [weak self] job, source, target, text in
            self?.applyTranslation(job: job, source: source, target: target, text: text)
        }
        corrector.onResult = { [weak self] key, source, corrected, translation in
            self?.applyCorrection(key: key, source: source, corrected: corrected, translation: translation)
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
        translator.onFallback = { [weak self] in
            self?.showCloudFallbackOnce()
        }
        corrector.onFallback = { [weak self] in
            self?.showCloudFallbackOnce()
        }
        featureObserver = NotificationCenter.default.addObserver(
            forName: AIFeatureSettings.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String,
                  id == AIFeature.liveTranslate.id || id == AIFeature.liveCorrection.id else { return }
            MainActor.assumeIsolated {
                self?.restartIfRunning()
            }
        }
    }

    // MARK: - 开关

    /// 「开始自由听译」开关（菜单、`livetranslate.toggle`）：没在跑 → 按给的配置开（适配器给 `.fromSettings(recordLibrary:)`，
    /// 带着会议库，docs/meeting/ENGINE.md §4.6）；自由听译中 → 停。
    func toggle(startingWith config: LiveTranslateSessionConfig) {
        // 会议记录中：开关 = 打开 / 收起字幕（docs/meeting/REQUIREMENTS.md §1：记录中再点「自由听译」不另开）。
        if isRunning, let onUserRequest = sessionConfig.onUserRequest {
            onUserRequest(.toggle)
            return
        }
        if isRunning { stop() } else { start(config: config) }
    }

    /// 按给定配置开一次会话。正在运行 / 正在开始、或麦克风被别的会话占着时返回 false（后者发一条宠物提示）。
    @discardableResult
    func start(config: LiveTranslateSessionConfig) -> Bool {
        guard !isRunning, !isStarting else { return false }
        // 与会议记录、听写互斥（设备端识别同一时间只能跑一个请求），见 Core/AudioCaptureCoordinator。
        guard AudioCaptureCoordinator.shared.claim(owner: config.owner, label: config.label,
                                                   microphone: config.sources.usesMicrophone) else {
            if let message = AudioCaptureCoordinator.shared.busyMessage() {
                NotifyCenter.shared.post(PetNotification(source: config.owner, level: .ambient, title: message))
            }
            return false
        }
        if !sessionOpen {
            // 新的一次会话（不是改设置引起的重启）：暂停、单路静音都从头来。
            audioPaused = false
            mutedLanes = []
        }
        sessionConfig = config
        sessionOpen = true
        isStarting = true
        Task { await self.startFlow() }
        return true
    }

    /// 改了音源 / 语言 / 翻译开关等需要重建识别链路的设置后调用。本地记录接着写同一份。
    /// 自由听译按设置重组，会议库照旧是这次会话带来的那个。
    func restartIfRunning() {
        guard isRunning, !isFinishing else { return }
        let next = sessionConfig.rebuild?() ?? .fromSettings(recordLibrary: sessionConfig.recordLibrary)
        restarting = true
        stop()
        restarting = false
        start(config: next)
    }

    /// 这次是别的模块托管的会话（会议记录），不是实时翻译自己。
    var isHostedSession: Bool { (isRunning || isStarting) && !sessionConfig.followsSettings }

    /// 字幕条上能换音源（实时翻译）；会议的音源由会议类型定。
    var showsSourceMenu: Bool { sessionConfig.followsSettings }

    /// 字幕条「打开记录文件夹」打开哪：当前会话配置里的会议库目录（自由听译、会议都带着，docs/meeting/ENGINE.md §4.6）。
    var recordFolder: URL? { sessionConfig.recordLibrary?.folderURL }

    /// App 退出：停下来，自由听译的记录同步写完；托管会话剩下的句子与 `.ended` 在返回前同步报完。
    /// 还在整理的纪要（会议的、自由听译的）由会议在退出时统一标「没整理完」（docs/meeting/ENGINE.md §4.5.5）。
    func terminate() {
        terminating = true
        stop()
        finishTranscript()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        AudioCaptureCoordinator.shared.release(owner: sessionConfig.owner)
        // 线上会议：最后那句还没定稿也判一下说话人（音源还没停，累计值还在）。
        for index in lines.indices where !lines[index].isFinal {
            settleSpeaker(index)
        }
        // 记录：最后那句还没定稿也记上（托管会话经 onFinalLine 报给会议，都在 .ended 之前）；改设置重启时接着写，
        // 否则收尾（结束时间、整理纪要）。
        for line in lines {
            record(line, force: true)
        }
        if !restarting {
            finishTranscript()
        }
        audioSource?.stop()
        audioSource = nil
        mixedSource = nil
        recognizer?.stop()
        recognizer = nil
        router.setSink(nil)
        translator.reset()
        corrector.reset()
        offlineTask?.cancel()
        offlineTask = nil
        translationKeepAlive?.endKeepAlive()
        translationKeepAlive = nil
        correctionKeepAlive?.endKeepAlive()
        correctionKeepAlive = nil
        correcting = false
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
        barVisible = false
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
        if !restarting {
            endSession()
        }
    }

    /// 会话真的结束了（不是改设置引起的重启）：告诉托管方一次。
    private func endSession() {
        guard sessionOpen else { return }
        sessionOpen = false
        audioPaused = false
        mutedLanes = []
        sessionConfig.onLifecycle?(.ended)
    }

    private func startFlow() async {
        var config = sessionConfig
        if config.followsSettings {
            // 实时翻译：音源、语言就在这里现读 —— 与改造前读设置的时刻一样（`start()` 到这里之间改了也算数）。
            config.sources = LiveTranslateSessionConfig.Sources(LiveTranslateSettings.source)
            config.speech = SpeechSettings.speech
            config.target = LiveTranslateSettings.target
        }
        // 没能开起来（权限被拒、识别不可用…）：改设置重启时留着的记录也就此收尾。
        defer {
            isStarting = false
            if !isRunning {
                finishTranscript()
                lines = []
                // 没开起来（权限被拒、识别不可用…）：让出占用。
                AudioCaptureCoordinator.shared.release(owner: config.owner)
                endSession()
            }
        }
        let source = config.sources
        let speech = config.speech
        let target = config.target

        // 新引擎本身不一定要这项授权，但回退到旧引擎时要；统一先问，免得运行中途弹窗。
        guard await Self.ensureSpeechPermission() else {
            presentAlert(title: L("livetranslate.alert.speechDeniedTitle"),
                         message: L("livetranslate.alert.speechDeniedMessage"),
                         settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            return
        }

        // 线上会议两样都要：先麦克风，再屏幕录制（系统声音）。
        if source.usesMicrophone {
            guard await Self.ensureMicrophonePermission() else {
                presentAlert(title: L("livetranslate.alert.micDeniedTitle"),
                             message: L("livetranslate.alert.micDeniedMessage"),
                             settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                return
            }
        }
        if source.usesSystemAudio {
            guard Permissions.hasScreenRecording else {
                Permissions.requestScreenRecording()
                presentAlert(title: L("livetranslate.alert.screenTitle"),
                             message: L("livetranslate.alert.screenMessage"),
                             settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                return
            }
        }

        if config.followsSettings {
            // 同上：翻译、纠错开关在权限都问完之后现读（改造前就是在这里读的）。
            config.translate = LiveTranslateSettings.translateEnabled
            config.correction = LiveTranslateSettings.aiCorrection ? .whenTranslating : .off
            sessionConfig.sources = config.sources
            sessionConfig.speech = config.speech
            sessionConfig.target = config.target
            sessionConfig.translate = config.translate
            sessionConfig.correction = config.correction
        }
        // 翻译引擎与方向：每种可能出现的语言各一个方向（自动模式两个）；本来就是「译成」那种的不用翻。
        let directions = Self.directions(speech: speech, target: target)
        var engine: TranslationEngineKind? = config.translate ? TranslationSettings.resolve(.liveTranslate) : nil
        if engine == .system, TranslationSettings.canFallBackToOffline(.liveTranslate),
           await !TranslationSettings.systemSupports(directions) {
            engine = .offline
        }
        // 系统翻译的会话挂在字幕条上：这次不显示字幕条（会议默认）就只能用离线模型翻，或者不翻。
        if engine == .system, !config.showsBar {
            engine = TranslationSettings.canFallBackToOffline(.liveTranslate) ? .offline : nil
        }

        // 字幕历史：手动停止时已经清空；改设置重启时留着（见 stop）。新句子的 id 排在留下的后面。
        lineIDBase = (lines.map(\.id).max() ?? 0) + 1
        lineLanguages = [:]
        notice = nil
        translationErrorShown = false
        cloudFallbackShown = false
        translator.reset()
        resetLatency()
        sessionTarget = target
        sessionEngine = engine
        channelStates = []
        corrector.reset()
        // 纠错：实时翻译跟着翻译走（按单元纠、纠完再翻）；会议只转录原文时也纠（与翻译解耦）。本地模型常驻，免得每句都等加载。
        // 走哪边按「AI 纠错」这个功能选的模型，会议只转录时也一样（docs/ai-service/DESIGN.md §5.3）。
        correctionRoute = AIService.shared.route(for: .liveCorrection)
        corrector.route = correctionRoute
        let correctionReady = AIService.shared.isReady(correctionRoute, local: .generation)
        switch config.correction {
        case .off: correcting = false
        case .always: correcting = correctionReady
        case .whenTranslating: correcting = engine != nil && correctionReady
        }
        if correcting, let backend = AIService.shared.localBackend(for: correctionRoute, local: .generation) {
            backend.beginKeepAlive()
            correctionKeepAlive = backend
        }
        virtualDevices = LiveTranslateAudioDevice.virtualDevices()
        if engine != nil, LiveTranslateVoiceSettings.enabled {
            startVoice(source: source, target: target)
        }
        defaultLineLanguage = speech.languages.first ?? .english
        run += 1
        let recordConfig = MeetingEngineRun(
            source: source.title, speech: speech.title,
            target: config.translate && engine != nil ? target.endonym : nil)
        transcriptConfig = recordConfig
        startTranscript(recordConfig)
        isRunning = true
        beat = Beat()
        _ = router.takeStats()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logHeartbeat()
            }
        }

        if config.translate && engine == nil {
            notice = L("livetranslate.notice.needsOfflineModel")
        } else if engine != nil, directions.isEmpty {
            // 说的就是「译成」的语言：只显示原文，提示一下免得以为坏了。
            notice = L("livetranslate.notice.sameLanguage \(target.endonym)")
        }
        if config.showsBar {
            let bar = LiveTranslateBarController(controller: self, translates: engine != nil,
                                                 systemPairs: engine == .system ? directions : [])
            self.bar = bar
            bar.show()
        }
        barVisible = config.showsBar
        if let engine, engine != .system {
            startModelTranslation(engine)
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

        // 实时翻译：原来的单路音源。会议：混音链路（线上两路，线下只有麦克风）。
        let audio: LiveTranslateAudioSource
        var mixed: LiveTranslateMixedSource?
        switch source {
        case .microphone where !config.usesMixer: audio = LiveTranslateMicSource(router: router)
        case .system where !config.usesMixer: audio = LiveTranslateSystemAudioSource(router: router)
        default:
            let created = LiveTranslateMixedSource(router: router, microphone: source.usesMicrophone,
                                                   system: source.usesSystemAudio)
            created.setPaused(audioPaused)
            for lane in mutedLanes { created.setMuted(true, lane: lane) }
            mixed = created
            audio = created
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
        mixedSource = mixed
        speakerBaseline = mixed?.laneTotals ?? LiveTranslateLaneStats()
        config.onLifecycle?(.started(recordConfig))
    }

    /// 每种可能出现的语言各一个翻译方向（自动模式两个）；本来就是「译成」那种的不用翻。
    private static func directions(speech: SpeechLanguages,
                                   target: TranslationLanguage) -> [(source: TranslationLanguage,
                                                                     target: TranslationLanguage)] {
        speech.languages.compactMap { language -> (source: TranslationLanguage, target: TranslationLanguage)? in
            LiveTranslateSettings.target(for: language, target: target).map { (source: language, target: $0) }
        }
    }

    /// 朗读译文：送会议（虚拟声卡）/ 外放。只有音源是麦克风（说话的是我）才送会议 —— 音源是系统声音时说话的是
    /// 会议里的别人，再送回会议，对方会听到自己的话被译过来读回去。原声混入同理只在麦克风时有。
    /// 线上会议的混音里也有对方的声音，同样不送会议；麦克风在混音里，外放时照样暂停识别防回授。
    private func startVoice(source: LiveTranslateSessionConfig.Sources, target: TranslationLanguage) {
        let meeting = source == .microphone
            ? LiveTranslateAudioDevice.device(uid: LiveTranslateVoiceSettings.meetingDeviceUID) : nil
        let mixOriginal = source == .microphone && meeting != nil && LiveTranslateVoiceSettings.mixOriginal
        // 不送会议就只能外放：「同时从音响播放」只在送会议时才有得选（2026-11-05 两个都关着 = 朗读没声音）。
        let speakers = meeting == nil || LiveTranslateVoiceSettings.speakers
        voice.start(meetingDevice: meeting, speakers: speakers, mixOriginal: mixOriginal)
        voice.prewarm(target)
        router.setMonitor(voice.originalSink)
        speaksTranslations = voice.isActive
        muteWhileSpeaking = source.usesMicrophone && speakers && !LiveTranslateVoiceSettings.keepListening
    }

    /// 离线模型 / 云端服务的翻译循环（系统翻译时由字幕条上的翻译会话驱动，不用它）。
    /// 离线模型时常驻；云端时不让本地模型白占内存，真要退回本地时再加载（之后空闲 10 分钟才退）。
    private func startModelTranslation(_ engine: TranslationEngineKind) {
        let route: AIRoute
        switch engine {
        case .cloud(let modelID): route = .cloud(modelID)
        case .localModel(let id): route = .localModel(id)
        case .offline, .system: route = .local
        }
        if let backend = AIService.shared.localBackend(for: route, local: .translation) {
            backend.beginKeepAlive()
            translationKeepAlive = backend
        }
        offlineTask = Task { [translator] in
            await translator.serveModel(route: route)
        }
    }

    /// 自动模式：双识别器；某一种语言的识别器不可用就退回单语言。
    private func startRecognizer(speech: SpeechLanguages) async -> LiveTranslateRecognizer? {
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
                                                               vocabulary: SpeechSettings.vocabulary)
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

    // MARK: - 托管会话（会议记录，docs/meeting/TECH_DESIGN.md §2.1）

    /// 结束并等最后一句定稿（会议结束、听写结束用；实时翻译的 ✕ / `stop` 不变）：先停音频 → 识别器 endAudio →
    /// 等最后一个 final（最多 1.5 秒）→ 再停（记录收尾、整理纪要照常；托管会话是最后几句报完再报 `.ended`，会议在那里收尾文档）。
    func finish() async {
        guard isRunning, !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        // 混音链路停的时候会把缓冲里剩下的那点声音送完（同步），之后识别器手里就是全部的音频了。
        audioSource?.stop()
        audioSource = nil
        if recognizer != nil {
            let gate = LiveTranslateOnceGate()
            Task { [weak self] in
                await self?.recognizer?.flush()
                gate.open()
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.finishTimeout * 1_000_000_000))
                gate.open()
            }
            await gate.wait()
        }
        stop()
    }

    private static let finishTimeout: TimeInterval = 1.5

    /// 字幕条右上角的 ✕：实时翻译 = 停止（原行为）；会议 = 收起字幕，会议照常记录。
    func closeBar() {
        if let onUserRequest = sessionConfig.onUserRequest {
            onUserRequest(.closeBar)
        } else {
            stop()
        }
    }

    /// 运行中显示 / 收起字幕条（会议控制条的「字幕」开关）。`translate`：同时开 / 关翻译 —— 系统翻译的会话挂在
    /// 字幕条上，收起字幕条翻译也就停了；已经翻好的留在字幕历史和记录里。只给托管会话用（实时翻译的字幕条一直在）。
    func setBarVisible(_ visible: Bool, translate: Bool) {
        guard isRunning, !sessionConfig.followsSettings else { return }
        sessionConfig.showsBar = visible
        sessionConfig.translate = visible && translate
        barGeneration += 1
        let generation = barGeneration
        Task { await self.applyBar(generation: generation) }
    }

    private func applyBar(generation: Int) async {
        let config = sessionConfig
        let directions = Self.directions(speech: config.speech, target: config.target)
        var engine: TranslationEngineKind?
        if config.translate {
            engine = TranslationSettings.resolve(.liveTranslate)
            if engine == .system, TranslationSettings.canFallBackToOffline(.liveTranslate),
               await !TranslationSettings.systemSupports(directions) {
                engine = .offline
            }
        }
        // 等系统翻译回话期间又切了一次 / 停了：以后来的为准。
        guard isRunning, generation == barGeneration else { return }
        if engine != sessionEngine {
            stopTranslation()
            sessionEngine = engine
            if let engine, engine != .system {
                startModelTranslation(engine)
            }
            if engine != nil, LiveTranslateVoiceSettings.enabled {
                startVoice(source: config.sources, target: config.target)
            }
        }
        bar?.hide()
        bar = nil
        if config.showsBar {
            let bar = LiveTranslateBarController(controller: self, translates: engine != nil,
                                                 systemPairs: engine == .system ? directions : [])
            self.bar = bar
            bar.show()
        }
        barVisible = config.showsBar
        if config.translate && engine == nil {
            notice = L("livetranslate.notice.needsOfflineModel")
        } else if engine != nil, directions.isEmpty {
            notice = L("livetranslate.notice.sameLanguage \(config.target.endonym)")
        } else if notice == L("livetranslate.notice.needsOfflineModel") {
            notice = nil
        }
    }

    /// 关掉这次的翻译（会议收起字幕）：排着的作废、离线模型不再常驻、朗读停下。
    private func stopTranslation() {
        translator.reset()
        offlineTask?.cancel()
        offlineTask = nil
        translationKeepAlive?.endKeepAlive()
        translationKeepAlive = nil
        voice.stop()
        router.setMonitor(nil)
        router.setMuted(false)
        speaksTranslations = false
        muteWhileSpeaking = false
        listeningPaused = false
        pausedAt = nil
        unitSubmittedAt = [:]
        translationPendingSince = nil
        sessionEngine = nil
    }

    /// 会议暂停 / 继续：暂停 = 不往识别器送音频，会话不停（手头那句照常定稿）。字幕条的「记录」按钮跟着变；
    /// 「暂停 / 继续」那行由会议记进它自己的文档（docs/meeting/ENGINE.md §4.5.2）。
    func setPaused(_ paused: Bool) {
        guard isRunning || isStarting, audioPaused != paused else { return }
        audioPaused = paused
        mixedSource?.setPaused(paused)
        if hostedRecording {
            recording = !paused
        }
    }

    /// 会议里单独不录某一路（麦克风 = 你的声音，系统声音 = 对方的声音）：这一路换成静音送进去，另一路照录。
    /// 只是 Baobox 不录，会议软件里照样听得到；说明行由会议记进它自己的文档。
    func setLaneMuted(_ muted: Bool, lane: Int) {
        guard isRunning || isStarting, mutedLanes.contains(lane) != muted else { return }
        if muted { mutedLanes.insert(lane) } else { mutedLanes.remove(lane) }
        mixedSource?.setMuted(muted, lane: lane)
    }

    /// 两路此刻的电平（控制条的电平点，取一次清一次）；不是混音链路时为 nil。
    func takeInputLevels() -> MeetingInputLevels? {
        mixedSource?.takeLevels()
    }

    /// 在字幕条上显示一行提示（会议的文档写盘失败时用）。没在运行就不显示 —— 同自由听译记录的写盘失败提示；字幕条收着就看不到。
    func showNotice(_ text: String) {
        guard isRunning else { return }
        notice = text
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
                settleSpeaker(index)
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
            if isFinal {
                settleSpeaker(index)
            }
            // 在翻译，或会议只转录但开着 AI 纠错：按单元处理（实时翻译里纠错只在翻译时开，两个条件等价于原来的「字幕条在翻译」）。
            if sessionEngine != nil || correcting {
                submitUnits(lineIndex: index)
            }
            record(lines[index])
        }
    }

    /// 线上会议：一句定稿时按这句期间两路的人声时长判「我 / 对方」（docs/meeting/TECH_DESIGN.md §2.2）。
    /// 这句的期间 = 上一句定稿到这句定稿（识别单元一个接一个）。不标说话人的会话什么也不做。
    private func settleSpeaker(_ index: Int) {
        guard let mixedSource, sessionConfig.speakers,
              lines.indices.contains(index), !lines[index].speakerSettled else { return }
        let totals = mixedSource.laneTotals
        lines[index].speaker = LiveTranslateSpeakerJudge.decide(totals - speakerBaseline)
        lines[index].speakerSettled = true
        speakerBaseline = totals
    }

    // MARK: - 本地记录

    /// 开始：新建一份记录；改设置后的重启接着写原来那份（设置变了记一行「改为：…」）。
    /// 托管会话（会议）不建记录：文档归会议，它在 `.started` 时建、重启时续写（docs/meeting/ENGINE.md §4.5.2）；
    /// 这里只在第一次开起来时把字幕条的「记录」按钮置为在记，重启时不动。
    private func startTranscript(_ config: MeetingEngineRun) {
        if !sessionConfig.followsSettings {
            guard !hostedRecording else { return }
            hostedRecording = true
            transcriptURL = nil
            recording = true
            return
        }
        if let transcript {
            transcript.continueWith(config, at: Date())
            return
        }
        guard LiveTranslateRecordSettings.enabled else { return }
        // 自由听译：新记录写进会议库（docs/meeting/TECH_DESIGN.md §2.3），会议库定写到哪、写成什么样。
        // 会议库跟着会话配置来（适配器开的会话都带着，docs/meeting/ENGINE.md §4.6），没带就不记录 —— 走不到。
        guard let library = sessionConfig.recordLibrary else {
            LiveTranslateLog.recognition.fault("free listening record skipped: no meeting library in the session config")
            return
        }
        let transcript = library.beginFreeListeningRecord(start: Date(), run: config,
                                                          summarizes: LiveTranslateRecordSettings.summary)
        transcript.onWriteError = { [weak self] message in
            guard let self, self.isRunning else { return }
            self.notice = message
        }
        self.transcript = transcript
        transcriptURL = nil
        recording = true
    }

    /// 停止：写结束时间、整理纪要（App 退出时同步写完、不整理）。托管会话只把字幕条的「记录」按钮复原 ——
    /// 会议在 `.ended` 里收尾它自己的文档。
    private func finishTranscript() {
        if hostedRecording {
            hostedRecording = false
            transcriptURL = nil
            recording = false
            return
        }
        guard let transcript else { return }
        self.transcript = nil
        transcriptURL = nil
        recording = false
        transcript.finish(at: Date(), terminating: terminating, summarizes: LiveTranslateRecordSettings.summary)
    }

    /// 手动开 / 关记录（字幕条「记录」菜单、设置页）：记住选择；正在实时翻译时立刻生效 ——
    /// 开：从现在起记，字幕条上已经有的几句也补进去；关：这一份就此收尾（写结束时间、整理纪要）。
    func setRecording(_ on: Bool) {
        if LiveTranslateRecordSettings.enabled != on {
            LiveTranslateRecordSettings.enabled = on
        }
        // 会议记录中：这个开关只管自由听译的记录，不动会议的转录。
        guard isRunning, sessionConfig.followsSettings else { return }
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

    /// 字幕条上的「记录」按钮：实时翻译 = 开 / 关保存记录（原行为）；会议 = 暂停 / 继续记录（交给会议，与控制条同步）。
    func toggleBarRecording() {
        if let onUserRequest = sessionConfig.onUserRequest {
            onUserRequest(.toggleRecording)
        } else {
            setRecording(!recording)
        }
    }

    /// 记进本地记录：说完（定稿）的句子；停止时 `force` 把最后那句没定稿的也记上。托管会话（会议）只经 `onFinalLine`
    /// 报给会议、由会议写进它自己的文档；记下第一句后字幕条的「打开本次记录」指向这场的 meeting.md（`documentURL`）。
    private func record(_ line: Line, force: Bool = false) {
        guard transcript != nil || sessionConfig.onFinalLine != nil, line.isFinal || force else { return }
        let original = line.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        let key = "\(run)-\(line.id)"
        let translation = line.translates ? line.translation : ""
        let entry = MeetingEngineLine(
            key: key, time: line.startedAt, original: original, translation: translation, speaker: line.speaker)
        sessionConfig.onFinalLine?(entry)
        if hostedRecording {
            if transcriptURL == nil, isRunning { transcriptURL = sessionConfig.documentURL }
            return
        }
        guard let transcript else { return }
        transcript.update(entry)
        if transcriptURL == nil, isRunning { transcriptURL = transcript.fileURL }
    }

    /// 这句此刻译成什么语言；nil = 它本来就是「译成」的语言，不翻（这次不翻译时一律 nil）。
    private func target(forLine id: Int) -> TranslationLanguage? {
        // 会议只转录、或字幕收起了：不翻。实时翻译只在翻译时才会走到这里，不受影响。
        guard sessionEngine != nil else { return nil }
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
        let corrects = correcting && language.isChinese
            && !(AIService.shared.localBackend(for: correctionRoute, local: .generation)?.isStartingServer ?? false)
        // 纠错和翻译选的是同一个云端模型：一条请求纠完顺便翻（`LiveTranslateCorrector`），少一次往返。
        var combinedTarget: TranslationLanguage?
        if case .cloud(let modelID) = correctionRoute, sessionEngine == .cloud(modelID) {
            combinedTarget = target
        }
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
                corrector.submit(key: key, text: text, context: correctionContext(line, before: unit),
                                 translateTo: combinedTarget)
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
    private func applyCorrection(key: Int, source: String, corrected: String,
                                 translation: LiveTranslateCorrector.Translation?) {
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
            if let translation, translation.target.code == target.code {
                // 合一请求顺带回来的译文：就是纠正后这段的译文，不用再排队翻。
                applyTranslation(job: key, source: corrected, target: target.code, text: translation.text)
            } else {
                translator.submit(id: key, text: corrected, isFinal: true, target: target.code)
            }
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

    /// 云端不可用、这一句改用了本地：提示一次（字幕照常出）。
    private func showCloudFallbackOnce() {
        guard isRunning, !cloudFallbackShown else { return }
        cloudFallbackShown = true
        notice = L("ai.notice.cloudFallback")
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
