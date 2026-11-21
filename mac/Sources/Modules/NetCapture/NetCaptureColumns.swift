import AppKit
import SwiftUI

/// 抓包窗口的三栏：左栏、请求列表各有默认宽度，详情占其余；窗口拉宽时多出来的都给详情；两条分隔线能拖。
/// 宽度怎么算在 Logic/ColumnLayout.swift（HSplitView 不认 idealWidth，做不到「默认 200、又能拖到 280」）。
struct NetCaptureColumns<Sidebar: View, Requests: View, Detail: View>: View {
    private let layout = ColumnLayout.standard
    private let sidebar: () -> Sidebar
    private let list: () -> Requests
    private let detail: () -> Detail

    init(@ViewBuilder sidebar: @escaping () -> Sidebar,
         @ViewBuilder list: @escaping () -> Requests,
         @ViewBuilder detail: @escaping () -> Detail) {
        self.sidebar = sidebar
        self.list = list
        self.detail = detail
    }

    /// 用户想要的宽度（默认值，或拖出来的）。实际宽度还要看窗口多宽，见 `ColumnLayout.resolve`。
    @State private var sidebarWidth = ColumnLayout.standard.sidebarDefault
    @State private var listWidth = ColumnLayout.standard.listDefault
    /// 拖动开始时那一栏的实际宽度。
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let total = Double(geometry.size.width)
            let widths = layout.resolve(total: total, sidebar: sidebarWidth, list: listWidth)
            HStack(spacing: 0) {
                sidebar().frame(width: widths.sidebar)
                handle { delta in
                    let start = dragStart ?? widths.sidebar
                    dragStart = start
                    sidebarWidth = layout.draggingSidebar(from: start, by: delta, total: total, list: widths.list)
                }
                list().frame(width: widths.list)
                handle { delta in
                    let start = dragStart ?? widths.list
                    dragStart = start
                    listWidth = layout.draggingList(from: start, by: delta, total: total, sidebar: widths.sidebar)
                }
                detail().frame(width: widths.detail)
            }
        }
    }

    /// 1pt 的分隔线，两边各多出几 pt 的拖动区域（悬停时显示左右箭头光标）。
    private func handle(onDrag: @escaping (Double) -> Void) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: layout.divider)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { onDrag(Double($0.translation.width)) }
                            .onEnded { _ in dragStart = nil }
                    )
            }
            .zIndex(1)
    }
}
