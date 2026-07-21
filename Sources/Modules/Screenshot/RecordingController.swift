import AppKit
import AVFoundation
import ScreenCaptureKit

/// 屏幕录制：SCStream → AVAssetWriter，输出 H.264 MP4（当前不含音频）。
/// 选区来自截图 overlay（录制模式），全屏 / 框选 / 点选窗口三种入口共用。
@MainActor
final class RecordingController: NSObject {
    static let shared = RecordingController()

    private(set) var isRecording = false
    private(set) var isPaused = false

    private var stream: SCStream?
    private var sink: RecordingSink?
    private var writer: AVAssetWriter?
    private var outputURL: URL?
    private var hud: RecordingHUD?
    private var border: RecordingBorderWindow?
    private var micCapture: MicrophoneCapture?

    private override init() {
        super.init()
    }

    // MARK: - 开始

    /// rectAK 为 AK 全局坐标；与屏幕 frame 相等视为全屏（不裁剪 sourceRect）。
    func start(rectAK: NSRect, on screen: NSScreen) async throws {
        guard !isRecording else { return }
        guard let displayID = screen.displayID else { throw CaptureError.targetNotFound }

        // H.264 要求偶数尺寸。
        let scale = screen.backingScaleFactor
        let pixelW = (Int(rectAK.width * scale) / 2) * 2
        let pixelH = (Int(rectAK.height * scale) / 2) * 2
        guard pixelW >= 16, pixelH >= 16 else { throw CaptureError.cropFailed }

        // GIF 输出没有声音，两路音频直接跳过（设置本身不动）。
        let isGIF = ScreenshotSettings.recordFormat == .gif

        // 麦克风权限先行确认（可能弹系统授权窗）；被拒时降级为无麦克风继续录。
        var captureMic = !isGIF && ScreenshotSettings.recordMicrophone
        if captureMic {
            captureMic = await ensureMicrophonePermission()
        }

        // 边框与控制条必须先上屏：随后枚举共享内容才能拿到它们的 SCWindow 并从画面中剔除。
        let border = RecordingBorderWindow(rectAK: rectAK)
        self.border = border
        border.orderFrontRegardless()

        let hud = RecordingHUD(rectAK: rectAK, on: screen,
                               onStop: { [weak self] in self?.stopFromUser() },
                               onCancel: { [weak self] in self?.cancelFromUser() },
                               onPauseToggle: { [weak self] in self?.togglePause() })
        self.hud = hud
        hud.orderFrontRegardless()

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.targetNotFound
            }
            let ownIDs: Set<CGWindowID> = [CGWindowID(hud.windowNumber), CGWindowID(border.windowNumber)]
            let excluded = content.windows.filter { ownIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)

            let config = SCStreamConfiguration()
            config.width = pixelW
            config.height = pixelH
            if !rectAK.equalTo(screen.frame) {
                // sourceRect：该显示器本地坐标、原点左上、单位 pt。
                config.sourceRect = CGRect(x: rectAK.minX - screen.frame.minX,
                                           y: screen.frame.maxY - rectAK.maxY,
                                           width: rectAK.width, height: rectAK.height)
            }
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.queueDepth = 6

            // 系统声音：SCK 直接采集，屏幕录制权限已覆盖，无需额外授权。
            let captureAudio = !isGIF && ScreenshotSettings.recordSystemAudio
            if captureAudio {
                config.capturesAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                config.excludesCurrentProcessAudio = true
            }

            let url = try makeOutputURL()
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: pixelW,
                AVVideoHeightKey: pixelH
            ])
            videoInput.expectsMediaDataInRealTime = true
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if captureAudio {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000
                ])
                audio.expectsMediaDataInRealTime = true
                writer.add(audio)
                audioInput = audio
            }

            // 麦克风独立成第二条音轨（不与系统声音混音）。
            var micInput: AVAssetWriterInput?
            if captureMic {
                let mic = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 96_000
                ])
                mic.expectsMediaDataInRealTime = true
                writer.add(mic)
                micInput = mic
            }

            guard writer.startWriting() else {
                throw writer.error ?? CaptureError.cropFailed
            }

            let sink = RecordingSink(writer: writer, videoInput: videoInput,
                                     systemAudioInput: audioInput, micInput: micInput)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            if captureAudio {
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            }
            try await stream.startCapture()

            if captureMic {
                // 采集器整不出来（无输入设备等）就静默降级，不阻断录制。
                micCapture = MicrophoneCapture(sink: sink)
                micCapture?.start()
            }

            self.stream = stream
            self.sink = sink
            self.writer = writer
            self.outputURL = url
            isRecording = true
            hud.startTimer()
        } catch {
            closeSessionUI()
            throw error
        }
    }

    // MARK: - 停止

    func stopFromUser() {
        Task { await self.stop() }
    }

    /// 取消：停止采集并丢弃文件，不保存不提示。
    func cancelFromUser() {
        Task { await self.stop(discard: true) }
    }

    /// 暂停/继续：暂停期间丢弃样本，继续时时间轴平移补偿，成片不留空洞。
    func togglePause() {
        guard isRecording, let sink else { return }
        isPaused.toggle()
        sink.setPaused(isPaused)
        hud?.setPaused(isPaused)
    }

    func stop(discard: Bool = false) async {
        guard isRecording, let stream, let sink, let writer, let outputURL else { return }
        isRecording = false
        isPaused = false
        closeSessionUI()

        micCapture?.stop()
        micCapture = nil
        try? await stream.stopCapture()
        let wroteFrames = await sink.finish()

        if !discard, wroteFrames, writer.status == .completed {
            // 后处理（GIF 转换 / 混音）完成后在 Finder 里选中文件。
            let finalURL = await postProcess(outputURL)
            NSWorkspace.shared.activateFileViewerSelecting([finalURL])
        } else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: outputURL)
            if !discard && wroteFrames {
                // 有内容却没写成才值得报错；秒开秒停的空录制静默丢弃即可。
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = L("screenshot.record.error.saveFailed")
                alert.informativeText = writer.error?.localizedDescription ?? ""
                alert.alertStyle = .warning
                alert.runModal()
            }
        }

        self.stream = nil
        self.sink = nil
        self.writer = nil
        self.outputURL = nil
    }

    private func closeSessionUI() {
        hud?.orderOut(nil)
        hud = nil
        border?.orderOut(nil)
        border = nil
    }

    // MARK: - 麦克风权限

    /// 已授权 → true；未询问过 → 弹系统授权窗；被拒 → 引导去系统设置并返回 false（降级录制）。
    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("screenshot.record.mic.deniedTitle")
            alert.informativeText = L("screenshot.record.mic.deniedMessage")
            alert.addButton(withTitle: L("common.goEnable"))
            alert.addButton(withTitle: L("clipboard.paste.gotIt"))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
    }

    /// 停止后的离线处理：GIF 格式 → 转 GIF 删原 MP4（失败回退保留 MP4）；
    /// MP4 且开了混音、双音轨齐备 → 原地混为单轨（失败保留双轨）。
    private func postProcess(_ url: URL) async -> URL {
        if ScreenshotSettings.recordFormat == .gif {
            if let gif = await RecordingExport.exportGIF(from: url) {
                try? FileManager.default.removeItem(at: url)
                return gif
            }
            return url
        }
        if ScreenshotSettings.recordMixAudio {
            _ = await RecordingExport.mixAudioTracks(at: url)
        }
        return url
    }

    // MARK: - 输出路径

    private func makeOutputURL() throws -> URL {
        let dir = ScreenshotSettings.saveDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ScreenshotResultHandler.uniqueURL(in: dir,
                                                 base: ScreenshotSettings.filenameBase(for: Date()),
                                                 ext: "mp4")
    }
}

// MARK: - 流异常回调

extension RecordingController: SCStreamDelegate {
    /// 显示器拔出、系统撤权等导致流中断：收尾已有内容。
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            await self.stop()
        }
    }
}

// MARK: - 写入端（串行队列上消费样本，与主线程无共享可变状态）

/// @unchecked Sendable 依据：全部可变状态只在自持的串行 `queue` 上触达 ——
/// SCK 视频/系统音频回调与麦克风 AVCapture 回调都派发到该队列，
/// setPaused/finish 也把工作投递到同队列。
final class RecordingSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.baobox.app.recording")

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?
    private var sessionStarted = false

    /// 暂停机制：暂停期间丢弃全部样本；继续后首个视频帧计算被跳过的时长并累进 offset，
    /// 之后所有样本（三条轨共用）时间戳统一前移 —— 成片时间轴连续，不留黑段。
    private var paused = false
    private var resumePending = false
    private var offset = CMTime.zero
    private var lastVideoPTS: CMTime?
    private var lastAppended: [Track: CMTime] = [:]
    private let frameDuration = CMTime(value: 1, timescale: 30)

    private enum Track { case video, systemAudio, mic }

    init(writer: AVAssetWriter, videoInput: AVAssetWriterInput,
         systemAudioInput: AVAssetWriterInput?, micInput: AVAssetWriterInput?) {
        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.micInput = micInput
    }

    func setPaused(_ value: Bool) {
        queue.async {
            guard value != self.paused else { return }
            self.paused = value
            if !value { self.resumePending = true }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            append(sampleBuffer, to: systemAudioInput, track: .systemAudio)
        default:
            break
        }
    }

    /// 麦克风样本入口（AVCaptureAudioDataOutput 的 delegate 同样派发到本队列）。
    func appendMicSample(_ sampleBuffer: CMSampleBuffer) {
        append(sampleBuffer, to: micInput, track: .mic)
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }
        // 只写完整帧：闲置/空帧的 attachment status ≠ complete，写进去会得到坏时间轴。
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete else { return }

        if paused { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if resumePending {
            if let last = lastVideoPTS {
                let gap = CMTimeSubtract(CMTimeSubtract(pts, last), frameDuration)
                if gap > .zero { offset = CMTimeAdd(offset, gap) }
            }
            resumePending = false
        }
        if !sessionStarted {
            writer.startSession(atSourceTime: CMTimeSubtract(pts, offset))
            sessionStarted = true
        }
        lastVideoPTS = pts
        appendRetimed(sampleBuffer, to: videoInput, track: .video)
    }

    /// 音频通用路径：会话未开 / 暂停中 / 补偿未重算前全部丢弃。
    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?, track: Track) {
        guard let input, sampleBuffer.isValid, sessionStarted, !paused, !resumePending else { return }
        appendRetimed(sampleBuffer, to: input, track: track)
    }

    private func appendRetimed(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput, track: Track) {
        guard input.isReadyForMoreMediaData, let out = retimed(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(out)
        // 每条轨的时间戳必须严格递增，重定时边界样本越界时直接丢弃。
        if let last = lastAppended[track], pts <= last { return }
        if input.append(out) { lastAppended[track] = pts }
    }

    /// 按累计 offset 平移时间戳（offset 为零时原样返回，不做拷贝）。
    private func retimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard offset != .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0,
                                               arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count,
                                               arrayToFill: &infos, entriesNeededOut: &count)
        for i in 0..<count {
            infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, offset)
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, offset)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: count,
                                              sampleTimingArray: &infos,
                                              sampleBufferOut: &out)
        return out
    }

    /// 收尾。返回 false 表示一帧都没写入（此时调用方应取消 writer 并删除空文件）。
    func finish() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.sessionStarted else {
                    continuation.resume(returning: false)
                    return
                }
                self.videoInput.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.micInput?.markAsFinished()
                self.writer.finishWriting {
                    continuation.resume(returning: true)
                }
            }
        }
    }
}

// MARK: - 麦克风采集

/// macOS 14 的 SCK 不支持麦克风，走独立 AVCaptureSession 管线写入第二条音轨。
/// delegate 回调派发到 sink 的串行队列，与 SCK 样本天然串行。
/// @unchecked Sendable 依据：startRunning/stopRunning 线程安全（AVFoundation 保证），
/// 其余状态构造后只读。
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private weak var sink: RecordingSink?

    init?(sink: RecordingSink) {
        self.sink = sink
        super.init()
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sink.queue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
    }

    func start() {
        // startRunning 会阻塞当前线程，放后台。
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sink?.appendMicSample(sampleBuffer)
    }
}

// MARK: - 录制范围边框

/// 圈出正在录制的区域：红色描边、完全穿透鼠标事件；本窗口已从录制画面中剔除，
/// 且描边画在选区外沿，不遮挡录制内容。
@MainActor
private final class RecordingBorderWindow: NSPanel {
    init(rectAK: NSRect) {
        // 窗口比选区大一圈，让 2pt 描边完整落在选区外侧。
        super.init(contentRect: rectAK.insetBy(dx: -3, dy: -3),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        contentView = BorderView()
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            path.lineWidth = 2
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}

// MARK: - 录制控制条

/// 录制中的悬浮控制条：红点 + 计时 + 停止/取消按钮。
/// 定位在选区右下（下方放不下换上方，再不行放选区内部右下角），可拖动；
/// 已从录制画面中剔除。
@MainActor
private final class RecordingHUD: NSPanel {
    private static let size = NSSize(width: 214, height: 34)

    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let dot = NSView(frame: NSRect(x: 14, y: 12, width: 10, height: 10))
    private var pauseButton: NSButton?
    private var timer: Timer?
    private let onStop: () -> Void
    private let onCancel: () -> Void
    private let onPauseToggle: () -> Void

    /// 计时用「累计 + 当前段起点」两段式：暂停时冻结累计，继续时重开一段。
    private var accumulated: TimeInterval = 0
    private var segmentStart = Date()
    private var pausedFlag = false

    init(rectAK: NSRect, on screen: NSScreen,
         onStop: @escaping () -> Void, onCancel: @escaping () -> Void,
         onPauseToggle: @escaping () -> Void) {
        self.onStop = onStop
        self.onCancel = onCancel
        self.onPauseToggle = onPauseToggle
        let origin = Self.placement(for: rectAK, on: screen)
        super.init(contentRect: NSRect(origin: origin, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        content.layer?.cornerRadius = Self.size.height / 2

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        content.addSubview(dot)

        timeLabel.frame = NSRect(x: 32, y: 8, width: 56, height: 18)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textColor = .white
        content.addSubview(timeLabel)

        let pause = Self.makeButton(symbol: "pause.fill", tooltip: L("screenshot.record.hud.pause"),
                                    frame: NSRect(x: 94, y: 5, width: 36, height: 24))
        pause.contentTintColor = .white
        pause.target = self
        pause.action = #selector(pausePressed)
        content.addSubview(pause)
        pauseButton = pause

        let stop = Self.makeButton(symbol: "stop.fill", tooltip: L("screenshot.record.hud.stop"),
                                   frame: NSRect(x: 132, y: 5, width: 36, height: 24))
        stop.contentTintColor = .systemRed
        stop.target = self
        stop.action = #selector(stopPressed)
        content.addSubview(stop)

        let cancel = Self.makeButton(symbol: "xmark", tooltip: L("screenshot.record.hud.cancel"),
                                     frame: NSRect(x: 170, y: 5, width: 36, height: 24))
        cancel.contentTintColor = NSColor(white: 1, alpha: 0.65)
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        content.addSubview(cancel)

        contentView = content
    }

    /// 暂停态 UI：红点变橙、暂停键换成继续键、计时冻结。
    func setPaused(_ paused: Bool) {
        pausedFlag = paused
        if paused {
            accumulated += Date().timeIntervalSince(segmentStart)
        } else {
            segmentStart = Date()
        }
        dot.layer?.backgroundColor = (paused ? NSColor.systemOrange : NSColor.systemRed).cgColor
        let tooltip = paused ? L("screenshot.record.hud.resume") : L("screenshot.record.hud.pause")
        pauseButton?.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                     accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        pauseButton?.toolTip = tooltip
    }

    private static func makeButton(symbol: String, tooltip: String, frame: NSRect) -> NSButton {
        let button = HUDButton(frame: frame)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        button.toolTip = tooltip
        return button
    }

    /// 对齐截图工具条的摆位策略：选区下方右对齐 → 上方 → 选区内部右下角。
    private static func placement(for rect: NSRect, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        var x = rect.maxX - size.width
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)

        var y = rect.minY - size.height - margin
        if y < visible.minY + margin {
            y = rect.maxY + margin
            if y + size.height > visible.maxY - margin {
                // 内部右下角（全屏录制走到这里；控制条已从画面剔除，不会录进去）。
                x = min(rect.maxX, visible.maxX) - size.width - 16
                y = max(rect.minY, visible.minY) + 16
            }
        }
        return NSPoint(x: x, y: y)
    }

    func startTimer() {
        accumulated = 0
        segmentStart = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let elapsed = Int(accumulated + (pausedFlag ? 0 : Date().timeIntervalSince(segmentStart)))
        timeLabel.stringValue = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    @objc private func pausePressed() {
        onPauseToggle()
    }

    @objc private func stopPressed() {
        onStop()
    }

    @objc private func cancelPressed() {
        onCancel()
    }

    override func orderOut(_ sender: Any?) {
        timer?.invalidate()
        timer = nil
        super.orderOut(sender)
    }
}

/// 非激活面板里的按钮需要第一击就响应。
private final class HUDButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
