import AppKit
import SwiftUI

/// 会前简报（需求 §2）：这一场的时间与参会人、同系列上一场的纪要摘要、该系列全部未完成行动项（可勾选）；
/// 按钮 [加入会议][开始记录][打开上次纪要][关闭]。
struct MeetingBriefView: View {
    @ObservedObject var model: MeetingBriefModel
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var session = MeetingSessionController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let event = model.event {
                content(event)
            } else {
                Text("meeting.brief.none")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, idealWidth: 540, minHeight: 440, idealHeight: 560)
    }

    @ViewBuilder
    private func content(_ event: MeetingCalendarEvent) -> some View {
        let briefing = MeetingActions.briefing(for: event)
        VStack(alignment: .leading, spacing: 6) {
            Text("meeting.brief.heading")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: event.info.title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
            Text(verbatim: MeetingText.timeRange(event.info.start, event.info.end) + " · "
                 + MeetingText.relative(event.info.start))
                .foregroundStyle(.secondary)
            if !event.info.attendees.isEmpty {
                Text(verbatim: L("meeting.library.attendees \(MeetingText.attendeesPreview(event.info.attendees, limit: 6))"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let link = event.link {
                Text(verbatim: L("meeting.brief.link \(MeetingText.providerName(link.provider))"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                previousSection(briefing)
                openItemsSection(briefing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        Divider()
        HStack(spacing: 8) {
            if event.link != nil {
                Button(L("meeting.action.join")) {
                    MeetingActions.join(event)
                }
                .keyboardShortcut(.defaultAction)
            }
            Button(L("meeting.action.record")) {
                MeetingActions.record(event)
                MeetingWindowController.shared.closeBrief()
            }
            .disabled(session.isActive)
            Button(L("meeting.brief.openPrevious")) {
                if let previous = briefing.previous {
                    MeetingWindowController.shared.showLibrary(select: previous.id)
                }
            }
            .disabled(briefing.previous == nil)
            Spacer()
            Button(L("meeting.brief.close")) {
                MeetingWindowController.shared.closeBrief()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func previousSection(_ briefing: MeetingBriefing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let previous = briefing.previous {
                Text(verbatim: L("meeting.brief.previous \(MeetingText.dateTime(previous.meta.start))"))
                    .font(.headline)
                if previous.meta.title != model.event?.info.title {
                    Text(verbatim: previous.meta.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let minutes = model.previousMinutes, previous.meta.status == .summarized {
                    MeetingMarkdownBody(text: MeetingMarkdown.summary(fromMinutes: minutes, maxLines: 8))
                } else if !model.previousLoaded {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("meeting.library.loading")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(verbatim: L("meeting.brief.noMinutes \(MeetingText.statusName(previous.meta.status))"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("meeting.brief.previousHeading")
                    .font(.headline)
                Text("meeting.brief.noPrevious")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func openItemsSection(_ briefing: MeetingBriefing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: L("meeting.brief.openItems \(briefing.openItems.count)"))
                .font(.headline)
            if briefing.openItems.isEmpty {
                Text("meeting.brief.noOpenItems")
                    .foregroundStyle(.secondary)
            }
            ForEach(briefing.openItems, id: \.item.id) { open in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MeetingActionItemCheckRow(meetingID: open.meetingID, item: open.item)
                    Spacer(minLength: 8)
                    Text(verbatim: MeetingText.shortDay(open.meetingStart))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
