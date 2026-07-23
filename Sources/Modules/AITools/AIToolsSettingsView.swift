import AppKit
import SwiftUI

/// Cursor / Codex 助手 —— 设置 Tab。segmented 两节：Codex / Cursor（DESIGN 第 1 节）。
///
/// - Codex：approval_policy / sandbox_mode / model 可视化单选（danger 档红字警示）+ 完成通知开关。
///   config.toml 对应键不可编辑（多行 / 非字符串数组）时控件置灰并给说明。
/// - Cursor：项目列表增删、每项目 Rules 状态与模板写入、全局 MCP 列表 + 添加 sheet + 删除。
/// 所有写配置操作在后台线程执行、完成回主线程刷新，失败以红字或 NSAlert 提示。

// MARK: - 顶层容器

struct AIToolsSettingsView: View {

    enum Section: String, CaseIterable, Identifiable {
        case codex, cursor
        var id: String { rawValue }
        var titleKey: LocalizedStringKey {
            switch self {
            case .codex: return "aitools.settings.section.codex"
            case .cursor: return "aitools.settings.section.cursor"
            }
        }
    }

    @State private var section: Section = .codex

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in
                    Text(s.titleKey).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            Divider()

            switch section {
            case .codex: AIToolsCodexSection()
            case .cursor: AIToolsCursorSection()
            }
        }
    }
}

// MARK: - Codex 节视图模型

/// Codex 配置节的状态与后台读写。`@Published` 只在主线程写；核心层 throws 接口 do/catch。
@MainActor
final class CodexConfigModel: ObservableObject {
    @Published var approvalPolicy = ""       // "" = 跟随默认（键缺失）
    @Published var sandboxMode = ""
    @Published var model = ""
    @Published var approvalUneditable = false
    @Published var sandboxUneditable = false
    @Published var modelUneditable = false
    @Published var errorMessage: String?

    /// 常用 model 值（外加「跟随默认」与自定义输入）。
    static let commonModels = ["gpt-5-codex", "gpt-5", "o3"]

    func load() {
        DispatchQueue.global(qos: .utility).async {
            let approval = CodexEnv.approvalPolicy()
            let sandbox = CodexEnv.sandboxMode()
            let model = CodexEnv.model()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch approval {
                    case .absent: self.approvalPolicy = ""; self.approvalUneditable = false
                    case .value(let s): self.approvalPolicy = s; self.approvalUneditable = false
                    case .uneditable: self.approvalUneditable = true
                    }
                    switch sandbox {
                    case .absent: self.sandboxMode = ""; self.sandboxUneditable = false
                    case .value(let s): self.sandboxMode = s; self.sandboxUneditable = false
                    case .uneditable: self.sandboxUneditable = true
                    }
                    switch model {
                    case .absent: self.model = ""; self.modelUneditable = false
                    case .value(let s): self.model = s; self.modelUneditable = false
                    case .uneditable: self.modelUneditable = true
                    }
                }
            }
        }
    }

    func setApprovalPolicy(_ value: String) {
        approvalPolicy = value
        perform { value.isEmpty ? try CodexEnv.removeApprovalPolicy() : try CodexEnv.setApprovalPolicy(value) }
    }

    func setSandboxMode(_ value: String) {
        sandboxMode = value
        perform { value.isEmpty ? try CodexEnv.removeSandboxMode() : try CodexEnv.setSandboxMode(value) }
    }

    func setModel(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        model = trimmed
        perform { trimmed.isEmpty ? try CodexEnv.removeModel() : try CodexEnv.setModel(trimmed) }
    }

    private func perform(_ work: @escaping () throws -> Void) {
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work()
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.errorMessage = L("aitools.common.writeFailed")
                        self.load()
                    }
                }
            }
        }
    }
}

// MARK: - Codex 节

struct AIToolsCodexSection: View {
    @StateObject private var model = CodexConfigModel()
    @ObservedObject private var notify = CodexNotify.shared
    @AppStorage(AIToolsNotifierSettings.soundKey) private var sound = true
    @State private var customModel = ""

    private var configUneditable: Bool {
        model.approvalUneditable || model.sandboxUneditable || model.modelUneditable
    }

    var body: some View {
        Form {
            if !CodexEnv.isInstalled {
                Text("aitools.settings.codex.notInstalled")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(verbatim: error).foregroundStyle(.red).font(.caption)
            }
            if configUneditable {
                Text("aitools.settings.codex.uneditable")
                    .font(.caption).foregroundStyle(.orange)
            }

            approvalSection
            sandboxSection
            modelSection
            notifySection
        }
        .formStyle(.grouped)
        .onAppear { model.load(); notify.refreshState() }
    }

    // MARK: approval_policy

    private var approvalSection: some View {
        SwiftUI.Section("aitools.settings.codex.approval") {
            Picker("aitools.settings.codex.approval.label", selection: Binding(
                get: { model.approvalPolicy },
                set: { model.setApprovalPolicy($0) }
            )) {
                Text("aitools.settings.codex.follow").tag("")
                Text("aitools.settings.codex.approval.untrusted").tag("untrusted")
                Text("aitools.settings.codex.approval.onRequest").tag("on-request")
                Text("aitools.settings.codex.approval.never").tag("never")
            }
            .disabled(model.approvalUneditable)
            Text("aitools.settings.codex.approval.help")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: sandbox_mode

    private var sandboxSection: some View {
        SwiftUI.Section("aitools.settings.codex.sandbox") {
            Picker("aitools.settings.codex.sandbox.label", selection: Binding(
                get: { model.sandboxMode },
                set: { model.setSandboxMode($0) }
            )) {
                Text("aitools.settings.codex.follow").tag("")
                Text("aitools.settings.codex.sandbox.readOnly").tag("read-only")
                Text("aitools.settings.codex.sandbox.workspaceWrite").tag("workspace-write")
                Text("aitools.settings.codex.sandbox.dangerFull").tag("danger-full-access")
            }
            .disabled(model.sandboxUneditable)
            if model.sandboxMode == "danger-full-access" {
                Text("aitools.settings.codex.sandbox.dangerWarning")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("aitools.settings.codex.sandbox.help")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: model

    private var modelSection: some View {
        SwiftUI.Section("aitools.settings.codex.model") {
            Picker("aitools.settings.codex.model.label", selection: Binding(
                get: { model.model },
                set: { model.setModel($0) }
            )) {
                Text("aitools.settings.codex.follow").tag("")
                ForEach(CodexConfigModel.commonModels, id: \.self) { name in
                    Text(verbatim: name).tag(name)
                }
                // 当前值为自定义（非常用项且非空）时，补一个动态标签让 Picker 正确回显。
                if !model.model.isEmpty, !CodexConfigModel.commonModels.contains(model.model) {
                    Text(verbatim: model.model).tag(model.model)
                }
            }
            .disabled(model.modelUneditable)

            HStack {
                TextField("aitools.settings.codex.model.customPlaceholder", text: $customModel)
                    .textFieldStyle(.roundedBorder)
                Button("aitools.settings.codex.model.apply") {
                    model.setModel(customModel)
                    customModel = ""
                }
                .disabled(model.modelUneditable || customModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("aitools.settings.codex.model.help")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: 完成通知

    private var notifySection: some View {
        SwiftUI.Section("aitools.settings.codex.notify") {
            Toggle("aitools.settings.codex.notify.enabled", isOn: Binding(
                get: { notify.isInstalled },
                set: { newValue in
                    if newValue {
                        notify.requestAuthorizationIfNeeded()
                        notify.install { _ in }
                    } else {
                        notify.remove { _ in }
                    }
                }
            ))
            .disabled(notify.isUneditable || !CodexEnv.isInstalled)
            if notify.isUneditable {
                Text("aitools.settings.codex.notify.uneditable")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("aitools.settings.codex.notify.sound", isOn: $sound)
            Text("aitools.settings.codex.notify.help")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cursor 节

struct AIToolsCursorSection: View {
    @ObservedObject private var index = CursorProjectIndex.shared
    @State private var showAddMCP = false

    var body: some View {
        Form {
            projectsSection
            mcpSection
        }
        .formStyle(.grouped)
        .onAppear { index.refresh() }
        .sheet(isPresented: $showAddMCP) {
            AIToolsMCPAddSheet()
        }
    }

    // MARK: 项目列表

    private var projectsSection: some View {
        SwiftUI.Section("aitools.settings.cursor.projects") {
            if index.projects.isEmpty {
                Text("aitools.settings.cursor.noProjects")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(index.projects) { project in
                    AIToolsProjectRow(project: project)
                }
            }
            Button("aitools.settings.cursor.addProject") { addProject() }
            Text("aitools.settings.cursor.projectsHelp")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("aitools.settings.cursor.addProject")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        index.addProject(url.path)
    }

    // MARK: MCP

    private var mcpSection: some View {
        AIToolsMCPListView(showAdd: $showAddMCP)
    }
}

/// 单个项目行：Rules 状态 + 模板写入 + 移除。
private struct AIToolsProjectRow: View {
    let project: CursorProject
    @ObservedObject private var index = CursorProjectIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: project.name).bold()
                Spacer()
                Button(role: .destructive) {
                    index.removeProject(project.path)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
            Text(verbatim: project.path)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            if project.ruleFileNames.isEmpty {
                Text("aitools.settings.cursor.noRules")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(project.ruleFileURLs, id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(verbatim: url.lastPathComponent).font(.caption).lineLimit(1)
                        Spacer()
                        Button("aitools.settings.cursor.open") {
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                    }
                }
            }
            if project.hasLegacyCursorrules {
                Text("aitools.settings.cursor.legacy")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(CursorRuleTemplate.all) { template in
                    Button(template.localizedTitle) {
                        writeTemplate(template)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func writeTemplate(_ template: CursorRuleTemplate) {
        index.writeTemplate(template, toProject: project.path) { result in
            guard case .failure(let error) = result else { return }
            let alert = NSAlert()
            if case CursorEnv.TemplateError.alreadyExists = error {
                alert.messageText = L("aitools.cursor.template.existsTitle")
                alert.informativeText = L("aitools.cursor.template.existsMessage")
            } else {
                alert.messageText = L("aitools.common.writeFailed")
            }
            alert.addButton(withTitle: L("common.ok"))
            alert.runModal()
        }
    }
}

// MARK: - MCP 列表 + 添加 sheet

struct AIToolsMCPListView: View {
    @Binding var showAdd: Bool
    @State private var rows: [MCPRow] = []
    @State private var loading = false

    var body: some View {
        SwiftUI.Section("aitools.settings.cursor.mcp") {
            if loading {
                ProgressView().controlSize(.small)
            } else if rows.isEmpty {
                Text("aitools.settings.cursor.mcp.empty")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.name)
                            Text(verbatim: "\(row.type) · \(row.detail)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            confirmDelete(row)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button("aitools.settings.cursor.mcp.add") { showAdd = true }
            Text("aitools.settings.cursor.mcp.help")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { reload() }
        .onChange(of: showAdd) { _, isShowing in
            if !isShowing { reload() }
        }
    }

    private func reload() {
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let servers = CursorEnv.mcpServers()
            let mapped: [MCPRow] = servers.map { entry in
                let config = entry.config
                let type = (config["type"] as? String) ?? (config["command"] != nil ? "stdio" : "http")
                let detail: String
                if let command = config["command"] as? String {
                    detail = command
                } else if let url = config["url"] as? String {
                    detail = url
                } else {
                    detail = ""
                }
                return MCPRow(id: entry.name, name: entry.name, type: type, detail: detail)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    rows = mapped
                    loading = false
                }
            }
        }
    }

    private func confirmDelete(_ row: MCPRow) {
        let alert = NSAlert()
        alert.messageText = L("aitools.settings.cursor.mcp.deleteConfirm.title \(row.name)")
        alert.informativeText = L("aitools.settings.cursor.mcp.deleteConfirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("aitools.common.remove"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? CursorEnv.removeMCPServer(name: row.name)
            DispatchQueue.main.async { MainActor.assumeIsolated { reload() } }
        }
    }

    struct MCPRow: Identifiable {
        let id: String
        let name: String
        let type: String
        let detail: String
    }
}

/// 添加 MCP 服务器 sheet（结构同 Claude MCP，写 ~/.cursor/mcp.json）。
private struct AIToolsMCPAddSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type = "stdio"
    @State private var command = ""
    @State private var args = ""
    @State private var url = ""
    @State private var env = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("aitools.settings.cursor.mcp.addTitle").font(.headline)
            Form {
                TextField("aitools.settings.cursor.mcp.name", text: $name)
                Picker("aitools.settings.cursor.mcp.type", selection: $type) {
                    Text("aitools.settings.cursor.mcp.type.stdio").tag("stdio")
                    Text("aitools.settings.cursor.mcp.type.http").tag("http")
                }
                if type == "stdio" {
                    TextField("aitools.settings.cursor.mcp.command", text: $command)
                    TextField("aitools.settings.cursor.mcp.args", text: $args)
                } else {
                    TextField("aitools.settings.cursor.mcp.url", text: $url)
                }
                TextField("aitools.settings.cursor.mcp.env", text: $env, axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                Button("aitools.common.save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasTarget = type == "stdio"
            ? !command.trimmingCharacters(in: .whitespaces).isEmpty
            : !url.trimmingCharacters(in: .whitespaces).isEmpty
        return hasName && hasTarget
    }

    private func save() {
        let serverName = name.trimmingCharacters(in: .whitespaces)
        var config: [String: Any] = [:]
        if type == "stdio" {
            config["command"] = command.trimmingCharacters(in: .whitespaces)
            let argList = args.split(separator: " ").map(String.init)
            if !argList.isEmpty { config["args"] = argList }
        } else {
            config["type"] = "http"
            config["url"] = url.trimmingCharacters(in: .whitespaces)
        }
        let envDict = Self.parseEnv(env)
        if !envDict.isEmpty { config["env"] = envDict }

        DispatchQueue.global(qos: .userInitiated).async {
            try? CursorEnv.setMCPServer(name: serverName, config: config)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { dismiss() }
            }
        }
    }

    private static func parseEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }
}
