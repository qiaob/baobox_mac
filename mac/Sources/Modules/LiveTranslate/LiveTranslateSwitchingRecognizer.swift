import AVFoundation
import Foundation
import Speech

/// 「自动（A / B）」在两种语言**都装了本机模型**时的做法：一次只开一个识别器，按需切换（docs/translation-engine/DESIGN.md §3.3）。
///
/// 系统的本机识别同一时间只能跑一路，两路同时开会互相挤掉；而装了本机模型的语言没法让它走服务器。所以：
/// 只开当前语言的识别器，同时把这一句的录音存一份；一句说完看结果像不像当前语言 —— 中文识别器听到英文会吐出
/// 英文单词，英文识别器听到中文时置信度很低 —— 不像就把录音交给另一种语言的识别器重认一遍（本机识别比实时快得多），
/// 两边打分取高的，并切到那种语言接着听。重认期间音频由闸门攒着，下一句开时补喂，不丢字。
///
/// 只有一种语言有本机模型时用 `LiveTranslateDualRecognizer`（中文本机 + 英文云端同时听）；两种都有时用这个，免得两路
/// 互相挤掉、中文被停用。英文本机模型删不掉、删了系统也会自动装回来（2026-11-05），所以这台 Mac 上这是「自动」的主路径。
@MainActor
final class LiveTranslateSwitchingRecognizer: LiveTranslateRecognizer {
    var onUpdate: ((Int, String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onLanguage: ((Int, TranslationLanguage) -> Void)?
    /// 当前在听的语言（本机 / 服务器）与待命的那种，变了才报（字幕条状态行用）。
    var onRouting: (([LiveTranslateChannelState]) -> Void)?

    private let languages: [TranslationLanguage]
    private var recognizers: [SFSpeechRecognizer]
    private let router: LiveTranslateAudioRouter
    private let gate = LiveTranslateAudioGate()
    private let recorder = LiveTranslateSegmentRecorder()
    /// 当前在听的语言（下标）。
    private var active = 0

    private var running = false
    private var watchdog: Timer?
    /// `flush()` 在等这一句定稿（交接 / 重认）：定稿了就放行，不再开新段。
    private var flushGate: LiveTranslateOnceGate?
    private var segmentID = 0
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segmentStart = Date()
    /// 文字最近一次变化的时间（判停顿）。
    private var lastChange = Date()
    /// 最近一次收到任何结果的时间（看门狗）。
    private var lastResultAt = Date()
    private var segmentHasText = false
    private var latest = ""
    private var finalResult: (text: String, confidence: Double)?
    /// 交接中：当前句已 endAudio，等 final（最多 `finalWait`）。
    private var handoffDeadline: Date?
    /// 重认中：拿这一句的录音给另一种语言的识别器（最多 `recheckWait`）。
    private var recheckDeadline: Date?
    private var recheckTask: SFSpeechRecognitionTask?
    private var recheckSegment = 0
    private var recheckOwn: (text: String, confidence: Double) = ("", 0)
    /// 这一句录音里有人声的秒数（重认时两边按同一时长算字数密度）。
    private var recheckVoiced: TimeInterval = 0
    /// 看门狗触发的切段：结果为空也拿另一种语言试一次。
    private var forceRecheck = false
    /// 为什么强制重认（日志用）：stall = 有人声却没字；early = 说到一半就看出语言不对。
    private var forceReason = ""
    /// 这一段有人声的累计秒数（不随出字清零），判「说到一半就看出语言不对」用。
    private var segmentVoice = LiveTranslateStallClock()
    /// 这一段已经提前查过一次了（一段只提前切一次）。
    private var earlyChecked = false
    private var recheckStartedAt = Date()
    /// 说了这么久（有人声的秒数）还看不出语言不对就不提前切，等这句说完再判。
    private static let earlyCheckVoiced: TimeInterval = 2.5
    private var quickFailures = 0
    /// 有声音却没字的连续次数：1、2 次先换语言试，3 次当卡死重建识别器；出字清零。
    private var stallStreak = 0
    private var stall = LiveTranslateStallClock()
    private var reportedRouting: [LiveTranslateChannelState] = []

    /// 每段最多持续多久（秒），防触到识别请求的时长上限。
    private static let maxSegmentDuration: TimeInterval = 45
    /// 文字多久没变化视为一句说完（秒）。
    private static let pauseThreshold: TimeInterval = 1.2
    private static let finalWait: TimeInterval = 1.2
    /// 重认几秒的录音，本机识别通常一秒内回；超时就用当前语言的结果。
    private static let recheckWait: TimeInterval = 3
    /// 有人在说话、却这么久没有任何识别结果（秒；连续发生按 2 倍退避，封顶 60）。
    private static let stallTimeout: TimeInterval = 6

    init?(languages: [TranslationLanguage], router: LiveTranslateAudioRouter) {
        let built = languages.compactMap { language -> SFSpeechRecognizer? in
            guard let localeID = language.speechLocale,
                  let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
                  recognizer.isAvailable else { return nil }
            return recognizer
        }
        guard built.count == 2, languages.count == 2 else { return nil }
        self.languages = languages
        self.recognizers = built
        self.router = router
    }

    func start() async throws {
        running = true
        LiveTranslateLog.recognition.notice(
            "switching recognizer start: \(self.languages.map(\.code).joined(separator: "+"), privacy: .public)")
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
        recheckTask?.cancel()
        request = nil
        task = nil
        recheckTask = nil
        handoffDeadline = nil
        recheckDeadline = nil
        _ = recorder.take()
        flushGate?.open()
        flushGate = nil
    }

    /// 收尾：这一句有字就照切段那样 endAudio、等 final（交接 / 重认中就等它们完），定稿时不再拿录音重认
    /// （没时间了，用当前语言的结果）；没字直接返回。到点由看门狗按超时收尾。之后不再开新段。
    func flush() async {
        guard running, flushGate == nil,
              handoffDeadline != nil || recheckDeadline != nil || segmentHasText else { return }
        let flushing = LiveTranslateOnceGate()
        flushGate = flushing
        if handoffDeadline == nil, recheckDeadline == nil {
            rollSegment()
        }
        await flushing.wait()
    }

    /// 这一句定稿了：收尾中就放行 `flush()`，否则开下一段。
    private func nextSegmentOrEndFlush() {
        if let flushGate {
            self.flushGate = nil
            flushGate.open()
            return
        }
        beginSegment()
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
        latest = ""
        finalResult = nil
        forceRecheck = false
        forceReason = ""
        segmentVoice.reset()
        earlyChecked = false
        let recognizer = recognizers[active]
        let request = Self.makeRequest(for: recognizer)
        self.request = request
        _ = recorder.take()
        // 交接 / 重认期间攒下的音频先补喂（也录进这一句），再直通。
        gate.forward(to: [request], recorder: recorder)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // 回调线程不定：只取出值类型再回主线程。
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let confidence = LiveTranslateScoring.averageConfidence(result)
            let failure = (error as NSError?).map { "\($0.domain) \($0.code)" }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(segment: id, text: text, isFinal: isFinal, confidence: confidence, failure: failure)
                }
            }
        }
        reportRouting()
    }

    private static func makeRequest(for recognizer: SFSpeechRecognizer) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // 专有名词每段现读：设置里改完，下一句起生效。
        request.contextualStrings = SpeechSettings.vocabulary
        request.requiresOnDeviceRecognition = LiveTranslateSettings.preferOnDevice && recognizer.supportsOnDeviceRecognition
        return request
    }

    /// 结束当前句：先让它把 final 回完（最多 `finalWait`），其间音频由闸门攒着。
    private func rollSegment() {
        guard handoffDeadline == nil, recheckDeadline == nil else { return }
        gate.hold()
        request?.endAudio()
        request = nil
        handoffDeadline = Date().addingTimeInterval(Self.finalWait)
    }

    private func handle(segment id: Int, text: String?, isFinal: Bool, confidence: Double, failure: String?) {
        guard running, id == segmentID, recheckDeadline == nil else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ended = isFinal || failure != nil
        if let failure {
            LiveTranslateLog.recognition.error(
                "\(self.languages[self.active].code, privacy: .public) segment \(id) ended with error: \(failure, privacy: .public)")
        }
        if !trimmed.isEmpty {
            if trimmed != latest { lastChange = Date() }
            latest = trimmed
            lastResultAt = Date()
            segmentHasText = true
            quickFailures = 0
            stallStreak = 0
            stall.reset()
            if !ended, handoffDeadline == nil {
                onLanguage?(id, languages[active])
                onUpdate?(id, trimmed, false)
            }
        }
        guard ended else { return }
        finalResult = (trimmed.isEmpty ? latest : trimmed, isFinal ? confidence : 0)
        if handoffDeadline == nil {
            // 系统自己收尾了（长时间没说话超时 / 出错）：刚开就出错、连续 3 次判不可恢复。
            if failure != nil, latest.isEmpty, Date().timeIntervalSince(segmentStart) < 1 {
                quickFailures += 1
                if quickFailures >= 3 {
                    stop()
                    onFailure?(L("livetranslate.alert.unavailableMessage"))
                    return
                }
            }
            gate.hold()
        }
        finishSegment()
    }

    /// 这一句的 final 回来了（或等超时）：像当前语言就定稿；不像就拿录音给另一种语言重认。
    private func finishSegment() {
        handoffDeadline = nil
        task?.cancel()
        task = nil
        request = nil
        let id = segmentID
        let own = finalResult ?? (latest, 0)
        let audio = recorder.take()
        let voiced = LiveTranslateAudioRouter.voicedDuration(of: audio)
        let language = languages[active]
        let wrong = Self.looksWrong(own.text, confidence: own.confidence, voiced: voiced, language: language)
        // 每句一行（排查「识别不到 / 卡在错的语言上」用）：只记字数、时长、分数，不记内容。
        LiveTranslateLog.recognition.notice(
            "auto seg \(id) [\(language.code, privacy: .public)]: \(LiveTranslateScoring.units(own.text, cjk: language.isChinese)) units, voiced \(String(format: "%.1f", voiced), privacy: .public)s, density \(String(format: "%.2f", LiveTranslateScoring.density(text: own.text, voiced: voiced, language: language)), privacy: .public), conf \(String(format: "%.2f", own.confidence), privacy: .public)\(self.forceRecheck ? " (\(self.forceReason))" : "", privacy: .public) -> \(wrong || self.forceRecheck ? "recheck" : "keep", privacy: .public)")
        if flushGate == nil, !audio.isEmpty, forceRecheck || wrong {
            recheck(segment: id, own: own, voiced: voiced, audio: audio)
            return
        }
        publish(segment: id, text: own.text, languageIndex: active)
        nextSegmentOrEndFlush()
    }

    /// 像不像当前语言：说了 1.5 秒以上却几乎没字（英文识别器听中文常常只吐 "You"、"I" 这种短词，置信度还不低）；
    /// 文字系统对不上（中文识别器吐出英文单词）；或有置信度却偏低（英文识别器听中文）。
    private static func looksWrong(_ text: String, confidence: Double, voiced: TimeInterval,
                                   language: TranslationLanguage) -> Bool {
        if voiced >= 1.5, LiveTranslateScoring.density(text: text, voiced: voiced, language: language) < 0.6 {
            return true
        }
        guard text.count >= 2 else { return false }
        if language.scriptRatio(of: text) < 0.3 { return true }
        return confidence > 0 && confidence < 0.5
    }

    /// 说到一半时的判断（partial 没有置信度，只看文字）：比说完再判更严，免得把说对了的话切断 ——
    /// 文字系统对不上（至少 3 个字符），或说了 2.5 秒以上字数密度还不到正常的四成。
    private static func looksWrongEarly(_ text: String, voiced: TimeInterval, language: TranslationLanguage) -> Bool {
        if text.count >= 3, language.scriptRatio(of: text) < 0.3 { return true }
        return LiveTranslateScoring.density(text: text, voiced: voiced, language: language) < 0.4
    }

    private func recheck(segment id: Int, own: (text: String, confidence: Double), voiced: TimeInterval,
                         audio: [AVAudioPCMBuffer]) {
        let other = active == 0 ? 1 : 0
        let recognizer = recognizers[other]
        let request = Self.makeRequest(for: recognizer)
        request.shouldReportPartialResults = false
        for buffer in audio {
            request.append(buffer)
        }
        request.endAudio()
        recheckSegment = id
        recheckOwn = own
        recheckVoiced = voiced
        recheckStartedAt = Date()
        recheckDeadline = Date().addingTimeInterval(Self.recheckWait)
        recheckTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard error != nil || result?.isFinal == true else { return }
            let text = result?.bestTranscription.formattedString ?? ""
            let confidence = LiveTranslateScoring.averageConfidence(result)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.recheckDone(segment: id, other: other, text: text, confidence: confidence)
                }
            }
        }
    }

    /// 另一种语言重认的结果（超时时 text 为空）：分高的定稿；另一种赢了就切过去。
    private func recheckDone(segment id: Int, other: Int, text: String, confidence: Double) {
        guard running, recheckDeadline != nil, id == recheckSegment else { return }
        recheckDeadline = nil
        recheckTask?.cancel()
        recheckTask = nil
        let own = recheckOwn
        let otherText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownScore = LiveTranslateScoring.score(text: own.text, confidence: own.confidence, language: languages[active],
                                                  voiced: recheckVoiced)
        let otherScore = LiveTranslateScoring.score(text: otherText, confidence: confidence, language: languages[other],
                                                    voiced: recheckVoiced)
        // 略高一点不切（差不多时留在当前语言，免得来回跳）。
        let switches = otherScore > max(ownScore * 1.1, ownScore + 0.02)
        LiveTranslateLog.recognition.notice(
            "auto recheck seg \(id) (\(String(format: "%.1f", Date().timeIntervalSince(self.recheckStartedAt)), privacy: .public)s): \(self.languages[self.active].code, privacy: .public) \(String(format: "%.2f", ownScore), privacy: .public) vs \(self.languages[other].code, privacy: .public) \(String(format: "%.2f", otherScore), privacy: .public) (\(LiveTranslateScoring.units(otherText, cjk: self.languages[other].isChinese)) units, conf \(String(format: "%.2f", confidence), privacy: .public)) -> \(switches ? "switch" : "keep", privacy: .public)")
        if switches {
            LiveTranslateLog.recognition.notice(
                "auto: switched \(self.languages[self.active].code, privacy: .public) -> \(self.languages[other].code, privacy: .public)")
            active = other
            stallStreak = 0
            publish(segment: id, text: otherText, languageIndex: other)
        } else {
            publish(segment: id, text: own.text, languageIndex: active)
        }
        nextSegmentOrEndFlush()
    }

    private func publish(segment id: Int, text: String, languageIndex: Int) {
        guard !text.isEmpty else { return }
        onLanguage?(id, languages[languageIndex])
        onUpdate?(id, text, true)
    }

    // MARK: - 看门狗

    private func tick() {
        guard running else { return }
        let now = Date()
        if let deadline = recheckDeadline {
            if now >= deadline {
                recheckDone(segment: recheckSegment, other: active == 0 ? 1 : 0, text: "", confidence: 0)
            }
            return
        }
        if let deadline = handoffDeadline {
            if now >= deadline { finishSegment() }
            return
        }
        // 说到一半就看出语言不对（中文识别器在吐英文单词 / 英文识别器只吐零星几个词）：不等这句说完，提前切段重认。
        // 不然换语言后的第一句要等「说完 + 停顿 1.2 秒 + 重认」才出字（2026-11-05 用户：中英切换一次后第一句识别很慢）。
        segmentVoice.tick(now: now, lastVoice: router.lastVoiceDate)
        if !earlyChecked, segmentVoice.voiced >= Self.earlyCheckVoiced,
           Self.looksWrongEarly(latest, voiced: segmentVoice.voiced, language: languages[active]) {
            earlyChecked = true
            forceRecheck = true
            forceReason = "early"
            rollSegment()
            return
        }
        // 有人在说话却一直没字：多半是当前语言不对（识别器听不懂就不出字）—— 先切段、拿录音给另一种语言试；
        // 连续三次都这样就当系统识别服务卡死了，重建识别器。只数有人声的时间（`LiveTranslateStallClock`）：
        // 停顿、朗读暂停识别的时间不算。
        stall.tick(now: now, lastVoice: router.lastVoiceDate)
        let silentFor = now.timeIntervalSince(lastResultAt)
        let timeout = min(Self.stallTimeout * Double(1 << min(stallStreak, 4)), 60)
        if stall.voiced > timeout {
            stallStreak += 1
            if stallStreak >= 3 {
                restartAfterStall(silentFor: silentFor)
            } else {
                forceRecheck = true
                forceReason = "stall"
                rollSegment()
            }
            return
        }
        guard segmentHasText else { return }
        if now.timeIntervalSince(lastChange) > Self.pauseThreshold
            || now.timeIntervalSince(segmentStart) > Self.maxSegmentDuration {
            rollSegment()
        }
    }

    private func restartAfterStall(silentFor: TimeInterval) {
        LiveTranslateLog.recognition.error(
            "switching watchdog: \(Int(self.stall.voiced))s of voice but no results (\(Int(silentFor))s since last result), restarting recognizers")
        gate.hold()
        request?.endAudio()
        task?.cancel()
        recheckTask?.cancel()
        request = nil
        task = nil
        recheckTask = nil
        handoffDeadline = nil
        recheckDeadline = nil
        recognizers = recognizers.map { SFSpeechRecognizer(locale: $0.locale) ?? $0 }
        beginSegment()
    }

    private func reportRouting() {
        let states = languages.indices.map { index -> LiveTranslateChannelState in
            guard index == active else { return LiveTranslateChannelState(language: languages[index], mode: .standby) }
            let mode: LiveTranslateChannelState.Mode = recognizers[index].supportsOnDeviceRecognition ? .onDevice : .server
            return LiveTranslateChannelState(language: languages[index], mode: mode)
        }
        guard states != reportedRouting else { return }
        reportedRouting = states
        onRouting?(states)
    }
}
