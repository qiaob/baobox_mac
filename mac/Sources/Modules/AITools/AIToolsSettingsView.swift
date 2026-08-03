import AppKit
import SwiftUI

/// Codex 助手 —— 设置 Tab。顶部状态卡 + segmented Picker 分节（DESIGN §5）：
/// 配置 / 通知 / 用量 / MCP / 维护。Cursor 已移除。
///
/// - 配置：approval_policy / sandbox_mode / model 可视化单选（danger 档红字），config.toml 行级读写保注释。
/// - 通知：完成通知开关 + 提示音 + 额度预算与 80% 提醒。
/// - 用量：周窗口口径开关（固定重置对齐）+ 星期 / 小时选择器。
/// - MCP：只读列出 config.toml 的 [mcp_servers.*] + 打开配置文件（DESIGN §5.1 MVP）。
/// - 维护：磁盘占用 + 清理旧 rollout + codex 版本 / 检查最新版 / 复制升级命令。
/// 所有写配置在后台线程执行、完成回主线程刷新，失败以红字或 NSAlert 提示。

// MARK: - 顶层容器

struct AIToolsSettingsView: View {

    enum Section: String, CaseIterable, Identifiable {
        case config, notify, usage, mcp, maintenance
        var id: String { rawValue }
        var titleKey: LocalizedStringKey {
            switch self {
            case .config: return "aitools.settings.section.config"
            case .notify: return "aitools.settings.section.notify"
            case .usage: return "aitools.settings.section.usage"
            case .mcp: return "aitools.settings.section.mcp"
            case .maintenance: return "aitools.settings.section.maintenance"
            }
        }
    }

    @ObservedObject private var index = CodexSessionIndex.shared
    @State private var section: Section = .config
    @State private var cliVersion: String?

    var body: some View {
        VStack(spacing: 0) {
            statusCard
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)

            if CodexEnv.isInstalled {
                Picker("", selection: $section) {
                    ForEach(Section.allCases) { s in
                        Text(s.titleKey).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Divider()
                sectionBody
            } else {
                Spacer()
                Text("aitools.settings.codex.notInstalled")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(32)
                Spacer()
            }
        }
        .onAppear { loadVersion() }
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .config: AIToolsConfigSection()
        case .notify: AIToolsNotifySection()
        case .usage: AIToolsUsageSettingsSection()
        case .mcp: AIToolsMCPSection()
        case .maintenance: AIToolsMaintenanceSection(localVersion: cliVersion)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 16) {
            Label {
                if let cliVersion {
                    Text("aitools.maint.version \(cliVersion)")
                } else {
                    Text("aitools.settings.status.versionUnknown")
                }
            } icon: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
            Label {
                Text("aitools.settings.status.sessions \(index.sessions.count)")
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func loadVersion() {
        DispatchQueue.global(qos: .utility).async {
            let version = CodexEnv.cliVersion()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { cliVersion = version }
            }
        }
    }
}

// MARK: - 配置节视图模型

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

    /// 常用 model 值。
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

// MARK: - 配置节

struct AIToolsConfigSection: View {
    @StateObject private var model = CodexConfigModel()
    @State private var customModel = ""

    private var configUneditable: Bool {
        model.approvalUneditable || model.sandboxUneditable || model.modelUneditable
    }

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .onAppear { model.load() }
    }

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
}

// MARK: - 通知节

struct AIToolsNotifySection: View {
    @ObservedObject private var notify = CodexNotify.shared
    @AppStorage(AIToolsNotifierSettings.soundKey) private var sound = true
    @AppStorage(AIToolsNotifierSettings.budgetAlertKey) private var budgetAlert = true
    @AppStorage(CodexUsageStore.budgetKey) private var tokenBudget = 0
    @AppStorage(CodexUsageStore.weeklyBudgetKey) private var weeklyBudget = 0

    /// 预算以千 token 为单位输入。
    private var budgetK: Binding<Int> {
        Binding(get: { tokenBudget / 1000 }, set: { tokenBudget = max(0, $0) * 1000 })
    }
    private var weeklyBudgetK: Binding<Int> {
        Binding(get: { weeklyBudget / 1000 }, set: { weeklyBudget = max(0, $0) * 1000 })
    }

    var body: some View {
        Form {
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

            SwiftUI.Section("aitools.notify.budgetSection") {
                HStack {
                    Text("aitools.notify.budget")
                    Spacer()
                    TextField("", value: budgetK, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("aitools.notify.weeklyBudget")
                    Spacer()
                    TextField("", value: weeklyBudgetK, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                // 80% 提醒依赖预算基准，预算为 0 时置灰以显式表达这一依赖。
                Toggle("aitools.notify.budgetAlert", isOn: $budgetAlert)
                    .disabled(tokenBudget == 0 && weeklyBudget == 0)
                Text("aitools.notify.budgetHelp")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { notify.refreshState() }
    }
}

// MARK: - 用量节（周窗口口径）

struct AIToolsUsageSettingsSection: View {
    @AppStorage(CodexUsageStore.weeklyFixedKey) private var weeklyFixed = false
    @AppStorage(CodexUsageStore.weeklyWeekdayKey) private var weeklyWeekday = 2
    @AppStorage(CodexUsageStore.weeklyHourKey) private var weeklyHour = 0

    private static func weekdayName(_ weekday: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        let symbols = formatter.standaloneWeekdaySymbols ?? []
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "\(weekday)"
    }

    var body: some View {
        Form {
            SwiftUI.Section("aitools.settings.section.usage") {
                Toggle("aitools.settings.usage.weeklyFixed", isOn: $weeklyFixed)
                    .onChange(of: weeklyFixed) { _, _ in CodexUsageStore.shared.refresh() }
                if weeklyFixed {
                    Picker("aitools.settings.usage.weeklyWeekday", selection: $weeklyWeekday) {
                        ForEach(1...7, id: \.self) { weekday in
                            Text(verbatim: Self.weekdayName(weekday)).tag(weekday)
                        }
                    }
                    .onChange(of: weeklyWeekday) { _, _ in CodexUsageStore.shared.refresh() }
                    Picker("aitools.settings.usage.weeklyHour", selection: $weeklyHour) {
                        ForEach(0...23, id: \.self) { hour in
                            Text(verbatim: String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    .onChange(of: weeklyHour) { _, _ in CodexUsageStore.shared.refresh() }
                }
                Text("aitools.settings.usage.weeklyHint")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - MCP 节（列出 + 增删 [mcp_servers.*]，stdio）

struct AIToolsMCPSection: View {
    @State private var servers: [CodexEnv.MCPServerInfo] = []
    @State private var loading = false
    @State private var showAdd = false

    var body: some View {
        Form {
            SwiftUI.Section("aitools.settings.section.mcp") {
                if loading {
                    ProgressView().controlSize(.small)
                } else if servers.isEmpty {
                    Text("aitools.settings.mcp.empty")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: server.name)
                                let detail = server.args.isEmpty
                                    ? server.command
                                    : "\(server.command) \(server.args.joined(separator: " "))"
                                if !detail.trimmingCharacters(in: .whitespaces).isEmpty {
                                    Text(verbatim: detail)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                confirmDelete(server)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    Button("aitools.settings.mcp.add") { showAdd = true }
                    Button("aitools.settings.mcp.openConfig") {
                        NSWorkspace.shared.open(CodexEnv.configFile)
                    }
                }
                Text("aitools.settings.mcp.help")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
        .sheet(isPresented: $showAdd) {
            AIToolsMCPAddSheet { reload() }
        }
    }

    private func confirmDelete(_ server: CodexEnv.MCPServerInfo) {
        let alert = NSAlert()
        alert.messageText = L("aitools.settings.mcp.deleteConfirm.title \(server.name)")
        alert.informativeText = L("aitools.settings.mcp.deleteConfirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("aitools.common.remove"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = server.name
        DispatchQueue.global(qos: .utility).async {
            try? CodexEnv.removeMCPServer(name: name)
            DispatchQueue.main.async { MainActor.assumeIsolated { reload() } }
        }
    }

    private func reload() {
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let result = CodexEnv.mcpServers()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    servers = result
                    loading = false
                }
            }
        }
    }
}

// MARK: - MCP 添加 sheet（stdio：command/args/env）

struct AIToolsMCPAddSheet: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var command = ""
    @State private var argsText = ""
    @State private var envText = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("aitools.settings.mcp.addTitle").font(.headline)
            Form {
                TextField("aitools.settings.mcp.name", text: $name)
                TextField("aitools.settings.mcp.command", text: $command)
                TextField("aitools.settings.mcp.args", text: $argsText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("aitools.settings.mcp.env").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $envText)
                        .font(.caption.monospaced())
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
                }
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

    private func save() {
        let serverName = name.trimmingCharacters(in: .whitespaces)
        let cmd = command.trimmingCharacters(in: .whitespaces)
        let args = argsText.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var env: [String: String] = [:]
        for line in envText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { env[parts[0]] = parts[1] }
        }
        DispatchQueue.global(qos: .utility).async {
            try? CodexEnv.setMCPServer(name: serverName, command: cmd, args: args, env: env)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onSaved()
                    dismiss()
                }
            }
        }
    }
}

// MARK: - 维护节

struct AIToolsMaintenanceSection: View {
    let localVersion: String?

    @State private var diskBytes: Int64 = 0
    @State private var fileCount = 0
    @State private var diskLoaded = false
    @State private var cleanupDays = 30
    @State private var latestVersion: String?
    @State private var checking = false
    @State private var checkFailed = false
    @State private var copied = false

    private static let upgradeCommand = "npm install -g @openai/codex"

    var body: some View {
        Form {
            SwiftUI.Section("aitools.maint.diskSection") {
                if diskLoaded {
                    Text("aitools.maint.disk \(AIToolsFormat.bytes(diskBytes)) \(fileCount)")
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack {
                    Picker("aitools.maint.cleanupOlderThan", selection: $cleanupDays) {
                        Text("aitools.maint.cleanupDays \(30)").tag(30)
                        Text("aitools.maint.cleanupDays \(60)").tag(60)
                        Text("aitools.maint.cleanupDays \(90)").tag(90)
                    }
                    Button("aitools.maint.cleanup \(cleanupDays)", role: .destructive) { confirmCleanup() }
                }
            }

            SwiftUI.Section("aitools.maint.versionSection") {
                if let localVersion {
                    Text("aitools.maint.version \(localVersion)")
                } else {
                    Text("aitools.settings.status.versionUnknown").foregroundStyle(.secondary)
                }
                if checking {
                    Text("aitools.maint.checking").font(.caption).foregroundStyle(.secondary)
                } else if checkFailed {
                    Text("aitools.maint.checkFailed").font(.caption).foregroundStyle(.red)
                } else if let latestVersion {
                    Text("aitools.maint.latestVersion \(latestVersion)").font(.caption)
                }
                HStack {
                    Button("aitools.maint.checkUpdate") { checkUpdate() }
                        .disabled(checking)
                    Button("aitools.maint.copyUpgrade") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.upgradeCommand, forType: .string)
                        copied = true
                    }
                    if copied {
                        Text("aitools.common.copied").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadDisk() }
    }

    private func reloadDisk() {
        DispatchQueue.global(qos: .utility).async {
            let (bytes, count) = CodexEnv.sessionsDiskStats()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    diskBytes = bytes
                    fileCount = count
                    diskLoaded = true
                }
            }
        }
    }

    private func confirmCleanup() {
        let alert = NSAlert()
        alert.messageText = L("aitools.maint.cleanupConfirm.title")
        alert.informativeText = L("aitools.maint.cleanupConfirm.message \(cleanupDays)")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("aitools.maint.cleanup \(cleanupDays)"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .utility).async {
            let (count, bytes) = CodexEnv.cleanupSessions(olderThanDays: cleanupDays)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    reloadDisk()
                    CodexSessionIndex.shared.refresh()
                    let done = NSAlert()
                    done.messageText = L("aitools.maint.cleanupResult \(count) \(AIToolsFormat.bytes(bytes))")
                    done.addButton(withTitle: L("common.ok"))
                    done.runModal()
                }
            }
        }
    }

    private func checkUpdate() {
        checking = true
        checkFailed = false
        latestVersion = nil
        guard let url = URL(string: "https://registry.npmjs.org/@openai/codex/latest") else {
            checking = false
            checkFailed = true
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let version: String?
            if let data,
               let raw = try? JSONSerialization.jsonObject(with: data),
               let object = raw as? [String: Any],
               let v = object["version"] as? String {
                version = v
            } else {
                version = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    checking = false
                    if let version {
                        latestVersion = version
                    } else {
                        checkFailed = true
                    }
                }
            }
        }.resume()
    }
}
