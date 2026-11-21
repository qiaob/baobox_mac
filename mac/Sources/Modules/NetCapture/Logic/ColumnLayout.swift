import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：抓包窗口三栏的宽度（docs/packet-capture/TOOLS.md §7）。
//
// 详情最宽：左栏默认 200、可拖 160–280；请求列表默认 360、可拖 280–560；详情占其余、最少 420。
// 窗口拉宽时多出来的全给详情；窗口变窄、详情不够 420 时先缩列表、再缩左栏（都不低于各自最小）。
// SwiftUI 的 HSplitView 不认 idealWidth（按 HStack 的规则分），给不出「默认 200、又能拖到 280」，所以自己算。

struct ColumnLayout: Equatable, Sendable {
    var sidebarMin = 160.0, sidebarDefault = 200.0, sidebarMax = 280.0
    var listMin = 280.0, listDefault = 360.0, listMax = 560.0
    var detailMin = 420.0
    /// 两条分隔线各占的宽度。
    var divider = 1.0

    static let standard = ColumnLayout()

    /// 三栏放下所需的最小总宽。
    var minimumTotal: Double { sidebarMin + listMin + detailMin + 2 * divider }

    /// `sidebar` / `list` 是想要的宽度（默认值或拖出来的）；返回这个总宽下三栏实际的宽度。
    func resolve(total: Double, sidebar: Double, list: Double) -> (sidebar: Double, list: Double, detail: Double) {
        let available = max(0, total - 2 * divider)
        var side = Self.clamp(sidebar, sidebarMin, sidebarMax)
        var middle = Self.clamp(list, listMin, listMax)
        var shortfall = side + middle + detailMin - available
        if shortfall > 0 {
            let cut = min(shortfall, middle - listMin)
            middle -= cut
            shortfall -= cut
        }
        if shortfall > 0 {
            side -= min(shortfall, side - sidebarMin)
        }
        return (side, middle, max(0, available - side - middle))
    }

    /// 拖左栏右边的分隔线：新的左栏宽度。不超出左栏的范围，也不把详情挤到最小宽度以下。
    func draggingSidebar(from start: Double, by delta: Double, total: Double, list: Double) -> Double {
        let upper = min(sidebarMax, max(sidebarMin, total - 2 * divider - list - detailMin))
        return Self.clamp(start + delta, sidebarMin, upper)
    }

    /// 拖列表右边的分隔线：新的列表宽度。
    func draggingList(from start: Double, by delta: Double, total: Double, sidebar: Double) -> Double {
        let upper = min(listMax, max(listMin, total - 2 * divider - sidebar - detailMin))
        return Self.clamp(start + delta, listMin, upper)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
