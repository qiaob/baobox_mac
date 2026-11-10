import AppKit
import SwiftUI

/// 会议设置（docs/meeting/REQUIREMENTS.md §6）：日历（读哪些日历、会前提醒、菜单栏倒计时）、检测（开关、忽略名单）、
/// 记录（默认类型、自动开始、保留时长、纪要模板、设备自检）、快捷键、嵌入的「字幕与同传」（原实时翻译的全部设置，键名不变）。
struct MeetingSettingsView: View {
    @AppStorage(MeetingSettings.defaultTypeKey) private var defaultType = MeetingType.online.rawValue
    @AppStorage(MeetingSettings.templateKey) private var template = MeetingMinutesStyle.standard.rawValue
    @AppStorage(MeetingSettings.retentionDaysKey) private var retentionDays = 0
    @AppStorage(MeetingSettings.calendarEnabledKey) private var calendarEnabled = false
    @AppStorage(MeetingSettings.reminderLeadKey) private var reminderLead = 1
    @AppStorage(MeetingSettings.menuBarCountdownKey) private var menuBarCountdown = false
    @AppStorage(MeetingSettings.detectionEnabledKey) private var detectionEnabled = true
    @AppStorage(MeetingSettings.autoStartKey) private var autoStart = false
    @ObservedObject private var session = MeetingSessionController.shared
    @ObservedObject private var calendar = MeetingCalendar.shared
    @ObservedObject private var reminder = MeetingReminder.shared
    /// 忽略名单 / 不读的日历：会在气泡、别处被改，打开设置页与 UserDefaults 变化时重读。
    @State private var ignoredApps: [String: String] = MeetingSettings.ignoredApps
    @State private var excluded: Set<String> = MeetingSettings.excludedCalendars

    var body: some View {
        Form {
            Section {
                Text("meeting.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(session.isActive ? L("meeting.menu.finish") : L("meeting.menu.startOnline")) {
                        MeetingMenu.toggleOnline()
                    }
                    .disabled(session.phase == .finishing)
                    if !session.isActive {
                        Button("meeting.menu.startOffline") {
                            MeetingSessionController.shared.start(type: .offline)
                        }
                    }
                    Spacer()
                    Button("meeting.menu.library") {
                        MeetingWindowController.shared.showLibrary()
                    }
                }
            }

            calendarSection
            detectionSection
            recordSection

            Section {
                // id 与 MeetingTool.hotkeys() 一致（livetranslate.toggle 也在那里声明，#106）。
                ModuleHotkeyRows(ids: ["meeting.join", "meeting.startOnline", "meeting.startOffline",
                                       "livetranslate.toggle", "meeting.mark", "meeting.notes"])
                Text("meeting.settings.hotkeyHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("meeting.settings.hotkeySection")
            }

            Section {
                Text("meeting.settings.subtitlesIntro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("meeting.settings.subtitlesSection")
            }
            // 「停止后整理纪要」那行提示问的是会议纪要生成器：纪要归会议，字幕与同传只拿结果（docs/meeting/ENGINE.md §4.5.4）。
            LiveTranslateSettingsSections(minutesReady: { MeetingMinutesGenerator.isReady })
        }
        .formStyle(.grouped)
        .onAppear {
            reload()
            calendar.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        let apps = MeetingSettings.ignoredApps
        if apps != ignoredApps { ignoredApps = apps }
        let calendars = MeetingSettings.excludedCalendars
        if calendars != excluded { excluded = calendars }
    }

    // MARK: - 日历

    private var calendarSection: some View {
        Section("meeting.settings.calendarSection") {
            Toggle("meeting.settings.calendarEnabled", isOn: $calendarEnabled)
                .onChange(of: calendarEnabled) { _, enabled in
                    if enabled { calendar.enable() } else { calendar.disable() }
                }
            Text("meeting.settings.calendarHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            if calendarEnabled {
                calendarAccess
            }
            Picker("meeting.settings.reminderLead", selection: $reminderLead) {
                Text("meeting.settings.reminderOff").tag(0)
                Text(verbatim: L("meeting.settings.reminderMinutes \(1)")).tag(1)
                Text(verbatim: L("meeting.settings.reminderMinutes \(5)")).tag(5)
            }
            .disabled(!calendarEnabled)
            if reminder.isPaused(), let until = reminder.pausedUntil {
                HStack {
                    Text(verbatim: L("meeting.settings.remindersPaused \(MeetingText.untilTime(until))"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("meeting.settings.resumeReminders") {
                        reminder.resume()
                    }
                }
            }
            Toggle("meeting.settings.menuBarCountdown", isOn: $menuBarCountdown)
                .onChange(of: menuBarCountdown) { _, _ in
                    MeetingReminder.shared.refreshCountdown()
                }
                .disabled(!calendarEnabled)
        }
    }

    @ViewBuilder
    private var calendarAccess: some View {
        switch calendar.access {
        case .granted:
            if calendar.calendars.isEmpty {
                Text("meeting.settings.calendarNone")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("meeting.settings.calendarsToRead")
                    ForEach(calendar.calendars) { item in
                        Toggle(isOn: Binding(
                            get: { !excluded.contains(item.id) },
                            set: { included in
                                calendar.setCalendar(item.id, included: included)
                                excluded = MeetingSettings.excludedCalendars
                            }
                        )) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(red: item.red, green: item.green, blue: item.blue))
                                    .frame(width: 9, height: 9)
                                Text(verbatim: item.title)
                                if !item.source.isEmpty {
                                    Text(verbatim: item.source)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        case .notDetermined:
            HStack {
                Text("meeting.settings.calendarNotDetermined")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("meeting.settings.calendarRequest") {
                    calendar.requestAccess()
                }
                .disabled(calendar.isRequesting)
            }
        case .denied, .restricted, .writeOnly:
            HStack {
                Text(verbatim: calendar.access == .writeOnly ? L("meeting.settings.calendarWriteOnly")
                                                             : L("meeting.settings.calendarDenied"))
                    .foregroundStyle(.orange)
                Spacer()
                Button("meeting.settings.openPrivacy") {
                    MeetingCalendar.openSystemSettings()
                }
            }
        }
    }

    // MARK: - 检测

    private var detectionSection: some View {
        Section("meeting.settings.detectSection") {
            Toggle("meeting.settings.detectEnabled", isOn: $detectionEnabled)
            Text("meeting.settings.detectHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("meeting.settings.ignoredApps")
                if ignoredApps.isEmpty {
                    Text("meeting.settings.ignoredNone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ignoredIDs, id: \.self) { bundleID in
                        let name = ignoredApps[bundleID] ?? bundleID
                        HStack {
                            Text(verbatim: name)
                            if name != bundleID {
                                Text(verbatim: bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("meeting.settings.ignoredRemove") {
                                MeetingDetector.shared.unignore(bundleID: bundleID)
                                ignoredApps = MeetingSettings.ignoredApps
                            }
                        }
                    }
                }
            }
        }
    }

    /// 忽略名单按显示名排。
    private var ignoredIDs: [String] {
        ignoredApps.keys.sorted { lhs, rhs in
            (ignoredApps[lhs] ?? lhs).localizedStandardCompare(ignoredApps[rhs] ?? rhs) == .orderedAscending
        }
    }

    // MARK: - 记录

    private var recordSection: some View {
        Section("meeting.settings.recordSection") {
            Picker("meeting.settings.defaultType", selection: $defaultType) {
                Text(verbatim: MeetingText.typeName(.online)).tag(MeetingType.online.rawValue)
                Text(verbatim: MeetingText.typeName(.offline)).tag(MeetingType.offline.rawValue)
            }
            Toggle("meeting.settings.autoStart", isOn: $autoStart)
            Text("meeting.settings.autoStartHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("meeting.settings.template", selection: $template) {
                ForEach(MeetingMinutesStyle.allCases, id: \.self) { style in
                    Text(verbatim: MeetingText.templateName(style)).tag(style.rawValue)
                }
            }
            Text("meeting.settings.templateHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            AIFeatureRow(definition: .meetingMinutes)
            AIFeatureRow(definition: .meetingWeekly, showsManage: true)
            Picker("meeting.settings.retention", selection: $retentionDays) {
                ForEach(MeetingSettings.retentionChoices, id: \.self) { days in
                    Text(verbatim: MeetingText.retentionName(days)).tag(days)
                }
            }
            Text("meeting.settings.retentionHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("meeting.settings.library")
                Spacer()
                Text(verbatim: (MeetingStore.shared.rootURL.path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("meeting.menu.openLibrary") {
                    MeetingStore.shared.openInFinder()
                }
            }
            Text("meeting.settings.libraryHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            MeetingDeviceTestRow()
        }
    }
}

/// 设备自检（试录 3 秒）：两路电平、回放混音、结论。
struct MeetingDeviceTestRow: View {
    @ObservedObject private var test = MeetingDeviceTest.shared
    @ObservedObject private var session = MeetingSessionController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("meeting.settings.selfTest")
                    Text("meeting.settings.selfTestHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(test.phase == .idle ? L("meeting.selfTest.start") : L("meeting.selfTest.again")) {
                    test.start()
                }
                .disabled(test.isBusy || session.isActive)
            }
            if test.phase != .idle {
                meter(L("meeting.selfTest.microphone"), level: test.microphoneLevel, verdict: microphoneVerdict)
                meter(L("meeting.selfTest.system"), level: test.systemLevel, verdict: systemVerdict)
                if test.phase == .recording {
                    ProgressView(value: test.progress)
                        .progressViewStyle(.linear)
                }
                Text(verbatim: statusText)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
            }
        }
    }

    private func meter(_ label: String, level: Float?, verdict: String?) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: label)
                .frame(width: 92, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(level == nil ? Color.clear : Color.green)
                    .frame(width: CGFloat(max(0, min(1, level ?? 0))) * 180)
            }
            .frame(width: 180, height: 6)
            if let verdict {
                Text(verbatim: verdict)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var finished: Bool { test.phase == .done || test.phase == .playing }

    private var microphoneVerdict: String? {
        guard finished else { return nil }
        return test.microphoneHeard ? L("meeting.selfTest.heard") : L("meeting.selfTest.silent")
    }

    private var systemVerdict: String? {
        if test.systemUnavailable { return L("meeting.selfTest.systemUnavailable") }
        guard finished else { return nil }
        return test.systemHeard ? L("meeting.selfTest.heard") : L("meeting.selfTest.systemSilent")
    }

    private var statusIsError: Bool {
        if case .failed = test.phase { return true }
        return false
    }

    private var statusText: String {
        switch test.phase {
        case .idle: return ""
        case .preparing: return L("meeting.selfTest.preparing")
        case .recording: return L("meeting.selfTest.recording")
        case .playing: return L("meeting.selfTest.playing")
        case .done: return L("meeting.selfTest.done")
        case .failed(let message): return message
        }
    }
}
