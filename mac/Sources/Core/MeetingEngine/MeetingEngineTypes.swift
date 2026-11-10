import Foundation

/// 会议引擎接口的共用值类型（docs/meeting/ENGINE.md §4.2）：句子、说话人、电平、「这次怎么跑的」。
/// 会议（`Modules/Meeting/`）与字幕与同传的引擎（`Modules/LiveTranslate/`）都用这一份，谁也不用认识对方的类型。
///
/// **纯 Foundation**：不引用 `L()`、App / 模块类型、单例，单元测试（BaoboxTests）可以直接编这个目录。

/// 一句（取代 `LiveTranslateSessionConfig.FinalLine`）。
struct MeetingEngineLine: Equatable {
    /// 本场里唯一（改设置重启后句子 id 从头编，键里带着第几次运行：`"\(run)-\(id)"`）。
    let key: String
    /// 这句第一次出字的时刻。
    let time: Date
    /// 显示用的原文（有 AI 纠错就是纠正后的），去掉首尾空白，不会是空的。
    let original: String
    /// 空 = 没翻（字幕关着、不翻译、或这句本来就是「译成」的语言）。
    let translation: String
    /// 线上会议按两路音量判的说话人；判不准或不标说话人时为 nil。
    let speaker: MeetingSpeaker?
}

/// 这次怎么跑的（取代 `LiveTranslateTranscript.Config`）：文档开头的「音源」「说 … 译成 …」与「改为：…」那行。都已本地化。
struct MeetingEngineRun: Equatable {
    /// 「麦克风」「系统声音」「麦克风 + 系统声音」。
    var source: String
    /// 「English」「自动（简体中文 / English）」。
    var speech: String
    /// 译成什么；nil = 这次不翻译。
    var target: String?
}

/// 说话人：「我」= 麦克风，「对方」= 系统声音（取代 `LiveTranslateSpeaker`，rawValue 不变）。判法（近似）在引擎里：一句期间有人声
/// （RMS > 0.01）累计 ≥ 0.3 秒算显著，系统声音显著且 ≥ 麦克风的 35% → 对方；否则麦克风显著 → 我；都弱 → nil（docs/meeting/TECH_DESIGN.md §9）。
enum MeetingSpeaker: String, Codable, Equatable {
    case me
    case them
}

/// 两路电平（0…1 的 RMS 峰值；取代 `LiveTranslateInputLevels`）；nil = 没有这一路（线下会议没有系统声音）。
/// 会议每 0.25 秒取一次，自己按 0.006 判亮灭（比判「有人在说话」的 0.01 低一点）。
struct MeetingInputLevels: Equatable {
    var microphone: Float?
    var system: Float?
}
