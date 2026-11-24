import AppKit
import Combine
import SwiftUI

/// 快速入口设置页（这一期的最小版）：一句话说明 + 呼出快捷键（同快捷键页的录制控件，出厂 ⌘Space）。
/// 快捷键是 ⌘Space、正在运行的 Raycast 的快捷键也确实是 ⌘Space 时，快捷键那一行下面一条醒目的提示（§9）。
/// 不用计时器：有 App 启动 / 退出、这里的快捷键变了、快捷键中心的冲突标记变了、Baobox 重新回到前台（用户多半刚去 Raycast 里改完）时
/// 重算一次；换了快捷键、退出那个 App 就消失。
/// 下面两行开关：呼出时带不带上选中的文字、刚复制的内容（§3.7，默认开）。
/// 完整的设置页（来源开关、前缀、⌘Space 引导、别名、清除使用记录）在后面的 PR（docs/launcher/TECH_DESIGN.md §12）。
struct LauncherSettingsView: View {
    @State private var conflictName: String?
    /// 空着时最前面带上选中的文字、刚复制的内容（§3.7，键见 `LauncherContextSettings`，默认开）。
    @AppStorage(LauncherContextSettings.selectionKey) private var includesSelection = true
    @AppStorage(LauncherContextSettings.clipboardKey) private var includesClipboard = true
    /// 什么时候重算：都在主线程发出。
    private let refresh = Publishers.Merge4(
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification),
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification),
        NotificationCenter.default.publisher(for: HotkeyCenter.comboDidChangeNotification),
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))

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
            Section {
                Toggle("launcher.settings.context.selection", isOn: $includesSelection)
                Toggle("launcher.settings.context.clipboard", isOn: $includesClipboard)
            }
        }
        .formStyle(.grouped)
        .onAppear { conflictName = LauncherHotkeyConflictCheck.confirmedConflictName() }
        .onReceive(refresh) { _ in refreshConflict() }
        // 录制结束后 `resumeAll` 重新注册、冲突标记跟着变，不一定伴随这里的键位变化。`@Published` 在赋值之前发出，
        // 下一拍再读才是新值。
        .onReceive(HotkeyCenter.shared.$conflictedIDs.receive(on: DispatchQueue.main)) { _ in refreshConflict() }
    }

    private func refreshConflict() {
        let name = LauncherHotkeyConflictCheck.confirmedConflictName()
        if name != conflictName { conflictName = name }
    }
}
