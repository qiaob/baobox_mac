import SwiftUI

/// hosts 设置：方案的增删改、内容编辑、应用到系统。
struct HostsSettingsView: View {
    @ObservedObject private var store = HostsStore.shared
    /// 当前正在编辑内容的方案。nil = 只显示列表。
    @State private var editing: UUID?

    var body: some View {
        Form {
            Section("hosts.settings.schemesSection") {
                if store.schemes.isEmpty {
                    Text("hosts.settings.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.schemes) { scheme in
                        HStack(spacing: 8) {
                            Toggle("", isOn: enabledBinding(scheme))
                                .labelsHidden()
                                .disabled(store.isApplying)
                            TextField("hosts.settings.namePlaceholder", text: nameBinding(scheme.id))
                            Button {
                                editing = (editing == scheme.id) ? nil : scheme.id
                            } label: {
                                Image(systemName: editing == scheme.id ? "chevron.down" : "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help(Text("hosts.settings.edit"))
                            Button {
                                delete(scheme)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(Text("common.delete"))
                        }
                    }
                }

                HStack {
                    Button("hosts.settings.new") {
                        let id = store.add(name: L("hosts.settings.newName"))
                        editing = id
                    }
                    Button("hosts.settings.importSystem") {
                        editing = store.importFromSystem(name: L("hosts.settings.importedName"))
                    }
                    Spacer()
                }
            }

            if let editing, let scheme = store.schemes.first(where: { $0.id == editing }) {
                Section {
                    TextEditor(text: contentBinding(scheme.id))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                    Text("hosts.settings.contentHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(verbatim: scheme.name.isEmpty ? L("hosts.untitled") : scheme.name)
                }
            }

            Section("hosts.settings.systemSection") {
                HStack {
                    // 显式 LocalizedStringKey：两个字面量做三目会让 Text 的重载解析变模糊。
                    Text(store.isManaged ? LocalizedStringKey("hosts.settings.managed")
                                         : LocalizedStringKey("hosts.settings.notManaged"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("hosts.settings.apply") { apply() }
                        .disabled(store.isApplying)
                }
                Text("hosts.settings.privilegeHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("hosts.settings.backupHelp")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 绑定

    /// 勾选即写系统；失败或用户取消都回滚，保证界面与 /etc/hosts 实际内容一致。
    private func enabledBinding(_ scheme: HostsScheme) -> Binding<Bool> {
        Binding(
            get: { store.schemes.first(where: { $0.id == scheme.id })?.isEnabled ?? false },
            set: { newValue in
                let previous = !newValue
                store.setEnabled(scheme.id, newValue)
                store.apply { outcome in
                    switch outcome {
                    case .ok:
                        break
                    case .cancelled:
                        store.setEnabled(scheme.id, previous)
                    case .failed(let message):
                        store.setEnabled(scheme.id, previous)
                        HostsTool.reportFailure(message)
                    }
                }
            }
        )
    }

    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.schemes.first(where: { $0.id == id })?.name ?? "" },
            set: { store.setName(id, $0) }
        )
    }

    private func contentBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.schemes.first(where: { $0.id == id })?.content ?? "" },
            set: { store.setContent(id, $0) }
        )
    }

    // MARK: - 动作

    private func delete(_ scheme: HostsScheme) {
        if editing == scheme.id { editing = nil }
        let wasEnabled = scheme.isEnabled
        store.delete(scheme.id)
        // 删的是已启用的方案 → 系统 hosts 里还留着它的内容，得重写一次。
        if wasEnabled { apply() }
    }

    private func apply() {
        store.apply { outcome in
            if case .failed(let message) = outcome {
                HostsTool.reportFailure(message)
            }
        }
    }
}
