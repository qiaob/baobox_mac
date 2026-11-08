import SwiftUI

/// 设置页「菜单栏」（docs/menubar-manager/REQUIREMENTS.md §3.4）：启用、Baobox 图标的位置、每个图标显示 / 隐藏、
/// 被挤掉的也放进顶部那一行、两项权限。
struct MenuBarSettingsView: View {
    @ObservedObject private var scanner = MenuBarItemScanner.shared
    @ObservedObject private var actions = MenuBarActions.shared
    @AppStorage(MenuBarSettings.enabledKey) private var enabled = false
    @AppStorage(MenuBarSettings.showSqueezedKey) private var showSqueezed = true
    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var hasScreenRecording = Permissions.hasScreenRecording

    // 授权状态实时刷新（用户在系统设置里改了不用重开这一页）。
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Text("menubar.settings.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("menubar.settings.enabled", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        MenuBarManager.shared.apply(on, userToggled: true)
                    }
                Text("menubar.settings.enabledHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("menubar.settings.position")
                        Text("menubar.settings.positionHelp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("menubar.settings.moveRight") {
                        AppDelegate.shared?.statusItemController?.placeNearSystemIcons()
                    }
                }
            }

            if enabled {
                Section("menubar.settings.itemsSection") {
                    if scanner.items.isEmpty {
                        Text("menubar.settings.itemsEmpty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(scanner.items) { item in
                        itemRow(item)
                    }
                    Text("menubar.settings.itemsHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("menubar.settings.showSqueezed", isOn: $showSqueezed)
                    Text("menubar.settings.showSqueezedHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("settings.general.permissionSection") {
                permissionRow(title: "permission.screenRecording", detail: "menubar.settings.screenDesc",
                              granted: hasScreenRecording) {
                    Permissions.requestScreenRecording()
                    Permissions.openSystemSettings(pane: .screenRecording)
                }
                permissionRow(title: "permission.accessibility", detail: "menubar.settings.axDesc",
                              granted: hasAccessibility) {
                    Permissions.promptAccessibility()
                    Permissions.openSystemSettings(pane: .accessibility)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if enabled { scanner.refresh() }
        }
        .onReceive(timer) { _ in
            hasAccessibility = Permissions.hasAccessibility
            hasScreenRecording = Permissions.hasScreenRecording
        }
    }

    private func itemRow(_ item: MenuBarItem) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarIconRow.chipImage(scanner.images[item.id], pid: item.pid,
                                                    size: NSSize(width: 30, height: 22)))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.displayName)
                if item.state == .squeezed {
                    Text("menubar.settings.squeezedNow")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker(selection: hiddenBinding(item)) {
                Text("menubar.settings.show").tag(false)
                Text("menubar.settings.hide").tag(true)
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 130)
            .disabled(actions.busy || !hasAccessibility)
        }
    }

    /// 选「隐藏 / 显示」= 把图标 ⌘ 拖过占位项（MenuBarActions.setHidden），挪完扫描结果更新，选择跟着变。
    private func hiddenBinding(_ item: MenuBarItem) -> Binding<Bool> {
        Binding(
            get: { item.state == .hidden },
            set: { hide in
                guard hide != (item.state == .hidden) else { return }
                Task { await MenuBarActions.shared.setHidden(hide, itemID: item.id) }
            }
        )
    }

    private func permissionRow(title: LocalizedStringKey, detail: LocalizedStringKey, granted: Bool,
                               enable: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("common.granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button("common.goEnable", action: enable)
            }
        }
    }
}
