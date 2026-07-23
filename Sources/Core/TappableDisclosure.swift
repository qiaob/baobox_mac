import SwiftUI

/// 整行可点的 DisclosureGroup。
///
/// 系统 DisclosureGroup 在 macOS 上仅小箭头可点,展开/收起命中区太小。
/// 本包装让 label 撑满整行并接管点击(带动画),展开态内部自管理。
/// 用法与 DisclosureGroup 同形:`TappableDisclosure { 内容 } label: { 标题 }`。
struct TappableDisclosure<Content: View, Label: View>: View {
    @State private var isExpanded: Bool
    private let content: () -> Content
    private let label: () -> Label

    init(
        initiallyExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: @escaping () -> Label
    ) {
        _isExpanded = State(initialValue: initiallyExpanded)
        self.content = content
        self.label = label
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: content) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }
        }
    }
}
