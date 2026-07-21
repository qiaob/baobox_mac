import SwiftUI

/// 剪贴板设置：历史上限、隐私说明、清空。
struct ClipboardSettingsView: View {
    @ObservedObject var store: ClipboardStore
    @AppStorage(ClipboardStore.maxItemsKey) private var maxItems = 200

    var body: some View {
        Form {
            Section("clipboard.settings.historySection") {
                Stepper("clipboard.settings.maxItems \(maxItems)", value: $maxItems, in: 50...1000, step: 50)
                Text("clipboard.settings.maxItemsHelp")
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

            Section {
                Button("clipboard.settings.clear", role: .destructive) { confirmClear() }
                Text("clipboard.settings.count \(store.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
