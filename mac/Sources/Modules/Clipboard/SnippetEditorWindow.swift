import AppKit
import SwiftUI

/// 片段编辑弹窗：名称 / 关键字 / 内容，一份表单两处入口（设置页列表、剪贴板面板动作栏）。
/// 编辑即保存（与设置页其余开关一致），「完成」只负责关窗。
/// 结构对齐 `ClipboardEditorWindow`（标准窗口 + 强引用池 + `windowWillClose` 摘除）。
@MainActor
final class SnippetEditorWindow: NSWindow, NSWindowDelegate {

    private static var editors: [SnippetEditorWindow] = []

    static func open(store: ClipboardStore, id: UUID) {
        // 同一条已开着编辑窗就前置它，不再开第二个。
        if let existing = editors.first(where: { $0.itemID == id }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = SnippetEditorWindow(store: store, id: id)
        editors.append(window)
        // 无 Dock 图标的 accessory App：不先激活，窗口拿不到键盘焦点。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private let itemID: UUID
    private weak var store: ClipboardStore?

    private init(store: ClipboardStore, id: UUID) {
        self.itemID = id
        self.store = store
        let contentRect = NSRect(x: 0, y: 0, width: 460, height: 380)
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        title = L("clipboard.snippetEditor.title")
        minSize = NSSize(width: 400, height: 320)
        isReleasedWhenClosed = false
        delegate = self
        contentView = NSHostingView(rootView: SnippetEditorView(store: store, id: id,
                                                                onDone: { [weak self] in self?.close() }))
        center()
    }

    func windowWillClose(_ notification: Notification) {
        // 新建后什么都没填就关掉：删掉空壳，别在列表里留一条空行。
        if let store, let item = store.items.first(where: { $0.id == itemID }),
           (item.title ?? "").isEmpty, (item.keyword ?? "").isEmpty,
           (item.text ?? "").isEmpty {
            store.delete(itemID)
        }
        SnippetEditorWindow.editors.removeAll { $0 === self }
    }
}

/// 编辑表单。绑定直接读写 store（边打边存），条目被外部删除时显示空态。
private struct SnippetEditorView: View {
    @ObservedObject var store: ClipboardStore
    let id: UUID
    var onDone: () -> Void

    @AppStorage(SnippetExpander.prefixKey) private var snippetPrefix = ";"

    private var item: ClipboardItem? { store.items.first { $0.id == id } }

    var body: some View {
        if item != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    fieldLabel("clipboard.settings.snippetTitle")
                    TextField("clipboard.snippetEditor.titlePlaceholder", text: titleBinding)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    fieldLabel("clipboard.settings.snippetKeyword")
                    Text(verbatim: snippetPrefix)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField("clipboard.snippetEditor.keywordPlaceholder", text: keywordBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Spacer(minLength: 0)
                }
                Text(verbatim: keywordHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 64)

                Text("clipboard.snippetEditor.content")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                TextEditor(text: contentBinding)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    .frame(minHeight: 140, maxHeight: .infinity)

                HStack {
                    Button(role: .destructive) {
                        store.delete(id)
                        onDone()
                    } label: {
                        Text("common.delete")
                    }
                    Spacer()
                    Button {
                        onDone()
                    } label: {
                        Text("clipboard.snippetEditor.done")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        } else {
            // 条目在别处被删了（面板 ⌘⌫ / 设置页垃圾桶）。
            VStack {
                Text("clipboard.preview.empty").foregroundStyle(.secondary)
                Button("clipboard.snippetEditor.done") { onDone() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fieldLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 56, alignment: .trailing)
    }

    /// 设了关键字：展示完整触发词；没设：说明只是普通收藏。
    private var keywordHint: String {
        let keyword = item?.keyword ?? ""
        if keyword.isEmpty {
            return L("clipboard.snippetEditor.noKeywordHint")
        }
        return L("clipboard.snippetEditor.hint \(snippetPrefix + keyword)")
    }

    private var titleBinding: Binding<String> {
        Binding(get: { item?.title ?? "" },
                set: { store.setSnippetTitle(id, $0) })
    }

    private var keywordBinding: Binding<String> {
        Binding(get: { item?.keyword ?? "" },
                set: { store.setSnippetKeyword(id, $0) })
    }

    private var contentBinding: Binding<String> {
        Binding(get: { item?.text ?? "" },
                set: { store.setSnippetContent(id, $0) })
    }
}
