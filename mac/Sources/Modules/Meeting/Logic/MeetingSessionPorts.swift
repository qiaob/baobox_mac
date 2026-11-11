import Foundation

// 会话（`MeetingSessionController`，纯逻辑）碰到的外面的东西，拆成三个端口（docs/meeting/ENGINE.md §5.2）：
// 会议库、本场的 meeting.md、App 环境。App 里的实现是 MeetingStore、MeetingTranscript、MeetingSessionShell；
// 测试里是假的（mac/Tests/Meeting/）。引擎另有自己的协议（Core/MeetingEngine/MeetingEngine.swift）。
// 本文件只依赖 Foundation，可脱离 App 单独编译测试。

/// 会话要会议库做的几件事（MeetingStore 实现，签名与它的方法一致）。
@MainActor
protocol MeetingSessionLibrary: AnyObject {
    /// 会议库根目录（会话空闲时 `engineConfig.documentURL` 的兜底，引擎这时不会来取）。
    var rootURL: URL { get }
    /// 新开一场：分目录、写 meta.json（状态「记录中」）、进索引。
    func createMeeting(type: MeetingType, title: String, start: Date, event: MeetingEventInfo?,
                       template: String) -> MeetingRecord
    /// 这场的 meeting.md。
    func markdownURL(for record: MeetingRecord) -> URL
    func record(_ id: String) -> MeetingRecord?
    /// 改一条的元信息；`sync` = App 正在退出，写完再返回。
    func update(_ id: String, sync: Bool, _ change: (inout MeetingMeta) -> Void)
    /// 这一场写完了（转录收尾、纪要也处理完）。
    func finishWriting(_ id: String)
    /// 作废一场什么也没记下的会议。
    func discard(_ id: String)
    /// 等排着的写盘做完（App 退出前）。
    func flush()
    /// 这场的 meeting.md（App 里是 MeetingTranscript，测试里是假的）：第一次开起来时建，`start` = 那一刻，`run` = 这次怎么跑的。
    func makeTranscript(_ spec: MeetingTranscriptSpec, start: Date, run: MeetingEngineRun) -> MeetingTranscriptWriting
}

/// 一场会议的 meeting.md（docs/meeting/ENGINE.md §4.5.2）。
@MainActor
protocol MeetingTranscriptWriting: AnyObject {
    /// 第一笔内容（created）、收尾（finished，在 `finish` 里同步回调）、纪要结果（minutes，之后异步）。
    var onEvent: ((MeetingTranscriptEvent) -> Void)? { get set }
    /// 写盘失败回调一次，参数是给用户看的一行提示（已本地化）。
    var onWriteError: ((String) -> Void)? { get set }
    /// 记下 / 更新一句（同一 `key` 后到的覆盖先到的）。
    func update(_ line: MeetingEngineLine)
    /// 🔖 标记重点。
    func mark(at time: Date)
    /// 一行说明（暂停 / 继续、单路静音）。
    func note(_ note: MeetingTranscriptNote, at time: Date)
    /// 速记（整份替换）。
    func setNotes(_ text: String)
    /// 改设置后的重启接着写：设置真变了才记一行「改为：…」。
    func continueWith(_ run: MeetingEngineRun, at time: Date)
    /// 收尾：决定纪要怎么处理，同步报 `.finished`；`terminating` = App 退出：同步写完、纪要标「没整理完」。
    func finish(at time: Date, terminating: Bool)
}

/// 控制条要怎么变（MeetingSessionEnvironment.controlBar）。
enum MeetingControlBarChange: Equatable {
    case show
    case hide
    /// 内容变了（开始 / 记录中 / 暂停 / 收尾、速记展开收起、字幕开关、标记数）：按新内容重量大小。
    case refreshSize
    /// 速记区展开（控制条能接收键盘输入）/ 收起（交还焦点）。
    case notesExpanded(Bool)
}

/// 会话发的一行轻提示（宠物 toast，alert 级：记录中挂着会议自己的勿扰，普通提示会被攒起来）。
enum MeetingSessionToast: Equatable {
    /// 「正在记录会议」：记录中又点了开始。
    case alreadyRecording
    /// 麦克风被自由听译 / 听写占着（文案由占用登记给，已本地化）。
    case busy(String)
    /// 「已超过预定结束时间 5 分钟」。
    case overtime
    /// 「这次什么也没记下，没有保存」：晚一拍发（结束时转录收尾在撤勿扰之前）。
    case nothingRecorded
}

/// 会话碰到的 App 侧的东西（控制条、菜单栏项、Timer、勿扰、宠物通知、合规对话框、日历、设置、文案）。
/// App 里的实现是 MeetingSessionShell；调用顺序就是会话里原来内联的顺序（docs/meeting/ENGINE.md §7.1 R16）。
@MainActor
protocol MeetingSessionEnvironment: AnyObject {
    func now() -> Date

    // MARK: 开始前

    /// 麦克风被自由听译 / 听写占着时的提示（AudioCaptureCoordinator）；没占着为 nil。
    func captureBusyMessage() -> String?
    /// 合规说明：确认过就直接 true，否则弹对话框问（取消为 false）。
    func confirmConsent() -> Bool
    /// 手动开始线上会议时自动绑的日历事件（正在进行或 5 分钟内开始的）；没读日历或没有为 nil。
    func calendarBindingCandidate() -> MeetingEventInfo?
    /// 手动开始时的默认类型（设置里选）。
    var defaultType: MeetingType { get }
    /// 会议纪要模板（设置里选）。
    var minutesStyle: MeetingMinutesStyle { get }
    /// 占用冲突时给用户看的名字（「会议记录」，已本地化）。
    var captureLabel: String { get }
    /// 「线上会议」「线下会议」（已本地化）：没绑日历时的标题、文件头的类型。
    func typeName(_ type: MeetingType) -> String

    // MARK: 会中 / 会后

    /// 记录中挂 / 撤 `meeting` 勿扰（宠物安静、非重要通知攒批、专注与健康的提醒顺延）。
    func setDoNotDisturb(_ on: Bool)
    /// 心跳：0.25 秒一次回调会话的 `tick()`（电平点、录音指示、超时）；false = 停。
    func setHeartbeat(_ running: Bool)
    func controlBar(_ change: MeetingControlBarChange)
    /// 菜单栏的录音指示「● 32:15」（按会话此刻的状态；空闲时收起）。
    func refreshIndicators()
    func toast(_ toast: MeetingSessionToast)
    /// 纪要好了 / 没整理成 / 只存了转录：宠物通知（晚一拍发，等会议自己的勿扰撤掉），[打开] 打开这场的记录。
    func notifySaved(_ record: MeetingRecord, outcome: MeetingMinutesOutcome)
}
