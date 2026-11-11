import SwiftUI

// 快速切换面板的会话栏视图（#109，docs/codex-assistant/DEDUPE.md §4.3）：外框、搜索栏、会话列表、会话行、底栏与按键提示。
// Claude Code 助手、Codex 助手的面板用它们拼；Claude 的「最近文件」模式（chips、文件列表、文件行）留在 Claude 模块。

/// 面板外框：640×420、毛玻璃、圆角 14、细描边；内容竖排、间距 0。
struct QuickSwitchCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(width: QuickSwitchPanelHost.size.width, height: QuickSwitchPanelHost.size.height)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// 搜索栏：图标 + 输入框 + 右侧附件（Claude 放会话 / 文件分段控件）。
/// 自己管焦点：出现后等 50 ms 再让输入框拿焦点 —— 必须晚于面板的 makeKeyAndOrderFront（同剪贴板面板的时序说明）。
/// 搜索栏随面板一起建、不放在任何条件分支里，这个 `.task` 每次打开面板跑一次。
struct QuickSwitchSearchBar<Accessory: View>: View {
    private let symbol: String
    private let placeholder: LocalizedStringKey
    @Binding private var text: String
    private let accessory: Accessory

    @FocusState private var focused: Bool

    init(symbol: String, placeholder: LocalizedStringKey, text: Binding<String>,
         @ViewBuilder accessory: () -> Accessory) {
        self.symbol = symbol
        self.placeholder = placeholder
        _text = text
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            focused = true
        }
    }
}

extension QuickSwitchSearchBar where Accessory == EmptyView {
    init(symbol: String, placeholder: LocalizedStringKey, text: Binding<String>) {
        self.init(symbol: symbol, placeholder: placeholder, text: text) { EmptyView() }
    }
}

/// 会话列表：空态文案，或可滚动的会话行（单击选中、双击续接、选中项变了滚到正中）。
struct QuickSwitchSessionList<Source: QuickSwitchSessionSource>: View {
    private let source: Source
    private let sessions: [Source.Session]
    @Binding private var selectedIndex: Int
    private let emptyText: LocalizedStringKey
    private let onResume: (Source.Session) -> Void
    /// 每次随面板重画，同原来行写在面板 body 里时一样：行的第二行依赖数据源背后、参数里看不出的状态
    /// （Claude 的会话行方案、相对时间），参数都没变时 SwiftUI 会跳过这个 body，所以放一个每次都不同的值。
    private let renderToken = UUID()

    init(source: Source, sessions: [Source.Session], selectedIndex: Binding<Int>,
         emptyText: LocalizedStringKey, onResume: @escaping (Source.Session) -> Void) {
        self.source = source
        self.sessions = sessions
        _selectedIndex = selectedIndex
        self.emptyText = emptyText
        self.onResume = onResume
    }

    var body: some View {
        if sessions.isEmpty {
            VStack {
                Spacer()
                Text(emptyText)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            QuickSwitchSessionRow(title: session.title,
                                                  meta: source.metadataLine(for: session),
                                                  selected: index == selectedIndex)
                                .id(session.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onResume(session) }
                                .onTapGesture { selectedIndex = index }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selectedIndex) { _, _ in
                    if let session = QuickSwitchSelection.element(sessions, at: selectedIndex) {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(session.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

/// 会话行：图标 + 标题 + 第二行（空串不显示）；选中时 accent 底、白字。
struct QuickSwitchSessionRow: View {
    let title: String
    let meta: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
                .background(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(selected ? Color.white : Color.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .lineLimit(1)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                if !meta.isEmpty {
                    Text(verbatim: meta)
                        .lineLimit(1)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// 底栏：左边计数、右边按键提示，内容由面板给；字号 11.5、次要色。
struct QuickSwitchFooter<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 16) {
            content
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

/// 按键提示：等宽键帽 + 说明。两个都是现成的字符串（说明已经 `L()` 过），原样显示、不再查表。
struct QuickSwitchKeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            Text(label)
        }
    }
}
