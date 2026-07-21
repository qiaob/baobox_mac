import SwiftUI

/// 窗口管理设置：窗口间距、辅助功能权限状态、快捷键说明。
struct WindowManagerSettingsView: View {
    @AppStorage(WindowManagerSettings.gapKey) private var gap = 0.0
    @State private var hasAccess = Permissions.hasAccessibility

    // 授权状态实时刷新（用户在系统设置中改动后无需重启）。
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("windowmanager.settings.layoutSection") {
                Stepper(value: $gap, in: 0...20, step: 1) {
                    Text("windowmanager.settings.gap \(Int(gap))")
                }
                Text("windowmanager.settings.gapHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.general.permissionSection") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("permission.accessibility")
                        Text("windowmanager.settings.axDesc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if hasAccess {
                        Label("common.granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        Button("common.goEnable") {
                            Permissions.promptAccessibility()
                            Permissions.openSystemSettings(pane: .accessibility)
                        }
                    }
                }
            }

            Section {
                Text("windowmanager.settings.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            hasAccess = Permissions.hasAccessibility
        }
    }
}
