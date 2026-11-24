import CoreGraphics
import Foundation

/// 交来的文字（快速入口，docs/launcher/TECH_DESIGN.md §5.4）的结果面板放哪：没有选区可贴，
/// 就水平居中于鼠标所在屏幕的可见区域，顶边在可见区域从上往下 1/5 处（同快速入口面板的顶边）。
/// 内容变高、切换动作时重新摆：还是居中、顶边不动，放不下时夹回可见区。
/// 「选中文字后贴在选区旁」的定位不走这里（`SelectionTranslatePanelController.placement`）。纯逻辑，进 BaoboxTests。
struct SelectionCenteredSlot: Equatable {
    /// 离可见区域边缘至少留多少（同选区定位）。
    static let margin: CGFloat = 8
    /// 顶边在可见区域从上往下的比例（同快速入口 `LauncherPanel.initialFrame`）。
    static let topFraction: CGFloat = 0.2

    /// 那块屏幕的可见区域（屏幕坐标，原点在左下）。
    let visible: CGRect
    /// 面板顶边的 y。
    let top: CGFloat

    init(visible: CGRect) {
        self.visible = visible
        top = visible.maxY - visible.height * Self.topFraction
    }

    /// 这么大的面板的原点（左下角）。取最近的整数：系统会把窗口原点取整，自己先取整，之后才比得出用户拖过没有。
    func origin(for size: CGSize) -> CGPoint {
        var x = visible.midX - size.width / 2
        x = min(max(x, visible.minX + Self.margin), visible.maxX - size.width - Self.margin)
        var y = top - size.height
        y = min(max(y, visible.minY + Self.margin), visible.maxY - size.height - Self.margin)
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// 报上来的内容尺寸是不是真的量过（SwiftUI 第一次排版前会报 0 × 0）。
    static func isMeasured(_ size: CGSize) -> Bool {
        size.width >= 1 && size.height >= 1
    }

    /// 窗口实际的原点和我们摆的差超过 1 点才算用户拖过（取整、换算误差不算）。
    static func wasMoved(placed: CGPoint, actual: CGPoint) -> Bool {
        abs(placed.x - actual.x) > 1 || abs(placed.y - actual.y) > 1
    }

    /// 用户拖过面板没有：之前已经认定拖过，或者此刻的位置和我们上次摆的差超过 1 点；我们还没摆过（`placed` 为 nil）时不算。
    /// 切换动作前先问它 —— 拖过就别再拉回居中。
    static func userMoved(placed: CGPoint?, actual: CGPoint, alreadyMoved: Bool) -> Bool {
        if alreadyMoved { return true }
        guard let placed else { return false }
        return wasMoved(placed: placed, actual: actual)
    }
}
