import SwiftUI
import UniformTypeIdentifiers

/// 剪贴板设置：历史上限、保留时长、隐私（Concealed 过滤 + 按 App 忽略名单）、清空。
struct ClipboardSettingsView: View {
    @ObservedObject var store: ClipboardStore
    @AppStorage(ClipboardStore.maxItemsKey) private var maxItems = 200
    @AppStorage(ClipboardStore.retentionDaysKey) private var retentionDays = 0
    @State private var ignoredApps: [String] = ClipboardStore.ignoredBundleIDs

    var body: some View {
        Form {
            Section("clipboard.settings.historySection") {
                Stepper("clipboard.settings.maxItems \(maxItems)", value: $maxItems, in: 50...1000, step: 50)
                Text("clipboard.settings.maxItemsHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("clipboard.settings.retention", selection: $retentionDays) {
                    Text("clipboard.settings.retention.forever").tag(0)
                    Text("clipboard.settings.retention.day1").tag(1)
                    Text("clipboard.settings.retention.days7").tag(7)
                    Text("clipboard.settings.retention.days30").tag(30)
                    Text("clipboard.settings.retention.days90").tag(90)
                }
                Text("clipboard.settings.retentionHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("clipboard.settings.privacySection") {
                Toggle("clipboard.settings.ignoreConcealed", isOn: .constant(true))
                    .disabled(true)
                Text("clipboard.settings.ignoreConcealedHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("clipboard.settings.ignoredApps") {
                if ignoredApps.isEmpty {
                    Text("clipboard.settings.ignoredEmpty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ignoredApps, id: \.self) { bundleID in
                        ignoredAppRow(bundleID)
                    }
                }
                Button("clipboard.settings.addApp") { addApp() }
                Text("clipboard.settings.ignoredAppsHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("clipboard.settings.clear", role: .destructive) { confirmClear() }
                Text("clipboard.settings.count \(store.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: retentionDays) { _, _ in
            store.pruneExpired()
        }
    }

    // MARK: - 忽略名单

    private func ignoredAppRow(_ bundleID: String) -> some View {
        // App 可能已卸载：图标/名称取不到时降级为 bundle id 文本。
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(verbatim: FileManager.default.displayName(atPath: url.path))
            } else {
                Image(systemName: "questionmark.app")
                    .frame(width: 18, height: 18)
                Text(verbatim: bundleID)
            }
            Spacer()
            Button {
                ignoredApps.removeAll { $0 == bundleID }
                ClipboardStore.ignoredBundleIDs = ignoredApps
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = L("clipboard.settings.addAppPrompt")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  !ignoredApps.contains(bundleID) else { continue }
            ignoredApps.append(bundleID)
        }
        ClipboardStore.ignoredBundleIDs = ignoredApps
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = L("clipboard.clearConfirm.title")
        alert.informativeText = L("clipboard.clearConfirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("clipboard.clearConfirm.confirm"))
        alert.addButton(withTitle: L("common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearAll()
        }
    }
}
