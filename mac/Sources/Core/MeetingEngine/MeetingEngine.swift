import Foundation

/// 会议引擎接口（docs/meeting/ENGINE.md §4.1–§4.3）：会议（`Modules/Meeting/`）只认这一份，不认识字幕与同传的类型。
/// 实现是 `LiveTranslateMeetingEngine`（字幕与同传的引擎包一层），装配在 `AppDelegate.meetingEngine`。
///
/// **纯 Foundation**：同目录的约定（见 MeetingEngineTypes.swift）。

/// 托管方（会议会话）：引擎从它取配置、向它报事件。引擎只弱引用它。
@MainActor
protocol MeetingEngineHost: AnyObject {
    /// 此刻的会话配置。开始时取一次；运行中改了引擎自己的设置（说话语言、译成、朗读…）、要重建识别链路时再取一次 ——
    /// 这时托管方会再收到一次带着新 `run` 的 `.started`（I9）。
    var engineConfig: MeetingEngineConfig { get }
    /// 引擎的事件。一律在主线程、按发生顺序报；可能在托管方调引擎方法的过程中同步报回来（I8）。
    func meetingEngine(didReport event: MeetingEngineEvent)
}

/// 会议记录要的「把会上的声音变成一句句文字」。只出句子，不写文件、不碰纪要。实现：LiveTranslateMeetingEngine。
///
/// 线程与事件的约定（ENGINE.md §4.3）。实现必须守，托管方可以依赖：
/// - I1 协议方法只在主线程调，事件只在主线程报。
/// - I2 `start(host:)` 返回 true 之后才（异步）报 `.started` 或 `.ended`；返回 false 什么都不报。
///   托管方在 `start` 返回后才挂勿扰、开控制条，同步报 `.ended` 会让它们留在那儿。
/// - I3 一场里 `.started` 零到多次（改设置引起的重启会再报），`.ended` 恰好一次。
/// - I4 这一场的 `.line` 全部报完才报 `.ended`（含停止时没定稿、强制记下的最后几句），中间不让出主线程；
///   `.ended` 之后不再有 `.line`。托管方在 `.ended` 里收尾文档 —— 这就是「收尾冲刷」在接口上的全部要求。
/// - I5 `terminate()` 返回前把剩下的 `.line` 和 `.ended` 同步报完；转发不能隔一拍（不能包 `Task` / `DispatchQueue.main.async`）。
/// - I6 同一 `key` 的 `.line` 可能报多次（纠错、译文回来），后到的覆盖先到的。
/// - I7 `.userAction` 只在托管会话运行中报。
/// - I8 重入：事件可能在托管方调引擎方法的过程中同步到达（`terminate`、`toggleFreeListening`、`finish` 里的停止）。
/// - I9 改设置重启：引擎重新取 `host.engineConfig`，带新的 `run` 再报 `.started`；句子键带运行次数、不撞；
///   暂停 / 单路不录的状态保留。
/// - I10 第一个 `.started` 之前可能已经报过 `.line`：`.started` 等音源全开好才报，这期间先开的那一路（麦克风）就可能出字定稿。
@MainActor
protocol MeetingEngine: AnyObject {
    // MARK: 托管会话（线上 / 线下会议）

    /// 开一场。false = 没开：别的会话还在 / 正在开，或麦克风被听写等占着（引擎已经发过「正在 XX，先停止再开始」）。
    /// true 之后一定**异步**报 `.started` 或 `.ended`（权限被拒、识别不可用、音源打不开），不在这个调用里报（I2）。
    func start(host: MeetingEngineHost) -> Bool
    /// 暂停 / 继续：暂停 = 不往识别器送音频，会话不停（手头那句照常定稿）。开始中也收，开起来时生效；跨改设置的重启保留。
    func setPaused(_ paused: Bool)
    /// 单独不录某一路：这一路换成等长静音送进去（两路仍对齐），另一路照录，电平随之为 0。开始中也收；跨重启保留。
    func setMuted(_ muted: Bool, lane: MeetingAudioLane)
    /// 字幕条显示 / 收起；显示时译不译按引擎自己的翻译开关。没在运行时不做 —— 托管方在第一次 `.started` 时再设一次。
    func setSubtitles(_ visible: Bool)
    /// 在字幕条上显示一行提示（会议的文档写盘失败时用）。字幕条没显示就看不到。
    func showNotice(_ text: String)
    /// 屏幕上最新那句的原文（没定稿的也算）；没有为 nil。🔖 记「标记时在说什么」用。
    var currentText: String? { get }
    /// 两路电平：上次取走以来每路的最大 RMS（0…1），取一次清一次；暂停中为 0；没在托管会话里为 nil。
    func takeInputLevels() -> MeetingInputLevels?
    /// 结束：先停音频，等最后一句定稿（最多 1.5 秒）再停。不用等它返回：最后几句的 `.line` 报完才报 `.ended`（I4）。没在运行时不做。
    func finish()

    // MARK: 自由听译（引擎自己的会话；入口在会议里，#106）

    /// 此刻在跑什么：会议菜单、`livetranslate.toggle` 在环形菜单里的标题、状态行用。
    var activity: MeetingEngineActivity { get }
    /// 「开始自由听译」开关：没在跑 → 按引擎自己的设置开一次（记录经 FreeListeningLibrary 进会议库）；自由听译中 → 停；
    /// 托管会话中 → 报 `.userAction(.freeListeningTogglePressed)`，由托管方决定（会议：切字幕）。
    func toggleFreeListening()

    // MARK: 退出

    /// App 退出：停下来。托管会话剩下的 `.line` 和 `.ended` 在返回前同步报完（I5）；自由听译的记录同步写完。可以重复调用。
    func terminate()
}

/// 一场托管会话要什么。会议只说「线上还是线下、开不开字幕、标不标说话人」，怎么识别、译不译、纠不纠错由引擎定。
struct MeetingEngineConfig: Equatable {
    enum Capture: Equatable {
        /// 线上会议：麦克风 + 系统声音混成一路进一个识别器。
        case microphoneAndSystem
        /// 线下会议：只有麦克风（照样走混音链路：要电平、暂停也靠它）。
        case microphone
    }

    /// 占用登记（AudioCaptureCoordinator）的 owner，也是占用冲突提示的通知来源：`meeting`。
    var owner: String
    /// 占用冲突时给用户看的名字（已本地化：「会议记录」）。
    var label: String
    var capture: Capture
    /// 字幕条（+ 译文）开着。运行中用 `setSubtitles` 切，重启时按这里重组。
    var subtitles: Bool
    /// 每句判「我 / 对方」（线上会议）。
    var speakers: Bool
    /// 这场的 meeting.md：只给字幕条用 —— 记下第一句后，「记录」按钮旁的小按钮打开它。引擎不写它。
    var documentURL: URL
}

enum MeetingEngineEvent: Equatable {
    /// 开起来了；`run` = 这次怎么跑的（文档头信息、「改为：…」用）。改设置引起的重启会带着新的 `run` 再报一次。
    case started(MeetingEngineRun)
    /// 一句定稿；之后纠错 / 译文回来再报（同一 `key`，后到的覆盖先到的）。停止时没定稿的最后几句也报。
    case line(MeetingEngineLine)
    /// 会话结束（结束、识别出错停了、没开起来），每场恰好一次；这一场的 `.line` 都在它之前报完（I4）。
    case ended
    /// 用户在引擎自己的界面上点的；是什么意思由托管方定。
    case userAction(MeetingEngineUserAction)
}

enum MeetingEngineUserAction: Equatable {
    /// 字幕条右上角的 ✕（会议：收起字幕，照常记录）。
    case subtitleBarClosed
    /// 字幕条上的「记录」按钮（会议：暂停 / 继续，与控制条同步）。
    case recordButtonPressed
    /// 「开始自由听译」开关（菜单、快捷键、环形菜单）在托管会话中被按下（会议：打开 / 收起字幕）。
    case freeListeningTogglePressed
}

enum MeetingEngineActivity: Equatable {
    case idle
    /// 自由听译在跑（正在开始的不算）。
    case freeListening
    /// 托管会话正在开始或在跑；`subtitlesVisible` = 字幕条此刻真的显示着。
    case hosted(subtitlesVisible: Bool)
}

enum MeetingAudioLane: Equatable, CaseIterable {
    /// 你的声音。
    case microphone
    /// 对方的声音（只有线上会议有）。
    case system
}
