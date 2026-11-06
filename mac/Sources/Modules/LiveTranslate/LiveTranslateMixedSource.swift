import AVFoundation
import Foundation

/// 会议用的采集链路（docs/meeting/TECH_DESIGN.md §2.2）：麦克风（`AVAudioEngine`）与系统声音（`SCStream`）同时开，
/// 两路各转成 16 kHz 单声道 Float32、进各自的环形缓冲；一个 20 ms 的混音节拍从两路各取一块相加后送进识别的音频路由。
///
/// 设备端识别同一时间只能跑一个请求，所以两路必须混成**一路**进一个识别器。两路的采集直接复用实时翻译原来的
/// `LiveTranslateMicSource` / `LiveTranslateSystemAudioSource`（配置一模一样，麦克风换设备时的自动恢复也在里面），
/// 只是各自接到一个私有的路由上，再由这里混。线下会议只开麦克风这一路（照样走这条链路：要电平）。
///
/// 每块同时记下两路的 RMS：控制条的电平点、按识别单元判「我 / 对方」都用它（`laneTotals`）。
@MainActor
final class LiveTranslateMixedSource: LiveTranslateAudioSource {
    private let core: LiveTranslateMixerCore
    private let microphoneRouter = LiveTranslateAudioRouter()
    private let systemRouter = LiveTranslateAudioRouter()
    private let includesMicrophone: Bool
    private let includesSystem: Bool
    private var microphone: LiveTranslateMicSource?
    private var system: LiveTranslateSystemAudioSource?

    init(router: LiveTranslateAudioRouter, microphone: Bool, system: Bool) {
        includesMicrophone = microphone
        includesSystem = system
        core = LiveTranslateMixerCore(output: router)
    }

    func start() async throws {
        guard core.isUsable else { throw LiveTranslateError.noInputDevice }
        microphoneRouter.setSink(core.sink(lane: LiveTranslateMixerCore.microphoneLane))
        systemRouter.setSink(core.sink(lane: LiveTranslateMixerCore.systemLane))
        core.start()
        do {
            if includesMicrophone {
                let source = LiveTranslateMicSource(router: microphoneRouter)
                try await source.start()
                microphone = source
            }
            if includesSystem {
                let source = LiveTranslateSystemAudioSource(router: systemRouter)
                try await source.start()
                system = source
            }
        } catch {
            stop()
            throw error
        }
    }

    /// 先停两路采集，再把缓冲里剩下的混完送出去（停止时最后那点声音也进识别器），最后停节拍。
    func stop() {
        microphone?.stop()
        microphone = nil
        system?.stop()
        system = nil
        microphoneRouter.setSink(nil)
        systemRouter.setSink(nil)
        core.stop()
    }

    /// 暂停：照常采集、照常走节拍，只是不往识别器送（也不计说话人能量）；继续后从当下接着送。
    func setPaused(_ paused: Bool) {
        core.setPaused(paused)
    }

    /// 上次取走以来两路的峰值 RMS（控制条的电平点）；没开的那一路为 nil。
    func takeLevels() -> LiveTranslateInputLevels {
        let peaks = core.takePeaks()
        return LiveTranslateInputLevels(microphone: includesMicrophone ? peaks.microphone : nil,
                                        system: includesSystem ? peaks.system : nil)
    }

    /// 两路有人声的累计时长（一直往上累计；判一句的说话人时取差）。
    var laneTotals: LiveTranslateLaneStats { core.totals }
}

/// 两路此刻的电平（0…1 的 RMS 峰值）；nil = 没有这一路。
struct LiveTranslateInputLevels: Equatable {
    var microphone: Float?
    var system: Float?
}

/// 混音的线程部分：两路的采集回调线程往环形缓冲里写，混音队列每 20 ms 取。
/// @unchecked Sendable 依据：`mixer` / `totals` / `peaks` / `paused` 只在 `lock` 内读写；`timer` / `clock` 只在 `queue` 上碰。
final class LiveTranslateMixerCore: @unchecked Sendable {
    static let microphoneLane = 0
    static let systemLane = 1

    private let output: LiveTranslateAudioRouter
    private let format: AVAudioFormat?
    private let queue = DispatchQueue(label: "com.baobox.app.livetranslate.mixer", qos: .userInitiated)
    private let lock = NSLock()
    private var mixer = LiveTranslateMixer(laneCount: 2)
    private var stats = LiveTranslateLaneStats()
    private var peaks: [Float] = [0, 0]
    private var paused = false
    private var timer: DispatchSourceTimer?
    private var clock: LiveTranslateMixClock?

    init(output: LiveTranslateAudioRouter) {
        self.output = output
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveTranslateMixer.sampleRate,
                               channels: 1, interleaved: false)
    }

    var isUsable: Bool { format != nil }

    /// 某一路的接收端：在采集回调线程上把 PCM 转成 16 kHz 单声道，写进这一路的环形缓冲。
    /// 每一路各一个转换器，只在那一路的回调线程上用。
    func sink(lane: Int) -> LiveTranslateAudioRouter.Sink {
        guard let format else { return { _ in } }
        let converter = LiveTranslatePCMConverter(outputFormat: format)
        return { [weak self] buffer in
            guard let self, let converted = converter.convert(buffer),
                  let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            let samples = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
            self.lock.lock()
            self.mixer.push(samples, lane: lane)
            self.lock.unlock()
        }
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            clock = LiveTranslateMixClock(start: Self.now())
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }
    }

    /// 停节拍；缓冲里剩下的（不在暂停中时）混完送出去。同步做完再返回：调用方紧接着就让识别器收尾。
    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            clock = nil
            lock.lock()
            let blocks = mixer.drain()
            let paused = self.paused
            if !paused {
                for block in blocks { stats.add(levels: block.levels) }
            }
            lock.unlock()
            if !paused { emit(blocks) }
        }
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        self.paused = paused
        peaks = [0, 0]
        lock.unlock()
    }

    func takePeaks() -> (microphone: Float, system: Float) {
        lock.lock()
        defer {
            peaks = [0, 0]
            lock.unlock()
        }
        return (peaks[Self.microphoneLane], peaks[Self.systemLane])
    }

    var totals: LiveTranslateLaneStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    // MARK: - 节拍（只在 queue 上）

    private func tick() {
        guard var clock else { return }
        let due = clock.blocksDue(at: Self.now())
        self.clock = clock
        guard due > 0 else { return }
        lock.lock()
        var blocks: [LiveTranslateMixer.Block] = []
        blocks.reserveCapacity(due)
        for _ in 0..<due {
            blocks.append(mixer.nextBlock())
        }
        let paused = self.paused
        if !paused {
            for block in blocks {
                stats.add(levels: block.levels)
                for lane in block.levels.indices where lane < peaks.count {
                    peaks[lane] = max(peaks[lane], block.levels[lane])
                }
            }
        }
        lock.unlock()
        // 暂停中：照样从缓冲里取（不攒旧声音），只是丢掉。
        if !paused { emit(blocks) }
    }

    /// 几块拼成一个 PCM 缓冲送进识别的音频路由。
    private func emit(_ blocks: [LiveTranslateMixer.Block]) {
        guard let format, !blocks.isEmpty else { return }
        let frames = blocks.count * LiveTranslateMixer.blockFrames
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        var offset = 0
        for block in blocks {
            for sample in block.samples {
                channel[offset] = sample
                offset += 1
            }
        }
        output.append(buffer)
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
