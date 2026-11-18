import SwiftUI

// 中心窗口「用量」页与调用统计的部件（#164 PR5，docs/codex-assistant/DEDUPE-P2.md §2.4 类 1、D7）：
// Claude Code 助手与 Codex 助手的用量页原来各写一份，这里只放两边逐行相同的小部件，由模块拼：
// 卡片的组合与顺序、文案（D5，各用各的 key）、明细表的列、Claude 的周脚注、调用统计几组的顺序都留在模块。
// 部件照搬原来的写法（修饰符的顺序、间距、字号一样），两个用量页逐像素不变。

extension View {
    /// 中心窗口统一卡片：内边距 14 + 圆角 10 的控件底色，撑满可用宽度。
    func cliCenterCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// 卡片标题右侧的「刷新中转圈 + 刷新按钮」。不自带容器：两样直接排进调用方的 HStack，同原来写在卡片里。
struct CLIUsageRefreshControl: View {
    private let isRefreshing: Bool
    private let help: LocalizedStringKey
    private let action: () -> Void

    init(isRefreshing: Bool, help: LocalizedStringKey, action: @escaping () -> Void) {
        self.isRefreshing = isRefreshing
        self.help = help
        self.action = action
    }

    var body: some View {
        if isRefreshing {
            ProgressView().controlSize(.small)
        }
        Button {
            action()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help(Text(help))
    }
}

/// 一项指标：大号数字 + 小号说明（已用 / 费用 / 重置倒计时）。
struct CLIUsageMetric: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 预算进度条 + 说明（「已用 X / 预算 Y」，文案由模块拼好）。预算 ≤ 0（没设）时什么也不画，也不占位。
struct CLIUsageBudgetBar: View {
    let used: Int
    let budget: Int
    let caption: Text

    var body: some View {
        if budget > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: min(1, Double(used) / Double(budget)))
                caption
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 周卡右上角的口径标注：固定重置（「周三 09:00 重置」，文案由模块拼好）或近 7 天滚动。
struct CLIUsageWeekBadge: View {
    let fixed: Bool
    let fixedText: Text
    let rollingText: LocalizedStringKey

    var body: some View {
        if fixed {
            fixedText
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(rollingText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 明细表的一列（第一列之外）：列名、宽度、这一列的值怎么从合计里取（格式化由模块做）。
struct CLIUsageColumn<Table: CLIUsagePricingTable> {
    let title: LocalizedStringKey
    let width: CGFloat
    let value: (CLIUsageTotals<Table>) -> String
}

/// 明细表：表头 + 斑马纹的各行 + 合计行（`CLIUsageTotals.sum(of:)`）。第一列（日期 / 项目 / 模型）撑满剩余宽度、过长中间省略，其余列按模块给的宽度右对齐。
struct CLIUsageBucketTable<Table: CLIUsagePricingTable>: View {
    let buckets: [CLIUsageBucket<Table>]
    /// 第一列的列名（随维度变）。
    let firstColumn: LocalizedStringKey
    let columns: [CLIUsageColumn<Table>]
    /// 合计行第一列的文字。
    let totalLabel: String

    var body: some View {
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
            usageRow(label: totalLabel, totals: .sum(of: buckets), emphasized: true)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text(firstColumn)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            ForEach(columns.indices, id: \.self) { column in
                Text(columns[column].title).frame(width: columns[column].width, alignment: .trailing)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private func usageRow(label: String, totals: CLIUsageTotals<Table>, emphasized: Bool) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: label)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(columns.indices, id: \.self) { column in
                Text(verbatim: columns[column].value(totals)).frame(width: columns[column].width, alignment: .trailing)
            }
        }
        .font(emphasized ? .callout.weight(.semibold).monospacedDigit() : .callout.monospacedDigit())
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }
}

// MARK: - 调用统计

/// 调用统计的一组「名称 → 次数」（Skill、内置工具…）：按次数从多到少，整组可点折叠（默认收起），标题右侧带总次数。
/// `count` 把次数变成「N 次」的文字（模块的 key）。
struct CLIInvocationCountGroup: View {
    let title: LocalizedStringKey
    let counts: [String: Int]
    let count: (Int) -> Text
    /// 一次都没有时组里显示的提示。
    let empty: LocalizedStringKey

    var body: some View {
        let sorted = counts.sorted { $0.value > $1.value }
        TappableDisclosure {
            if sorted.isEmpty {
                CLIInvocationParts.emptyHint(empty)
            } else {
                VStack(spacing: 0) {
                    ForEach(sorted, id: \.key) { name, times in
                        CLIInvocationParts.countRow(name: name, count: count(times))
                    }
                }
            }
        } label: {
            CLIInvocationParts.groupLabel(title: title, total: count(counts.values.reduce(0, +)))
        }
    }
}

/// 调用统计的 MCP 组：服务器（总次数，可折叠）展开 → 各工具次数，两级都按次数从多到少；整组默认收起，标题带总次数。
struct CLIInvocationMCPGroup: View {
    let title: LocalizedStringKey
    let servers: [String: CLIUsageMCPServerStat]
    let count: (Int) -> Text
    let empty: LocalizedStringKey

    var body: some View {
        let sorted = servers.values.sorted { $0.total > $1.total }
        TappableDisclosure {
            if sorted.isEmpty {
                CLIInvocationParts.emptyHint(empty)
            } else {
                VStack(spacing: 0) {
                    ForEach(sorted, id: \.server) { server in
                        TappableDisclosure {
                            ForEach(server.tools.sorted { $0.value > $1.value }, id: \.key) { tool, times in
                                CLIInvocationParts.countRow(name: tool, count: count(times))
                                    .padding(.leading, 12)
                            }
                        } label: {
                            HStack {
                                Text(verbatim: server.server).font(.callout).lineLimit(1)
                                Spacer()
                                count(server.total)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } label: {
            CLIInvocationParts.groupLabel(title: title, total: count(sorted.reduce(0) { $0 + $1.total }))
        }
    }
}

/// 两种组共用的三样：组标题行、一行计数、空组提示（原来两个模块的调用统计小节里各一份私有函数）。
@MainActor
private enum CLIInvocationParts {
    static func groupLabel(title: LocalizedStringKey, total: Text) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            total
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    static func countRow(name: String, count: Text) -> some View {
        HStack {
            Text(verbatim: name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            count
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    static func emptyHint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
