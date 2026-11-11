import AVFoundation
import CoreAudio
import Foundation

/// 朗读译文的设置（前缀 `livetranslate.voice.`）。见 docs/live-translate-voice/DESIGN.md。
enum LiveTranslateVoiceSettings {
    static let enabledKey = "livetranslate.voice.enabled"
    static let meetingDeviceKey = "livetranslate.voice.meetingDevice"
    static let speakersKey = "livetranslate.voice.speakers"
    static let rateKey = "livetranslate.voice.rate"
    static let mixOriginalKey = "livetranslate.voice.mixOriginal"
    static let keepListeningKey = "livetranslate.voice.keepListening"

    static func voiceKey(_ language: TranslationLanguage) -> String {
        "livetranslate.voice.voice.\(language.code)"
    }

    /// 0…1（`AVSpeechUtterance` 的语速刻度，0.5 = 正常）；默认略快，跟得上说话。
    static let defaultRate: Double = 0.55

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 送会议用的虚拟声卡 UID；空 = 不送会议。
    static var meetingDeviceUID: String {
        get { UserDefaults.standard.string(forKey: meetingDeviceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: meetingDeviceKey) }
    }

    /// 送会议时同时从系统默认输出（音响 / 耳机）播放。不送会议时不看它，总是外放。
    static var speakers: Bool {
        get { UserDefaults.standard.object(forKey: speakersKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: speakersKey) }
    }

    static var rate: Double {
        get { UserDefaults.standard.object(forKey: rateKey) as? Double ?? defaultRate }
        set { UserDefaults.standard.set(newValue, forKey: rateKey) }
    }

    /// 戴着耳机：音源是麦克风、又外放朗读时也继续识别（耳机里的声音不会被麦克风听回去）。
    /// 默认关：从音响外放时读的那几秒暂停识别，防回授，这期间说的话会丢。
    /// （试过用系统语音处理做回声消除、读的时候照常收音，这台 Mac 上会把音频引擎搞坏，已撤掉，见 DESIGN §6。）
    static var keepListening: Bool {
        get { UserDefaults.standard.bool(forKey: keepListeningKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepListeningKey) }
    }

    /// 我的原声也送进会议（读译文时压低）。默认关：会议里只听到译文，像同声传译。
    static var mixOriginal: Bool {
        get { UserDefaults.standard.bool(forKey: mixOriginalKey) }
        set { UserDefaults.standard.set(newValue, forKey: mixOriginalKey) }
    }

    /// 某种语言在这台 Mac 上可选的音色：高品质 → 增强 → 标准，同级按名字排；怪声音色（Bahh、Bells…）不列。
    static func voices(for language: TranslationLanguage) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language.voiceLanguage && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { lhs, rhs in
                lhs.quality.rawValue != rhs.quality.rawValue
                    ? lhs.quality.rawValue > rhs.quality.rawValue
                    : lhs.name < rhs.name
            }
    }

    /// 选定的音色；没选或已被删掉：有增强 / 高品质的就用最好的那个，否则用系统给这种语言的默认音色。
    static func voice(for language: TranslationLanguage) -> AVSpeechSynthesisVoice? {
        if let identifier = UserDefaults.standard.string(forKey: voiceKey(language)),
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            return voice
        }
        let available = voices(for: language)
        if let best = available.first, best.quality != .default { return best }
        return AVSpeechSynthesisVoice(language: language.voiceLanguage) ?? available.first
    }
}

/// 能当「虚拟麦克风」的音频设备：既能输入又能输出的虚拟声卡（BlackHole、Loopback……）。
/// 会议软件把它的输入端选作麦克风，Baobox 往它的输出端播。
struct LiveTranslateAudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func virtualDevices() -> [LiveTranslateAudioDevice] {
        allDeviceIDs().compactMap { id in
            guard channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
                  channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0,
                  transportType(id) == kAudioDeviceTransportTypeVirtual,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return LiveTranslateAudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func device(uid: String) -> LiveTranslateAudioDevice? {
        guard !uid.isEmpty else { return nil }
        return virtualDevices().first { $0.uid == uid }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// 朗读译文：系统 TTS 渲染成 PCM，同时排到「会议」（虚拟声卡）和「音响」（系统默认输出）两路播放，
/// 两路同步。按顺序读；跟不上时跳过积压超过 `maxLag` 的旧句子。见 docs/live-translate-voice/DESIGN.md。
@MainActor
final class LiveTranslateVoiceOutput {
    /// 正在读（读完后再留 `tail` 余量）。控制器据此在「麦克风 + 外放」时暂停识别，防回授。
    var onSpeakingChanged: ((Bool) -> Void)?
    private(set) var isActive = false
    /// 原声混入「会议」那一路的接收端（音频线程调用）；没开原声混入时为 nil。
    private(set) var originalSink: LiveTranslateAudioRouter.Sink?

    private struct Output {
        let engine: AVAudioEngine
        let player: AVAudioPlayerNode
        /// 原声混入用（只在「会议」那一路）。
        let original: AVAudioPlayerNode?
    }

    private struct Item {
        let text: String
        let language: TranslationLanguage
        let createdAt: Date
    }

    private var outputs: [Output] = []
    private var queue: [Item] = []
    private var speaking = false
    private var speakingReported = false
    private var tailWork: DispatchWorkItem?
    private var timeoutWork: DispatchWorkItem?
    /// 每读一句 +1：超时 / 停止后迟到的「读完了」回调作废。
    private var utteranceID = 0
    /// 必须常驻持有：中途释放会静音。
    private let synthesizer = AVSpeechSynthesizer()
    private let playerFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)

    /// 积压超过这么久没读的旧句子跳过（只要后面还有更新的）。
    private static let maxLag: TimeInterval = 8
    /// 读完后再等这么久才算「不在读」（声音从音响出来到麦克风有延迟）。
    private static let tail: TimeInterval = 0.3
    /// 读原声时的音量；读译文期间压低到这个值。
    private static let duckedOriginalVolume: Float = 0.25

    /// `meetingDevice`：送会议的虚拟声卡；`speakers`：同时从系统默认输出播放；`mixOriginal`：原声也送进会议。
    func start(meetingDevice: LiveTranslateAudioDevice?, speakers: Bool, mixOriginal: Bool) {
        stop()
        if let meetingDevice, let output = makeOutput(device: meetingDevice.id, withOriginal: mixOriginal) {
            outputs.append(output)
            if let node = output.original, let playerFormat {
                originalSink = Self.makeOriginalSink(node: node, format: playerFormat)
            }
        }
        if speakers, let output = makeOutput(device: nil, withOriginal: false) {
            outputs.append(output)
        }
        isActive = !outputs.isEmpty
        LiveTranslateLog.audio.notice(
            "voice output: meeting \(meetingDevice?.name ?? "off", privacy: .public), speakers \(speakers), original \(mixOriginal)")
    }

    func stop() {
        isActive = false
        utteranceID += 1
        queue = []
        speaking = false
        tailWork?.cancel()
        timeoutWork?.cancel()
        synthesizer.stopSpeaking(at: .immediate)
        originalSink = nil
        for output in outputs {
            output.player.stop()
            output.original?.stop()
            output.engine.stop()
        }
        outputs = []
        reportSpeaking(false)
    }

    /// 预先加载音色：每次开始后的第一句要先花约 1.3 秒加载，之后出声只要 0.02 秒（实测 2026-11-05）。
    /// 开始时先合成一个字、丢掉，第一句就不用等了。
    func prewarm(_ language: TranslationLanguage) {
        guard isActive else { return }
        let utterance = AVSpeechUtterance(string: language.isChinese ? "好" : "OK")
        utterance.voice = LiveTranslateVoiceSettings.voice(for: language)
        synthesizer.write(utterance) { _ in }
    }

    /// 还没读完的句数（排队的 + 正在读的），心跳日志用。
    var backlog: Int { queue.count + (speaking ? 1 : 0) }

    func speak(_ text: String, language: TranslationLanguage) {
        guard isActive else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.append(Item(text: trimmed, language: language, createdAt: Date()))
        speakNext()
    }

    // MARK: - 播放

    private func makeOutput(device: AudioDeviceID?, withOriginal: Bool) -> Output? {
        guard let playerFormat else { return nil }
        let engine = AVAudioEngine()
        if let device {
            // 先指定设备，再碰 mainMixerNode（它一碰就按当前输出设备的格式接好线）。
            guard let unit = engine.outputNode.audioUnit else { return nil }
            var deviceID = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                LiveTranslateLog.audio.error("voice output: cannot use device \(device) (\(status))")
                return nil
            }
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        var original: AVAudioPlayerNode?
        if withOriginal {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: playerFormat)
            original = node
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            LiveTranslateLog.audio.error("voice output: engine start failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        player.play()
        original?.play()
        return Output(engine: engine, player: player, original: original)
    }

    private func speakNext() {
        guard isActive, !speaking else { return }
        while queue.count > 1, Date().timeIntervalSince(queue[0].createdAt) > Self.maxLag {
            queue.removeFirst()
        }
        guard !queue.isEmpty, let playerFormat else {
            scheduleQuiet()
            return
        }
        let item = queue.removeFirst()
        speaking = true
        tailWork?.cancel()
        reportSpeaking(true)

        utteranceID += 1
        let id = utteranceID
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.voice = LiveTranslateVoiceSettings.voice(for: item.language)
        utterance.rate = Float(LiveTranslateVoiceSettings.rate)
        let players = outputs.map(\.player)
        let tracker = LiveTranslatePlaybackTracker { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.didFinish(utterance: id)
                }
            }
        }
        // 万一系统 TTS 没回调结束（音色被删等）：按字数给个上限，到点当读完了。
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.didFinish(utterance: id)
            }
        }
        timeoutWork?.cancel()
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(item.text.count) * 0.4 + 5, execute: timeout)

        let converter = LiveTranslatePCMConverter(outputFormat: playerFormat)
        // 第一块音频可能要等音色加载；这么久还一块都没有就当这句读不出来。
        tracker.expectAudio(within: 2)
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            guard pcm.frameLength > 0 else {
                tracker.synthesisEnded()
                return
            }
            tracker.received()
            guard let converted = converter.convert(pcm) else { return }
            for (index, player) in players.enumerated() {
                // 每路一份自己的缓冲区，播放进度互不影响；只按第一路计「读完」。
                guard let copy = index == 0 ? converted : LiveTranslateAudioGate.copy(converted) else { continue }
                if index == 0 { tracker.scheduled() }
                player.scheduleBuffer(copy, completionCallbackType: .dataPlayedBack) { _ in
                    if index == 0 { tracker.played() }
                }
            }
            if players.isEmpty { tracker.synthesisEnded() }
        }
    }

    private func didFinish(utterance id: Int) {
        guard id == utteranceID, speaking else { return }
        timeoutWork?.cancel()
        speaking = false
        speakNext()
    }

    /// 队列读空了：余量过后再报「不在读」。
    private func scheduleQuiet() {
        tailWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.speaking else { return }
                self.reportSpeaking(false)
            }
        }
        tailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tail, execute: work)
    }

    private func reportSpeaking(_ value: Bool) {
        guard value != speakingReported else { return }
        speakingReported = value
        for output in outputs {
            output.original?.volume = value ? Self.duckedOriginalVolume : 1
        }
        onSpeakingChanged?(value)
    }

    /// 原声混入的接收端：在无 actor 隔离的上下文里造闭包（它在音频线程上调）。音源给的缓冲区之后可能被复用，
    /// 转换器格式一致时会原样返回，所以排进播放器前一律拷一份。
    nonisolated private static func makeOriginalSink(node: AVAudioPlayerNode,
                                                     format: AVAudioFormat) -> LiveTranslateAudioRouter.Sink {
        let converter = LiveTranslatePCMConverter(outputFormat: format)
        return { buffer in
            guard let converted = converter.convert(buffer),
                  let copy = converted === buffer ? LiveTranslateAudioGate.copy(converted) : converted else { return }
            node.scheduleBuffer(copy, completionHandler: nil)
        }
    }
}

/// 一句话的播放进度：排了几块、播完几块、合成结束没有；都完了回调一次。
///
/// 「合成结束」不能只等 `write` 最后那个空缓冲区：macOS 14 实测它不一定发（音频照常给，结尾标记没有）。
/// 所以收到一块就重新计时，`idleEnd` 内没有新块就当合成结束（合成比实时快得多，块是一阵一阵连着来的）。
/// @unchecked Sendable 依据：可变状态都在 lock 内；TTS 回调线程、播放回调线程、计时队列都会调。
private final class LiveTranslatePlaybackTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var synthesisDone = false
    private var finished = false
    private var idleWork: DispatchWorkItem?
    private let onFinish: () -> Void
    private static let idleEnd: TimeInterval = 0.4
    private static let timerQueue = DispatchQueue(label: "com.baobox.app.livetranslate.tts")

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    /// 刚开始合成：这么久一块都没来就当结束。
    func expectAudio(within seconds: TimeInterval) {
        arm(after: seconds)
    }

    /// 来了一块：重新计时。
    func received() {
        arm(after: Self.idleEnd)
    }

    private func arm(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.synthesisEnded()
        }
        lock.lock()
        idleWork?.cancel()
        idleWork = work
        lock.unlock()
        Self.timerQueue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func scheduled() {
        lock.lock()
        pending += 1
        lock.unlock()
    }

    func played() {
        lock.lock()
        pending -= 1
        let done = finishIfDone()
        lock.unlock()
        if done { onFinish() }
    }

    func synthesisEnded() {
        lock.lock()
        idleWork?.cancel()
        synthesisDone = true
        let done = finishIfDone()
        lock.unlock()
        if done { onFinish() }
    }

    private func finishIfDone() -> Bool {
        guard !finished, synthesisDone, pending <= 0 else { return false }
        finished = true
        return true
    }
}

/// 「Baobox 同传」虚拟麦克风驱动的安装 / 卸载（docs/live-translate-voice/DESIGN.md §3）。
///
/// 驱动随 App 打包在 `Contents/Library/Audio/`（BlackHole 源码改名编译，见 Makefile）。装进
/// `/Library/Audio/Plug-Ins/HAL/` 要管理员权限：用系统的授权对话框（`osascript … with administrator privileges`），
/// 装完 / 卸完重启系统音频服务（coreaudiod），所有声音会断 1～2 秒。
enum LiveTranslateDriver {
    static let bundleName = "BaoboxInterpreter.driver"
    /// 驱动里的设备 UID（`kDriver_Name` + "_UID"）。
    static let deviceUID = "BaoboxInterpreter_UID"
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)
        .appendingPathComponent(bundleName)

    /// App 包里带的驱动；构建时没编进去为 nil。
    static var bundledURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Audio/\(bundleName)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    /// nil = 成功；"" = 用户取消；其他 = 出错说明。
    static func install() async -> String? {
        guard let source = bundledURL else { return L("livetranslate.voice.driverNotBundled") }
        let target = Shell.quote(installedURL.path)
        return await runPrivileged("mkdir -p /Library/Audio/Plug-Ins/HAL && rm -rf \(target) && "
                                   + "cp -R \(Shell.quote(source.path)) \(target) && chown -R root:wheel \(target) && "
                                   + "killall -9 coreaudiod")
    }

    static func uninstall() async -> String? {
        await runPrivileged("rm -rf \(Shell.quote(installedURL.path)) && killall -9 coreaudiod")
    }

    /// 装完后等音频服务重启、设备出现（最多 10 秒）；出现了返回它的 UID。
    @MainActor
    static func waitForDevice() async -> String? {
        for _ in 0..<20 {
            if LiveTranslateAudioDevice.device(uid: deviceUID) != nil { return deviceUID }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// 后台线程跑 osascript（会弹系统的管理员密码框），不卡主线程。
    private static func runPrivileged(_ command: String) async -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let errors = Pipe()
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                    return
                }
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // -128：用户在密码框点了取消。
                continuation.resume(returning: text.contains("-128") ? "" : text)
            }
        }
    }
}
