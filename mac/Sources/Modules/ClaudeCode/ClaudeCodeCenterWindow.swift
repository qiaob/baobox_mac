import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Claude Code 助手 —— 中心窗口：会话浏览 / 用量报表 / 改动审计三 Tab，及其窗口控制器。
///
/// 控制器仿 `SettingsWindowController`（NSWindow + NSHostingController，
/// `isReleasedWhenClosed = false`，`show(tab:)` 定位到指定页）。尺寸 720×480，可缩放。
/// 所有重 IO 走核心层单例的后台接口，完成回主线程；视图层只做展示与交互。

// MARK: - 共享格式化

/// 模块内共享的展示格式化（费用 `$%.2f`、token ≥1000 记 `%.1fk` / ≥100 万记 `%.1fM`、倒计时、字节）。
enum ClaudeFormat {

    /// 费用统一 `$%.2f`（处处标「估算」由文案负责）。
    static func cost(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// token 数：≥100 万记 `%.1fM`，≥1000 记 `%.1fk`，否则原样。
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
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

    /// 长倒计时（跨度可到「天」，供周窗口用）：≥24h 显示本地化的「N 天 M 小时」，<24h 沿用 `countdown`。
    static func countdownLong(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        guard days > 0 else { return countdown(seconds) }
        let hours = (total % 86_400) / 3600
        return L("claudecode.usage.countdown.dayHour \(days) \(hours)")
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

// MARK: - 卡片容器

/// 中心窗口统一卡片：内边距 + 圆角控件底色，撑满可用宽度。
private extension View {
    func centerCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
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
                .alternatingRowBackgrounds(.enabled)
            }
        }
    }
}

/// 单条会话行：标题 + 元信息（沿用会话行方案格式），操作按钮悬停浮现，
/// 双击续接，右键菜单提供全部操作。
private struct ClaudeSessionRow: View {
    let session: ClaudeSessionSummary
    @ObservedObject private var index = ClaudeSessionIndex.shared
    @ObservedObject private var format = SessionRowFormatStore.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: session.title)
                    .lineLimit(1)
                Text(verbatim: format.metadataLine(for: session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if hovering {
                actionButtons
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(TapGesture(count: 2).onEnded { resume() })
        .contextMenu { menuItems }
        .help(Text("claudecode.sessions.rowHint"))
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            iconButton("terminal", help: "claudecode.sessions.resume") { resume() }
            iconButton("doc.on.doc", help: "claudecode.sessions.copyCommand") { copyResumeCommand() }
            iconButton("square.and.arrow.up", help: "claudecode.sessions.export") { exportMarkdown() }
            Button(role: .destructive) {
                confirmDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(Text("claudecode.sessions.delete"))
        }
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(Text(help))
    }

    @ViewBuilder
    private var menuItems: some View {
        Button { resume() } label: { Label("claudecode.sessions.resume", systemImage: "terminal") }
        Button { copyResumeCommand() } label: { Label("claudecode.sessions.copyCommand", systemImage: "doc.on.doc") }
        Button { exportMarkdown() } label: { Label("claudecode.sessions.export", systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive) { confirmDelete() } label: { Label("claudecode.sessions.delete", systemImage: "trash") }
    }

    private func resume() {
        TerminalLauncher.resume(sessionID: session.id, in: session.projectPath)
    }

    private func copyResumeCommand() {
        let command = TerminalLauncher.resumeCommandString(sessionID: session.id, in: session.projectPath)
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
    @State private var dimension = UsageDimension.day
    // 周窗口口径与锚点(驱动周卡片标注与脚注即时刷新)。
    @AppStorage(ClaudeUsageStore.weeklyFixedKey) private var weeklyFixed = false
    @AppStorage(ClaudeUsageStore.weeklyWeekdayKey) private var weeklyWeekday = 2
    @AppStorage(ClaudeUsageStore.weeklyHourKey) private var weeklyHour = 0

    /// 明细表维度（按天 / 按项目 / 按模型），单表切换代替三张长表堆叠。
    private enum UsageDimension: String, CaseIterable, Identifiable {
        case day, project, model
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .day: return "claudecode.usage.dim.day"
            case .project: return "claudecode.usage.dim.project"
            case .model: return "claudecode.usage.dim.model"
            }
        }

        var columnTitle: LocalizedStringKey {
            switch self {
            case .day: return "claudecode.usage.col.date"
            case .project: return "claudecode.usage.col.project"
            case .model: return "claudecode.usage.col.model"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                windowCard
                weeklyWindowCard
                detailCard
                if !weeklyFixed, let week = usage.weeklyWindow {
                    Text("claudecode.usage.weekFootnote \(ClaudeFormat.tokens(week.totals.totalTokens)) \(ClaudeFormat.cost(week.totals.costUSD))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ClaudeInvocationSection()
                    .centerCard()
            }
            .padding(16)
        }
        .onAppear {
            if !loadedReport { reloadReport() }
        }
    }

    // MARK: 当前窗口卡片

    private var windowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                HStack(alignment: .firstTextBaseline, spacing: 32) {
                    metric(value: ClaudeFormat.tokens(window.totals.totalTokens),
                           label: "claudecode.usage.metric.used")
                    metric(value: ClaudeFormat.cost(window.totals.costUSD),
                           label: "claudecode.usage.metric.cost")
                    metric(value: ClaudeFormat.countdown(window.secondsUntilReset),
                           label: "claudecode.usage.metric.reset")
                }
                let budget = UserDefaults.standard.integer(forKey: ClaudeUsageStore.budgetKey)
                if budget > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: min(1, Double(window.totals.totalTokens) / Double(budget)))
                        Text("claudecode.usage.budgetUsed \(ClaudeFormat.tokens(window.totals.totalTokens)) \(ClaudeFormat.tokens(budget))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("claudecode.menu.noWindow").foregroundStyle(.secondary)
            }
        }
        .centerCard()
    }

    private func metric(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 本周窗口卡片

    private var weeklyWindowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("claudecode.usage.weekCard.title").font(.headline)
                Spacer()
                // 右上角标注当前口径：滚动 7 天 or 固定重置（周几 hh:00）。
                if weeklyFixed {
                    Text("claudecode.usage.weekCard.fixed \(weekAnchorDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("claudecode.usage.weekCard.rolling")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let window = usage.weeklyWindow {
                HStack(alignment: .firstTextBaseline, spacing: 32) {
                    metric(value: ClaudeFormat.tokens(window.totals.totalTokens),
                           label: "claudecode.usage.metric.used")
                    metric(value: ClaudeFormat.cost(window.totals.costUSD),
                           label: "claudecode.usage.metric.cost")
                    metric(value: ClaudeFormat.countdownLong(window.secondsUntilReset),
                           label: "claudecode.usage.metric.reset")
                }
                let budget = UserDefaults.standard.integer(forKey: ClaudeUsageStore.weeklyBudgetKey)
                if budget > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: min(1, Double(window.totals.totalTokens) / Double(budget)))
                        Text("claudecode.usage.budgetUsed \(ClaudeFormat.tokens(window.totals.totalTokens)) \(ClaudeFormat.tokens(budget))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("claudecode.menu.noWeekWindow").foregroundStyle(.secondary)
            }
        }
        .centerCard()
    }

    /// 固定锚点描述，如「周三 09:00」（本地化 standalone 星期名 + hh:00）。
    private var weekAnchorDescription: String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        let symbols = formatter.standaloneWeekdaySymbols ?? []
        let index = weeklyWeekday - 1
        let name = symbols.indices.contains(index) ? symbols[index] : "\(weeklyWeekday)"
        return String(format: "%@ %02d:00", name, weeklyHour)
    }

    // MARK: 明细表（维度切换）

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("claudecode.usage.detail").font(.headline)
                Spacer()
                Picker("claudecode.usage.detail", selection: $dimension) {
                    ForEach(UsageDimension.allCases) { dim in
                        Text(dim.label).tag(dim)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            let buckets = buckets(for: dimension)
            if buckets.isEmpty {
                Text("claudecode.usage.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                bucketTable(buckets)
                if buckets.contains(where: { $0.totals.unpriced }) {
                    Text("claudecode.usage.unpricedNote")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .centerCard()
    }

    private func buckets(for dimension: UsageDimension) -> [UsageBucket] {
        switch dimension {
        case .day: return report.byDay
        case .project: return report.byProject
        case .model: return report.byModel
        }
    }

    private func bucketTable(_ buckets: [UsageBucket]) -> some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                usageRow(label: bucket.label, totals: bucket.totals, emphasized: false)
                    .background(
                        index.isMultiple(of: 2)
                            ? Color.clear
                            : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
            Divider()
            usageRow(label: L("claudecode.usage.total"), totals: summed(buckets), emphasized: true)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text(dimension.columnTitle)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            Text("claudecode.usage.col.input").frame(width: 80, alignment: .trailing)
            Text("claudecode.usage.col.output").frame(width: 80, alignment: .trailing)
            Text("claudecode.usage.col.cacheWrite").frame(width: 80, alignment: .trailing)
            Text("claudecode.usage.col.cacheRead").frame(width: 80, alignment: .trailing)
            Text("claudecode.usage.col.cost").frame(width: 96, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private func usageRow(label: String, totals: UsageTotals, emphasized: Bool) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: label)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: ClaudeFormat.tokens(totals.input)).frame(width: 80, alignment: .trailing)
            Text(verbatim: ClaudeFormat.tokens(totals.output)).frame(width: 80, alignment: .trailing)
            Text(verbatim: ClaudeFormat.tokens(totals.cacheWrite)).frame(width: 80, alignment: .trailing)
            Text(verbatim: ClaudeFormat.tokens(totals.cacheRead)).frame(width: 80, alignment: .trailing)
            Text(verbatim: ClaudeFormat.cost(totals.costUSD)).frame(width: 96, alignment: .trailing)
        }
        .font(emphasized ? .callout.weight(.semibold).monospacedDigit() : .callout.monospacedDigit())
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }

    private func summed(_ buckets: [UsageBucket]) -> UsageTotals {
        var total = UsageTotals()
        for bucket in buckets {
            total.input += bucket.totals.input
            total.output += bucket.totals.output
            total.cacheWrite += bucket.totals.cacheWrite
            total.cacheRead += bucket.totals.cacheRead
            total.costUSD += bucket.totals.costUSD
            total.unpriced = total.unpriced || bucket.totals.unpriced
        }
        return total
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
/// 三组均整条可点折叠，标题右侧带总次数。
struct ClaudeInvocationSection: View {
    @State private var days = 7
    @State private var stats = ClaudeInvocationStats()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("claudecode.usage.invocations").font(.headline)
                Spacer()
                Picker("claudecode.usage.range", selection: $days) {
                    Text("claudecode.usage.range.days7").tag(7)
                    Text("claudecode.usage.range.days30").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            countGroup(title: "claudecode.usage.inv.skills", counts: stats.skills)
            mcpGroup
            countGroup(title: "claudecode.usage.inv.builtin", counts: stats.builtin)
        }
        .onAppear {
            if !loaded { reload() }
        }
        .onChange(of: days) { _, _ in reload() }
    }

    /// 单级计数组（名称 → 次数），按次数降序，整组可折叠（默认收起，标题带总次数）。
    private func countGroup(title: LocalizedStringKey, counts: [String: Int]) -> some View {
        let sorted = counts.sorted { $0.value > $1.value }
        return TappableDisclosure {
            if sorted.isEmpty {
                emptyHint
            } else {
                VStack(spacing: 0) {
                    ForEach(sorted, id: \.key) { name, count in
                        countRow(name: name, count: count)
                    }
                }
            }
        } label: {
            groupLabel(title: title, total: counts.values.reduce(0, +))
        }
    }

    /// MCP 两级组：服务器（总次数，可折叠）展开 → 各工具次数。默认收起。
    private var mcpGroup: some View {
        let servers = stats.mcp.values.sorted { $0.total > $1.total }
        return TappableDisclosure {
            if servers.isEmpty {
                emptyHint
            } else {
                VStack(spacing: 0) {
                    ForEach(servers, id: \.server) { server in
                        TappableDisclosure {
                            ForEach(server.tools.sorted { $0.value > $1.value }, id: \.key) { tool, count in
                                countRow(name: tool, count: count)
                                    .padding(.leading, 12)
                            }
                        } label: {
                            HStack {
                                Text(verbatim: server.server).font(.callout).lineLimit(1)
                                Spacer()
                                Text("claudecode.usage.inv.count \(server.total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } label: {
            groupLabel(title: "claudecode.usage.inv.mcp",
                       total: servers.reduce(0) { $0 + $1.total })
        }
    }

    private func groupLabel(title: LocalizedStringKey, total: Int) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text("claudecode.usage.inv.count \(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func countRow(name: String, count: Int) -> some View {
        HStack {
            Text(verbatim: name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("claudecode.usage.inv.count \(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var emptyHint: some View {
        Text("claudecode.usage.inv.empty")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                if !projects.isEmpty {
                    Text("claudecode.audit.summary \(projects.count) \(projects.reduce(0) { $0 + $1.totalCount })")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(projects) { project in
                            ClaudeAuditProjectGroup(project: project)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear {
            if !loadedOnce { reload() }
        }
        .onChange(of: day) { _, _ in reload() }
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

/// 审计页单个项目卡片：整条标题可点折叠，内容为该项目当日的文件改动行。
private struct ClaudeAuditProjectGroup: View {
    let project: ClaudeAuditProject

    var body: some View {
        TappableDisclosure(initiallyExpanded: true) {
            VStack(spacing: 1) {
                ForEach(project.entries) { entry in
                    ClaudeAuditEntryRow(entry: entry)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(verbatim: project.projectName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text("claudecode.audit.projectCount \(project.totalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// 审计文件行：文件名 + 全路径 + 次数/时间，悬停高亮，点击在访达中显示。
private struct ClaudeAuditEntryRow: View {
    let entry: ClaudeAuditEntry
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.filePath)])
        } label: {
            HStack(spacing: 8) {
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
                    .opacity(hovering ? 1 : 0.35)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Color.primary.opacity(0.05) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .help(Text("claudecode.audit.reveal"))
    }
}
