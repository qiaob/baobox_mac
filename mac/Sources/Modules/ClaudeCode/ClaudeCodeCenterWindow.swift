import AppKit
import SwiftUI

/// Claude Code 助手 —— 中心窗口：会话浏览 / 用量报表 / 改动审计三 Tab，及其窗口控制器。
///
/// 控制器仿 `SettingsWindowController`（NSWindow + NSHostingController，
/// `isReleasedWhenClosed = false`，`show(tab:)` 定位到指定页）。尺寸 720×480，可缩放。
/// 所有重 IO 走核心层单例的后台接口，完成回主线程；视图层只做展示与交互。

// MARK: - 共享格式化

/// 模块内共享的展示格式化（费用 `$%.2f`、token ≥1000 记 `%.1fk` / ≥100 万记 `%.1fM`、倒计时、字节、相对时间、星期名）。
/// 实现在 Core 的 `CLIFormat`（与 Codex 助手共用，#164）；这里只给 Claude 自己的「N 天 M 小时」文案 key 与界面语言。
enum ClaudeFormatLocalization: CLIFormatLocalization {
    static func dayHour(days: Int, hours: Int) -> String { L("claudecode.usage.countdown.dayHour \(days) \(hours)") }
    static var locale: Locale { L10n.locale }
}

typealias ClaudeFormat = CLIFormat<ClaudeFormatLocalization>

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
            // 要拿焦点的普通窗口：在桌面空间建，不叠进别的 App 的全屏空间（见 mac/CLAUDE.md「普通窗口与全屏空间」，#181）。
            let created = DesktopSpaceWindow.make { NSWindow(contentViewController: hosting) }
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

/// 会话页：实现在 Core 的 `CLISessionsPage`（与 Codex 助手共用，#164 PR3），这里只给数据源与文案。
/// 观察会话行方案：设置里一换方案就重建页面，第二行跟着变（页面里的 `renderToken` 保证不被跳过）。
struct ClaudeSessionsTab: View {
    @ObservedObject private var format = SessionRowFormatStore.shared

    private static let strings = CLISessionsPageStrings(
        search: "claudecode.sessions.search",
        empty: "claudecode.sessions.empty",
        refreshHelp: "claudecode.common.refresh",
        rowHint: "claudecode.sessions.rowHint",
        resume: "claudecode.sessions.resume",
        copyCommand: "claudecode.sessions.copyCommand",
        export: "claudecode.sessions.export",
        delete: "claudecode.sessions.delete",
        exportFailed: L("claudecode.sessions.exportFailed"),
        deleteConfirmTitle: L("claudecode.sessions.deleteConfirm.title"),
        deleteConfirmMessage: L("claudecode.sessions.deleteConfirm.message"),
        deleteButton: L("claudecode.sessions.delete"),
        exportFileFallback: "session"
    )

    var body: some View {
        CLISessionsPage(index: ClaudeSessionIndex.shared, source: ClaudeSessionSource(), strings: Self.strings)
    }
}

// MARK: - 用量 Tab

/// 用量页：5 小时卡、周卡、明细表、周脚注（只有 Claude 有）、调用统计。卡片、指标、预算条、周标注、明细表、调用统计的分组
/// 是与 Codex 助手共用的部件（`Core/CLICenter/CLIUsageViews.swift`，#164 PR5），这里定卡片的组合与顺序、文案与明细表的列。
struct ClaudeUsageTab: View {
    @ObservedObject private var usage = ClaudeUsageStore.shared
    @State private var report = ClaudeUsageReport()
    @State private var loadedReport = false
    @State private var dimension = CLIUsageDimension.day
    // 周窗口口径与锚点(驱动周卡片标注与脚注即时刷新)。
    @AppStorage(ClaudeUsageStore.weeklyFixedKey) private var weeklyFixed = false
    @AppStorage(ClaudeUsageStore.weeklyWeekdayKey) private var weeklyWeekday = 2
    @AppStorage(ClaudeUsageStore.weeklyHourKey) private var weeklyHour = 0

    /// 明细表的列：输入 / 输出 / 缓存写 / 缓存读（宽 80）、费用（宽 96）。
    private static let columns: [CLIUsageColumn<ClaudePricingTable>] = [
        CLIUsageColumn(title: "claudecode.usage.col.input", width: 80) { ClaudeFormat.tokens($0.input) },
        CLIUsageColumn(title: "claudecode.usage.col.output", width: 80) { ClaudeFormat.tokens($0.output) },
        CLIUsageColumn(title: "claudecode.usage.col.cacheWrite", width: 80) { ClaudeFormat.tokens($0.cacheWrite) },
        CLIUsageColumn(title: "claudecode.usage.col.cacheRead", width: 80) { ClaudeFormat.tokens($0.cacheRead) },
        CLIUsageColumn(title: "claudecode.usage.col.cost", width: 96) { ClaudeFormat.cost($0.costUSD) },
    ]

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
                    .cliCenterCard()
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
                CLIUsageRefreshControl(isRefreshing: usage.isRefreshing, help: "claudecode.common.refresh") {
                    usage.refresh()
                    reloadReport()
                }
            }
            if let window = usage.fiveHourWindow {
                HStack(alignment: .firstTextBaseline, spacing: 32) {
                    CLIUsageMetric(value: ClaudeFormat.tokens(window.totals.totalTokens),
                                   label: "claudecode.usage.metric.used")
                    CLIUsageMetric(value: ClaudeFormat.cost(window.totals.costUSD),
                                   label: "claudecode.usage.metric.cost")
                    CLIUsageMetric(value: ClaudeFormat.countdown(window.secondsUntilReset),
                                   label: "claudecode.usage.metric.reset")
                }
                budgetBar(window: window, budgetKey: ClaudeUsageStore.budgetKey)
            } else {
                Text("claudecode.menu.noWindow").foregroundStyle(.secondary)
            }
        }
        .cliCenterCard()
    }

    private func budgetBar(window: UsageWindow, budgetKey: String) -> some View {
        let budget = UserDefaults.standard.integer(forKey: budgetKey)
        return CLIUsageBudgetBar(
            used: window.totals.totalTokens, budget: budget,
            caption: Text("claudecode.usage.budgetUsed \(ClaudeFormat.tokens(window.totals.totalTokens)) \(ClaudeFormat.tokens(budget))")
        )
    }

    // MARK: 本周窗口卡片

    private var weeklyWindowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("claudecode.usage.weekCard.title").font(.headline)
                Spacer()
                // 右上角标注当前口径：滚动 7 天 or 固定重置（周几 hh:00）。
                CLIUsageWeekBadge(fixed: weeklyFixed,
                                  fixedText: Text("claudecode.usage.weekCard.fixed \(weekAnchorDescription)"),
                                  rollingText: "claudecode.usage.weekCard.rolling")
            }
            if let window = usage.weeklyWindow {
                HStack(alignment: .firstTextBaseline, spacing: 32) {
                    CLIUsageMetric(value: ClaudeFormat.tokens(window.totals.totalTokens),
                                   label: "claudecode.usage.metric.used")
                    CLIUsageMetric(value: ClaudeFormat.cost(window.totals.costUSD),
                                   label: "claudecode.usage.metric.cost")
                    CLIUsageMetric(value: ClaudeFormat.countdownLong(window.secondsUntilReset),
                                   label: "claudecode.usage.metric.reset")
                }
                budgetBar(window: window, budgetKey: ClaudeUsageStore.weeklyBudgetKey)
            } else {
                Text("claudecode.menu.noWeekWindow").foregroundStyle(.secondary)
            }
        }
        .cliCenterCard()
    }

    /// 固定锚点描述，如「周三 09:00」（本地化 standalone 星期名 + hh:00）。
    private var weekAnchorDescription: String {
        ClaudeFormat.weekAnchor(weekday: weeklyWeekday, hour: weeklyHour)
    }

    // MARK: 明细表（维度切换）

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("claudecode.usage.detail").font(.headline)
                Spacer()
                Picker("claudecode.usage.detail", selection: $dimension) {
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
                Text("claudecode.usage.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                CLIUsageBucketTable(buckets: buckets, firstColumn: dimension.columnTitle,
                                    columns: Self.columns, totalLabel: L("claudecode.usage.total"))
                if buckets.contains(where: { $0.totals.unpriced }) {
                    Text("claudecode.usage.unpricedNote")
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

/// 明细表维度（按天 / 按项目 / 按模型）的文案，单表切换代替三张长表堆叠。
private extension CLIUsageDimension {
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

// MARK: - 调用统计小节（用量 Tab 末尾）

/// 近 7 / 30 天调用统计：Skill / 斜杠命令、MCP（服务器 › 工具两级）、内置工具。
/// 三组均整条可点折叠，标题右侧带总次数（分组视图与 Codex 助手共用，`CLIInvocationCountGroup` / `CLIInvocationMCPGroup`）。
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

            CLIInvocationCountGroup(title: "claudecode.usage.inv.skills", counts: stats.skills,
                                    count: Self.count, empty: "claudecode.usage.inv.empty")
            CLIInvocationMCPGroup(title: "claudecode.usage.inv.mcp", servers: stats.mcp,
                                  count: Self.count, empty: "claudecode.usage.inv.empty")
            CLIInvocationCountGroup(title: "claudecode.usage.inv.builtin", counts: stats.builtin,
                                    count: Self.count, empty: "claudecode.usage.inv.empty")
        }
        .onAppear {
            if !loaded { reload() }
        }
        .onChange(of: days) { _, _ in reload() }
    }

    /// 「N 次」。
    nonisolated private static func count(_ times: Int) -> Text {
        Text("claudecode.usage.inv.count \(times)")
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
