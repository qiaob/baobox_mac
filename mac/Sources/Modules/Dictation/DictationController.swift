import AppKit
import AVFoundation
import Speech

/// 语音听写的编排（docs/dictation/TECH_DESIGN.md）：三种唤起 → 占用登记 → 权限 → 识别 → 后处理 →（AI 润色）→
/// 插入 → 结果条 → 历史。所有状态只在主线程读写。
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()
    private init() {}

    /// 通知来源、语音采集占用登记的 owner。
    static let source = "dictation"

    enum Mode {
        /// 按住说话：按下开始，松开结束并上屏。
        case hold
        /// 点按切换 = 连续听写：按一下开始，一句定稿就上屏；再按一下或安静一阵后结束。
        case toggle
        /// 长听写：一段段进收集面板，编辑后整段插入 / 复制。
        case long
    }

    enum Phase: Equatable {
        case idle
        /// 已占用，等权限 / 识别器起来。
        case starting
        case listening
        /// 收尾中（等最后一段、润色、插入）。
        case finishing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: Mode?
    /// 上一次听写的文字（菜单「复制上一次听写」；历史关着也记在内存里）。
    @Published private(set) var lastText: String?
    /// 长听写的收集面板开着（可能在听，也可能停了在编辑）。
    @Published private(set) var collecting = false

    let history = DictationHistoryStore()
    private let historyWindow = DictationHistoryWindowController()

    /// 每次开始 / 取消加一：异步回来的结果对不上号就作废。
    private var session = 0
    private var recognizer: DictationRecognizer?
    private var bar: DictationBarController?
    private var collect: DictationCollectPanelController?
    /// 正在被用户关掉的收集面板（关闭回调期间保活，见 `collectClosed`）。
    private var closingCollect: DictationCollectPanelController?
    private let escape = DictationEscapeTap()
    private var uiTimer: Timer?
    private var startedAt = Date()
    /// 开始时在前台的 App（AI 润色按它判断；长听写插入时的后备目标）。
    private var target: NSRunningApplication?
    /// 这次听写要 AI 润色（目标 App 命中设置）。
    private var polishes = false
    private var modelWarm = false
    private var polishHintShown = false
    /// 还在等权限时就松手 / 再按了一次：起来后立刻结束。
    private var stopWhenReady = false
    private var pauseSeconds = 0
    /// 长听写：各段按顺序处理（润色是异步的），插入 / 复制前等它们都接上。
    private var longPipeline: Task<Void, Never>?
    /// 连续听写（点按切换）这一次的状态。
    private var stream: DictationStream?
    /// 结果条上「复制」复制的文字。
    private var resultText = ""

    // 按住说话的兜底：松开事件万一丢了（比如在状态栏菜单开着时按下），按物理按键状态结束。
    private var holdKeyCode: CGKeyCode?
    private var holdKeySeenDown = false
    private var holdKeyUpSince: Date?

    private static let insertDelay: UInt64 = 150_000_000

    // MARK: - 生命周期

    func activate() {
        DictationSettings.migrateLegacyValues()
        history.load(limit: DictationSettings.historyLimit)
        // 识别器对象先建好（不录音、不申请权限），按下时少等一截。
        DictationRecognizer.prewarm(DictationSettings.speechLanguages)
    }

    func terminate() {
        if let stream { recordStream(stream) }
        if phase != .idle { cancelSession() }
        if let collect, !collect.model.isEmpty { record(collect.model.text, app: target) }
        collect?.close()
        collect = nil
        collecting = false
        history.flush()
    }

    // MARK: - 唤起

    /// 「按住说话」按下（按键自动重复、已在听写中都不理）。
    func holdPressed() {
        guard phase == .idle else { return }
        start(.hold)
    }

    /// 「按住说话」松开。
    func holdReleased() {
        guard mode == .hold else { return }
        switch phase {
        case .starting: stopWhenReady = true
        case .listening: finish()
        case .idle, .finishing: break
        }
    }

    /// 「开始 / 结束听写」（快捷键、菜单）。
    func toggle() {
        switch phase {
        case .idle:
            start(.toggle)
        case .starting where mode == .toggle:
            stopWhenReady = true
        case .listening where mode == .toggle:
            finish()
        default:
            break
        }
    }

    /// 「长听写」（快捷键、菜单）：没开 → 开收集面板并开始听；在听 → 停下（字留在面板里）；停着 → 接着听。
    func toggleLong() {
        if mode == .long, phase == .listening {
            stopLong()
            return
        }
        guard phase == .idle else { return }
        start(.long)
    }

    /// Esc / 录音条上的 ✕。长听写只停止听（面板里的字留着）。
    func cancel() {
        if mode == .long {
            if phase == .listening { stopLong() }
            return
        }
        switch phase {
        case .starting, .listening, .finishing:
            cancelSession()
        case .idle:
            bar?.hide()
            bar = nil
        }
    }

    // MARK: - 开始

    private func start(_ mode: Mode) {
        guard AudioCaptureCoordinator.shared.claim(owner: Self.source, label: L("dictation.name"), microphone: true) else {
            // 设备端识别同一时间只能跑一个请求：会议记录 / 实时翻译在用就不开。
            let label = AudioCaptureCoordinator.shared.current?.label ?? ""
            notify(L("dictation.toast.busy \(label)"))
            return
        }
        session += 1
        let session = self.session
        self.mode = mode
        phase = .starting
        stopWhenReady = false
        pauseSeconds = DictationSettings.pauseSeconds
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            target = front
        } else if mode != .long {
            target = nil
        }
        // 先给反馈：录音条 / 收集面板马上出来，权限、识别器在后面起。
        if mode == .long {
            showCollect()
        } else {
            showBar(for: mode)
        }
        Task { await self.startFlow(session: session, mode: mode) }
    }

    private func startFlow(session: Int, mode: Mode) async {
        guard await ensurePermissions() else {
            if session == self.session { abortStart() }
            return
        }
        guard session == self.session, phase == .starting else { return }
        guard let recognizer = DictationRecognizer(mode: mode == .hold ? .utterance : .segmented,
                                                   languages: DictationSettings.speechLanguages,
                                                   preferOnDevice: DictationSettings.preferOnDevice,
                                                   vocabulary: LiveTranslateSettings.vocabulary) else {
            notify(L("dictation.error.unavailable"))
            abortStart()
            return
        }
        recognizer.onPreview = { [weak self] text in
            self?.previewChanged(text)
        }
        recognizer.onSegment = { [weak self] text, language in
            self?.segmentFinished(text, language: language)
        }
        recognizer.onFailure = { [weak self] message, kept in
            self?.recognitionFailed(message, kept: kept, session: session)
        }
        // 开了润色且目标 App 命中：现在就把模型加载起来，结束时少等。
        polishes = DictationSettings.polishes(bundleID: target?.bundleIdentifier)
        if polishes, DictationPolisher.isReady, !modelWarm {
            DictationPolisher.warmUp()
            modelWarm = true
        }
        if mode == .toggle { stream = DictationStream(session: session) }
        do {
            try recognizer.start()
        } catch {
            notify(error.localizedDescription)
            abortStart()
            return
        }
        self.recognizer = recognizer
        phase = .listening
        startedAt = Date()
        escape.onEscape = { [weak self] in
            self?.cancel()
        }
        escape.start()
        if DictationSettings.sounds { NSSound(named: "Tink")?.play() }
        if mode == .long {
            collect?.model.listening = true
            collect?.model.preview = ""
        }
        prepareHoldWatch(mode)
        startUITimer()
        if stopWhenReady {
            if mode == .long { stopLong() } else { finish() }
        }
    }

    /// 开不起来（没权限、识别器不可用…）：收起界面、让出占用。
    private func abortStart() {
        stream = nil
        AudioCaptureCoordinator.shared.release(owner: Self.source)
        coolModel()
        if mode == .long {
            collect?.model.listening = false
            if collect?.model.isEmpty ?? false { closeCollect() }
        } else {
            bar?.hide()
            bar = nil
        }
        phase = .idle
        mode = nil
    }

    /// 语音识别、麦克风：首次使用时申请；被拒 → 宠物提示并打开系统设置对应页（需求 §8）。
    private func ensurePermissions() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard granted else {
                permissionDenied(message: L("dictation.toast.speechDenied"), pane: "Privacy_SpeechRecognition")
                return false
            }
        default:
            permissionDenied(message: L("dictation.toast.speechDenied"), pane: "Privacy_SpeechRecognition")
            return false
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                permissionDenied(message: L("dictation.toast.micDenied"), pane: "Privacy_Microphone")
                return false
            }
            return true
        default:
            permissionDenied(message: L("dictation.toast.micDenied"), pane: "Privacy_Microphone")
            return false
        }
    }

    private func permissionDenied(message: String, pane: String) {
        notify(message)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 听

    private func showBar(for mode: Mode) {
        bar?.hide()
        let bar = DictationBarController()
        bar.model.phase = .listening
        bar.model.hint = hint(for: mode)
        bar.model.placeholder = mode == .toggle ? L("dictation.bar.placeholderStream") : ""
        bar.model.onCancel = { [weak self] in
            self?.cancel()
        }
        bar.model.onCopy = { [weak self] in
            self?.copyResult()
        }
        bar.onAutoHide = { [weak self, weak bar] in
            guard let self, let bar, self.bar === bar else { return }
            self.bar = nil
        }
        let caret = DictationSettings.barPosition == .caret ? TextInserter.caretRect(in: target) : nil
        bar.show(near: caret)
        self.bar = bar
    }

    /// 录音条上的提示：「松开结束」「再按一次结束 · Esc 取消」。
    private func hint(for mode: Mode) -> String {
        var parts: [String] = []
        switch mode {
        case .hold:
            parts.append(L("dictation.hint.release"))
        case .toggle:
            if HotkeyCenter.shared.combo(for: DictationTool.toggleHotkeyID) != nil {
                parts.append(L("dictation.hint.pressAgain"))
            } else if pauseSeconds > 0 {
                parts.append(L("dictation.hint.autoStop \(pauseSeconds)"))
            }
        case .long:
            break
        }
        if Permissions.hasAccessibility { parts.append(L("dictation.hint.esc")) }
        return parts.joined(separator: " · ")
    }

    private func previewChanged(_ text: String) {
        if mode == .long {
            collect?.model.preview = text
        } else {
            bar?.model.preview = text
        }
    }

    private func startUITimer() {
        uiTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                DictationController.shared.uiTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    private func stopUITimer() {
        uiTimer?.invalidate()
        uiTimer = nil
    }

    /// 20 Hz：电平、计时；点按切换模式的停顿自动结束；按住说话的松开兜底。
    private func uiTick() {
        guard let recognizer, phase == .listening else { return }
        let level = recognizer.level
        let elapsed = Date().timeIntervalSince(startedAt)
        if mode == .long {
            collect?.model.level = level
            collect?.model.elapsed = elapsed
        } else if let bar {
            bar.model.level = level
            bar.model.elapsed = elapsed
        }
        switch mode {
        case .toggle:
            // 停顿自动结束：没有人声、也没有新字持续 N 秒，且已经认出了内容。
            if pauseSeconds > 0, recognizer.hasText, recognizer.quietSeconds >= Double(pauseSeconds) {
                finish()
            }
        case .hold:
            checkHoldKey()
        case .long, .none:
            break
        }
    }

    private func prepareHoldWatch(_ mode: Mode) {
        holdKeySeenDown = false
        holdKeyUpSince = nil
        holdKeyCode = mode == .hold
            ? HotkeyCenter.shared.combo(for: DictationTool.holdHotkeyID).map { CGKeyCode($0.keyCode) } : nil
    }

    /// 松开事件的兜底：读到过「按着」之后连续 0.3 秒「没按着」才算松开 —— 这个接口万一在这台机器上读不到按键
    /// （一直是「没按着」），就永远不会据此结束，不会误停。
    private func checkHoldKey() {
        guard let holdKeyCode else { return }
        if CGEventSource.keyState(.hidSystemState, key: holdKeyCode) {
            holdKeySeenDown = true
            holdKeyUpSince = nil
            return
        }
        guard holdKeySeenDown else { return }
        let now = Date()
        guard let since = holdKeyUpSince else {
            holdKeyUpSince = now
            return
        }
        if now.timeIntervalSince(since) >= 0.3 {
            DictationLog.general.notice("hold key is up but no release event arrived, finishing")
            finish()
        }
    }

    // MARK: - 结束（按住说话 / 点按切换）

    private func finish() {
        guard phase == .listening, mode != .long, let recognizer else { return }
        phase = .finishing
        stopUITimer()
        holdKeyCode = nil
        let session = self.session
        bar?.model.level = 0
        bar?.model.phase = .working(L("dictation.bar.recognizing"))
        if mode == .toggle {
            // 连续听写：前面的句子已经上屏了，冲刷最后一句（照常经 onSegment 上屏）后收尾。
            recognizer.finish(tail: 0) { [weak self] _ in
                self?.streamRecognitionFinished(session: session)
            }
            return
        }
        // 按住说话松手时最后一个字可能还没说完：多收 0.2 秒。
        recognizer.finish(tail: mode == .hold ? 0.2 : 0) { [weak self] transcript in
            self?.recognitionFinished(transcript, session: session)
        }
    }

    private func recognitionFinished(_ transcript: DictationTranscript, session: Int) {
        guard session == self.session else { return }
        recognizer = nil
        // 识别完就让出麦克风 / 识别器（润色、插入不需要它们）。
        AudioCaptureCoordinator.shared.release(owner: Self.source)
        let language = DictationSettings.processingLanguage(for: transcript.language)
        let text = DictationTextProcessor.process(transcript.text, language: language,
                                                  options: DictationSettings.processingOptions)
        guard !text.isEmpty else {
            escape.stop()
            coolModel()
            showMessage(L("dictation.bar.nothingHeard"))
            endSession()
            return
        }
        Task { await self.deliver(text, language: language, session: session) }
    }

    private func recognitionFailed(_ message: String, kept: DictationTranscript?, session: Int) {
        guard session == self.session else { return }
        recognizer = nil
        AudioCaptureCoordinator.shared.release(owner: Self.source)
        notify(L("dictation.toast.failed"), body: message)
        if mode == .toggle, let stream {
            // 连续听写：已经上屏的不动，等排队的句子上完照常收尾。
            phase = .finishing
            stopUITimer()
            Task { await self.wrapUpStream(stream, failure: message) }
            return
        }
        if mode == .long {
            stopUITimer()
            escape.stop()
            collect?.model.listening = false
            collect?.model.busy = false
            phase = .idle
            mode = nil
            let pipeline = longPipeline
            Task {
                await pipeline?.value
                self.coolModelIfIdle()
            }
            return
        }
        // 已经认出来的那几段照常上屏，不丢字。
        if let kept {
            phase = .finishing
            stopUITimer()
            let language = DictationSettings.processingLanguage(for: kept.language)
            let text = DictationTextProcessor.process(kept.text, language: language,
                                                      options: DictationSettings.processingOptions)
            if !text.isEmpty {
                Task { await self.deliver(text, language: language, session: session) }
                return
            }
        }
        escape.stop()
        coolModel()
        showMessage(message)
        endSession()
    }

    /// 润色（按需）→ 插入 → 结果条 → 历史。
    private func deliver(_ processed: String, language: DictationTextProcessor.Language, session: Int) async {
        var text = processed
        if polishes {
            if DictationPolisher.isReady {
                bar?.model.phase = .working(L("dictation.bar.polishing"))
                bar?.model.preview = processed
                if let polished = await DictationPolisher.polish(processed, language: language) {
                    text = polished
                }
                // 润色期间按了 Esc / ✕：作废。
                guard session == self.session else { return }
            } else if !polishHintShown {
                polishHintShown = true
                notify(L("dictation.toast.polishNoModel"))
            }
        }
        coolModel()
        escape.stop()
        let app = NSWorkspace.shared.frontmostApplication
        let result = await TextInserter.insert(text, mode: DictationSettings.insertMode == .paste ? .alwaysPaste : .auto)
        record(text, app: app)
        showResult(result, text: text)
        if DictationSettings.sounds { NSSound(named: "Pop")?.play() }
        if session == self.session { endSession() }
    }

    private func showResult(_ result: TextInserter.Result, text: String) {
        resultText = text
        if case .copied(.noAccessibility) = result { postAccessibilityGuide() }
        guard let bar else { return }
        bar.model.preview = text
        switch result {
        case .ax, .paste:
            bar.model.phase = .result(inserted: true, detail: nil)
        case .copied(let reason):
            bar.model.phase = .result(inserted: false, detail: Self.reasonText(reason))
        }
        bar.hide(after: 2)
    }

    private func showMessage(_ message: String) {
        guard let bar else { return }
        bar.model.preview = ""
        bar.model.phase = .message(message)
        bar.hide(after: 1.6)
    }

    private static func reasonText(_ reason: TextInsertionPolicy.CopyReason) -> String {
        switch reason {
        case .secureInput: return L("dictation.reason.secureInput")
        case .noAccessibility: return L("dictation.reason.noAccessibility")
        case .noTextFocus: return L("dictation.reason.noTextFocus")
        case .busy: return L("dictation.reason.busy")
        }
    }

    private func copyResult() {
        guard !resultText.isEmpty else { return }
        TextInserter.copyToClipboard(resultText)
        bar?.model.phase = .result(inserted: false, detail: nil)
        bar?.hide(after: 1.2)
    }

    private func postAccessibilityGuide() {
        NotifyCenter.shared.post(PetNotification(
            source: Self.source, level: .bubble, title: L("dictation.toast.noAXTitle"),
            body: L("dictation.toast.noAXBody"),
            actions: [.init(id: "grant", label: L("dictation.toast.grant"), role: .primary)],
            dedupeKey: "noAccessibility", icon: "mic.fill"
        )) { action in
            guard action == "grant" else { return }
            // 首次会弹系统窗并把 App 登记进列表（同剪贴板回填粘贴）。
            Permissions.promptAccessibility()
            Permissions.openSystemSettings(pane: .accessibility)
        }
    }

    /// 取消（Esc / ✕）：什么都不上屏。
    private func cancelSession() {
        session += 1
        recognizer?.cancel()
        recognizer = nil
        if let stream {
            // 连续听写：只丢正在说、还没定稿的那句（识别器已取消）；已经定稿、还在排队的照常上完，再记历史。
            self.stream = nil
            Task { await self.drainCancelledStream(stream) }
        }
        AudioCaptureCoordinator.shared.release(owner: Self.source)
        escape.stop()
        coolModel()
        stopUITimer()
        holdKeyCode = nil
        bar?.hide()
        bar = nil
        phase = .idle
        mode = nil
    }

    /// 一次听写走完（结果条自己按时收起）。
    private func endSession() {
        stopUITimer()
        holdKeyCode = nil
        phase = .idle
        mode = nil
    }

    private func coolModel() {
        guard modelWarm else { return }
        modelWarm = false
        DictationPolisher.coolDown()
    }

    /// 长听写还在排队润色时不能放掉模型：等空闲了再放。
    private func coolModelIfIdle() {
        guard phase == .idle || mode != .long else { return }
        coolModel()
    }

    // MARK: - 连续听写（点按切换：一句定稿就上屏）

    /// 分段模式下一段定稿：长听写进收集面板，连续听写直接上屏。
    private func segmentFinished(_ raw: String, language: TranslationLanguage) {
        switch mode {
        case .long: longSegment(raw, language: language)
        case .toggle: streamSegment(raw, language: language)
        case .hold, .none: break
        }
    }

    /// 一句定稿：后处理（按需润色）后按顺序上屏（docs/dictation/TECH_DESIGN.md §3.1）。
    private func streamSegment(_ raw: String, language: TranslationLanguage) {
        guard let stream, stream.session == session else { return }
        let processing = DictationSettings.processingLanguage(for: language)
        // 只有口头禅的一句（停下来想的时候「嗯」了一声）不上屏。
        let prepared = DictationTextProcessor.prepare(raw, language: processing,
                                                      options: DictationSettings.processingOptions,
                                                      keepLoneFiller: false)
        guard !prepared.isEmpty else { return }
        let polish = polishes && DictationPolisher.isReady && !DictationTextProcessor.containsDelete(prepared)
        if polishes, !DictationPolisher.isReady, !polishHintShown {
            polishHintShown = true
            notify(L("dictation.toast.polishNoModel"))
        }
        let previous = stream.pipeline
        stream.pipeline = Task { [weak self] in
            await previous?.value
            var piece = prepared
            if polish {
                let standalone = DictationTextProcessor.render(prepared, into: "")
                piece = await DictationPolisher.polish(standalone, language: processing) ?? standalone
            }
            guard let self else { return }
            await self.place(piece, in: stream)
        }
    }

    /// 一句上屏：接在这次已经输入的字后面（英文补空格；「删除上一句」先退格删掉上一句）。
    /// 插不进去的攒着，结束时一次复制（不每句覆盖剪贴板）。
    private func place(_ piece: String, in stream: DictationStream) async {
        stream.transcript = DictationTextProcessor.render(piece, into: stream.transcript)
        // 状态栏菜单开着（多半正要点「结束听写」）：合成的 ⌘V / 退格会被菜单吃掉、这句就丢了 —— 等菜单关了再上屏。
        let menuDeadline = Date().addingTimeInterval(30)
        while StatusItemController.isMenuOpen, Date() < menuDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != stream.typedApp {
            // 第一句，或中途换了 App：接缝与删除都只认这次在当前 App 里输入的字，绝不删到别的字。
            stream.typed = ""
            stream.typedApp = front?.processIdentifier
        }
        let edit = DictationTextProcessor.streamEdit(piece, after: stream.typed)
        var typed = stream.typed
        if edit.deleteCount > 0, await TextInserter.deleteBackward(edit.deleteCount) {
            typed = String(typed.dropLast(edit.deleteCount))
        }
        stream.typed = typed
        guard !edit.insertion.isEmpty else { return }
        let mode: TextInserter.Mode = DictationSettings.insertMode == .paste ? .alwaysPaste : .auto
        let result = await TextInserter.insert(edit.insertion, mode: mode, copyOnFailure: false)
        switch result {
        case .ax, .paste:
            stream.typed = typed + edit.insertion
            stream.placedAny = true
            if stream.app == nil { stream.app = front }
            if stream.session == session { followCaret() }
        case .copied(let reason):
            stream.unplaced = DictationTextProcessor.join(stream.unplaced,
                                                          edit.insertion.trimmingCharacters(in: .whitespaces))
            stream.unplacedReason = reason
        }
    }

    /// 每上屏一句，录音条挪到新的光标旁（免得挡住刚输入的字）。取不到光标位置就不动。
    private func followCaret() {
        guard phase == .listening, DictationSettings.barPosition == .caret, let bar,
              let caret = TextInserter.caretRect() else { return }
        bar.show(near: caret)
    }

    /// 识别器交完最后一句（它的 `onSegment` 先于这里）：让出麦克风，等排队的句子都上屏再收尾。
    private func streamRecognitionFinished(session: Int) {
        guard session == self.session, let stream else { return }
        recognizer = nil
        AudioCaptureCoordinator.shared.release(owner: Self.source)
        Task { await self.wrapUpStream(stream, failure: nil) }
    }

    /// 连续听写收尾：等排队的句子都上屏 → 没插进去的一次复制 → 结果条 → 历史（全文一条）。
    private func wrapUpStream(_ stream: DictationStream, failure: String?) async {
        await stream.pipeline?.value
        // 等的时候按了 Esc / ✕：取消那边收了界面，也会自己记历史。
        guard stream.session == session else { return }
        self.stream = nil
        recordStream(stream)
        coolModel()
        escape.stop()
        if !stream.unplaced.isEmpty {
            TextInserter.copyToClipboard(stream.unplaced)
            showResult(.copied(stream.unplacedReason ?? .noTextFocus), text: stream.unplaced)
        } else if stream.placedAny {
            showResult(.ax, text: stream.transcript)
        } else {
            showMessage(failure ?? L("dictation.bar.nothingHeard"))
        }
        if DictationSettings.sounds, stream.placedAny || !stream.unplaced.isEmpty {
            NSSound(named: "Pop")?.play()
        }
        endSession()
    }

    /// Esc / ✕ 之后：已经定稿、还在排队的句子上完再记历史。界面已经收了，没插进去的不复制（历史里有）。
    private func drainCancelledStream(_ stream: DictationStream) async {
        await stream.pipeline?.value
        recordStream(stream)
    }

    /// 连续听写记历史：全文一条，只记一次。
    private func recordStream(_ stream: DictationStream) {
        guard !stream.recorded else { return }
        stream.recorded = true
        record(stream.transcript, app: stream.app ?? target)
    }

    // MARK: - 长听写

    private func showCollect() {
        if let collect {
            collect.show()
            return
        }
        let collect = DictationCollectPanelController()
        collect.model.onInsert = { [weak self] in
            self?.finishCollect(insert: true)
        }
        collect.model.onCopy = { [weak self] in
            self?.finishCollect(insert: false)
        }
        collect.model.onClear = { [weak self] in
            self?.collect?.model.text = ""
        }
        collect.model.onToggleListening = { [weak self] in
            self?.toggleLong()
        }
        collect.model.onClose = { [weak self] in
            self?.collectClosed()
        }
        collect.show()
        self.collect = collect
        collecting = true
    }

    /// 一段定稿：后处理（按需润色）后按顺序接到面板里。「删除上一句」能删到面板里已有的末句。
    private func longSegment(_ raw: String, language: TranslationLanguage) {
        let processing = DictationSettings.processingLanguage(for: language)
        let prepared = DictationTextProcessor.prepare(raw, language: processing,
                                                      options: DictationSettings.processingOptions)
        guard !prepared.isEmpty else { return }
        let polish = polishes && DictationPolisher.isReady && !DictationTextProcessor.containsDelete(prepared)
        if polishes, !DictationPolisher.isReady, !polishHintShown {
            polishHintShown = true
            notify(L("dictation.toast.polishNoModel"))
        }
        let previous = longPipeline
        longPipeline = Task { [weak self] in
            await previous?.value
            guard let self, let collect = self.collect else { return }
            guard polish else {
                collect.model.text = DictationTextProcessor.render(prepared, into: collect.model.text)
                return
            }
            collect.model.polishing = true
            let standalone = DictationTextProcessor.render(prepared, into: "")
            let polished = await DictationPolisher.polish(standalone, language: processing) ?? standalone
            collect.model.polishing = false
            guard let current = self.collect else { return }
            current.model.text = DictationTextProcessor.render(polished, into: current.model.text)
        }
    }

    /// 停止听（[结束]、快捷键、Esc）：最后一段定稿接进面板，面板留着编辑。
    private func stopLong(completion: (() -> Void)? = nil) {
        guard mode == .long, phase == .listening, let recognizer else {
            // 没在听：也要等排队润色的段接上再继续。
            let pipeline = longPipeline
            Task {
                await pipeline?.value
                completion?()
            }
            return
        }
        phase = .finishing
        stopUITimer()
        escape.stop()
        collect?.model.busy = true
        let session = self.session
        recognizer.finish(tail: 0) { [weak self] _ in
            guard let self, session == self.session else { return }
            self.recognizer = nil
            AudioCaptureCoordinator.shared.release(owner: Self.source)
            self.phase = .idle
            self.mode = nil
            let pipeline = self.longPipeline
            Task {
                await pipeline?.value
                self.collect?.model.listening = false
                self.collect?.model.busy = false
                self.collect?.model.preview = ""
                self.coolModelIfIdle()
                completion?()
            }
        }
    }

    /// [插入] / [复制]：先停下来、等最后几段接上，再整段插入（焦点还给原 App）/ 复制；记进历史，收起面板。
    private func finishCollect(insert: Bool) {
        stopLong { [weak self] in
            guard let self, let collect = self.collect else { return }
            let text = collect.model.text
            guard !collect.model.isEmpty else { return }
            let app = self.longTarget()
            self.closeCollect()
            self.record(text, app: app)
            self.coolModel()
            Task {
                guard insert else {
                    TextInserter.copyToClipboard(text)
                    self.showStandaloneResult(nil, text: text)
                    return
                }
                // 收集面板可能拿过键盘焦点：先把焦点还给原 App，等它接住再插。
                app?.activate()
                try? await Task.sleep(nanoseconds: Self.insertDelay)
                let result = await TextInserter.insert(
                    text, into: app, mode: DictationSettings.insertMode == .paste ? .alwaysPaste : .auto)
                self.showStandaloneResult(result, text: text)
            }
        }
    }

    /// 长听写插入的目标：此刻的前台 App（收集面板不抢前台），是 Baobox 自己时用开始时记下的那个。
    private func longTarget() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { return front }
        return target
    }

    /// 长听写 / 历史窗口插入之后的结果条：放在屏幕底部。`result` 为 nil = 用户要的复制（`detail` 说明原因，可空）。
    private func showStandaloneResult(_ result: TextInserter.Result?, text: String, detail: String? = nil) {
        bar?.hide()
        let bar = DictationBarController()
        bar.model.onCancel = { [weak self, weak bar] in
            bar?.hide()
            if let self, self.bar === bar { self.bar = nil }
        }
        bar.model.onCopy = { [weak self] in
            self?.copyResult()
        }
        bar.onAutoHide = { [weak self, weak bar] in
            guard let self, let bar, self.bar === bar else { return }
            self.bar = nil
        }
        bar.show(near: nil)
        self.bar = bar
        guard let result else {
            resultText = text
            bar.model.preview = text
            bar.model.phase = .result(inserted: false, detail: detail)
            bar.hide(after: 2)
            return
        }
        showResult(result, text: text)
    }

    private func closeCollect() {
        collect?.close()
        collect = nil
        collecting = false
    }

    /// 用户点了收集面板的关闭按钮：停下来，面板里的字记进历史（不丢字）。
    private func collectClosed() {
        if mode == .long, phase != .idle { cancelSession() }
        guard let collect else { return }
        if !collect.model.isEmpty { record(collect.model.text, app: longTarget()) }
        // 这是在面板自己的 windowWillClose 里：先留着它，下一拍再放，别在关闭过程中把窗口释放掉。
        closingCollect = collect
        self.collect = nil
        collecting = false
        longPipeline = nil
        coolModel()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DictationController.shared.closingCollect = nil
            }
        }
    }

    // MARK: - 历史与菜单

    private func record(_ text: String, app: NSRunningApplication?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastText = text
        guard DictationSettings.historyEnabled else { return }
        let info = app.map { DictationRecord.App(bundleID: $0.bundleIdentifier, name: $0.localizedName) }
        history.add(DictationRecord(app: info, text: text), limit: DictationSettings.historyLimit)
    }

    /// 菜单「复制上一次听写」。
    func copyLast() {
        guard let text = lastText ?? history.records.first?.text else { return }
        TextInserter.copyToClipboard(text)
        notify(L("dictation.toast.copiedLast"))
    }

    var hasLastText: Bool { lastText != nil || !history.records.isEmpty }

    /// 菜单「听写历史…」。
    func openHistory() {
        historyWindow.show(store: history, actions: DictationHistoryActions(
            copy: { record in
                TextInserter.copyToClipboard(record.text)
            },
            insert: { [weak self] record in
                self?.reinsert(record)
            },
            delete: { [weak self] record in
                self?.history.delete(record.id)
            },
            clear: { [weak self] in
                self?.history.clear()
            }
        ))
    }

    /// 历史窗口「再次插入」：插进打开历史窗口之前在前台的 App。
    private func reinsert(_ record: DictationRecord) {
        guard let app = historyWindow.previousApp, !app.isTerminated else {
            TextInserter.copyToClipboard(record.text)
            showStandaloneResult(nil, text: record.text, detail: L("dictation.reason.noTarget"))
            return
        }
        Task {
            app.activate()
            try? await Task.sleep(nanoseconds: Self.insertDelay)
            let result = await TextInserter.insert(
                record.text, into: app, mode: DictationSettings.insertMode == .paste ? .alwaysPaste : .auto)
            self.showStandaloneResult(result, text: record.text)
        }
    }

    private func notify(_ title: String, body: String = "") {
        NotifyCenter.shared.post(PetNotification(source: Self.source, level: .ambient, title: title, body: body,
                                                 icon: "mic.fill"))
    }
}

/// 连续听写这一次的状态（docs/dictation/TECH_DESIGN.md §3.1）。每次听写一个：取消后新开的听写不会和它串。
@MainActor
private final class DictationStream {
    let session: Int
    /// 各句按顺序处理（润色、插入都是异步的）。
    var pipeline: Task<Void, Never>?
    /// 这次听写在当前前台 App 里输入成功的字（接缝空格、「删除上一句」据此算）；前台 App 变了就清空。
    var typed = ""
    var typedApp: pid_t?
    /// 插不进去的句子：结束时一次复制。
    var unplaced = ""
    var unplacedReason: TextInsertionPolicy.CopyReason?
    /// 有句子上屏了。
    var placedAny = false
    /// 整次听写的全文（历史记这个；「删除上一句」也作用在它上面）。
    var transcript = ""
    /// 第一句上屏时的前台 App（历史记它）。
    var app: NSRunningApplication?
    /// 已经记进历史（收尾、取消、退出 App 三条路只记一次）。
    var recorded = false

    init(session: Int) {
        self.session = session
    }
}
