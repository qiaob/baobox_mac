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

/// 用量页：5 小时卡、周卡、明细表、调用统计。卡片、指标、预算条、周标注、明细表、调用统计的分组是与 Claude Code 助手
/// 共用的部件（`Core/CLICenter/CLIUsageViews.swift`，#164 PR5），这里定卡片的组合与顺序、文案与明细表的列。
struct AIToolsUsageTab: View {
    @ObservedObject private var usage = CodexUsageStore.shared
    @State private var report = CodexUsageReport()
    @State private var loadedReport = false
    @State private var dimension = CLIUsageDimension.day
    @AppStorage(CodexUsageStore.weeklyFixedKey) private var weeklyFixed = false
    @AppStorage(CodexUsageStore.weeklyWeekdayKey) private var weeklyWeekday = 2
    @AppStorage(CodexUsageStore.weeklyHourKey) private var weeklyHour = 0

    /// 明细表的列：输入 / 缓存输入 / 输出（宽 90）、费用（宽 96）。Codex 的输入已含缓存输入。
    private static let columns: [CLIUsageColumn<CodexPricingTable>] = [
        CLIUsageColumn(title: "aitools.usage.col.input", width: 90) { AIToolsFormat.tokens($0.input) },
        CLIUsageColumn(title: "aitools.usage.col.cachedInput", width: 90) { AIToolsFormat.tokens($0.cachedInput) },
        CLIUsageColumn(title: "aitools.usage.col.output", width: 90) { AIToolsFormat.tokens($0.output) },
        CLIUsageColumn(title: "aitools.usage.col.cost", width: 96) { AIToolsFormat.cost($0.costUSD) },
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                fiveHourCard
                weeklyWindowCard
                detailCard
                AIToolsInvocationSection()
                    .cliCenterCard()
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
                CLIUsageRefreshControl(isRefreshing: usage.isRefreshing, help: "aitools.common.refresh") {
                    usage.refresh()
                    reloadReport()
                }
            }
            if let window = usage.fiveHourWindow {
                metricsRow(window: window)
                budgetBar(window: window, budgetKey: CodexUsageStore.budgetKey)
            } else {
                Text("aitools.menu.noWindow").foregroundStyle(.secondary)
            }
        }
        .cliCenterCard()
    }

    // MARK: 本周窗口卡片

    private var weeklyWindowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("aitools.usage.weekCard.title").font(.headline)
                Spacer()
                CLIUsageWeekBadge(fixed: weeklyFixed,
                                  fixedText: Text("aitools.usage.weekCard.fixed \(weekAnchorDescription)"),
                                  rollingText: "aitools.usage.weekCard.rolling")
            }
            if let window = usage.weeklyWindow {
                metricsRow(window: window, longCountdown: true)
                budgetBar(window: window, budgetKey: CodexUsageStore.weeklyBudgetKey)
            } else {
                Text("aitools.menu.noWeekWindow").foregroundStyle(.secondary)
            }
        }
        .cliCenterCard()
    }

    private func metricsRow(window: CodexUsageWindow, longCountdown: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 32) {
            CLIUsageMetric(value: AIToolsFormat.tokens(window.totals.totalTokens),
                           label: "aitools.usage.metric.used")
            CLIUsageMetric(value: AIToolsFormat.cost(window.totals.costUSD),
                           label: "aitools.usage.metric.cost")
            CLIUsageMetric(value: longCountdown ? AIToolsFormat.countdownLong(window.secondsUntilReset)
                                                : AIToolsFormat.countdown(window.secondsUntilReset),
                           label: "aitools.usage.metric.reset")
        }
    }

    private func budgetBar(window: CodexUsageWindow, budgetKey: String) -> some View {
        let budget = UserDefaults.standard.integer(forKey: budgetKey)
        return CLIUsageBudgetBar(
            used: window.totals.totalTokens, budget: budget,
            caption: Text("aitools.usage.budgetUsed \(AIToolsFormat.tokens(window.totals.totalTokens)) \(AIToolsFormat.tokens(budget))")
        )
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
                    ForEach(CLIUsageDimension.allCases, id: \.self) { dim in
                        Text(dim.label).tag(dim)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            let buckets = dimension.buckets(of: report)
            if buckets.isEmpty {
                Text("aitools.usage.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                CLIUsageBucketTable(buckets: buckets, firstColumn: dimension.columnTitle,
                                    columns: Self.columns, totalLabel: L("aitools.usage.total"))
                if buckets.contains(where: { $0.totals.unpriced }) {
                    Text("aitools.usage.unpricedNote")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cliCenterCard()
    }

    private func reloadReport() {
        loadedReport = true
        usage.report(days: 30) { result in
            MainActor.assumeIsolated { report = result }
        }
    }
}

/// 明细表维度（按天 / 按项目 / 按模型）的文案。
private extension CLIUsageDimension {
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

// MARK: - 调用统计小节（用量 Tab 末尾）

/// 近 7 / 30 天调用统计：内置工具、MCP（服务器 › 工具两级）。整组可折叠，标题右侧带总次数
/// （分组视图与 Claude Code 助手共用，`CLIInvocationCountGroup` / `CLIInvocationMCPGroup`）。
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

            CLIInvocationCountGroup(title: "aitools.usage.inv.builtin", counts: stats.builtin,
                                    count: Self.count, empty: "aitools.usage.inv.empty")
            CLIInvocationMCPGroup(title: "aitools.usage.inv.mcp", servers: stats.mcp,
                                  count: Self.count, empty: "aitools.usage.inv.empty")
        }
        .onAppear {
            if !loaded { reload() }
        }
        .onChange(of: days) { _, _ in reload() }
    }

    /// 「N 次」。
    nonisolated private static func count(_ times: Int) -> Text {
        Text("aitools.usage.inv.count \(times)")
    }

    private func reload() {
        loaded = true
        CodexUsageStore.shared.invocationStats(days: days) { result in
            MainActor.assumeIsolated { stats = result }
        }
    }
}
