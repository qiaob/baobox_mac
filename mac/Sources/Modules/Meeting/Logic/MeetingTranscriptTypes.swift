import Foundation

// 会议文档（meeting.md，MeetingTranscript 写）报给会议库的进度与纪要结果（docs/meeting/ENGINE.md §4.8）。
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

enum MeetingTranscriptEvent {
    /// 记下了第一句（或第一笔速记）：文件马上就要建起来了。
    case created
    /// 停止：结束时间、纪要怎么处理；`terminating` = App 正在退出（调用方要同步写完）。
    case finished(end: Date, minutes: MeetingMinutesOutcome, terminating: Bool)
    /// 纪要整理完 / 失败 / 没整理完（只在 `.finished` 报了 `.generating` 之后）。
    case minutes(MeetingMinutesOutcome)
}
