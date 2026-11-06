import AVFoundation
import os

private let selfTestLog = Logger(subsystem: "com.baobox.app", category: "meeting.selftest")

/// 设备自检（需求 §2「试录 3 秒」）：同时录麦克风与系统声音 3 秒，显示两路电平，然后回放混音。
///
/// 采集直接用线上会议同一条混音链路（`LiveTranslateMixedSource`：两路各转 16 kHz、20 ms 一块相加），录到的就是会议里
/// 识别器听到的那一路；回放是一个只有输出的 `AVAudioEngine` + 播放节点 —— 不碰 voice processing（会议回声消除在用户的
/// Mac 上把整个 App 卡死过）。系统声音采不到（没给屏幕录制权限）时只录麦克风，并说明原因。
/// 自检期间登记占用（`AudioCaptureCoordinator`），免得与会议记录、自由听译同时抢麦克风；会议检测也就不会把它当成开会。
@MainActor
final class MeetingDeviceTest: ObservableObject {
    static let shared = MeetingDeviceTest()
    private init() {}

    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case playing
        case done
        case failed(String)
    }

    static let duration: TimeInterval = 3
    private static let owner = "meetingSelfTest"
    /// 「有声音」的阈值（与控制条的电平点一致）。
    private static let soundThreshold: Float = 0.006

    @Published private(set) var phase: Phase = .idle
    /// 此刻的电平（0…1，按 dB 映射）；系统声音那一路采不到时为 nil。
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var systemLevel: Float?
    /// 3 秒里两路的最大 RMS（判「有没有声音」）。
    @Published private(set) var microphonePeak: Float = 0
    @Published private(set) var systemPeak: Float = 0
    @Published private(set) var systemUnavailable = false
    @Published private(set) var progress: Double = 0

    private var source: LiveTranslateMixedSource?
    private let router = LiveTranslateAudioRouter()
    private let collector = MeetingSampleCollector()
    private var timer: Timer?
    private var startedAt: Date?
    private var playback: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var generation = 0

    var isBusy: Bool {
        switch phase {
        case .preparing, .recording, .playing: return true
        case .idle, .done, .failed: return false
        }
    }

    var microphoneHeard: Bool { microphonePeak > Self.soundThreshold }
    var systemHeard: Bool { systemPeak > Self.soundThreshold }

    func start() {
        guard !isBusy else { return }
        if let busy = AudioCaptureCoordinator.shared.busyMessage() {
            phase = .failed(busy)
            return
        }
        generation += 1
        let run = generation
        phase = .preparing
        microphoneLevel = 0
        systemLevel = 0
        microphonePeak = 0
        systemPeak = 0
        systemUnavailable = false
        progress = 0
        Task { await self.record(run: run) }
    }

    func cancel() {
        generation += 1
        teardown()
        phase = .idle
    }

    // MARK: - 录

    private func record(run: Int) async {
        guard await Self.microphoneAllowed() else {
            guard run == generation else { return }
            phase = .failed(L("meeting.selfTest.micDenied"))
            return
        }
        guard run == generation else { return }
        guard AudioCaptureCoordinator.shared.claim(owner: Self.owner, label: L("meeting.selfTest.captureLabel"),
                                                   microphone: true) else {
            phase = .failed(AudioCaptureCoordinator.shared.busyMessage() ?? L("meeting.selfTest.failed"))
            return
        }
        collector.reset()
        let collector = self.collector
        router.setSink { buffer in collector.append(buffer) }
        var mixed = LiveTranslateMixedSource(router: router, microphone: true, system: true)
        var systemOK = true
        do {
            try await mixed.start()
        } catch {
            // 多半是没给屏幕录制权限：只录麦克风。
            selfTestLog.notice("system audio unavailable: \(error.localizedDescription, privacy: .public)")
            systemOK = false
            // 第一次失败前麦克风可能已经送进来一点：从头录。
            collector.reset()
            mixed = LiveTranslateMixedSource(router: router, microphone: true, system: false)
            do {
                try await mixed.start()
            } catch {
                selfTestLog.error("microphone unavailable: \(error.localizedDescription, privacy: .public)")
                teardown()
                if run == generation {
                    phase = .failed(L("meeting.selfTest.micFailed \(error.localizedDescription)"))
                }
                return
            }
        }
        guard run == generation else {
            mixed.stop()
            return
        }
        source = mixed
        systemUnavailable = !systemOK
        systemLevel = systemOK ? 0 : nil
        startedAt = Date()
        phase = .recording
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingDeviceTest.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard phase == .recording, let source, let startedAt else { return }
        let levels = source.takeLevels()
        let microphone = levels.microphone ?? 0
        microphoneLevel = Self.meter(microphone)
        microphonePeak = max(microphonePeak, microphone)
        if let system = levels.system {
            systemLevel = Self.meter(system)
            systemPeak = max(systemPeak, system)
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        progress = min(1, elapsed / Self.duration)
        if elapsed >= Self.duration {
            finishRecording()
        }
    }

    // MARK: - 回放

    private func finishRecording() {
        timer?.invalidate()
        timer = nil
        source?.stop()
        source = nil
        router.setSink(nil)
        AudioCaptureCoordinator.shared.release(owner: Self.owner)
        microphoneLevel = 0
        if systemLevel != nil { systemLevel = 0 }
        let samples = collector.take()
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveTranslateMixer.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            phase = .failed(L("meeting.selfTest.nothing"))
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            channel[index] = samples[index]
        }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            selfTestLog.error("playback failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(L("meeting.selfTest.playbackFailed"))
            return
        }
        playback = engine
        player = node
        phase = .playing
        let run = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MeetingDeviceTest.shared.playbackFinished(run: run) }
            }
        }
        node.play()
        // 保险：回调没来也按时收尾。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 2) {
            MainActor.assumeIsolated { MeetingDeviceTest.shared.playbackFinished(run: run) }
        }
    }

    private func playbackFinished(run: Int) {
        guard run == generation, phase == .playing else { return }
        teardown()
        phase = .done
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        source?.stop()
        source = nil
        router.setSink(nil)
        player?.stop()
        playback?.stop()
        player = nil
        playback = nil
        AudioCaptureCoordinator.shared.release(owner: Self.owner)
    }

    // MARK: - 工具

    /// RMS → 0…1（-50 dB 以下为 0，0 dB 为 1）。
    static func meter(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (decibels + 50) / 50))
    }

    private static func microphoneAllowed() async -> Bool {
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

/// 混音链路送出来的 16 kHz 单声道样本，攒着回放。混音队列上写、主线程取。
/// @unchecked Sendable 依据：`samples` 只在 `lock` 内读写。
final class MeetingSampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    /// 最多攒 10 秒（3 秒自检用不满；防止异常时无限长）。
    private static let limit = Int(LiveTranslateMixer.sampleRate * 10)

    func reset() {
        lock.lock()
        samples = []
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        lock.lock()
        if samples.count < Self.limit {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: min(count, Self.limit - samples.count)))
        }
        lock.unlock()
    }

    func take() -> [Float] {
        lock.lock()
        defer {
            samples = []
            lock.unlock()
        }
        return samples
    }
}
