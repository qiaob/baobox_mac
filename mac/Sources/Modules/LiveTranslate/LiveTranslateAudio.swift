import AVFoundation
import CoreMedia
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

    func setSink(_ sink: Sink?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(buffer)
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

/// 默认输入设备，经 AVAudioEngine 的 inputNode tap 取 PCM。
@MainActor
final class LiveTranslateMicSource: LiveTranslateAudioSource {
    private let engine = AVAudioEngine()
    private let router: LiveTranslateAudioRouter
    private var tapInstalled = false

    init(router: LiveTranslateAudioRouter) {
        self.router = router
    }

    func start() async throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw LiveTranslateError.noInputDevice
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(router: router))
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
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
