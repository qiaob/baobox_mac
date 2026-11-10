import Foundation

/// 一次实时翻译会话怎么开（docs/meeting/TECH_DESIGN.md §2.1）：实时翻译（自由听译）与会议记录共用一个引擎，
/// 区别都在这里。`LiveTranslateController.start()` 等价于 `start(config: .fromSettings())` —— 读的仍是原来那些
/// `livetranslate.*` 设置，行为与改造前一样；会议记录由 `MeetingSessionController` 组一份自己的。
struct LiveTranslateSessionConfig {
    /// 音源。`.microphone` / `.system` 是实时翻译原来的两种；`.mixed` = 麦克风 + 系统声音混成一路（线上会议）。
    enum Sources: Equatable {
        case microphone
        case system
        case mixed

        init(_ source: LiveTranslateSource) {
            switch source {
            case .microphone: self = .microphone
            case .system: self = .system
            }
        }

        var usesMicrophone: Bool { self != .system }
        var usesSystemAudio: Bool { self != .microphone }

        /// 记录文件头里的「音源：…」。
        var title: String {
            switch self {
            case .microphone: return LiveTranslateSource.microphone.title
            case .system: return LiveTranslateSource.system.title
            case .mixed: return L("livetranslate.source.mixed")
            }
        }
    }

    /// AI 纠正识别错字什么时候开（还要纠错模型已下载；只纠中文单元）。
    enum Correction: Equatable {
        case off
        /// 只要模型就绪就纠，与翻译无关（会议：只转录原文时也纠）。
        case always
        /// 只在这次真的在翻译时纠（实时翻译原来的行为：「纠错跟着翻译走」）。
        case whenTranslating
    }

    /// 会话的开始与结束（改设置引起的重启不算结束，只会再报一次 `.started`）。
    enum Lifecycle {
        case started
        case ended
    }

    /// 托管会话（会议）里用户在实时翻译的入口上做的操作，交给托管方处理。
    enum UserRequest {
        /// 字幕条右上角的 ✕（会议：收起字幕，会议照常记录）。
        case closeBar
        /// 字幕条上的「记录」按钮（会议：暂停 / 继续记录，与控制条同步）。
        case toggleRecording
        /// 实时翻译的开 / 关（菜单、`livetranslate.toggle` 快捷键；会议：打开 / 收起字幕）。
        case toggle
    }

    /// 占用登记（`AudioCaptureCoordinator`）用：`livetranslate` /「实时翻译」，`meeting` /「会议记录」。
    /// 同时也是占用冲突时那条宠物提示的通知来源。
    var owner: String
    var label: String
    var sources: Sources
    /// 走混音链路采集（两路各转 16 kHz 单声道，能读电平、按两路能量判说话人）：会议总是 true（线下会议也要麦克风电平）；
    /// 实时翻译 false —— 沿用原来的单路音源，一行不改。`.mixed` 总是走混音链路。
    var usesMixer = false
    var speech: LiveTranslateSpeech
    var target: TranslationLanguage
    var translate: Bool
    /// 显示字幕条。系统翻译的会话挂在字幕条视图上，不显示字幕条时只能用离线模型翻（或不翻）。
    /// 运行中用 `LiveTranslateController.setBarVisible(_:translate:)` 切换。
    var showsBar: Bool
    var correction: Correction
    /// 转录去向：nil = 实时翻译原来的行为（按「保存记录」开关，写进会议库的自由听译）；给定 = 这次一定记，写到这里。
    var transcript: LiveTranslateTranscript.Destination?
    /// 一句定稿（含之后纠错 / 译文回来的更新，同一句 `key` 不变）。
    var onFinalLine: ((MeetingEngineLine) -> Void)?

    /// 整份配置跟着 `livetranslate.*` 设置走（实时翻译）：运行中改设置时按设置重来，字幕条上能换音源。
    var followsSettings = false
    /// 运行中改了设置（语言、译成、朗读…）要重建识别链路时，用它组新的一份；nil = `.fromSettings()`。
    var rebuild: (() -> LiveTranslateSessionConfig)?
    var onLifecycle: ((Lifecycle) -> Void)?
    /// nil = 实时翻译原来的行为（✕ 停止、记录按钮开关保存记录、开关就是开 / 停）。
    var onUserRequest: ((UserRequest) -> Void)?

    init(owner: String, label: String, sources: Sources, speech: LiveTranslateSpeech, target: TranslationLanguage,
         translate: Bool, showsBar: Bool, correction: Correction,
         transcript: LiveTranslateTranscript.Destination? = nil) {
        self.owner = owner
        self.label = label
        self.sources = sources
        self.speech = speech
        self.target = target
        self.translate = translate
        self.showsBar = showsBar
        self.correction = correction
        self.transcript = transcript
    }

    /// 实时翻译（自由听译）：全部取自原来的设置。
    static func fromSettings() -> LiveTranslateSessionConfig {
        var config = LiveTranslateSessionConfig(
            owner: "livetranslate",
            label: L("livetranslate.name"),
            sources: Sources(LiveTranslateSettings.source),
            speech: LiveTranslateSettings.speech,
            target: LiveTranslateSettings.target,
            translate: LiveTranslateSettings.translateEnabled,
            showsBar: true,
            correction: LiveTranslateSettings.aiCorrection ? .whenTranslating : .off
        )
        config.followsSettings = true
        return config
    }
}
