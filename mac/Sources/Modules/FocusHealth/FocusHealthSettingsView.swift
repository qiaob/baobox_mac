import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 专注与健康设置（需求 §8）：总开关、专注、提醒项（增删改）、休息画面、工作时间、避让说明。
struct FocusHealthSettingsView: View {
    @ObservedObject private var controller = FocusHealthController.shared
    @AppStorage(FocusHealthSettings.remindersEnabledKey) private var remindersEnabled = true
    @AppStorage(FocusHealthSettings.defaultMinutesKey) private var defaultMinutes = 25
    @AppStorage(FocusHealthSettings.shortBreakKey) private var shortBreak = 5
    @AppStorage(FocusHealthSettings.longBreakKey) private var longBreak = 15
    @AppStorage(FocusHealthSettings.longEveryKey) private var longEvery = 4
    @AppStorage(FocusHealthSettings.autoNextKey) private var autoNext = false
    @AppStorage(FocusHealthSettings.strengthKey) private var strength = BreakStrength.standard.rawValue
    @AppStorage(FocusHealthSettings.maxSnoozesKey) private var maxSnoozes = 2
    @AppStorage(FocusHealthSettings.backdropKey) private var backdrop = "teal"
    @AppStorage(FocusHealthSettings.backdropImageKey) private var backdropImage = ""
    @AppStorage(FocusHealthSettings.workStartKey) private var workStart = 9 * 60
    @AppStorage(FocusHealthSettings.workEndKey) private var workEnd = 18 * 60
    @AppStorage(FocusHealthSettings.workdaysOnlyKey) private var workdaysOnly = true
    @AppStorage(FocusHealthSettings.minSpacingKey) private var minSpacing = 15
    @AppStorage(FocusHealthSettings.confirmIdentityKey) private var confirmIdentity = true
    @State private var expandedID: String?

    private static let focusOptions = [15, 25, 30, 45, 50, 60, 90]

    var body: some View {
        Form {
            Section {
                // 最上面一行：今天 / 本周 / 连续天数（docs/focus-health/HISTORY.md §3）。
                Label {
                    Text(verbatim: FocusText.historyLine(controller.historySummary))
                } icon: {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(Color.accentColor)
                }
                Text("focus.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("focus.settings.focusSection") {
                Picker("focus.settings.defaultMinutes", selection: $defaultMinutes) {
                    ForEach(Self.focusOptions, id: \.self) { minutes in
                        Text(verbatim: L("focus.settings.minutes \(minutes)")).tag(minutes)
                    }
                }
                Stepper(value: $shortBreak, in: 1...30) {
                    Text(verbatim: L("focus.settings.shortBreak \(shortBreak)"))
                }
                Stepper(value: $longBreak, in: 5...60, step: 5) {
                    Text(verbatim: L("focus.settings.longBreak \(longBreak)"))
                }
                Stepper(value: $longEvery, in: 2...8) {
                    Text(verbatim: L("focus.settings.longEvery \(longEvery)"))
                }
                Toggle("focus.settings.autoNext", isOn: $autoNext)
                Text("focus.settings.focusHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("focus.settings.remindersSection") {
                Toggle("focus.settings.remindersEnabled", isOn: $remindersEnabled)
                ForEach(controller.items) { item in
                    ReminderItemRow(item: binding(for: item.id), expanded: expandedBinding(for: item.id)) {
                        controller.deleteItem(item.id)
                    }
                }
                HStack {
                    Button("focus.settings.addItem") {
                        expandedID = controller.addItem()
                    }
                    Button("focus.settings.restorePresets") {
                        controller.restorePresets()
                    }
                    Spacer()
                }
                Stepper(value: $minSpacing, in: 10...30, step: 5) {
                    Text(verbatim: L("focus.settings.minSpacing \(minSpacing)"))
                }
                Text("focus.settings.rhythmHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("focus.settings.breakSection") {
                Picker("focus.settings.strength", selection: $strength) {
                    Text("focus.strength.relaxed").tag(BreakStrength.relaxed.rawValue)
                    Text("focus.strength.standard").tag(BreakStrength.standard.rawValue)
                    Text("focus.strength.strict").tag(BreakStrength.strict.rawValue)
                }
                Text(verbatim: strengthHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 只有轻松档能推迟（标准 / 严格档不能推迟，长按 3 秒才能跳过）。
                if strength == BreakStrength.relaxed.rawValue {
                    Stepper(value: $maxSnoozes, in: 0...5) {
                        Text(verbatim: L("focus.settings.maxSnoozes \(maxSnoozes)"))
                    }
                } else {
                    // 标准 / 严格档会盖屏：结束前确认是本人，人不在就锁屏（TECH_DESIGN.md §5.6）。
                    Toggle("focus.settings.confirmIdentity", isOn: $confirmIdentity)
                    Text("focus.settings.confirmIdentityHint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("focus.settings.backdrop", selection: $backdrop) {
                    Text("focus.backdrop.teal").tag("teal")
                    Text("focus.backdrop.dusk").tag("dusk")
                    Text("focus.backdrop.forest").tag("forest")
                    Text("focus.backdrop.image").tag("image")
                }
                if backdrop == "image" {
                    HStack {
                        Text(verbatim: backdropImage.isEmpty
                             ? L("focus.settings.noImage")
                             : URL(fileURLWithPath: backdropImage).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("focus.settings.chooseImage") { chooseImage() }
                    }
                }
                Text("focus.settings.backdropHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("focus.settings.preview") {
                        controller.previewStage()
                    }
                    Spacer()
                }
            }

            Section("focus.settings.workSection") {
                DatePicker("focus.settings.workStart", selection: minuteBinding($workStart),
                           displayedComponents: .hourAndMinute)
                DatePicker("focus.settings.workEnd", selection: minuteBinding($workEnd),
                           displayedComponents: .hourAndMinute)
                Toggle("focus.settings.workdaysOnly", isOn: $workdaysOnly)
                Text("focus.settings.workHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("focus.settings.avoidSection") {
                Text("focus.settings.avoidHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var strengthHelp: String {
        switch BreakStrength(rawValue: strength) ?? .standard {
        case .relaxed: return L("focus.strength.relaxedHelp")
        case .standard: return L("focus.strength.standardHelp")
        case .strict: return L("focus.strength.strictHelp")
        }
    }

    private func binding(for id: String) -> Binding<ReminderItem> {
        Binding(
            get: { controller.item(id) ?? ReminderItem(id: id) },
            set: { controller.updateItem($0) }
        )
    }

    private func expandedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedID == id },
            set: { open in
                if open {
                    expandedID = id
                } else if expandedID == id {
                    expandedID = nil
                }
            }
        )
    }

    /// 分钟数 ↔ 今天的那个时刻（DatePicker 只认 Date）。
    private func minuteBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { FocusDay.date(minute: minutes.wrappedValue, sameDayAs: Date()) },
            set: { minutes.wrappedValue = FocusDay.minuteOfDay($0) }
        )
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            backdropImage = url.path
        }
    }
}

/// 一条提醒：开关 + 名称 + 概要，展开后编辑。
struct ReminderItemRow: View {
    @Binding var item: ReminderItem
    @Binding var expanded: Bool
    let onDelete: () -> Void

    private static let restOptions = [20, 30, 60, 120, 300, 600, 900, 1200]

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            editor
        } label: {
            HStack(spacing: 10) {
                Toggle("", isOn: $item.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Image(systemName: item.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.displayName)
                    Text(verbatim: item.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        TextField("focus.settings.item.name", text: $item.name, prompt: Text(verbatim: item.presetName))
        Picker("focus.settings.item.schedule", selection: $item.schedule) {
            Text("focus.schedule.interval").tag(ReminderItem.Schedule.interval)
            Text("focus.schedule.daily").tag(ReminderItem.Schedule.daily)
        }
        if item.schedule == .interval {
            Stepper(value: $item.intervalMinutes, in: 5...240, step: 5) {
                Text(verbatim: L("focus.settings.item.interval \(item.intervalMinutes)"))
            }
            Picker("focus.settings.item.clock", selection: $item.clock) {
                Text("focus.clock.active").tag(ReminderItem.Clock.active)
                Text("focus.clock.wall").tag(ReminderItem.Clock.wall)
            }
        } else {
            DatePicker("focus.settings.item.time", selection: timeBinding, displayedComponents: .hourAndMinute)
        }
        Picker("focus.settings.item.style", selection: $item.style) {
            Text("focus.style.nudge").tag(ReminderItem.Style.nudge)
            Text("focus.style.bubble").tag(ReminderItem.Style.bubble)
            Text("focus.style.rest").tag(ReminderItem.Style.rest)
        }
        if item.style == .rest {
            Picker("focus.settings.item.restLength", selection: $item.restSeconds) {
                ForEach(restOptions, id: \.self) { seconds in
                    Text(verbatim: FocusText.duration(seconds)).tag(seconds)
                }
            }
        }
        Toggle("focus.settings.item.workHoursOnly", isOn: $item.workHoursOnly)
        if item.schedule == .interval {
            Toggle("focus.settings.item.awayCounts", isOn: $item.awayCounts)
        }
        HStack {
            Spacer()
            Button("focus.settings.item.delete", role: .destructive) { onDelete() }
        }
    }

    /// 选项里没有当前值（手改过 JSON）时把它也列上，免得 Picker 显示空白。
    private var restOptions: [Int] {
        Array(Set(Self.restOptions + [item.restSeconds])).sorted()
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { FocusDay.date(minute: item.timeOfDay, sameDayAs: Date()) },
            set: { item.timeOfDay = FocusDay.minuteOfDay($0) }
        )
    }
}
