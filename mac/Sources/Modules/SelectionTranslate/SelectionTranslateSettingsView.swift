import SwiftUI

/// 划词翻译设置页：触发方式、朗读、权限、立即试用。
struct SelectionTranslateSettingsView: View {
    @AppStorage(SelectionTranslateSettings.autoPopupKey) private var autoPopup = true
    @AppStorage(SelectionTranslateSettings.copyFallbackKey) private var copyFallback = true
    @AppStorage(SelectionTranslateSettings.autoSpeakKey) private var autoSpeak = false

    var body: some View {
        Form {
            Section {
                Text("selectiontranslate.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("selectiontranslate.settings.autoPopup", isOn: $autoPopup)
                    .onChange(of: autoPopup) { _, _ in
                        SelectionTranslateController.shared.refreshEventTap()
                    }
                Text("selectiontranslate.settings.autoPopupHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("selectiontranslate.settings.copyFallback", isOn: $copyFallback)
                Text("selectiontranslate.settings.copyFallbackHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("selectiontranslate.settings.triggerSection")
            }

            Section {
                Toggle("selectiontranslate.settings.autoSpeak", isOn: $autoSpeak)
            } header: {
                Text("selectiontranslate.settings.speakSection")
            }

            Section {
                HStack {
                    Text("selectiontranslate.settings.accessibility")
                    Spacer()
                    if Permissions.hasAccessibility {
                        Text("selectiontranslate.settings.accessibilityGranted")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("selectiontranslate.settings.accessibilityMissing")
                            .foregroundStyle(.orange)
                        Button("selectiontranslate.settings.grant") {
                            Permissions.promptAccessibility()
                        }
                    }
                }
                HStack {
                    Text("selectiontranslate.settings.screenRecording")
                    Spacer()
                    if Permissions.hasScreenRecording {
                        Text("selectiontranslate.settings.accessibilityGranted")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("selectiontranslate.settings.accessibilityMissing")
                            .foregroundStyle(.orange)
                        Button("selectiontranslate.settings.grant") {
                            Permissions.requestScreenRecording()
                        }
                    }
                }
                Text("selectiontranslate.settings.screenRecordingHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("selectiontranslate.settings.permissionSection")
            }

            Section {
                HStack(spacing: 10) {
                    Button("selectiontranslate.settings.tryTranslate") {
                        SelectionTranslateController.shared.translateSelection(manual: true)
                    }
                    Button("selectiontranslate.settings.tryRegion") {
                        SelectionTranslateController.shared.translateRegion()
                    }
                }
            } header: {
                Text("selectiontranslate.settings.trySection")
            }
        }
        .formStyle(.grouped)
    }
}
