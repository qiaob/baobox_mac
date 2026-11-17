import AppKit
import SwiftUI

/// Codex 助手 —— 中心窗口：会话浏览 / 用量报表两 Tab，及其窗口控制器。
///
/// 仿 `ClaudeCodeCenterController`（NSWindow + NSHostingController，`isReleasedWhenClosed = false`，
/// `show(tab:)` 定位到指定页）但**独立实现、不跨模块依赖 Claude 内部类型**。尺寸 720×480，可缩放。
/// 所有重 IO 走核心层单例的后台接口，完成回主线程；视图层只做展示与交互。

// MARK: - 共享格式化

/// 模块内共享的展示格式化（费用 `$%.2f`、token 缩写、倒计时、字节、相对时间、星期名）。
/// 实现在 Core 的 `CLIFormat`（与 Claude Code 助手共用，#164）；这里只给 Codex 自己的「N 天 M 小时」文案 key 与界面语言。
enum AIToolsFormatLocalization: CLIFormatLocalization {
    static func dayHour(days: Int, hours: Int) -> String { L("aitools.usage.countdown.dayHour \(days) \(hours)") }
    static var locale: Locale { L10n.locale }
}

typealias AIToolsFormat = CLIFormat<AIToolsFormatLocalization>

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
            // 要拿焦点的普通窗口：在桌面空间建，不叠进别的 App 的全屏空间（见 mac/CLAUDE.md「普通窗口与全屏空间」，#181）。
            let created = DesktopSpaceWindow.make { NSWindow(contentViewController: hosting) }
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

/// 会话页：实现在 Core 的 `CLISessionsPage`（与 Claude Code 助手共用，#164 PR3），这里只给数据源与文案。
struct AIToolsSessionsTab: View {
    private static let strings = CLISessionsPageStrings(
        search: "aitools.sessions.search",
        empty: "aitools.sessions.empty",
        refreshHelp: "aitools.common.refresh",
        rowHint: "aitools.sessions.rowHint",
        resume: "aitools.sessions.resume",
        copyCommand: "aitools.sessions.copyCommand",
        export: "aitools.sessions.export",
        delete: "aitools.sessions.delete",
        exportFailed: L("aitools.sessions.exportFailed"),
        deleteConfirmTitle: L("aitools.sessions.deleteConfirm.title"),
        deleteConfirmMessage: L("aitools.sessions.deleteConfirm.message"),
        deleteButton: L("aitools.sessions.delete"),
        exportFileFallback: "codex-session"
    )

    var body: some View {
        CLISessionsPage(index: CodexSessionIndex.shared, source: CodexSessionSource(), strings: Self.strings)
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
        AIToolsFormat.weekAnchor(weekday: weeklyWeekday, hour: weeklyHour)
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
