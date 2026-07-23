import AppKit
import SwiftUI

/// Codex 助手 —— 中心窗口：会话浏览 / 用量报表两 Tab，及其窗口控制器。
///
/// 仿 `ClaudeCodeCenterController`（NSWindow + NSHostingController，`isReleasedWhenClosed = false`，
/// `show(tab:)` 定位到指定页）但**独立实现、不跨模块依赖 Claude 内部类型**。尺寸 720×480，可缩放。
/// 所有重 IO 走核心层单例的后台接口，完成回主线程；视图层只做展示与交互。

// MARK: - 共享格式化

/// 模块内共享的展示格式化（费用 `$%.2f`、token 缩写、倒计时、字节、相对时间）。
enum AIToolsFormat {

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
        return L("aitools.usage.countdown.dayHour \(days) \(hours)")
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

/// Codex 续接命令构造（供窗口与复制按钮共用）。
enum CodexResumeCommand {
    /// 终端执行的续接命令：`codex resume <id>`。
    static func command(sessionID: String) -> String {
        let bin = CodexEnv.findCodexBinary()
        return "\(CodexEnv.shellQuote(bin)) resume \(CodexEnv.shellQuote(sessionID))"
    }

    /// 供「复制命令」用：附带 cd 到项目目录。
    static func fullCommand(sessionID: String, cwd: String) -> String {
        let resume = command(sessionID: sessionID)
        guard !cwd.isEmpty else { return resume }
        return "cd \(CodexEnv.shellQuote(cwd)) && \(resume)"
    }
}

extension CodexEnv {
    /// 单引号安全包裹（供命令拼接）。独立于 ClaudeEnv 以免耦合。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 卡片容器

private extension View {
    func centerCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Tab 定位

enum AIToolsCenterTab: String {
    case sessions
    case usage
}

@MainActor
final class AIToolsCenterTabSelection: ObservableObject {
    static let shared = AIToolsCenterTabSelection()
    @Published var selectedTab: String = AIToolsCenterTab.sessions.rawValue
    private init() {}
}

// MARK: - 窗口控制器

/// 中心窗口控制器（单例）。自持窗口，关闭后复用同一实例。
@MainActor
final class AIToolsCenterController {
    static let shared = AIToolsCenterController()

    private var window: NSWindow?

    private init() {}

    /// 打开中心窗口并切到指定 Tab；同时触发一次索引与用量刷新。
    func show(tab: AIToolsCenterTab) {
        AIToolsCenterTabSelection.shared.selectedTab = tab.rawValue

        if window == nil {
            let hosting = NSHostingController(rootView: AIToolsCenterView())
            let created = NSWindow(contentViewController: hosting)
            created.title = L("aitools.center.title")
            created.styleMask = [.titled, .closable, .resizable]
            created.setContentSize(NSSize(width: 720, height: 480))
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }

        CodexSessionIndex.shared.refresh()
        CodexUsageStore.shared.refresh()

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 根视图

struct AIToolsCenterView: View {
    @ObservedObject private var tabSelection = AIToolsCenterTabSelection.shared

    var body: some View {
        TabView(selection: $tabSelection.selectedTab) {
            AIToolsSessionsTab()
                .tabItem { Label("aitools.center.tab.sessions", systemImage: "clock.arrow.circlepath") }
                .tag(AIToolsCenterTab.sessions.rawValue)

            AIToolsUsageTab()
                .tabItem { Label("aitools.center.tab.usage", systemImage: "chart.bar") }
                .tag(AIToolsCenterTab.usage.rawValue)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

// MARK: - 会话 Tab

struct AIToolsSessionsTab: View {
    @ObservedObject private var index = CodexSessionIndex.shared
    @State private var query = ""

    private var filtered: [CodexSessionSummary] {
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
                TextField("aitools.sessions.search", text: $query)
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
                .help(Text("aitools.common.refresh"))
            }
            .padding(10)
            Divider()

            if filtered.isEmpty {
                Spacer()
                Text("aitools.sessions.empty")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { session in
                    AIToolsSessionRow(session: session)
                }
                .listStyle(.inset)
            }
        }
    }
}

/// 单条会话行：标题、项目、相对时间 + 操作按钮。
private struct AIToolsSessionRow: View {
    let session: CodexSessionSummary
    @ObservedObject private var index = CodexSessionIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: session.title)
                .lineLimit(1)
            HStack(spacing: 8) {
                if !session.projectName.isEmpty {
                    Text(verbatim: session.projectName)
                    Text(verbatim: "·")
                }
                Text(verbatim: AIToolsFormat.relative(session.lastActivity))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    resume()
                } label: {
                    Label("aitools.sessions.resume", systemImage: "terminal")
                }
                Button {
                    copyCommand()
                } label: {
                    Label("aitools.sessions.copyCommand", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    confirmDelete()
                } label: {
                    Label("aitools.sessions.delete", systemImage: "trash")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func resume() {
        TerminalLauncher.run(command: CodexResumeCommand.command(sessionID: session.id),
                             in: session.projectPath.isEmpty ? nil : session.projectPath)
    }

    private func copyCommand() {
        let command = CodexResumeCommand.fullCommand(sessionID: session.id, cwd: session.projectPath)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = L("aitools.sessions.deleteConfirm.title")
        alert.informativeText = L("aitools.sessions.deleteConfirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("aitools.sessions.delete"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        index.deleteSession(session) { _ in }
    }
}

// MARK: - 用量 Tab

struct AIToolsUsageTab: View {
    @ObservedObject private var usage = CodexUsageStore.shared
    @State private var report = CodexUsageReport()
    @State private var loadedReport = false
    @State private var dimension = UsageDimension.day
    @AppStorage(CodexUsageStore.weeklyFixedKey) private var weeklyFixed = false
    @AppStorage(CodexUsageStore.weeklyWeekdayKey) private var weeklyWeekday = 2
    @AppStorage(CodexUsageStore.weeklyHourKey) private var weeklyHour = 0

    /// 明细表维度（按天 / 按项目 / 按模型）。
    private enum UsageDimension: String, CaseIterable, Identifiable {
        case day, project, model
        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .day: return "aitools.usage.byDay"
            case .project: return "aitools.usage.byProject"
            case .model: return "aitools.usage.byModel"
            }
        }

        var columnTitle: LocalizedStringKey {
            switch self {
            case .day: return "aitools.usage.col.date"
            case .project: return "aitools.usage.col.project"
            case .model: return "aitools.usage.col.model"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                fiveHourCard
                weeklyWindowCard
                detailCard
                AIToolsInvocationSection()
                    .centerCard()
            }
            .padding(16)
        }
        .onAppear {
            if !loadedReport { reloadReport() }
        }
    }

    // MARK: 5 小时窗口卡片

    private var fiveHourCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("aitools.usage.fiveHourTitle").font(.headline)
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
                .help(Text("aitools.common.refresh"))
            }
            if let window = usage.fiveHourWindow {
                metricsRow(window: window)
                budgetBar(window: window, budgetKey: CodexUsageStore.budgetKey)
            } else {
                Text("aitools.menu.noWindow").foregroundStyle(.secondary)
            }
        }
        .centerCard()
    }

    // MARK: 本周窗口卡片

    private var weeklyWindowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("aitools.usage.weekCard.title").font(.headline)
                Spacer()
                if weeklyFixed {
                    Text("aitools.usage.weekCard.fixed \(weekAnchorDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("aitools.usage.weekCard.rolling")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let window = usage.weeklyWindow {
                metricsRow(window: window, longCountdown: true)
                budgetBar(window: window, budgetKey: CodexUsageStore.weeklyBudgetKey)
            } else {
                Text("aitools.menu.noWeekWindow").foregroundStyle(.secondary)
            }
        }
        .centerCard()
    }

    private func metricsRow(window: CodexUsageWindow, longCountdown: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 32) {
            metric(value: AIToolsFormat.tokens(window.totals.totalTokens),
                   label: "aitools.usage.metric.used")
            metric(value: AIToolsFormat.cost(window.totals.costUSD),
                   label: "aitools.usage.metric.cost")
            metric(value: longCountdown ? AIToolsFormat.countdownLong(window.secondsUntilReset)
                                        : AIToolsFormat.countdown(window.secondsUntilReset),
                   label: "aitools.usage.metric.reset")
        }
    }

    @ViewBuilder
    private func budgetBar(window: CodexUsageWindow, budgetKey: String) -> some View {
        let budget = UserDefaults.standard.integer(forKey: budgetKey)
        if budget > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: min(1, Double(window.totals.totalTokens) / Double(budget)))
                Text("aitools.usage.budgetUsed \(AIToolsFormat.tokens(window.totals.totalTokens)) \(AIToolsFormat.tokens(budget))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    /// 固定锚点描述，如「周三 09:00」。
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
                Text("aitools.usage.detail").font(.headline)
                Spacer()
                Picker("aitools.usage.detail", selection: $dimension) {
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
                Text("aitools.usage.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                bucketTable(buckets)
                if buckets.contains(where: { $0.totals.unpriced }) {
                    Text("aitools.usage.unpricedNote")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .centerCard()
    }

    private func buckets(for dimension: UsageDimension) -> [CodexUsageBucket] {
        switch dimension {
        case .day: return report.byDay
        case .project: return report.byProject
        case .model: return report.byModel
        }
    }

    private func bucketTable(_ buckets: [CodexUsageBucket]) -> some View {
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
            usageRow(label: L("aitools.usage.total"), totals: summed(buckets), emphasized: true)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text(dimension.columnTitle)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            Text("aitools.usage.col.input").frame(width: 90, alignment: .trailing)
            Text("aitools.usage.col.cachedInput").frame(width: 90, alignment: .trailing)
            Text("aitools.usage.col.output").frame(width: 90, alignment: .trailing)
            Text("aitools.usage.col.cost").frame(width: 96, alignment: .trailing)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private func usageRow(label: String, totals: CodexUsageTotals, emphasized: Bool) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: label)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: AIToolsFormat.tokens(totals.input)).frame(width: 90, alignment: .trailing)
            Text(verbatim: AIToolsFormat.tokens(totals.cachedInput)).frame(width: 90, alignment: .trailing)
            Text(verbatim: AIToolsFormat.tokens(totals.output)).frame(width: 90, alignment: .trailing)
            Text(verbatim: AIToolsFormat.cost(totals.costUSD)).frame(width: 96, alignment: .trailing)
        }
        .font(emphasized ? .callout.weight(.semibold).monospacedDigit() : .callout.monospacedDigit())
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }

    private func summed(_ buckets: [CodexUsageBucket]) -> CodexUsageTotals {
        var total = CodexUsageTotals()
        for bucket in buckets {
            total.input += bucket.totals.input
            total.cachedInput += bucket.totals.cachedInput
            total.output += bucket.totals.output
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

/// 近 7 / 30 天调用统计：内置工具、MCP（服务器 › 工具两级）。整组可折叠，标题右侧带总次数。
struct AIToolsInvocationSection: View {
    @State private var days = 7
    @State private var stats = CodexInvocationStats()
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("aitools.usage.invocations").font(.headline)
                Spacer()
                Picker("aitools.usage.range", selection: $days) {
                    Text("aitools.usage.range.days7").tag(7)
                    Text("aitools.usage.range.days30").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            countGroup(title: "aitools.usage.inv.builtin", counts: stats.builtin)
            mcpGroup
        }
        .onAppear {
            if !loaded { reload() }
        }
        .onChange(of: days) { _, _ in reload() }
    }

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
                                Text("aitools.usage.inv.count \(server.total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } label: {
            groupLabel(title: "aitools.usage.inv.mcp",
                       total: servers.reduce(0) { $0 + $1.total })
        }
    }

    private func groupLabel(title: LocalizedStringKey, total: Int) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text("aitools.usage.inv.count \(total)")
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
            Text("aitools.usage.inv.count \(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var emptyHint: some View {
        Text("aitools.usage.inv.empty")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reload() {
        loaded = true
        CodexUsageStore.shared.invocationStats(days: days) { result in
            MainActor.assumeIsolated { stats = result }
        }
    }
}
