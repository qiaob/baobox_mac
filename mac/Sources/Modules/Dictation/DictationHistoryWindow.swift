import AppKit
import SwiftUI

/// 听写历史窗口里的操作（由控制器给出：复制、再次插入要碰剪贴板 / 别的 App）。
struct DictationHistoryActions {
    var copy: (DictationRecord) -> Void
    var insert: (DictationRecord) -> Void
    var delete: (DictationRecord) -> Void
    var clear: () -> Void
}

/// 听写历史窗口（需求 §6）：搜索、复制、再次插入、删除、清空。普通窗口，打开时激活 Baobox。
@MainActor
final class DictationHistoryWindowController {
    private var window: NSWindow?
    /// 打开窗口之前在前台的 App：「再次插入」插进它。
    private(set) var previousApp: NSRunningApplication?

    func show(store: DictationHistoryStore, actions: DictationHistoryActions) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        if window == nil {
            let hosting = NSHostingController(rootView: DictationHistoryView(store: store, actions: actions))
            let created = NSWindow(contentViewController: hosting)
            created.title = L("dictation.history.title")
            created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            created.setContentSize(NSSize(width: 560, height: 480))
            created.minSize = NSSize(width: 420, height: 300)
            // 关掉后复用同一实例（默认 close 即释放，再打开会崩）。
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        // LSUIElement 应用不主动激活，窗口会出现在别的 App 后面。
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct DictationHistoryView: View {
    @ObservedObject var store: DictationHistoryStore
    let actions: DictationHistoryActions
    @AppStorage(DictationHistoryDefaults.enabledKey) private var enabled = true
    @State private var query = ""
    @State private var confirmingClear = false

    private var filtered: [DictationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.records }
        return store.records.filter {
            $0.text.localizedCaseInsensitiveContains(trimmed)
                || ($0.app?.name?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("dictation.history.search", text: $query)
                    .textFieldStyle(.plain)
                Spacer(minLength: 8)
                Button("dictation.history.clear") { confirmingClear = true }
                    .disabled(store.records.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if !enabled {
                Text("dictation.history.disabledNote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            Divider()
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    if store.records.isEmpty {
                        Text("dictation.history.empty")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("dictation.history.noMatch")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { record in
                    DictationHistoryRow(record: record, actions: actions)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .confirmationDialog(L("dictation.history.clearConfirm"), isPresented: $confirmingClear) {
            Button("dictation.history.clear", role: .destructive) { actions.clear() }
            Button("common.cancel", role: .cancel) {}
        }
    }
}

private struct DictationHistoryRow: View {
    let record: DictationRecord
    let actions: DictationHistoryActions

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(verbatim: record.date == .distantPast ? "—" : Self.dateFormatter.string(from: record.date))
                if let name = record.app?.name ?? record.app?.bundleID {
                    Text(verbatim: "·")
                    Text(verbatim: name)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { actions.copy(record) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help(L("dictation.history.copy"))
                Button { actions.insert(record) } label: {
                    Image(systemName: "text.insert")
                }
                .help(L("dictation.history.insert"))
                Button { actions.delete(record) } label: {
                    Image(systemName: "trash")
                }
                .help(L("dictation.history.delete"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            Text(verbatim: record.text)
                .font(.body)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}
