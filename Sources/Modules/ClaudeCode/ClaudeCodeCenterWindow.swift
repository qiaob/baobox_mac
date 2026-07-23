import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Claude Code 助手 —— 中心窗口：会话浏览 / 用量报表 / 改动审计三 Tab，及其窗口控制器。
///
/// 控制器仿 `SettingsWindowController`（NSWindow + NSHostingController，
/// `isReleasedWhenClosed = false`，`show(tab:)` 定位到指定页）。尺寸 720×480，可缩放。
/// 所有重 IO 走核心层单例的后台接口，完成回主线程；视图层只做展示与交互。

// MARK: - 共享格式化

/// 模块内共享的展示格式化（费用 `$%.2f`、token ≥1000 记 `%.1fk`、倒计时、字节）。
enum ClaudeFormat {

    /// 费用统一 `$%.2f`（处处标「估算」由文案负责）。
    static func cost(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// token 数：≥1000 记 `%.1fk`，否则原样。
    static func tokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    /// 倒计时：`2h15m` / `45m`（语言无关的 h/m）。
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }

    /// 字节数人性化展示。
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// 相对时间（如「3 分钟前」）。
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Tab 定位

/// 中心窗口三个页签。
enum ClaudeCenterTab: String {
    case sessions
    case usage
    case audit
}

/// 当前选中页签（供菜单点击定位）。
@MainActor
final class ClaudeCenterTabSelection: ObservableObject {
    static let shared = ClaudeCenterTabSelection()
    @Published var selectedTab: String = ClaudeCenterTab.sessions.rawValue
    private init() {}
}

// MARK: - 窗口控制器

/// 中心窗口控制器（单例）。自持窗口，关闭后复用同一实例。
@MainActor
final class ClaudeCodeCenterController {
    static let shared = ClaudeCodeCenterController()

    private var window: NSWindow?

    private init() {}

    /// 打开中心窗口并切到指定 Tab；同时触发一次索引与用量刷新。
    func show(tab: ClaudeCenterTab) {
        ClaudeCenterTabSelection.shared.selectedTab = tab.rawValue

        if window == nil {
            let hosting = NSHostingController(rootView: ClaudeCenterView())
            let created = NSWindow(contentViewController: hosting)
            created.title = L("claudecode.center.title")
            created.styleMask = [.titled, .closable, .resizable]
            created.setContentSize(NSSize(width: 720, height: 480))
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }

        ClaudeSessionIndex.shared.refresh()
        ClaudeUsageStore.shared.refresh()

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 根视图

struct ClaudeCenterView: View {
    @ObservedObject private var tabSelection = ClaudeCenterTabSelection.shared

    var body: some View {
        TabView(selection: $tabSelection.selectedTab) {
            ClaudeSessionsTab()
                .tabItem { Label("claudecode.center.tab.sessions", systemImage: "clock.arrow.circlepath") }
                .tag(ClaudeCenterTab.sessions.rawValue)

            ClaudeUsageTab()
                .tabItem { Label("claudecode.center.tab.usage", systemImage: "chart.bar") }
                .tag(ClaudeCenterTab.usage.rawValue)

            ClaudeAuditTab()
                .tabItem { Label("claudecode.center.tab.audit", systemImage: "doc.text.magnifyingglass") }
                .tag(ClaudeCenterTab.audit.rawValue)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: - 会话 Tab

struct ClaudeSessionsTab: View {
    @ObservedObject private var index = ClaudeSessionIndex.shared
    @State private var query = ""

    private var filtered: [ClaudeSessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return index.sessions }
        let needle = trimmed.lowercased()
        return index.sessions.filter {
            $0.title.lowercased().contains(needle) || $0.projectName.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("claudecode.sessions.search", text: $query)
                    .textFieldStyle(.plain)
                if index.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    index.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(Text("claudecode.common.refresh"))
            }
            .padding(10)
            Divider()

            if filtered.isEmpty {
                Spacer()
                Text("claudecode.sessions.empty")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { session in
                    ClaudeSessionRow(session: session)
                }
                .listStyle(.inset)
            }
        }
    }
}

/// 单条会话行：标题、项目、相对时间、大小 + 操作按钮。
private struct ClaudeSessionRow: View {
    let session: ClaudeSessionSummary
    @ObservedObject private var index = ClaudeSessionIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: session.title)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(verbatim: session.projectName)
                Text(verbatim: "·")
                Text(verbatim: ClaudeFormat.relative(session.lastActivity))
                Text(verbatim: "·")
                Text(verbatim: ClaudeFormat.bytes(session.fileSize))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    TerminalLauncher.resume(sessionID: session.id, in: session.projectPath)
                } label: {
                    Label("claudecode.sessions.resume", systemImage: "terminal")
                }
                Button {
                    copyResumeCommand()
                } label: {
                    Label("claudecode.sessions.copyCommand", systemImage: "doc.on.doc")
                }
                Button {
                    exportMarkdown()
                } label: {
                    Label("claudecode.sessions.export", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    confirmDelete()
                } label: {
                    Label("claudecode.sessions.delete", systemImage: "trash")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func copyResumeCommand() {
        let bin = ClaudeEnv.findClaudeBinary() ?? "claude"
        let command = "cd \(ClaudeEnv.shellSingleQuote(session.projectPath)) && "
            + "\(ClaudeEnv.shellSingleQuote(bin)) --resume \(ClaudeEnv.shellSingleQuote(session.id))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func exportMarkdown() {
        index.exportMarkdown(session) { markdown in
            MainActor.assumeIsolated {
                guard let markdown else {
                    Self.alert(title: L("claudecode.sessions.exportFailed"), message: "")
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                panel.nameFieldStringValue = Self.safeFileName(session.title) + ".md"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try markdown.data(using: .utf8)?.write(to: url)
                } catch {
                    Self.alert(title: L("claudecode.sessions.exportFailed"), message: "")
                }
            }
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = L("claudecode.sessions.deleteConfirm.title")
        alert.informativeText = L("claudecode.sessions.deleteConfirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("claudecode.sessions.delete"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        index.deleteSession(session) { _ in }
    }

    /// 会话标题转为安全文件名（去路径分隔符）。
    private static func safeFileName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "session" : String(cleaned.prefix(60))
    }

    private static func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        if !message.isEmpty { alert.informativeText = message }
        alert.addButton(withTitle: L("common.ok"))
        alert.runModal()
    }
}

// MARK: - 用量 Tab

struct ClaudeUsageTab: View {
    @ObservedObject private var usage = ClaudeUsageStore.shared
    @State private var report = ClaudeUsageReport()
    @State private var loadedReport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                windowCard
                bucketTable(title: "claudecode.usage.byDay", buckets: report.byDay)
                bucketTable(title: "claudecode.usage.byProject", buckets: report.byProject)
                bucketTable(title: "claudecode.usage.byModel", buckets: report.byModel)
                ClaudeInvocationSection()
            }
            .padding(16)
        }
        .onAppear {
            if !loadedReport { reloadReport() }
        }
    }

    // MARK: 当前窗口卡片

    private var windowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("claudecode.usage.windowTitle").font(.headline)
                Spacer()
                if usage.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    usage.refresh()
                    reloadReport()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(Text("claudecode.common.refresh"))
            }
            if let window = usage.currentWindow {
                let used = window.totals.totalTokens
                let budget = UserDefaults.standard.integer(forKey: ClaudeUsageStore.budgetKey)
                if budget > 0 {
                    ProgressView(value: min(1, Double(used) / Double(budget)))
                    Text("claudecode.usage.budgetUsed \(ClaudeFormat.tokens(used)) \(ClaudeFormat.tokens(budget))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("claudecode.usage.budgetUsedNoBudget \(ClaudeFormat.tokens(used))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text("claudecode.usage.windowCost \(ClaudeFormat.cost(window.totals.costUSD))")
                    Text("claudecode.usage.resetsIn \(ClaudeFormat.countdown(window.secondsUntilReset))")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("claudecode.menu.noWindow").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 维度表

    private func bucketTable(title: LocalizedStringKey, buckets: [UsageBucket]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if buckets.isEmpty {
                Text("claudecode.usage.empty").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        usageHeaderRow
                        Divider()
                        ForEach(buckets) { bucket in
                            usageRow(bucket)
                            Divider()
                        }
                    }
                }
                if buckets.contains(where: { $0.totals.unpriced }) {
                    Text("claudecode.usage.unpricedNote").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var usageHeaderRow: some View {
        HStack(spacing: 0) {
            Text("claudecode.usage.col.name").frame(width: 160, alignment: .leading)
            Text("claudecode.usage.col.input").frame(width: 80, alignment: .trailing)
            Text("claudecode.usage.col.output").frame(width: 80, alignment: .trailing)
            Text("claudecode.usage.col.cacheWrite").frame(width: 80, alignment: .trailing)
            Text("claudecode.usage.col.cacheRead").frame(width: 80, alignment: .trailing)
            Text("claudecode.usage.col.cost").frame(width: 90, alignment: .trailing)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func usageRow(_ bucket: UsageBucket) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: bucket.label).frame(width: 160, alignment: .leading).lineLimit(1)
            Text(verbatim: ClaudeFormat.tokens(bucket.totals.input)).frame(width: 80, alignment: .trailing)
            Text(verbatim: ClaudeFormat.tokens(bucket.totals.output)).frame(width: 80, alignment: .trailing)
            Text(verbatim: ClaudeFormat.tokens(bucket.totals.cacheWrite)).frame(width: 80, alignment: .trailing)
            Text(verbatim: ClaudeFormat.tokens(bucket.totals.cacheRead)).frame(width: 80, alignment: .trailing)
            Text(verbatim: ClaudeFormat.cost(bucket.totals.costUSD)).frame(width: 90, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 3)
    }

    private func reloadReport() {
        loadedReport = true
        usage.report(days: 30) { result in
            MainActor.assumeIsolated { report = result }
        }
    }
}

// MARK: - 调用统计小节（用量 Tab 末尾）

/// 近 7 / 30 天调用统计：Skill / 斜杠命令、MCP（服务器 › 工具两级）、内置工具。
struct ClaudeInvocationSection: View {
    @State private var days = 7
    @State private var stats = ClaudeInvocationStats()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("claudecode.usage.invocations").font(.headline)
                Spacer()
                Picker("claudecode.usage.range", selection: $days) {
                    Text("claudecode.usage.range.days7").tag(7)
                    Text("claudecode.usage.range.days30").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            countTable(title: "claudecode.usage.inv.skills", counts: stats.skills)
            mcpTable
            countTable(title: "claudecode.usage.inv.builtin", counts: stats.builtin)
        }
        .onAppear {
            if !loaded { reload() }
        }
        .onChange(of: days) { _, _ in reload() }
    }

    /// 单级计数表（名称 → 次数），按次数降序。
    private func countTable(title: LocalizedStringKey, counts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            let sorted = counts.sorted { $0.value > $1.value }
            if sorted.isEmpty {
                Text("claudecode.usage.inv.empty").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(sorted, id: \.key) { name, count in
                    HStack {
                        Text(verbatim: name).lineLimit(1)
                        Spacer()
                        Text("claudecode.usage.inv.count \(count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    /// MCP 两级表：服务器（总次数）展开 → 各工具次数。
    private var mcpTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("claudecode.usage.inv.mcp").font(.subheadline.bold())
            let servers = stats.mcp.values.sorted { $0.total > $1.total }
            if servers.isEmpty {
                Text("claudecode.usage.inv.empty").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(servers, id: \.server) { server in
                    DisclosureGroup {
                        ForEach(server.tools.sorted { $0.value > $1.value }, id: \.key) { tool, count in
                            HStack {
                                Text(verbatim: tool).font(.caption).lineLimit(1)
                                Spacer()
                                Text("claudecode.usage.inv.count \(count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 12)
                        }
                    } label: {
                        HStack {
                            Text(verbatim: server.server).lineLimit(1)
                            Spacer()
                            Text("claudecode.usage.inv.count \(server.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func reload() {
        loaded = true
        ClaudeUsageStore.shared.invocationStats(days: days) { result in
            MainActor.assumeIsolated { stats = result }
        }
    }
}

// MARK: - 审计 Tab

struct ClaudeAuditTab: View {
    @State private var day = Date()
    @State private var projects: [ClaudeAuditProject] = []
    @State private var loading = false
    @State private var loadedOnce = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DatePicker("claudecode.audit.date", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                if loading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(Text("claudecode.common.refresh"))
            }
            .padding(10)
            Divider()

            if !loading && projects.isEmpty {
                Spacer()
                Text("claudecode.audit.empty").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(projects) { project in
                        Section {
                            ForEach(project.entries) { entry in
                                auditRow(entry)
                            }
                        } header: {
                            HStack {
                                Text(verbatim: project.projectName)
                                Spacer()
                                Text("claudecode.audit.projectCount \(project.totalCount)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear {
            if !loadedOnce { reload() }
        }
        .onChange(of: day) { _, _ in reload() }
    }

    private func auditRow(_ entry: ClaudeAuditEntry) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.filePath)])
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: URL(fileURLWithPath: entry.filePath).lastPathComponent)
                        .lineLimit(1)
                    Text(verbatim: entry.filePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("claudecode.audit.entryCount \(entry.count)")
                        .font(.caption.monospacedDigit())
                    Text(verbatim: ClaudeFormat.relative(entry.lastEdited))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(Text("claudecode.audit.reveal"))
    }

    private func reload() {
        loadedOnce = true
        loading = true
        ClaudeSessionIndex.shared.auditEntries(on: day) { result in
            MainActor.assumeIsolated {
                projects = result
                loading = false
            }
        }
    }
}
