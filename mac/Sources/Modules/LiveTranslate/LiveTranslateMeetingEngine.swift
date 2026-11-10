import Foundation

/// 会议的引擎（docs/meeting/ENGINE.md §4.4）：字幕与同传的 `LiveTranslateController` 包一层，实现 Core 的 `MeetingEngine`。
/// 会议只认协议；会议专属的规则（沿用「字幕与同传」的说话语言、译成与纠错，字幕关着只转录，只转录时也纠错）都在这里。
/// 装配在 `AppDelegate.meetingEngine`：整个 App 只有那里同时认识会议和字幕与同传。
///
/// 不让控制器直接实现协议：它还管自由听译与字幕条，接口形状也不同（配置结构体 + 闭包）；包一层不动它的逻辑。
/// 事件一律在控制器的回调里同步转发，不包 `Task`、不隔一拍：退出时剩下的句子与 `.ended` 要在 `terminate()` 返回前
/// 到达托管方（ENGINE.md §4.3 I5），其余的顺序约定也就原样是控制器的。
@MainActor
final class LiveTranslateMeetingEngine: MeetingEngine {
    private let controller: LiveTranslateController

    init(controller: LiveTranslateController) {
        self.controller = controller
    }

    // MARK: - 托管会话（线上 / 线下会议）

    func start(host: MeetingEngineHost) -> Bool {
        controller.start(config: sessionConfig(for: host.engineConfig, host: host))
    }

    func setPaused(_ paused: Bool) {
        controller.setPaused(paused)
    }

    func setMuted(_ muted: Bool, lane: MeetingAudioLane) {
        controller.setLaneMuted(muted, lane: lane.mixerLane)
    }

    /// 显示时译不译：字幕与同传此刻的翻译开关。
    func setSubtitles(_ visible: Bool) {
        controller.setBarVisible(visible, translate: LiveTranslateSettings.translateEnabled)
    }

    func showNotice(_ text: String) {
        controller.showNotice(text)
    }

    var currentText: String? {
        controller.lines.last?.original
    }

    func takeInputLevels() -> MeetingInputLevels? {
        controller.takeInputLevels()
    }

    func finish() {
        let controller = self.controller
        Task { await controller.finish() }
    }

    // MARK: - 自由听译

    /// 托管会话（正在开始的也算）→ `.hosted`；否则在跑的就是自由听译（正在开始的不算）。
    var activity: MeetingEngineActivity {
        if controller.isHostedSession {
            return .hosted(subtitlesVisible: controller.barVisible)
        }
        return controller.isRunning ? .freeListening : .idle
    }

    /// 托管会话中由控制器转成 `.userAction(.freeListeningTogglePressed)` 报给托管方。
    func toggleFreeListening() {
        controller.toggle()
    }

    // MARK: - 退出

    func terminate() {
        controller.terminate()
    }

    // MARK: - 会话配置

    /// 会议的一场在字幕与同传这边怎么跑。语言、译成、纠错沿用「字幕与同传」的设置；默认只转录原文、不翻译、
    /// 不出字幕条，字幕打开后叠加字幕条与译文（同实时翻译）；纠错与翻译解耦（`.always`：只转录时也纠）。
    /// 文档不交给引擎（会议自己写），只告诉它标不标说话人、字幕条上「打开本次记录」打开哪个文件。
    private func sessionConfig(for meeting: MeetingEngineConfig, host: MeetingEngineHost?) -> LiveTranslateSessionConfig {
        var config = LiveTranslateSessionConfig(
            owner: meeting.owner,
            label: meeting.label,
            sources: meeting.capture == .microphoneAndSystem ? .mixed : .microphone,
            speech: SpeechSettings.speech,
            target: LiveTranslateSettings.target,
            translate: meeting.subtitles && LiveTranslateSettings.translateEnabled,
            showsBar: meeting.subtitles,
            correction: LiveTranslateSettings.aiCorrection ? .always : .off)
        // 线下会议也走混音链路：电平、暂停都靠它。
        config.usesMixer = true
        config.speakers = meeting.speakers
        config.documentURL = meeting.documentURL
        config.onFinalLine = { [weak host] line in
            host?.meetingEngine(didReport: .line(line))
        }
        config.onLifecycle = { [weak host] lifecycle in
            host?.meetingEngine(didReport: MeetingEngineEvent(lifecycle))
        }
        config.onUserRequest = { [weak host] request in
            host?.meetingEngine(didReport: .userAction(MeetingEngineUserAction(request)))
        }
        // 改设置引起的重启：按托管方此刻的配置再翻一遍。不能落回 `.fromSettings()` —— 那样会议中途变成自由听译，
        // 托管方再也收不到事件，会议卡在「记录中」。强引用 self：适配器和控制器都是常驻单例，这个环无害。
        config.rebuild = { [weak host] in
            self.sessionConfig(for: host?.engineConfig ?? meeting, host: host)
        }
        return config
    }
}

private extension MeetingAudioLane {
    /// 混音器内部的下标。
    var mixerLane: Int {
        switch self {
        case .microphone: return LiveTranslateMixerCore.microphoneLane
        case .system: return LiveTranslateMixerCore.systemLane
        }
    }
}

private extension MeetingEngineEvent {
    init(_ lifecycle: LiveTranslateSessionConfig.Lifecycle) {
        switch lifecycle {
        case .started(let run): self = .started(run)
        case .ended: self = .ended
        }
    }
}

private extension MeetingEngineUserAction {
    init(_ request: LiveTranslateSessionConfig.UserRequest) {
        switch request {
        case .closeBar: self = .subtitleBarClosed
        case .toggleRecording: self = .recordButtonPressed
        case .toggle: self = .freeListeningTogglePressed
        }
    }
}
