import AVFoundation
import CoreMedia
import os
import ScreenCaptureKit

/// 音频路由：音源回调线程把 PCM 交给当前识别引擎的接收端（sink）。
///
/// 旧引擎切段时主线程原子替换 sink，音频线程下一块就进新请求 —— 不丢音频。
/// @unchecked Sendable 依据：唯一的可变状态 `sink` 只在 `lock` 内读写；
/// sink 本身只在音频回调线程上调用（同一时刻只有一个音源）。
final class LiveTranslateAudioRouter: @unchecked Sendable {
    typealias Sink = (AVAudioPCMBuffer) -> Void

    private let lock = NSLock()
    private var sink: Sink?
    /// 旁路：原样再给一份（朗读译文时把我的原声混进会议，见 docs/live-translate-voice/DESIGN.md §3）。
    private var monitor: Sink?
    /// 静音：外放朗读译文期间不送识别，免得把读出来的声音再识别一遍（同上 §6）。
    private var muted = false
    /// 最近一次「有人在说话」（音量超过阈值）的时间。识别看门狗用它区分「没人说话」和「识别卡住」。
    private var lastVoice = Date.distantPast
    /// 停顿后重新开口的时刻，还没等到出字（字幕条的识别延迟 = 开口到出字，见 `takeOnset`）。
    private var onset: Date?
    /// 心跳日志用的统计（见 `takeStats`）。
    private var stats = Stats()

    /// 上次取走以来收到的音频：块数、总秒数、其中有人声的秒数、暂停识别（朗读中）丢掉的秒数。
    struct Stats {
        var buffers = 0
        var seconds: Double = 0
        var voiced: Double = 0
        var muted: Double = 0
    }

    /// 约 -40 dBFS：安静房间的底噪在它之下，正常说话 / 视频人声在它之上。
    private static let voiceRMSThreshold: Float = 0.01
    /// 静了这么久再出声才算「重新开口」。
    private static let onsetGap: TimeInterval = 0.6
    /// 一次开口最多等这么久出字，过了就让后来的开口顶替（之前那次多半是没被识别成字的杂音）。
    private static let onsetPending: TimeInterval = 2.5

    func setSink(_ sink: Sink?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func setMonitor(_ monitor: Sink?) {
        lock.lock()
        self.monitor = monitor
        lock.unlock()
    }

    func setMuted(_ muted: Bool) {
        lock.lock()
        self.muted = muted
        lock.unlock()
    }

    var lastVoiceDate: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastVoice
    }

    /// 字幕条出了新字时取走「开口时刻」（取一次就清掉）。超过 `maxAge` 还没出字的不算：多半是咳嗽、
    /// 敲键盘之类没被识别成字的声音，拿它算延迟会虚高。
    func takeOnset(maxAge: TimeInterval) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let onset else { return nil }
        self.onset = nil
        return Date().timeIntervalSince(onset) <= maxAge ? onset : nil
    }

    /// 取走统计并清零（控制器每 10 秒记一行心跳日志）。
    func takeStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        let taken = stats
        stats = Stats()
        return taken
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let voiced = Self.isVoiced(buffer)
        let seconds = buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
        lock.lock()
        stats.buffers += 1
        stats.seconds += seconds
        if voiced { stats.voiced += seconds }
        if muted { stats.muted += seconds }
        let sink = muted ? nil : self.sink
        let monitor = self.monitor
        // 静音期间不算「有人在说话」：识别器的看门狗不会因为没出字而误判卡死。
        if voiced, !muted {
            let now = Date()
            // 停顿后重新开口：记下开口时刻。上一次开口还在等出字（不到 onsetPending）就不覆盖 —— 不然先说的那截
            // 出字时会按后开口的那次算，延迟偏小。
            if now.timeIntervalSince(lastVoice) > Self.onsetGap,
               onset.map({ now.timeIntervalSince($0) > Self.onsetPending }) ?? true {
                onset = now
            }
            lastVoice = now
        }
        lock.unlock()
        sink?(buffer)
        monitor?(buffer)
    }

    /// 一串录音里有人声的总秒数（「自动」轮流识别判断「说了这么久、字却这么少」用）。
    static func voicedDuration(of buffers: [AVAudioPCMBuffer]) -> TimeInterval {
        buffers.reduce(0) { total, buffer in
            guard buffer.format.sampleRate > 0, isVoiced(buffer) else { return total }
            return total + Double(buffer.frameLength) / buffer.format.sampleRate
        }
    }

    /// 第一声道的 RMS 是否过阈值。非 float 格式拿不到样本就当没信息（不更新）。
    static func isVoiced(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return false }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let value = samples[index]
            sum += value * value
        }
        return (sum / Float(count)).squareRoot() > voiceRMSThreshold
    }
}

/// 把音源的 PCM 转成识别引擎要求的格式（新引擎要固定采样率 / 格式）。
/// 只在音频回调线程上使用，见 `LiveTranslateAudioRouter`。
final class LiveTranslatePCMConverter {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter, buffer.format.sampleRate > 0 else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

@MainActor
protocol LiveTranslateAudioSource: AnyObject {
    func start() async throws
    func stop()
}

// MARK: - 麦克风

/// 默认输入设备，经 AVAudioEngine 的 inputNode tap 取 PCM。换设备后的重启见 `MicrophoneTap`。
@MainActor
final class LiveTranslateMicSource: LiveTranslateAudioSource {
    private let tap: MicrophoneTap

    init(router: LiveTranslateAudioRouter) {
        tap = MicrophoneTap(log: LiveTranslateLog.audio, noDeviceError: LiveTranslateError.noInputDevice,
                            onBuffer: Self.makeTap(router: router))
    }

    func start() async throws {
        try tap.start()
    }

    func stop() {
        tap.stop()
    }

    /// tap 在音频线程回调：在 nonisolated 上下文里造闭包，避免被推断成主线程隔离。
    nonisolated private static func makeTap(router: LiveTranslateAudioRouter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            router.append(buffer)
        }
    }
}

// MARK: - 系统声音

/// ScreenCaptureKit 只采音频（视频压到 2×2、1fps 且不挂 `.screen` 输出），
/// 与录屏同一条路径，屏幕录制权限已覆盖。
@MainActor
final class LiveTranslateSystemAudioSource: LiveTranslateAudioSource {
    private let output: LiveTranslateStreamOutput
    private var stream: SCStream?

    init(router: LiveTranslateAudioRouter) {
        self.output = LiveTranslateStreamOutput(router: router)
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw LiveTranslateError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
        }
    }
}

/// @unchecked Sendable 依据：无可变状态；router 自身线程安全。
final class LiveTranslateStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.baobox.app.livetranslate.audio")
    private let router: LiveTranslateAudioRouter

    init(router: LiveTranslateAudioRouter) {
        self.router = router
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer),
              let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        router.append(buffer)
    }

    /// CMSampleBuffer → AVAudioPCMBuffer（拷贝一份，识别请求可能异步持有）。
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                                                                  frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
