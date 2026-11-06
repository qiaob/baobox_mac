import AVFoundation
import Foundation

/// 宠物的嗓子（#55，docs/desktop-pet/CHAT.md §5）：系统语音 `AVSpeechSynthesizer`，离线免费。
///
/// - 自己一个合成器、从系统默认输出出声：不碰同传的「朗读译文送进会议」那套输出（`LiveTranslateVoiceOutput`）。
/// - 回复流式到来，一句说完整了就排进去读（合成器自己排队），不等整段回复。
/// - 嘴型：系统每读到一个词回调一次（`willSpeakRangeOfSpeechString`），这个词读的时间里嘴一张一合，
///   词与词之间合上 —— 不用拿音频算音量，也就不用另开一路播放。
@MainActor
final class PetVoice: NSObject, AVSpeechSynthesizerDelegate {
    /// 张嘴程度 0–1（30 fps；不说话时最后报一次 0）。
    var onMouth: ((CGFloat) -> Void)?
    /// 开始 / 读完（排队的都读完）。
    var onSpeakingChanged: ((Bool) -> Void)?

    /// 必须常驻持有：中途释放会静音。
    private let synthesizer = AVSpeechSynthesizer()
    private var timer: Timer?
    private var wordUntil = Date.distantPast
    private var mouth: CGFloat = 0
    /// 排着 / 正在读的句子（按对象认：stop 之后迟到的「取消」回调不会算到新句子头上）。
    private var active: Set<ObjectIdentifier> = []
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, persona: PetPersona) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = persona.voice(for: trimmed)
        utterance.pitchMultiplier = Float(persona.pitch)
        utterance.rate = Float(persona.rate)
        active.insert(ObjectIdentifier(utterance))
        setSpeaking(true)
        synthesizer.speak(utterance)
    }

    func stop() {
        active = []
        synthesizer.stopSpeaking(at: .immediate)
        wordUntil = .distantPast
        setSpeaking(false)
    }

    private func setSpeaking(_ on: Bool) {
        guard on != isSpeaking else { return }
        isSpeaking = on
        onSpeakingChanged?(on)
        if on { startTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMouth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tickMouth() {
        let now = Date()
        if now < wordUntil {
            // 一个词里张合两三下，像在发音节。
            let t = now.timeIntervalSinceReferenceDate
            mouth = 0.3 + 0.6 * CGFloat(abs(sin(t * 17)))
        } else {
            mouth = max(0, mouth - 0.2)
        }
        onMouth?(mouth)
        if !isSpeaking, mouth <= 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func wordStarted(length: Int) {
        // 中文一个「词」常是一两个字，英文一个单词：按字数估这一下读多久。
        wordUntil = Date().addingTimeInterval(min(max(Double(length) * 0.11, 0.12), 0.6))
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard active.remove(id) != nil else { return }
        if active.isEmpty { setSpeaking(false) }
    }

    // MARK: - AVSpeechSynthesizerDelegate（系统线程回调，转回主线程）

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        let length = characterRange.length
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.wordStarted(length: length) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.utteranceEnded(id) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.utteranceEnded(id) }
        }
    }
}
