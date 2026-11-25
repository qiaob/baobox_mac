import AppKit

/// 会议给快速入口的文字动作「入会并开始会议记录」（docs/launcher/TECH_DESIGN.md §5.4，第 10 步）：只在输入是一个
/// `MeetingLinkParser` 认得的会议链接时适用（Zoom、腾讯会议、钉钉、Google Meet、Teams、飞书、Webex；`appliesTo`），
/// 紧跟在「打开 <网址>」后面（`leading`）。执行 = 现有的「一键入会 + 开始线上会议」：
/// - 日历上眼下这一场 / 下一场的链接就是它 → `MeetingActions.joinAndRecord(event)`（绑上那一场，同提醒气泡上的「加入并记录」）；
/// - 否则打开链接（会议 App 或浏览器），开始一场不绑日历的线上会议记录（同菜单「开始线上会议记录」）；已经在记就只入会。
/// 写在扩展里，不动 `MeetingTool.swift`。
extension MeetingTool {
    func launcherCommands() -> [LauncherCommand] {
        [
            .textAction(id: "meeting.text.joinAndRecord", title: L("meeting.launcher.joinAndRecordLink"),
                        symbolName: "video", suggestion: LauncherSuggestionTraits(kinds: [.url], priority: 10, leading: true),
                        hint: "会议链接",
                        appliesTo: { MeetingLinkParser.links(in: $0).first != nil }) { text in
                guard let link = MeetingLinkParser.links(in: text).first else { return }
                MeetingActions.joinAndRecord(link: link)
            },
        ]
    }
}

extension MeetingActions {
    /// 打开一个会议链接并开始线上会议记录（快速入口交来的链接，第 10 步）。链接正是日历上眼下这一场 / 下一场的：照日历会议的
    /// 「加入并记录」做（绑上那一场）；不是：打开链接，开始一场不绑日历的线上会议记录，已经在记就只入会。
    static func joinAndRecord(link: MeetingLink) {
        let calendar = MeetingCalendar.shared
        let known = [calendar.bindingCandidate(), calendar.next()].compactMap { $0 }
            .first { $0.link?.url.absoluteString == link.url.absoluteString }
        if let event = known {
            joinAndRecord(event)
            return
        }
        if !NSWorkspace.shared.open(link.url) {
            NotifyCenter.shared.post(Notice(source: MeetingSessionController.source, level: .ambient,
                                            title: L("meeting.toast.cannotOpenLink"), icon: "calendar"))
        }
        let session = MeetingSessionController.shared
        guard !session.isActive else { return }
        session.start(type: .online)
    }
}
