import SwiftUI

/// 防休眠设置：默认时长、是否同时防显示器休眠。
struct CaffeinateSettingsView: View {
    @AppStorage(CaffeinateSettings.defaultDurationKey) private var defaultDuration = CaffeinateSettings.infiniteSentinel
    @AppStorage(CaffeinateSettings.preventDisplaySleepKey) private var preventDisplaySleep = false

    @ObservedObject private var controller = CaffeinateController.shared

    var body: some View {
        Form {
            Section {
                Text("caffeinate.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("caffeinate.settings.durationSection") {
                Picker("caffeinate.settings.durationPicker", selection: $defaultDuration) {
                    Text("caffeinate.settings.15m").tag(Double(15 * 60))
                    Text("caffeinate.settings.1h").tag(Double(60 * 60))
                    Text("caffeinate.settings.2h").tag(Double(2 * 60 * 60))
                    Text("caffeinate.settings.infinite").tag(CaffeinateSettings.infiniteSentinel)
                }
                Text("caffeinate.settings.durationHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("caffeinate.settings.optionsSection") {
                Toggle("caffeinate.settings.preventDisplay", isOn: $preventDisplaySleep)
                    .onChange(of: preventDisplaySleep) { _, _ in
                        controller.rebuildIfActive()
                    }
                Text("caffeinate.settings.preventDisplayHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
