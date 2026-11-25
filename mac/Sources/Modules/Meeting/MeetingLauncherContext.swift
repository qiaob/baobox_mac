import Foundation

/// 快速入口空着时的情景建议（docs/launcher/TECH_DESIGN.md §5.6）。只读内存：会话状态、日历缓存（`MeetingCalendar.events`，
/// 日历没在设置里打开 / 没授权时 `next()` 是 nil，就没有下面两条）。
/// - 会议记录进行中 →「结束会议」：「开始 / 结束线上会议记录」那个快捷键动作此刻的 `stateTitle`，同 id（`meeting.startOnline`）、
///   同动作（记录中按下 = 结束并生成纪要）。正在收尾时不出（那时按了也没用）。
/// - 下一场会议 10 分钟内开始、或已经开始了（`next()` 认开始不到 15 分钟的），而且没在记这一场 →
///   「入会 · <标题>」（有会议链接时；同「加入下一场会议」，id `meeting.join`）、
///   「开始会议记录 · <标题>」（没在记录别的会时；同提醒气泡的 [开始记录]：绑这一场，有链接按线上会议，id 和
///   「开始 / 结束线上会议记录」同一个 `meeting.startOnline`）。
///   「还没入会」读不到（会议 App 有没有在开会只在会议检测里、按进程查麦克风），所以按「没在记这一场」算。
/// 写在扩展里（不动 `MeetingTool.swift`）：协议要求由这里的实现满足。
extension MeetingTool {
    /// 下一场会议开始前多久起提「入会」。
    static let launcherJoinLead: TimeInterval = 10 * 60
    /// 情景建议的次序（小的在前，§5.6 次序表）：会议最急，三条（结束会议 / 入会 / 开始会议记录）都排在最前。
    static let launcherSuggestionPriority = 10

    func launcherContextSuggestions() -> [LauncherCommand] {
        let session = MeetingSessionController.shared
        var commands: [LauncherCommand] = []
        switch session.phase {
        case .starting, .recording, .paused:
            commands += hotkeys().filter { $0.id == "meeting.startOnline" }
                .compactMap { $0.launcherStateCommand(symbolName: "stop.circle", priority: Self.launcherSuggestionPriority) }
        case .idle, .finishing:
            break
        }

        let now = Date()
        guard let next = MeetingCalendar.shared.next(at: now),
              next.info.start.timeIntervalSince(now) <= Self.launcherJoinLead else { return commands }
        if let current = session.event, session.isActive,
           current.eventID == next.info.eventID, current.start == next.info.start {
            return commands
        }
        let title = next.info.title
        let priority = LauncherSuggestionTraits(priority: Self.launcherSuggestionPriority)
        if next.link != nil {
            commands.append(LauncherCommand(id: "meeting.join", title: L("meeting.launcher.join \(title)"),
                                            symbolName: "video", suggestion: priority) { _ in
                MeetingActions.join(next)
            })
        }
        if !session.isActive {
            commands.append(LauncherCommand(id: "meeting.startOnline", title: L("meeting.launcher.record \(title)"),
                                            symbolName: "record.circle", suggestion: priority) { _ in
                MeetingActions.record(next)
            })
        }
        return commands
    }
}
