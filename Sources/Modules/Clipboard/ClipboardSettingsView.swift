import SwiftUI
import UniformTypeIdentifiers

/// 剪贴板设置：历史上限、保留时长、隐私（敏感内容开关 + 按 App 忽略名单）、
/// 文本工具（逐格式识别开关）、存储（落盘加密开关）、清空。
struct ClipboardSettingsView: View {
    @ObservedObject var store: ClipboardStore
    @AppStorage(ClipboardStore.maxItemsKey) private var maxItems = 200
    @AppStorage(ClipboardStore.retentionDaysKey) private var retentionDays = 0
    @AppStorage(ClipboardStore.recordConcealedKey) private var recordConcealed = false
    // 默认 true，与 ClipboardCrypto.isEnabled 的 `object(forKey:) as? Bool ?? true` 一致。
    @AppStorage(ClipboardCrypto.enabledKey) private var encryptStorage = true
    @AppStorage(TextToolSettings.masterKey) private var textToolsEnabled = true
    @State private var ignoredApps: [String] = ClipboardStore.ignoredBundleIDs
    /// 逐格式开关。数量不固定又要 ForEach，没法一个格式一个 @AppStorage，
    /// 所以本地存一份镜像，写的时候同步回 UserDefaults。
    @State private var toolStates: [String: Bool] = TextToolSettings.currentStates()
    @AppStorage(SnippetExpander.enabledKey) private var snippetExpandEnabled = false
    @AppStorage(SnippetExpander.prefixKey) private var snippetPrefix = ";"
    @AppStorage(SnippetExpander.restoreClipboardKey) private var snippetRestoreClipboard = true

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
                // 自定义 Binding 而不是直接绑 $recordConcealed：开启前要弹确认框，
                // 用户点「取消」时开关不能已经翻过去了。
                Toggle("clipboard.settings.recordConcealed", isOn: Binding(
                    get: { recordConcealed },
                    set: { newValue in
                        if newValue {
                            if confirmEnableConcealed() { recordConcealed = true }
                        } else {
                            recordConcealed = false
                            store.removeConcealed()
                        }
                    }
                ))
                if recordConcealed {
                    Text("clipboard.settings.recordConcealedOnHelp")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("clipboard.settings.recordConcealedOffHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("clipboard.settings.transientHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("clipboard.settings.textToolsSection") {
                Toggle("clipboard.settings.textTools", isOn: $textToolsEnabled)
                Text("clipboard.settings.textToolsHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if textToolsEnabled {
                    ForEach(TextToolSettings.descriptors, id: \.id) { descriptor in
                        Toggle(isOn: toolBinding(descriptor.id)) {
                            Text(verbatim: descriptor.title)
                        }
                        .padding(.leading, 14)
                    }
                }
            }

            Section("clipboard.settings.snippetsSection") {
                if store.snippets.isEmpty {
                    Text("clipboard.settings.snippetsEmpty")
                        .foregroundStyle(.secondary)
                } else {
                    // 行只做展示（名称/内容预览 + 触发词胶囊），编辑集中到弹窗：
                    // 行内无边框输入框看不出可编辑，内容编辑器也没法贴在被编辑的行旁边。
                    ForEach(store.snippets) { snippet in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: Self.displayName(of: snippet))
                                    .lineLimit(1)
                                if !(snippet.title ?? "").isEmpty, !Self.preview(of: snippet).isEmpty {
                                    Text(verbatim: Self.preview(of: snippet))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            if let keyword = snippet.keyword, !keyword.isEmpty {
                                Text(verbatim: snippetPrefix + keyword)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                            Button {
                                SnippetEditorWindow.open(store: store, id: snippet.id)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            Button {
                                store.delete(snippet.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            SnippetEditorWindow.open(store: store, id: snippet.id)
                        }
                    }
                }

                Button("clipboard.settings.snippetNew") {
                    // 空壳开编辑窗；什么都没填就关掉时由编辑窗负责删掉它。
                    let id = store.addSnippet(title: "", content: "")
                    SnippetEditorWindow.open(store: store, id: id)
                }

                Toggle("clipboard.settings.snippetExpand", isOn: $snippetExpandEnabled)
                    .onChange(of: snippetExpandEnabled) { _, _ in
                        SnippetExpander.shared.refresh()
                    }
                if snippetExpandEnabled {
                    HStack {
                        Text("clipboard.settings.snippetPrefix")
                        Spacer()
                        TextField("", text: $snippetPrefix)
                            .frame(width: 60)
                    }
                    .padding(.leading, 14)
                    Toggle("clipboard.settings.snippetRestore", isOn: $snippetRestoreClipboard)
                        .padding(.leading, 14)
                    if !Permissions.hasAccessibility {
                        Text("clipboard.settings.snippetNeedsAX")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.leading, 14)
                    }
                }
                Text("clipboard.settings.snippetHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("clipboard.settings.snippetPrivacy")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

            Section("clipboard.settings.storageSection") {
                // 同上：关掉是把已有历史明文重写到磁盘，先确认再翻开关。
                Toggle("clipboard.settings.encryptStorage", isOn: Binding(
                    get: { encryptStorage },
                    set: { newValue in
                        if newValue || confirmDisableEncryption() {
                            encryptStorage = newValue
                            store.applyStorageEncryptionChange()
                        }
                    }
                ))
                if encryptStorage {
                    if ClipboardCrypto.isAvailable {
                        Text("clipboard.settings.encryptStorageOnHelp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("clipboard.settings.encryptionUnavailable",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("clipboard.settings.encryptStorageOffHelp")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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

    /// 开启前的二次确认（记录进来的密码在面板里是明文可见的）。返回 true = 确认开启。
    private func confirmEnableConcealed() -> Bool {
        confirm(title: L("clipboard.concealedConfirm.title"),
                message: L("clipboard.concealedConfirm.message"),
                confirmTitle: L("clipboard.concealedConfirm.confirm"))
    }

    /// 关闭加密前的二次确认（已有历史会被明文重写回磁盘）。返回 true = 确认关闭。
    private func confirmDisableEncryption() -> Bool {
        confirm(title: L("clipboard.encryptOffConfirm.title"),
                message: L("clipboard.encryptOffConfirm.message"),
                confirmTitle: L("clipboard.encryptOffConfirm.confirm"))
    }

    private func confirm(title: String, message: String, confirmTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 文本工具

    /// 内容首行（截断），用于没起名字的收藏条目。
    private static func preview(of item: ClipboardItem) -> String {
        let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.components(separatedBy: "\n").first ?? ""
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    /// 列表主行文字：有名称用名称，没有就用内容首行顶上。
    private static func displayName(of item: ClipboardItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        let fallback = preview(of: item)
        return fallback.isEmpty ? L("clipboard.snippetEditor.untitled") : fallback
    }

    private func toolBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { toolStates[id] ?? true },
            set: { newValue in
                toolStates[id] = newValue
                TextToolSettings.setEnabled(newValue, for: id)
            }
        )
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
