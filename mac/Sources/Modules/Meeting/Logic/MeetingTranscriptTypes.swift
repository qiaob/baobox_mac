import Foundation

// 会议文档（meeting.md，MeetingTranscript 写）的描述、说明行，以及报给会议库的进度与纪要结果（docs/meeting/ENGINE.md §4.8、§5.2）。
// 本文件只依赖 Foundation，可脱离 App 单独编译测试。

/// 纪要怎么样了（给会议库更新状态）。
enum MeetingMinutesOutcome: Equatable {
    /// 没开纪要。
    case off
    case generating
    case done(String)
    case failed(String)
    case noModel
    case tooShort
    /// App 退出了，没整理完。
    case interrupted
}

enum MeetingTranscriptEvent: Equatable {
    /// 记下了第一句（或第一笔速记）：文件马上就要建起来了。
    case created
    /// 停止：结束时间、纪要怎么处理；`terminating` = App 正在退出（调用方要同步写完）。
    case finished(end: Date, minutes: MeetingMinutesOutcome, terminating: Bool)
    /// 纪要整理完 / 失败 / 没整理完（只在 `.finished` 报了 `.generating` 之后）。
    case minutes(MeetingMinutesOutcome)
}

/// 会议文档里的一行说明（`*10:32:05 暂停记录*`）。会话只说是哪种，文案由文档自己出（`MeetingTranscriptModel.Labels`）。
enum MeetingTranscriptNote: Equatable, CaseIterable {
    case paused
    case resumed
    /// 不录你的声音（控制条上点了麦克风图标）。
    case microphoneMuted
    case microphoneUnmuted
    /// 不录对方的声音（控制条上点了喇叭图标，只有线上会议有）。
    case systemMuted
    case systemUnmuted
}

/// 一份 meeting.md 写成什么样（docs/meeting/TECH_DESIGN.md §2.3）：写到哪、文件头、版式、纪要怎么整理。
/// 会议在开始时组好（`MeetingSessionController`），自由听译在会议库开记录时组好（`MeetingStore`）。
struct MeetingTranscriptSpec: Equatable {
    /// 会议的文件头；nil（自由听译）= 实时翻译原来的版式。
    struct Header: Equatable {
        var title: String
        /// 「线上会议」「线下会议」（已本地化）。
        var kind: String
        var start: Date
        var attendees: [String] = []
        /// 绑定的日历事件来自哪个日历。
        var calendar: String?
    }

    /// 记录文件（整份重写）。
    var fileURL: URL
    /// 「纪要已整理好」通知里提到的名字。
    var displayName: String
    var header: Header?
    /// 每句标说话人（线上会议）。
    var speakers = false
    var template: MeetingMinutesTemplate = .content
    /// 停止后整理纪要：会议总是整理；自由听译按开记录时、收尾时「停止后整理纪要」开关的值（引擎交进来，`FreeListeningRecord`）。
    var summarizes = true
    /// 纪要整理好后发「实时翻译纪要已整理好」（自由听译原来的行为）；会议自己发。
    var notifiesMinutes = true

    init(fileURL: URL, displayName: String, header: Header? = nil) {
        self.fileURL = fileURL
        self.displayName = displayName
        self.header = header
    }
}

extension MeetingStatus {
    /// 纪要的结果 → 会议库里的状态。
    static func after(_ outcome: MeetingMinutesOutcome) -> MeetingStatus {
        switch outcome {
        case .generating: return .summarizing
        case .done: return .summarized
        case .failed: return .failed
        case .off, .noModel, .tooShort, .interrupted: return .transcribed
        }
    }
}
