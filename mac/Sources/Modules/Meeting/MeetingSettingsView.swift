import AppKit
import SwiftUI

/// 会议设置（docs/meeting/REQUIREMENTS.md §6）。第一段：「记录」分组、快捷键、嵌入的「字幕与同传」
/// （原实时翻译的全部设置，键名不变）；日历、检测两组在第二段加。
struct MeetingSettingsView: View {
    @AppStorage(MeetingSettings.defaultTypeKey) private var defaultType = MeetingType.online.rawValue
    @AppStorage(MeetingSettings.templateKey) private var template = LiveTranslateMeetingStyle.standard.rawValue
    @AppStorage(MeetingSettings.retentionDaysKey) private var retentionDays = 0
    @ObservedObject private var session = MeetingSessionController.shared

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
                }
            }

            Section("meeting.settings.recordSection") {
                Picker("meeting.settings.defaultType", selection: $defaultType) {
                    Text(verbatim: MeetingText.typeName(.online)).tag(MeetingType.online.rawValue)
                    Text(verbatim: MeetingText.typeName(.offline)).tag(MeetingType.offline.rawValue)
                }
                Picker("meeting.settings.template", selection: $template) {
                    ForEach(LiveTranslateMeetingStyle.allCases, id: \.self) { style in
                        Text(verbatim: MeetingText.templateName(style)).tag(style.rawValue)
                    }
                }
                Text("meeting.settings.templateHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            }

            Section("meeting.settings.hotkeySection") {
                // id 与 MeetingTool.hotkeys() / LiveTranslateTool.hotkeys() 一致。
                ModuleHotkeyRows(ids: ["meeting.startOnline", "meeting.startOffline", "livetranslate.toggle",
                                       "meeting.mark", "meeting.notes"])
            }

            Section {
                Text("meeting.settings.subtitlesIntro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("meeting.settings.subtitlesSection")
            }
            LiveTranslateSettingsSections(embedded: true)
        }
        .formStyle(.grouped)
    }
}
