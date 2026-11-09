import AppKit
import AVFoundation
import Speech
import SwiftUI

// 「学习」：和「翻译」并列的动作（docs/selection-translate/ASSISTANT.md §1.7 / §2.6）。
// 按设置里的母语 / 在学的语言（暂时只有中文、英文）决定展示：词典卡、整句学习、中文拼音。

struct SelectionLearnView: View {
    @ObservedObject var session: SelectionSession

    var body: some View {
        let native = SelectionAssistantSettings.learnNative
        let target = SelectionAssistantSettings.learnTarget
        let detected = LanguageDetector.detect(session.text, preferred: [target, native])
        VStack(alignment: .leading, spacing: 8) {
            if detected.isSameLanguage(as: target) {
                if target.isSameLanguage(as: .english) {
                    if LearnText.isWordLike(session.text) {
                        LearnWordCard(word: session.text, context: session.context, native: native, session: session)
                    } else {
                        LearnSentenceView(text: session.text, native: native, showTranslation: true, session: session)
                    }
                } else {
                    LearnChineseView(text: session.text, native: native, session: session)
                }
            } else if detected.isSameLanguage(as: native) {
                LearnFromNativeView(session: session, native: native, target: target)
            } else {
                // 既不是母语也不是在学的语言：给母语译文，提示学习只支持中英。
                Text(L("selectiontranslate.learn.unsupported"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                AdaptiveText(text: session.text, size: 13, weight: .regular,
                             maxHeight: SelectionPanelMetrics.originalMaxHeight)
                SelectionTranslationArea(text: session.text, source: detected, target: native) { value in
                    session.primaryText = value
                }
            }
        }
    }
}

// MARK: - 文字工具

enum LearnText {
    /// 1–3 个英文词（单词、短语）：出词典卡。
    static func isWordLike(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 40 else { return false }
        let words = text.split(whereSeparator: { $0 == " " })
        guard words.count <= 3 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            (scalar.isASCII && CharacterSet.letters.contains(scalar)) || scalar == " " || scalar == "'"
                || scalar == "-" || scalar == "’"
        }
    }

    /// 汉字转带声调的拼音（系统转写）。
    static func pinyin(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable as CFMutableString, nil, kCFStringTransformToLatin, false)
        return mutable as String
    }
}

/// 句子里的一个「词」：显示的文字（带标点）、查词用的词、在整句里的范围（朗读高亮用）。
struct LearnToken: Identifiable {
    let id: Int
    let display: String
    /// 去掉首尾标点后的词；纯标点为空。
    let word: String
    let range: NSRange
}

enum LearnTokenizer {
    static func tokens(_ text: String) -> [LearnToken] {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "\\S+") else { return [] }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let trim = CharacterSet.punctuationCharacters.union(.symbols)
        return matches.enumerated().map { index, match in
            let display = ns.substring(with: match.range)
            return LearnToken(id: index, display: display, word: display.trimmingCharacters(in: trim), range: match.range)
        }
    }

    /// 比对用：小写、只留字母数字和撇号。
    static func normalized(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "'"
        }.map(Character.init))
    }

    /// 原文里哪些词读对了：两边按最长公共子序列对齐，返回原文中被对上的 token 下标。
    static func matchedTokens(_ tokens: [LearnToken], heard: String) -> Set<Int> {
        let target = tokens.map { normalized($0.word) }
        let spoken = heard.split(whereSeparator: { $0.isWhitespace }).map { normalized(String($0)) }.filter { !$0.isEmpty }
        guard !target.isEmpty, !spoken.isEmpty else { return [] }
        let n = target.count
        let m = spoken.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if !target[i].isEmpty, target[i] == spoken[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var matched = Set<Int>()
        var i = 0
        var j = 0
        while i < n, j < m {
            if !target[i].isEmpty, target[i] == spoken[j] {
                matched.insert(i)
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matched
    }
}

/// 一行排不下就折行的布局（整句学习里一个词一个按钮）。
struct SelectionFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        let width = proposal.width.map { min($0, widest) } ?? widest
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - 朗读（带当前词高亮）

@MainActor
final class LearnSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = LearnSpeaker()

    /// 正在读的整段文字，和它里面正在读的那个词的范围。
    @Published private(set) var speakingText: String?
    @Published private(set) var spokenRange: NSRange?

    /// 合成器必须常驻持有，中途释放会静音。
    private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    /// `rate`：1 = 系统默认语速；0.75、0.5 慢读。
    func speak(_ text: String, voice: String, rate: Float = 1) {
        SelectionTranslateController.shared.stopGeneralSpeech()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: voice)
        // 0.75× / 0.5× 按体感折成系统语速的 0.8 / 0.6（语速参数不是线性的）。
        let factor: Float = rate >= 1 ? 1 : (rate >= 0.75 ? 0.8 : 0.6)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * factor
        speakingText = text
        spokenRange = nil
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingText = nil
        spokenRange = nil
    }

    static func englishVoice(british: Bool) -> String { british ? "en-GB" : "en-US" }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.spokenRange = characterRange
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.speakingText = nil
                self.spokenRange = nil
            }
        }
    }
}

// MARK: - 跟读

/// 跟读：麦克风 + 在学语言的识别器，说完停顿 1.5 秒或 20 秒自动结束，按最长公共子序列标出读对的词。
@MainActor
final class LearnShadowing: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case finishing
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var heard = ""
    /// 读对的 token 下标；nil = 还没跟读过。
    @Published private(set) var matched: Set<Int>?

    private static let owner = "selectiontranslate"
    private static let silenceTimeout: TimeInterval = 1.5
    private static let maxDuration: TimeInterval = 20

    private var pipe: DictationAudioPipe?
    private var microphone: DictationMicrophone?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var startedAt = Date()
    private var tokens: [LearnToken] = []
    private var finishWork: DispatchWorkItem?

    var isActive: Bool { phase == .listening || phase == .finishing }

    func toggle(tokens: [LearnToken], language: TranslationLanguage) {
        if isActive {
            finish()
        } else {
            Task { await start(tokens: tokens, language: language) }
        }
    }

    private func start(tokens: [LearnToken], language: TranslationLanguage) async {
        guard await Self.ensurePermissions() else {
            phase = .failed(L("selectiontranslate.learn.shadowPermission"))
            return
        }
        guard let recognizer = DictationRecognizer.recognizer(for: language), recognizer.isAvailable else {
            phase = .failed(L("selectiontranslate.learn.shadowUnavailable"))
            return
        }
        guard AudioCaptureCoordinator.shared.claim(owner: Self.owner, label: L("selectiontranslate.learn.shadowLabel"),
                                                   microphone: true) else {
            phase = .failed(AudioCaptureCoordinator.shared.busyMessage() ?? L("selectiontranslate.learn.shadowUnavailable"))
            return
        }
        LearnSpeaker.shared.stop()
        self.tokens = tokens
        heard = ""
        matched = nil
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = Array(Set(tokens.map(\.word).filter { !$0.isEmpty })).prefix(100).map { $0 }
        let pipe = DictationAudioPipe()
        pipe.forward(to: request, record: false)
        let microphone = DictationMicrophone(pipe: pipe)
        do {
            try microphone.start()
        } catch {
            AudioCaptureCoordinator.shared.release(owner: Self.owner)
            phase = .failed(error.localizedDescription)
            return
        }
        self.request = request
        self.pipe = pipe
        self.microphone = microphone
        startedAt = Date()
        phase = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil && result == nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.receive(text: text, isFinal: isFinal, failed: failed)
                }
            }
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard phase == .listening, let pipe else { return }
        level = pipe.level
        let now = Date()
        let spoke = !heard.isEmpty
        if spoke, now.timeIntervalSince(pipe.lastVoice) >= Self.silenceTimeout {
            finish()
        } else if now.timeIntervalSince(startedAt) >= Self.maxDuration {
            finish()
        }
    }

    private func receive(text: String?, isFinal: Bool, failed: Bool) {
        if let text { heard = text }
        if isFinal || failed {
            complete()
        }
    }

    /// 停止收音，等识别器给出定稿（最多 1.5 秒）。
    func finish() {
        guard phase == .listening else { return }
        phase = .finishing
        timer?.invalidate()
        timer = nil
        microphone?.stop()
        pipe?.detach()
        request?.endAudio()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.complete()
            }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func complete() {
        guard phase == .listening || phase == .finishing else { return }
        finishWork?.cancel()
        finishWork = nil
        cleanup()
        matched = LearnTokenizer.matchedTokens(tokens, heard: heard)
        phase = heard.isEmpty ? .failed(L("selectiontranslate.learn.shadowNothing")) : .done
    }

    /// 浮层关了 / 换了句子：立即停下，不出结果。
    func cancel() {
        finishWork?.cancel()
        finishWork = nil
        let wasActive = isActive
        cleanup()
        if wasActive { phase = .idle }
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        microphone?.stop()
        microphone = nil
        pipe?.detach()
        pipe = nil
        task?.cancel()
        task = nil
        request = nil
        level = 0
        AudioCaptureCoordinator.shared.release(owner: Self.owner)
    }

    var score: (right: Int, total: Int)? {
        guard let matched else { return nil }
        return (matched.count, tokens.filter { !$0.word.isEmpty }.count)
    }

    private static func ensurePermissions() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard granted else { return false }
        default:
            return false
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

// MARK: - 词典卡

struct LearnWordCard: View {
    let word: String
    let context: String?
    let native: TranslationLanguage
    @ObservedObject var session: SelectionSession

    @ObservedObject private var dictionary = EnglishDictionary.shared
    @ObservedObject private var speaker = LearnSpeaker.shared
    @State private var slow = false

    private var display: String { word.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var lookup: EnglishLookup? {
        dictionary.isLoaded ? dictionary.lookup(display) : nil
    }

    var body: some View {
        let lookup = self.lookup
        VStack(alignment: .leading, spacing: 8) {
            Text(display)
                .font(.system(size: 22, weight: .bold))
                .textSelection(.enabled)

            HStack(spacing: 8) {
                if let phonetic = lookup?.entry.phonetic, !phonetic.isEmpty {
                    Text(verbatim: "/\(phonetic)/")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                pronounceButton(L("selectiontranslate.learn.us"), british: false)
                pronounceButton(L("selectiontranslate.learn.uk"), british: true)
                Toggle(L("selectiontranslate.learn.slow"), isOn: $slow)
                    .toggleStyle(.button)
                Spacer()
            }
            .controlSize(.small)

            if let lookup {
                definitions(lookup)
            } else if dictionary.state == .installed && !dictionary.isLoaded {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("selectiontranslate.dict.loading"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                // 没装词典 / 词典里查不到：先给译文。
                SelectionTranslationArea(text: display, source: .english, target: native) { value in
                    session.primaryText = value
                }
                if dictionary.state != .installed {
                    Text(L("selectiontranslate.dict.downloadHint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    EnglishDictionaryRow(compact: true)
                        .controlSize(.small)
                }
            }

            if let context {
                Divider()
                Text(L("selectiontranslate.learn.context"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 6) {
                    Text(context)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        speaker.speak(context, voice: LearnSpeaker.englishVoice(british: SelectionAssistantSettings.britishAccent),
                                      rate: slow ? 0.75 : 1)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .buttonStyle(.plain)
                    .help(L("selectiontranslate.panel.speakOriginal"))
                }
                SelectionTranslationArea(text: context, source: .english, target: native) { _ in }
            }
        }
        .onAppear {
            dictionary.loadIfNeeded()
            if SelectionAssistantSettings.learnAutoSpeak {
                speaker.speak(display, voice: LearnSpeaker.englishVoice(british: SelectionAssistantSettings.britishAccent))
            }
        }
        .task(id: dictionary.isLoaded) {
            if let lookup = self.lookup {
                session.primaryText = ([lookup.entry.word] + lookup.entry.displayDefinitions).joined(separator: "\n")
            }
        }
    }

    private func pronounceButton(_ title: String, british: Bool) -> some View {
        Button {
            speaker.speak(display, voice: LearnSpeaker.englishVoice(british: british), rate: slow ? 0.5 : 1)
        } label: {
            Label(title, systemImage: "speaker.wave.2")
        }
    }

    @ViewBuilder
    private func definitions(_ lookup: EnglishLookup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = lookup.lemmaNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(Array(lookup.entry.displayDefinitions.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lemma = lookup.lemmaEntry {
                Divider()
                Text(verbatim: lemma.word + (lemma.phonetic.isEmpty ? "" : "  /\(lemma.phonetic)/"))
                    .font(.system(size: 13, weight: .semibold))
                ForEach(Array(lemma.displayDefinitions.prefix(3).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            let forms = (lookup.lemmaEntry ?? lookup.entry).forms
            if !forms.isEmpty {
                Text(forms.map { "\($0.name) \($0.value)" }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 整句学习

struct LearnSentenceView: View {
    let text: String
    let native: TranslationLanguage
    /// 原文是在学的语言 → 下面给母语译文；从母语翻过来的就不用再翻一遍。
    let showTranslation: Bool
    @ObservedObject var session: SelectionSession

    @ObservedObject private var dictionary = EnglishDictionary.shared
    @ObservedObject private var speaker = LearnSpeaker.shared
    @StateObject private var shadowing = LearnShadowing()
    @State private var tokens: [LearnToken] = []
    @State private var selected: Int?
    @State private var detailWord: String?
    @State private var speed: Double = 1
    @State private var british = SelectionAssistantSettings.britishAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let detailWord {
                Button {
                    self.detailWord = nil
                } label: {
                    Label(L("selectiontranslate.learn.back"), systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                LearnWordCard(word: detailWord, context: text, native: native, session: session)
            } else {
                sentence
            }
        }
        .onAppear {
            tokens = LearnTokenizer.tokens(text)
            dictionary.loadIfNeeded()
        }
        .onDisappear {
            shadowing.cancel()
        }
    }

    @ViewBuilder
    private var sentence: some View {
        SelectionFlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(tokens) { token in
                tokenView(token)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let selected, selected < tokens.count, !tokens[selected].word.isEmpty {
            wordStrip(tokens[selected].word)
        }

        playbackBar

        shadowingStatus

        if showTranslation {
            Divider()
            SelectionTranslationArea(text: text, source: .english, target: native) { value in
                session.primaryText = value
            }
        }
    }

    private func tokenView(_ token: LearnToken) -> some View {
        let spoken = speaker.speakingText == text && speaker.spokenRange.map { NSIntersectionRange($0, token.range).length > 0 } == true
        let isSelected = selected == token.id
        let shadowColor: Color? = shadowing.matched.map { matched in
            token.word.isEmpty ? Color.primary : (matched.contains(token.id) ? Color.green : Color.red)
        }
        return Text(token.display)
            .font(.system(size: 15))
            .foregroundStyle(shadowColor ?? (isSelected ? Color.accentColor : Color.primary))
            .padding(.horizontal, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(spoken ? Color.yellow.opacity(0.45) : (isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
            )
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(Color.accentColor).frame(height: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !token.word.isEmpty else { return }
                selected = token.id
            }
            .onHover { hovering in
                if hovering, !token.word.isEmpty { selected = token.id }
            }
    }

    /// 点中的词：音标 + 第一条释义 + 发音 + 「详细」。
    private func wordStrip(_ word: String) -> some View {
        let lookup = dictionary.isLoaded ? dictionary.lookup(word) : nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(word)
                .font(.system(size: 13, weight: .semibold))
            if let lookup {
                if !lookup.entry.phonetic.isEmpty {
                    Text(verbatim: "/\(lookup.entry.phonetic)/")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text((lookup.lemmaEntry ?? lookup.entry).displayDefinitions.first ?? "")
                    .font(.system(size: 12))
                    .lineLimit(2)
            } else if dictionary.state != .installed {
                Text(L("selectiontranslate.dict.downloadHintShort"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                speaker.speak(word, voice: LearnSpeaker.englishVoice(british: british), rate: Float(speed))
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.plain)
            Button(L("selectiontranslate.learn.detail")) {
                detailWord = word
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var playbackBar: some View {
        HStack(spacing: 8) {
            Button {
                if speaker.speakingText == text {
                    speaker.stop()
                } else {
                    speaker.speak(text, voice: LearnSpeaker.englishVoice(british: british), rate: Float(speed))
                }
            } label: {
                Image(systemName: speaker.speakingText == text ? "stop.fill" : "play.fill")
                    .frame(width: 14)
            }
            .help(L("selectiontranslate.panel.speakOriginal"))
            Picker("", selection: $speed) {
                Text(verbatim: "0.5×").tag(0.5)
                Text(verbatim: "0.75×").tag(0.75)
                Text(verbatim: "1×").tag(1.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("", selection: $british) {
                Text(L("selectiontranslate.learn.us")).tag(false)
                Text(L("selectiontranslate.learn.uk")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Button {
                shadowing.toggle(tokens: tokens, language: .english)
            } label: {
                Label(shadowing.isActive ? L("selectiontranslate.learn.shadowStop") : L("selectiontranslate.learn.shadow"),
                      systemImage: shadowing.isActive ? "stop.circle" : "mic")
            }
            .help(L("selectiontranslate.learn.shadowHelp"))
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var shadowingStatus: some View {
        switch shadowing.phase {
        case .idle:
            EmptyView()
        case .listening:
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                ProgressView(value: Double(shadowing.level))
                    .frame(width: 60)
                Text(shadowing.heard.isEmpty ? L("selectiontranslate.learn.shadowListening") : shadowing.heard)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .finishing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("selectiontranslate.learn.shadowChecking"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .done:
            if let score = shadowing.score {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("selectiontranslate.learn.shadowScore \(score.right) \(score.total)"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(score.right == score.total ? Color.green : Color.primary)
                    Text(L("selectiontranslate.learn.shadowHeard \(shadowing.heard)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 从母语学

/// 选中的是母语：先翻成在学的语言，再按那种语言展示（可点词、朗读、跟读）。
struct LearnFromNativeView: View {
    @ObservedObject var session: SelectionSession
    let native: TranslationLanguage
    let target: TranslationLanguage

    @State private var translated: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveText(text: session.text, size: 12, weight: .regular, maxHeight: 80, color: .secondary)
            Text(L("selectiontranslate.learn.howToSay \(target.endonym)"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            SelectionTranslationArea(text: session.text, source: native, target: target, showsResult: false) { value in
                translated = value
                session.primaryText = value
            }
            if let translated {
                if target.isSameLanguage(as: .english) {
                    if LearnText.isWordLike(translated) {
                        LearnWordCard(word: translated, context: nil, native: native, session: session)
                    } else {
                        LearnSentenceView(text: translated, native: native, showTranslation: false, session: session)
                    }
                } else {
                    LearnChineseView(text: translated, native: native, session: session, showTranslation: false)
                }
            }
        }
    }
}

// MARK: - 学中文

struct LearnChineseView: View {
    let text: String
    let native: TranslationLanguage
    @ObservedObject var session: SelectionSession
    var showTranslation = true

    @ObservedObject private var speaker = LearnSpeaker.shared
    @State private var speed: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveText(text: text, size: 16, weight: .regular, maxHeight: SelectionPanelMetrics.originalMaxHeight)
            AdaptiveText(text: LearnText.pinyin(text), size: 13, weight: .regular,
                         maxHeight: SelectionPanelMetrics.originalMaxHeight, color: .secondary)
            HStack(spacing: 8) {
                Button {
                    if speaker.speakingText == text {
                        speaker.stop()
                    } else {
                        speaker.speak(text, voice: "zh-CN", rate: Float(speed))
                    }
                } label: {
                    Image(systemName: speaker.speakingText == text ? "stop.fill" : "play.fill")
                        .frame(width: 14)
                }
                Picker("", selection: $speed) {
                    Text(verbatim: "0.5×").tag(0.5)
                    Text(verbatim: "0.75×").tag(0.75)
                    Text(verbatim: "1×").tag(1.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .controlSize(.small)
            if showTranslation {
                Divider()
                SelectionTranslationArea(text: text, source: .simplifiedChinese, target: native) { value in
                    session.primaryText = value
                }
            }
        }
    }
}

// MARK: - 词典下载行

/// 离线词典的状态与操作（下载 / 暂停 / 删除）。`compact` = 浮层里的精简样式。
struct EnglishDictionaryRow: View {
    @ObservedObject private var dictionary = EnglishDictionary.shared
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !compact {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("selectiontranslate.dict.title")
                        Text(verbatim: "ECDICT · \(dictionary.sizeText) · MIT")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                actions
                if compact { Spacer(minLength: 0) }
            }
            status
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch dictionary.state {
        case .notInstalled:
            Button(L("selectiontranslate.dict.download \(dictionary.sizeText)")) {
                dictionary.startDownload()
            }
        case .downloading:
            Button(L("translation.model.pause")) {
                dictionary.cancelDownload()
            }
        case .preparing:
            ProgressView().controlSize(.small)
        case .installed:
            if !compact {
                Button(L("translation.model.delete"), role: .destructive) {
                    dictionary.delete()
                }
            }
        case .failed:
            Button(L("translation.model.retry")) {
                dictionary.startDownload()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch dictionary.state {
        case .notInstalled:
            if !compact {
                Text("selectiontranslate.dict.notInstalledHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let progress):
            ProgressView(value: progress)
        case .preparing:
            Text("selectiontranslate.dict.preparing")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .installed:
            if !compact {
                Text("selectiontranslate.dict.installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(verbatim: message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
