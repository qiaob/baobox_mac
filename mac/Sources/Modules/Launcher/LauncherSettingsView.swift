import AppKit
import Combine
import SwiftUI

/// 快速入口设置页：一句话说明 + 呼出快捷键（同快捷键页的录制控件，出厂 ⌘Space）。
/// 快捷键是 ⌘Space、正在运行的 Raycast 的快捷键也确实是 ⌘Space 时，快捷键那一行下面一条醒目的提示（§9）。
/// 不用计时器：有 App 启动 / 退出、这里的快捷键变了、快捷键中心的冲突标记变了、Baobox 重新回到前台（用户多半刚去 Raycast 里改完）时
/// 重算一次；换了快捷键、退出那个 App 就消失。
/// 下面是快速入口能做的全部事情（第 13 步，docs/launcher/TECH_DESIGN.md §11「功能开关」）：六个小节，全部展开，每一项一个开关；
/// 关掉的不在快速入口里出现，工具本身不受影响。行由 `LauncherFeatureCatalog` 经注册表收（视图不认识具体工具），
/// 设置页出现时收一次；拨开关直接写 `launcher.disabledFeatures`，下次呼出生效。每个小节标题右边一个「全部打开 / 全部关闭」。
/// 别的设置（前缀、⌘Space 引导、别名、清除使用记录）在后面的步骤（docs/launcher/TECH_DESIGN.md §12）。
struct LauncherSettingsView: View {
    /// 收功能清单用（同快捷键页拿注册表的方式）；nil = 只有快速入口自己的功能。
    let registry: ToolRegistry?

    @State private var conflictName: String?
    @State private var sections: [LauncherFeatureSection] = []
    @State private var features = LauncherFeatureSet.allEnabled
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
                Text("launcher.settings.features.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(sections, id: \.group) { section in
                featureSection(section)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            conflictName = LauncherHotkeyConflictCheck.confirmedConflictName()
            features = LauncherFeatureSettings.load()
            sections = LauncherFeatureLayout.sections(LauncherFeatureCatalog.rows(registry: registry))
        }
        .onReceive(refresh) { _ in refreshConflict() }
        // 录制结束后 `resumeAll` 重新注册、冲突标记跟着变，不一定伴随这里的键位变化。`@Published` 在赋值之前发出，
        // 下一拍再读才是新值。
        .onReceive(HotkeyCenter.shared.$conflictedIDs.receive(on: DispatchQueue.main)) { _ in refreshConflict() }
    }

    private func refreshConflict() {
        let name = LauncherHotkeyConflictCheck.confirmedConflictName()
        if name != conflictName { conflictName = name }
    }

    // MARK: - 功能开关

    @ViewBuilder
    private func featureSection(_ section: LauncherFeatureSection) -> some View {
        if section.group == .image {
            // 「<命令名>图里的文字」由文字动作派生，不单列：页脚说一句。
            Section {
                rows(section)
            } header: {
                header(section)
            } footer: {
                Text("launcher.settings.features.imageFooter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Section {
                rows(section)
            } header: {
                header(section)
            }
        }
    }

    private func rows(_ section: LauncherFeatureSection) -> some View {
        ForEach(section.rows, id: \.id) { row in
            featureRow(row)
        }
    }

    /// 小节标题：组名 + 同一行的小字（这一组管什么时候）+ 右边「全部打开 / 全部关闭」（这一节里有关着的就是「全部打开」）。
    private func header(_ section: LauncherFeatureSection) -> some View {
        let enablesAll = section.offersEnableAll(in: features)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: section.group.title)
            if let explanation = section.group.explanation {
                Text(verbatim: explanation)
                    .font(.caption)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(enablesAll ? "launcher.settings.features.enableAll" : "launcher.settings.features.disableAll") {
                update(features.setting(section.ids, enabled: enablesAll))
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    /// 一行：图标 + 名字（有说明的在下面一行小字）+ 右侧所属工具名 + 开关。一行只说一件事。
    private func featureRow(_ row: LauncherFeatureRow) -> some View {
        Toggle(isOn: Binding(
            get: { features.isEnabled(row.id) },
            set: { update(features.setting(row.id, enabled: $0)) })) {
            HStack(spacing: 8) {
                Image(systemName: row.symbolName)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.title)
                    if let detail = row.detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let toolName = row.toolName {
                    Text(verbatim: toolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 换上新的开关集合并写进设置（下次呼出生效）。设置里原有的、这次没人声明的 id 都在 `features` 里，写回时不丢。
    private func update(_ next: LauncherFeatureSet) {
        features = next
        LauncherFeatureSettings.save(next)
    }
}
