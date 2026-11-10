import AVFoundation
import os

/// 默认输入设备经 AVAudioEngine 的 inputNode tap 取 PCM。会议 / 字幕与同传（`LiveTranslateMicSource`）和语音听写
/// （`DictationMicrophone`）共用。
///
/// 换输入设备、蓝牙耳机切到通话模式、别的 App 改了采样率时，系统停掉引擎、只发 `AVAudioEngineConfigurationChange`，
/// 不接住麦克风就此静音。接住它要做对三件事（2026-11-10 开着会议时连上蓝牙耳机，整个 App 崩溃）：
///
/// 1. **等设备稳定**：通知一来设备往往还在切换（那次通知比系统选好新麦克风早 0.12 秒），0.5 秒内没有新通知再重启；
/// 2. **换一个新引擎**：旧引擎的 inputNode 还记着旧设备的格式（48 kHz），蓝牙耳机通话模式是 16 kHz，
///    按旧格式挂 tap 采样率对不上；新引擎按设备的实际格式（`inputFormat`）挂；
/// 3. **接住 Objective-C 异常**：格式对不上时 AVFAudio 抛 "required condition is false: format.sampleRate ==
///    hwFormat.sampleRate"，Swift 接不住、进程直接 abort。经 `BBXObjC.catchException` 转成错误，宁可这一次没接上。
///
/// 重启失败隔一会儿再试（设备可能还没就绪），几次都不行就停着（字幕的看门狗看得到没声音进来）。
@MainActor
final class MicrophoneTap {
    private let log: Logger
    private let noDeviceError: Error
    private let onBuffer: AVAudioNodeTapBlock

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var restartWork: DispatchWorkItem?
    private var running = false

    /// 最后一次配置变化之后等多久再重启。
    private static let settleDelay: TimeInterval = 0.5
    /// 重启失败后隔多久再试（第 1 次失败后等 1 秒，依次类推），用完就停着。
    private static let retryDelays: [TimeInterval] = [1, 2, 4]

    /// `onBuffer` 在音频线程上调用：在 nonisolated 的地方造这个闭包，免得被推断成主线程隔离。
    init(log: Logger, noDeviceError: Error, onBuffer: @escaping AVAudioNodeTapBlock) {
        self.log = log
        self.noDeviceError = noDeviceError
        self.onBuffer = onBuffer
    }

    /// 开始取音。没有输入设备抛 `noDeviceError`，格式不对 / 引擎起不来抛相应的错误。
    func start() throws {
        try startEngine()
        running = true
    }

    func stop() {
        running = false
        restartWork?.cancel()
        restartWork = nil
        teardown()
    }

    // MARK: - 引擎

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // 设备此刻的实际格式；不用 outputFormat —— 那是节点输出端记着的格式，设备一换就过时。
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw noDeviceError }
        let block = onBuffer
        var tapped = false
        var startError: Error?
        do {
            // 挂 tap、prepare、start 都可能因为格式和设备对不上抛 Objective-C 异常（见类型说明第 3 条）。
            try BBXObjC.catchException {
                input.installTap(onBus: 0, bufferSize: 1024, format: format, block: block)
                tapped = true
                engine.prepare()
                do { try engine.start() } catch { startError = error }
            }
        } catch {
            if tapped { input.removeTap(onBus: 0) }
            engine.stop()
            throw error
        }
        if let startError {
            input.removeTap(onBus: 0)
            engine.stop()
            throw startError
        }
        self.engine = engine
        observe(engine)
    }

    private func teardown() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func observe(_ engine: AVAudioEngine) {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configurationChanged()
            }
        }
    }

    // MARK: - 换设备后重启

    /// 系统已经停了引擎：先拆掉，0.5 秒后按新设备的格式重来。新引擎起来以后设备又变了，会再收到通知、再来一遍。
    private func configurationChanged() {
        guard running else { return }
        log.error("audio engine configuration changed, restarting microphone input after it settles")
        teardown()
        scheduleRestart(attempt: 0, after: Self.settleDelay)
    }

    private func scheduleRestart(attempt: Int, after delay: TimeInterval) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.restart(attempt: attempt)
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func restart(attempt: Int) {
        restartWork = nil
        guard running, engine == nil else { return }
        do {
            try startEngine()
            log.notice("microphone input restarted (attempt \(attempt + 1))")
        } catch {
            log.error("microphone restart failed (attempt \(attempt + 1)): \(error.localizedDescription, privacy: .public)")
            guard attempt < Self.retryDelays.count else { return }
            scheduleRestart(attempt: attempt + 1, after: Self.retryDelays[attempt])
        }
    }
}
