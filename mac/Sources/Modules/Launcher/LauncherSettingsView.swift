import SwiftUI

/// 快速入口设置页（这一期的最小版）：一句话说明 + 呼出快捷键（同快捷键页的录制控件，出厂不绑定）。
/// 完整的设置页（来源开关、前缀、⌘Space 引导、别名、清除使用记录）在后面的 PR（docs/launcher/TECH_DESIGN.md §12）。
struct LauncherSettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("launcher.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ModuleHotkeyRows(ids: [LauncherTool.toggleHotkeyID])
                Text("launcher.settings.hotkeyHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
