import Combine
import SwiftUI

/// 快速入口设置页（这一期的最小版）：一句话说明 + 呼出快捷键（同快捷键页的录制控件，出厂 ⌘Space）。
/// 快捷键是 ⌘Space、正在运行的 Raycast 的快捷键也确实是 ⌘Space 时，快捷键那一行下面一条醒目的提示（§9）；
/// 每秒重看一次（只读内存），换了快捷键、退出那个 App 就消失。
/// 完整的设置页（来源开关、前缀、⌘Space 引导、别名、清除使用记录）在后面的 PR（docs/launcher/TECH_DESIGN.md §12）。
struct LauncherSettingsView: View {
    @State private var conflictName: String?
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Text("launcher.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ModuleHotkeyRows(ids: [LauncherTool.toggleHotkeyID])
                if let name = conflictName {
                    Label {
                        Text("launcher.settings.hotkeyConflict \(name) \(name) \(name)")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
                Text("launcher.settings.hotkeyHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { conflictName = LauncherHotkeyConflictCheck.confirmedConflictName() }
        .onReceive(refresh) { _ in
            let name = LauncherHotkeyConflictCheck.confirmedConflictName()
            if name != conflictName { conflictName = name }
        }
    }
}
