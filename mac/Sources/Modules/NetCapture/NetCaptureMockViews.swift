import SwiftUI

// Mock 的界面（docs/packet-capture/TOOLS.md §4）：工具条「Mock」按钮打开的规则列表，和编辑一条规则的面板。
// 规则表本身在 MockRuleStore.swift。

/// 正在编辑的规则（新建的还不在表里）。
struct MockEditing: Identifiable {
    var rule: MockRule
    var isNew: Bool
    var id: String { rule.id }

    /// 列表行右键 / 详情区的「Mock…」：用这条请求预填。
    init(flow: Flow) {
        rule = MockRule.draft(method: flow.method, host: flow.host, path: flow.path,
                              status: flow.statusCode, headers: flow.responseHeaders, body: flow.responseBody)
        isNew = true
    }

    init(rule: MockRule, isNew: Bool) {
        self.rule = rule
        self.isNew = isNew
    }
}

/// 方法菜单里的选项（编辑面板）。
private let mockMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

/// 方法显示名：`*` 写成「任意」。
private func methodTitle(_ method: String) -> String {
    method == MockRule.anyMethod ? L("netcapture.mock.anyMethod") : method
}

// MARK: - 规则列表

/// 工具条「Mock」点开的面板：每行 = 开关 + 方法 + 域名路径 + 状态码；点一行进编辑；「新建」是空白规则。
/// 编辑就在同一个面板里换内容，不再叠一层。
struct MockRulesSheet: View {
    @ObservedObject private var store = MockRuleStore.shared
    let close: () -> Void
    @State private var editing: MockEditing?

    var body: some View {
        if let editing {
            MockRuleEditor(editing: editing,
                           onSave: { rule in
                               store.save(rule)
                               self.editing = nil
                           },
                           onDelete: editing.isNew ? nil : {
                               store.remove(id: editing.rule.id)
                               self.editing = nil
                           },
                           onCancel: { self.editing = nil })
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("netcapture.mock.listTitle").font(.headline)
            if store.rules.isEmpty {
                Text("netcapture.mock.empty")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List {
                    ForEach(store.rules) { rule in
                        MockRuleRow(rule: rule,
                                    setEnabled: { store.setEnabled(id: rule.id, $0) },
                                    open: { editing = MockEditing(rule: rule, isNew: false) })
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: min(CGFloat(store.rules.count) * 30 + 8, 300))
                Text("netcapture.mock.listHint")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    editing = MockEditing(rule: MockRule(), isNew: true)
                } label: {
                    Label("netcapture.mock.new", systemImage: "plus")
                }
                Spacer()
                Button("netcapture.mock.done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private struct MockRuleRow: View {
    let rule: MockRule
    let setEnabled: (Bool) -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: setEnabled))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            HStack(spacing: 8) {
                Text(verbatim: methodTitle(rule.method))
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .frame(width: 58)
                    .background(NetCaptureColors.method(rule.method), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                Text(verbatim: rule.host + rule.path)
                    .font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(verbatim: String(rule.status))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(NetCaptureColors.status(rule.status))
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 编辑一条规则

struct MockRuleEditor: View {
    let isNew: Bool
    private let original: MockRule
    let onSave: (MockRule) -> Void
    /// nil = 新建的规则，没有「删除」。
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var enabled: Bool
    @State private var method: String
    @State private var host: String
    @State private var path: String
    @State private var statusText: String
    @State private var headersText: String
    @State private var bodyText: String
    /// 抓到的正文不是文本（见 `BodyText`）：可以原样保留，也可以清空重写，不能逐字节编辑。nil = 正文是文本框里的内容。
    @State private var binaryBody: Data?

    init(editing: MockEditing, onSave: @escaping (MockRule) -> Void,
         onDelete: (() -> Void)?, onCancel: @escaping () -> Void) {
        let rule = editing.rule
        isNew = editing.isNew
        original = rule
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _enabled = State(initialValue: rule.enabled)
        _method = State(initialValue: rule.method)
        _host = State(initialValue: rule.host)
        _path = State(initialValue: rule.path)
        _statusText = State(initialValue: String(rule.status))
        _headersText = State(initialValue: HeaderText.text(rule.headers))
        if let text = rule.body.isEmpty ? "" : BodyText.text(rule.body) {
            _bodyText = State(initialValue: text)
            _binaryBody = State(initialValue: nil)
        } else {
            _bodyText = State(initialValue: "")
            _binaryBody = State(initialValue: rule.body)
        }
    }

    private var methods: [String] {
        let all = [MockRule.anyMethod] + mockMethods
        return all.contains(method) ? all : all + [method]
    }

    private var rule: MockRule {
        MockRule(id: original.id,
                 enabled: enabled,
                 method: method,
                 host: host,
                 path: path,
                 status: Int(statusText.trimmingCharacters(in: .whitespaces)) ?? 0,
                 headers: HeaderText.headers(headersText),
                 body: binaryBody ?? Data(bodyText.utf8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "netcapture.mock.newTitle" : "netcapture.mock.editTitle").font(.headline)
            Toggle("netcapture.mock.enabled", isOn: $enabled)

            HStack(spacing: 8) {
                Text("netcapture.mock.match").frame(width: 44, alignment: .leading)
                Picker("", selection: $method) {
                    ForEach(methods, id: \.self) { Text(verbatim: methodTitle($0)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                TextField("netcapture.mock.hostPlaceholder", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                TextField("netcapture.mock.pathPlaceholder", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }
            Text("netcapture.mock.pathHint")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 52)

            HStack(spacing: 8) {
                Text("netcapture.mock.response").frame(width: 44, alignment: .leading)
                Text("netcapture.mock.status")
                TextField("", text: $statusText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospacedDigit())
                    .frame(width: 64)
            }

            Text("netcapture.mock.headers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            editor($headersText, height: 90)
            Text("netcapture.mock.body").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let binary = binaryBody {
                HStack {
                    Text("netcapture.mock.binaryBody \(binary.count)")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("netcapture.mock.clearBody") { binaryBody = nil }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            } else {
                editor($bodyText, height: 150)
            }
            Text("netcapture.mock.decryptedOnly").font(.caption).foregroundStyle(.secondary)

            HStack {
                if let onDelete {
                    Button("common.delete", role: .destructive) { onDelete() }
                }
                Spacer()
                Button("common.cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("common.save") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!rule.isValid)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 600)
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.caption.monospaced())
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
    }
}
