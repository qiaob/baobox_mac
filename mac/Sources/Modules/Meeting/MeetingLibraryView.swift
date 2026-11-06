import AppKit
import SwiftUI

/// 会议库窗口（需求 §4）：上面切「会议 / 行动项」、按类型筛、搜索；左边列表、右边详情（纪要 / 原文 / 系列时间线 + 行动项）。
struct MeetingLibraryView: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var model = MeetingLibraryModel.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            switch model.mode {
            case .meetings:
                meetings
            case .actionItems:
                MeetingActionItemsView()
            }
            if let banner = model.banner {
                Divider()
                Text(verbatim: banner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .alert(L("meeting.library.deleteTitle"), isPresented: deleteBinding) {
            Button(L("meeting.library.delete"), role: .destructive) {
                if let id = model.pendingDelete { model.delete(id) }
            }
            Button(L("meeting.library.cancel"), role: .cancel) {
                model.pendingDelete = nil
            }
        } message: {
            Text(verbatim: deleteMessage)
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
    }

    private var deleteMessage: String {
        guard let id = model.pendingDelete, let record = store.record(id) else { return "" }
        return L("meeting.library.deleteMessage \(record.meta.title)")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.mode) {
                Text("meeting.library.modeMeetings").tag(MeetingLibraryModel.Mode.meetings)
                Text(verbatim: actionItemsTitle).tag(MeetingLibraryModel.Mode.actionItems)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if model.mode == .meetings {
                Picker("", selection: $model.typeFilter) {
                    Text("meeting.library.filterAll").tag(MeetingLibraryModel.TypeFilter.all)
                    Text(verbatim: MeetingText.typeBadge(.online)).tag(MeetingLibraryModel.TypeFilter.online)
                    Text(verbatim: MeetingText.typeBadge(.offline)).tag(MeetingLibraryModel.TypeFilter.offline)
                    Text(verbatim: MeetingText.typeBadge(.free)).tag(MeetingLibraryModel.TypeFilter.free)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            if model.mode == .meetings {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L("meeting.library.searchPrompt"), text: $model.query)
                        .textFieldStyle(.plain)
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 260)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
            }
        }
    }

    private var actionItemsTitle: String {
        let open = store.openActionItemCount
        return open > 0 ? L("meeting.library.modeActionsCount \(open)") : L("meeting.library.modeActions")
    }

    // MARK: - 会议

    private var meetings: some View {
        let records = model.filtered(store.records)
        return HStack(spacing: 0) {
            Group {
                if records.isEmpty {
                    emptyList
                } else {
                    List(selection: $model.selectedID) {
                        ForEach(records) { record in
                            MeetingLibraryRow(record: record)
                                .contextMenu { MeetingRowMenu(record: record) }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(width: 320)
            Divider()
            Group {
                if let id = model.selectedID, let record = store.record(id) {
                    MeetingLibraryDetail(record: record)
                        .id(record.id)
                } else {
                    placeholder(L("meeting.library.selectHint"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: store.records.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(verbatim: store.records.isEmpty ? L("meeting.library.empty") : L("meeting.library.noMatch"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 列表行

/// 一行：标题、类型徽标、时间、时长、参会人、纪要状态；悬停时换成操作按钮（同右键菜单）。
struct MeetingLibraryRow: View {
    let record: MeetingRecord
    @ObservedObject private var regenerator = MeetingMinutesRegenerator.shared
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: record.meta.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    MeetingTypeBadge(type: record.meta.type)
                }
                Text(verbatim: timeLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !record.meta.attendees.isEmpty {
                    Text(verbatim: MeetingText.attendeesPreview(record.meta.attendees))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if hovering {
                MeetingRowActions(record: record)
            } else {
                MeetingStatusBadge(status: record.meta.status, regenerating: regenerator.running.contains(record.id))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var timeLine: String {
        var line = MeetingText.dateTime(record.meta.start)
        if let duration = record.meta.duration, duration >= 60 {
            line += " · " + MeetingText.duration(duration)
        }
        return line
    }
}

/// 悬停时的小按钮：纪要、原文、复制纪要、重新生成、导出…、删除。
struct MeetingRowActions: View {
    let record: MeetingRecord
    @ObservedObject private var regenerator = MeetingMinutesRegenerator.shared

    var body: some View {
        let model = MeetingLibraryModel.shared
        HStack(spacing: 2) {
            icon("doc.text", L("meeting.library.actionMinutes")) { model.reveal(record.id, detail: .minutes) }
            icon("text.quote", L("meeting.library.actionTranscript")) { model.reveal(record.id, detail: .transcript) }
            icon("doc.on.doc", L("meeting.library.copyMinutes")) { model.copyMinutes(record.id) }
                .disabled(record.meta.status != .summarized)
            icon("arrow.clockwise", L("meeting.library.regenerate")) { regenerator.regenerate(record.id) }
                .disabled(!regenerator.canRegenerate(record))
            icon("square.and.arrow.up", L("meeting.library.exportEllipsis")) { model.export(record.id) }
            icon("trash", L("meeting.library.delete")) { model.confirmDelete(record.id) }
                .disabled(record.meta.status == .recording)
        }
    }

    private func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// 右键菜单：与悬停按钮同一组操作。
struct MeetingRowMenu: View {
    let record: MeetingRecord
    @ObservedObject private var regenerator = MeetingMinutesRegenerator.shared

    var body: some View {
        let model = MeetingLibraryModel.shared
        Button(L("meeting.library.actionMinutes")) { model.reveal(record.id, detail: .minutes) }
        Button(L("meeting.library.actionTranscript")) { model.reveal(record.id, detail: .transcript) }
        Button(L("meeting.library.copyMinutes")) { model.copyMinutes(record.id) }
            .disabled(record.meta.status != .summarized)
        Button(L("meeting.library.regenerate")) { regenerator.regenerate(record.id) }
            .disabled(!regenerator.canRegenerate(record))
        Button(L("meeting.library.exportEllipsis")) { model.export(record.id) }
        Button(L("meeting.library.reveal")) { MeetingStore.shared.reveal(record.id) }
        Divider()
        Button(L("meeting.library.delete"), role: .destructive) { model.confirmDelete(record.id) }
            .disabled(record.meta.status == .recording)
    }
}

struct MeetingTypeBadge: View {
    let type: MeetingType

    var body: some View {
        Text(verbatim: MeetingText.typeBadge(type))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var color: Color {
        switch type {
        case .online: return .blue
        case .offline: return .orange
        case .free: return .teal
        }
    }
}

struct MeetingStatusBadge: View {
    let status: MeetingStatus
    var regenerating = false

    var body: some View {
        HStack(spacing: 4) {
            if regenerating || status == .summarizing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(verbatim: MeetingText.statusName(regenerating ? .summarizing : status))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var color: Color {
        switch status {
        case .recording: return .red
        case .summarizing: return .orange
        case .summarized: return .green
        case .transcribed: return .gray
        case .failed: return .red
        }
    }
}

// MARK: - 详情

/// 选中一场的详情：头信息、纪要 / 原文 / 系列、行动项（勾选写回 meta.json）、底部按钮。
struct MeetingLibraryDetail: View {
    let record: MeetingRecord
    @ObservedObject private var model = MeetingLibraryModel.shared
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var regenerator = MeetingMinutesRegenerator.shared

    private var text: String? { model.text(for: record.id) }
    private var sections: MeetingMarkdown.Sections? { text.map(MeetingMarkdown.sections) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Picker("", selection: $model.detail) {
                Text("meeting.library.tabMinutes").tag(MeetingLibraryModel.Detail.minutes)
                Text("meeting.library.tabTranscript").tag(MeetingLibraryModel.Detail.transcript)
                Text("meeting.library.tabSeries").tag(MeetingLibraryModel.Detail.series)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch model.detail {
                    case .minutes:
                        minutesContent
                        if !record.meta.actionItems.isEmpty {
                            actionItems
                        }
                    case .transcript:
                        transcriptContent
                    case .series:
                        MeetingSeriesTimeline(record: record)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            Divider()
            buttons
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        .task(id: "\(record.id)|\(record.meta.status.rawValue)|\(record.meta.end?.timeIntervalSince1970 ?? 0)") {
            model.load(record)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(verbatim: record.meta.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                MeetingTypeBadge(type: record.meta.type)
                Spacer()
                MeetingStatusBadge(status: record.meta.status, regenerating: regenerator.running.contains(record.id))
            }
            Text(verbatim: timeLine)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !record.meta.attendees.isEmpty {
                Text(verbatim: L("meeting.library.attendees \(record.meta.attendees.joined(separator: L("livetranslate.record.doc.listSeparator")))"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let calendar = record.meta.calendar?.calendar {
                Text(verbatim: L("meeting.library.calendar \(calendar)"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var timeLine: String {
        var line = MeetingText.dateTime(record.meta.start)
        if let end = record.meta.end {
            line += "–" + MeetingText.clockTime(end)
        }
        if let duration = record.meta.duration, duration >= 60 {
            line += " · " + MeetingText.duration(duration)
        }
        return line
    }

    @ViewBuilder
    private var minutesContent: some View {
        if let minutes = sections?.minutes {
            // 没整理成（没模型、太短、失败）时这一节写的是原因，照样显示；重新生成期间先显示旧的。
            MeetingMarkdownBody(text: minutes)
        } else if text == nil {
            loading
        } else {
            Text(verbatim: minutesPlaceholder)
                .foregroundStyle(.secondary)
        }
    }

    private var minutesPlaceholder: String {
        switch record.meta.status {
        case .recording: return L("meeting.library.minutesRecording")
        case .summarizing: return L("meeting.library.minutesSummarizing")
        case .summarized, .transcribed, .failed: return L("meeting.library.minutesNone")
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if let sections {
            if let notes = sections.notes {
                Text("meeting.library.notesHeading")
                    .font(.headline)
                MeetingMarkdownBody(text: notes)
                Divider()
            }
            if let transcript = sections.transcript {
                MeetingMarkdownBody(text: transcript)
            } else {
                Text("meeting.library.transcriptNone")
                    .foregroundStyle(.secondary)
            }
        } else {
            loading
        }
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("meeting.library.loading")
                .foregroundStyle(.secondary)
        }
    }

    private var actionItems: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: L("meeting.library.actionItemsHeading \(record.meta.openActionItemCount) \(record.meta.actionItems.count)"))
                .font(.headline)
            ForEach(record.meta.actionItems) { item in
                MeetingActionItemCheckRow(meetingID: record.id, item: item)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(L("meeting.library.copyMinutes")) { model.copyMinutes(record.id) }
                .disabled(sections?.minutes == nil || record.meta.status != .summarized)
            Button(L("meeting.library.exportMarkdown")) { model.export(record.id) }
            Button(L("meeting.library.reveal")) { MeetingStore.shared.reveal(record.id) }
            Spacer()
            Button(L("meeting.library.regenerate")) { regenerator.regenerate(record.id) }
                .disabled(!regenerator.canRegenerate(record))
        }
    }
}

/// 一条行动项：勾选框（写回 meta.json）、事项、负责人、截止。
struct MeetingActionItemCheckRow: View {
    let meetingID: String
    let item: MeetingActionItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { item.done },
                set: { MeetingStore.shared.setActionItem(item.id, done: $0, inMeeting: meetingID) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.text)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                if let detail = MeetingActionItemCheckRow.detail(item) {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 「负责人：张三 · 截止：周五」。
    static func detail(_ item: MeetingActionItem) -> String? {
        var parts: [String] = []
        if let owner = item.owner { parts.append(L("meeting.actions.owner \(owner)")) }
        if let due = item.due { parts.append(L("meeting.actions.dueLabel \(due)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - 系列时间线

/// 同系列的会议按时间串起来（需求 §4），每场一行摘要，点一下切到那场。
struct MeetingSeriesTimeline: View {
    let record: MeetingRecord
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var model = MeetingLibraryModel.shared

    var body: some View {
        let series = MeetingSeries.timeline(of: record, in: store.records)
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: L("meeting.series.heading \(series.count)"))
                .font(.headline)
            if series.count <= 1 {
                Text(verbatim: record.meta.type == .free ? L("meeting.series.free") : L("meeting.series.single"))
                    .foregroundStyle(.secondary)
            }
            ForEach(series) { item in
                Button {
                    model.reveal(item.id, detail: .minutes)
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: series.map(\.id).joined(separator: ",")) {
            for item in series { model.load(item) }
        }
    }

    private func row(_ item: MeetingRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .fill(item.id == record.id ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                    .padding(.top, 4)
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
            }
            .frame(width: 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: MeetingText.dateTime(item.meta.start))
                        .font(.system(size: 12, weight: item.id == record.id ? .semibold : .regular))
                    if item.meta.openActionItemCount > 0 {
                        Text(verbatim: L("meeting.series.open \(item.meta.openActionItemCount)"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text(verbatim: summary(item))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func summary(_ item: MeetingRecord) -> String {
        if let minutes = model.minutes(of: item.id), item.meta.status == .summarized {
            let line = MeetingMarkdown.oneLineSummary(fromMinutes: minutes)
            if !line.isEmpty { return line }
        }
        return MeetingText.statusName(item.meta.status)
    }
}

// MARK: - 行动项（跨会议）

/// 所有会议的行动项（需求 §4）：未完成 / 已完成分组；每行勾选框、内容、负责人、来源会议（点了跳过去）。
struct MeetingActionItemsView: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var model = MeetingLibraryModel.shared

    var body: some View {
        let rows = MeetingLibraryModel.actionRows(store.records)
        let open = rows.filter { !$0.item.done }
        let done = rows.filter(\.item.done)
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: L("meeting.actions.summary \(open.count) \(done.count)"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("meeting.actions.copyOpen")) { model.copyOpenItems() }
                    .disabled(open.isEmpty)
                Button(L("meeting.actions.exportEllipsis")) { model.exportActionItems() }
                    .disabled(rows.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("meeting.actions.empty")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        if open.isEmpty {
                            Text("meeting.actions.allDone")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(open) { row in
                            MeetingActionRowView(row: row)
                        }
                    } header: {
                        Text(verbatim: L("meeting.actions.open \(open.count)"))
                    }
                    if !done.isEmpty {
                        Section {
                            ForEach(done) { row in
                                MeetingActionRowView(row: row)
                            }
                        } header: {
                            Text(verbatim: L("meeting.actions.done \(done.count)"))
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct MeetingActionRowView: View {
    let row: MeetingLibraryModel.ActionRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            MeetingActionItemCheckRow(meetingID: row.meetingID, item: row.item)
            Spacer(minLength: 8)
            Button {
                MeetingLibraryModel.shared.reveal(row.meetingID, detail: .minutes)
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: row.meetingTitle + " · " + MeetingText.shortDay(row.meetingStart))
                        .lineLimit(1)
                    Image(systemName: "arrow.right.circle")
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(L("meeting.actions.goToMeeting"))
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Markdown

/// 纪要 / 转录的轻量排版：小标题、列表、勾选项、引用（译文）、正文；行内的粗体 / 链接按 Markdown 显示。
struct MeetingMarkdownBody: View {
    private let blocks: [Block]

    init(text: String) {
        blocks = Self.parse(text)
    }

    struct Block: Identifiable {
        enum Kind {
            case heading
            case bullet
            case check(Bool)
            case quote
            case paragraph
            case gap
        }

        let id: Int
        let kind: Kind
        let text: String
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading:
                    Text(Self.inline(block.text))
                        .font(.headline)
                        .padding(.top, 6)
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•")
                            .foregroundStyle(.secondary)
                        Text(Self.inline(block.text))
                    }
                case .check(let done):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: done ? "checkmark.square" : "square")
                            .foregroundStyle(.secondary)
                        Text(Self.inline(block.text))
                    }
                case .quote:
                    Text(Self.inline(block.text))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.35))
                                .frame(width: 2)
                        }
                case .paragraph:
                    Text(Self.inline(block.text))
                case .gap:
                    Color.clear.frame(height: 4)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var lastWasGap = true
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let kind: Block.Kind
            var body = line
            if line.isEmpty {
                guard !lastWasGap else { continue }
                kind = .gap
            } else if line.hasPrefix("#") {
                kind = .heading
                body = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            } else if let rest = checkbox(line) {
                kind = .check(rest.done)
                body = rest.text
            } else if line.hasPrefix("> ") {
                kind = .quote
                body = String(line.dropFirst(2))
            } else if let bullet = MeetingMarkdown.bulletText(line), !(line.first?.isNumber ?? false) {
                kind = .bullet
                body = bullet
            } else {
                kind = .paragraph
            }
            lastWasGap = kind.isGap
            blocks.append(Block(id: blocks.count, kind: kind, text: body))
        }
        return blocks
    }

    private static func checkbox(_ line: String) -> (done: Bool, text: String)? {
        for (prefix, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("* [ ] ", false), ("* [x] ", true)]
        where line.hasPrefix(prefix) {
            return (done, String(line.dropFirst(prefix.count)))
        }
        return nil
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private extension MeetingMarkdownBody.Block.Kind {
    var isGap: Bool {
        if case .gap = self { return true }
        return false
    }
}
