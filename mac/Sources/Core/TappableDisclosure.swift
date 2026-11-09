import SwiftUI

/// 整行可点的 DisclosureGroup。
///
/// 系统 DisclosureGroup 在 macOS 上仅小箭头可点,展开/收起命中区太小。
/// 本包装让 label 撑满整行并接管点击(带动画),展开态内部自管理。
/// 用法与 DisclosureGroup 同形:`TappableDisclosure { 内容 } label: { 标题 }`。
///
/// 双击只算一下：切换后 0.4 秒内的第二下不再切回去（点标题和点小箭头都一样）。
/// 习惯双击展开的人，以前会看到它展开又马上收起，以为点不开（2026-11-09 实测）。
struct TappableDisclosure<Content: View, Label: View>: View {
    @State private var isExpanded: Bool
    @State private var lastToggle = Date.distantPast
    private let content: () -> Content
    private let label: () -> Label

    /// 两次切换至少隔这么久（双击的第二下落在这之内）。
    private static var debounce: TimeInterval { 0.4 }

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
        DisclosureGroup(isExpanded: Binding(get: { isExpanded }, set: { setExpanded($0) }), content: content) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    setExpanded(!isExpanded)
                }
        }
    }

    private func setExpanded(_ value: Bool) {
        let now = Date()
        guard value != isExpanded, now.timeIntervalSince(lastToggle) > Self.debounce else { return }
        lastToggle = now
        withAnimation(.easeInOut(duration: 0.18)) {
            isExpanded = value
        }
    }
}
