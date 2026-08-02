import SwiftUI
import AppKit

@MainActor
final class ClipboardPanelViewModel: ObservableObject {
    /// 一次转换动作的结果。只在内存里，不写回历史、不落盘。
    struct TransformState {
        let actionTitle: String
        let text: String
    }

    static let maximizedKey = "clipboard.previewMaximized"

    /// 顶栏筛选。类型之外还有「收藏」维度，所以不是单纯的 ClipboardItemType?。
    enum PanelFilter: Equatable {
        case all
        case type(ClipboardItemType)
        case favorites
    }

    @Published var query = ""
    @Published var filter: PanelFilter = .all
    @Published var selectedIndex = 0

    /// 当前选中条目命中的格式，按优先级升序。
    @Published private(set) var matches: [FormatMatch] = []
    /// 徽章行选中的那一个。切格式要清掉转换结果 —— 两个格式的转换不该串。
    @Published var activeMatchIndex = 0 { didSet { transformed = nil } }
    /// 预览缓冲：执行转换动作后的结果。任何赋值（转换、撤销、换条目/换格式时的
    /// 清空）都顺带清掉内嵌图片 —— 图片是按当时的文本生成的，文本一动它就是陈旧的。
    @Published var transformed: TransformState? { didSet { previewImage = nil } }
    /// 内嵌进预览区的图片（二维码）。非 nil 时预览区显示它而不是文本。
    @Published var previewImage: CGImage?
    /// 预览区最大化（列表列隐藏）。状态持久化，经常看 JSON 的人不必每次按一下。
    @Published var isPreviewMaximized: Bool {
        didSet { UserDefaults.standard.set(isPreviewMaximized, forKey: Self.maximizedKey) }
    }

    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
        self.isPreviewMaximized = UserDefaults.standard.bool(forKey: Self.maximizedKey)
    }

    var filtered: [ClipboardItem] {
        store.items.filter { item in
            matchesFilter(item) && matchesQuery(item)
        }
    }

    var selectedItem: ClipboardItem? {
        let list = filtered
        guard list.indices.contains(selectedIndex) else { return nil }
        return list[selectedIndex]
    }

    func resetForShow() {
        query = ""
        filter = .all
        selectedIndex = 0
        // selectedIndex 本来就是 0 时 didSet 不触发，这里必须显式刷一次。
        refreshDetection()
    }

    func moveSelection(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + delta), count - 1)
    }

    func clampSelection() {
        let count = filtered.count
        if count == 0 { selectedIndex = 0 }
        else if selectedIndex >= count { selectedIndex = count - 1 }
    }

    /// 顶栏 chips 的展示顺序，←/→ 循环切换也走它 —— 单一事实来源。
    static let filterOrder: [PanelFilter] = [
        .all, .favorites, .type(.text), .type(.image), .type(.link), .type(.file)
    ]

    /// ←/→ 在类型筛选间循环切换（越界回绕）。
    func cycleFilter(_ delta: Int) {
        let order = Self.filterOrder
        let current = order.firstIndex(of: filter) ?? 0
        filter = order[(current + delta + order.count) % order.count]
        clampSelection()
    }

    // MARK: - 格式识别

    /// 只对**当前选中的这一条**跑，纯内存、不落盘。绝不在 ClipboardMonitor 入库时跑 ——
    /// 那是 0.3s 轮询的热路径。
    ///
    /// 触发点统一在 View 的 `.onChange(of: selectedItem?.id)`，不挂在 `selectedIndex`
    /// 的 didSet 上：面板开着时用户在别处复制，新条目插到列表最前，`selectedIndex`
    /// 没变但它指向的已经是另一条了 —— 只盯索引会留下错位的徽章和动作。
    /// 反过来，选中项没变时（比如只是在搜索框里打字）也不该白清掉用户的转换结果。
    func refreshDetection() {
        transformed = nil
        activeMatchIndex = 0
        guard let item = selectedItem, item.type != .image,
              let text = item.text, !text.isEmpty else {
            matches = []
            return
        }
        matches = TextFormatRegistry.detectAll(text)
    }

    var activeMatch: FormatMatch? {
        matches.indices.contains(activeMatchIndex) ? matches[activeMatchIndex] : nil
    }

    /// 预览区显示的内容，也是 ⌘C 复制的内容 —— 所见即所copy。
    var previewText: String {
        if let transformed = transformed { return transformed.text }
        if let rendered = activeMatch?.rendered { return rendered }
        return selectedItem?.text ?? ""
    }

    /// 动作的输入：已转换过就在结果上接着转，否则用条目原文。
    ///
    /// **不用 `rendered`** —— 那只是展示（如 JWT 的解码视图带着分段注释），不是可再
    /// 转换的源；给二维码编码的也必须是原 token 而不是那份视图。
    /// 这里必须 trim：检测拿到的是 trim 过的文本，不 trim 的话「带尾换行的 Base64
    /// 徽章亮着、解码按钮却静默无反应」。
    var transformInput: String {
        (transformed?.text ?? (selectedItem?.text ?? ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ⏎ 粘贴时的覆盖内容。只有**显式转换过**才覆盖 —— 仅仅选中一条 JWT
    /// 不该让 ⏎ 粘出解码后的 JSON，那时用户要的就是原 token。
    var pasteOverride: String? { transformed?.text }

    /// 动作栏内容：格式专属在前，通用动作（二维码）在后。
    var visibleActions: [FormatAction] {
        var actions = activeMatch?.actions ?? []
        if let item = selectedItem, item.type != .image, let text = item.text, !text.isEmpty {
            actions += TextFormatRegistry.commonActions(for: text)
        }
        return actions
    }

    /// ⌘1…⌘9 的映射：把下拉子项按出现顺序展开，容器本身不占号。
    /// 动作栏菜单项里显示的序号与这里一致（slotTitle）。
    var keyboardActions: [FormatAction] {
        visibleActions.flatMap { action in
            if case .menu(let subActions) = action.kind { return subActions }
            return [action]
        }
    }

    func run(_ action: FormatAction) {
        guard action.isEnabled else { return }
        switch action.kind {
        case .transform(let transform):
            guard let result = transform(transformInput) else { return }
            transformed = TransformState(actionTitle: action.title, text: result)
        case .imagePreview(let render):
            // 再按一次 = 收起。输入用 transformInput 而不是 previewText：选中一个
            // JWT 时预览区是解码视图，但要生成二维码的显然是原 token。
            previewImage = previewImage == nil ? render(transformInput) : nil
        case .terminal(let terminal):
            terminal(transformInput)
        case .menu:
            // 容器不可执行也不进 keyboardActions，走不到这里；纯防御兜底。
            break
        }
    }

    private func matchesFilter(_ item: ClipboardItem) -> Bool {
        switch filter {
        case .all: return true
        case .type(let type): return item.type == type
        case .favorites: return item.isPinned
        }
    }

    /// 名字不能叫 `matches` —— 会和 `@Published var matches: [FormatMatch]` 撞名。
    private func matchesQuery(_ item: ClipboardItem) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        if let text = item.text, text.lowercased().contains(q) { return true }
        if let name = item.imageFilename, name.lowercased().contains(q) { return true }
        return false
    }
}

/// 剪贴板历史面板内容。
struct ClipboardPanelView: View {
    @ObservedObject var viewModel: ClipboardPanelViewModel
    @ObservedObject var store: ClipboardStore
    var onPaste: (ClipboardItem, Bool) -> Void
    var onTogglePin: (ClipboardItem) -> Void
    var onDelete: (ClipboardItem) -> Void
    var onClose: () -> Void
    /// 只复制不粘贴（表格行的复制按钮）。由 controller 负责抑制监听，避免转换结果进历史。
    var onCopyText: (String) -> Void
    /// 图片条目开独立预览窗（徽章行按钮 / 双击缩略图）。
    var onPreviewImage: (ClipboardItem) -> Void
    /// 收藏条目开片段编辑窗（动作栏「设关键字 / ;kw」按钮）。
    var onEditSnippet: (ClipboardItem) -> Void

    @FocusState private var searchFocused: Bool
    @State private var hoveredItemID: UUID?

    /// 顺序由 `ClipboardPanelViewModel.filterOrder` 决定（与 ←/→ 切换一致）。
    private let typeChips: [(String, ClipboardPanelViewModel.PanelFilter)] =
        ClipboardPanelViewModel.filterOrder.map { (Self.chipLabel($0), $0) }

    private static func chipLabel(_ filter: ClipboardPanelViewModel.PanelFilter) -> String {
        switch filter {
        case .all: return L("clipboard.chip.all")
        case .favorites: return L("clipboard.chip.favorites")
        case .type(.text): return L("clipboard.chip.text")
        case .type(.link): return L("clipboard.chip.link")
        case .type(.image): return L("clipboard.chip.image")
        case .type(.file): return L("clipboard.chip.file")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HStack(spacing: 0) {
                // 最大化 = 藏掉列表列，预览区独占面板宽度。
                if !viewModel.isPreviewMaximized {
                    listColumn
                    Divider()
                }
                previewColumn
            }
            Divider()
            footer
        }
        // 只锁下限：面板可拖拽调整大小（ClipboardPanelController.minSize 同值），
        // 根视图跟着窗口尺寸铺满。
        .frame(minWidth: 660, minHeight: 420)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        // 置焦点必须晚于 panel.makeKeyAndOrderFront。onAppear 发生在
        // `panel.contentView = hosting` 那一刻，此时面板还不是 key window，
        // 在非 key 窗口上置 @FocusState 会失败 —— 表现为搜索框打不进字。
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            searchFocused = true
        }
        .onChange(of: viewModel.query) { _, _ in viewModel.clampSelection() }
        .onChange(of: viewModel.filter) { _, _ in viewModel.clampSelection() }
        // 选中的**条目**变了就重新识别 —— 不管是键盘换行、搜索过滤变了，还是面板
        // 开着时来了新的复制把列表顶开。首次显示由 resetForShow() 负责。
        .onChange(of: viewModel.selectedItem?.id) { _, _ in viewModel.refreshDetection() }
    }

    // MARK: 顶部搜索 + 过滤

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("clipboard.panel.searchPlaceholder", text: $viewModel.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)

            HStack(spacing: 6) {
                ForEach(Array(typeChips.enumerated()), id: \.offset) { _, chip in
                    let active = viewModel.filter == chip.1
                    Text(chip.0)
                        .font(.caption)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(active ? Color.accentColor : Color.primary.opacity(0.07),
                                    in: Capsule())
                        .foregroundStyle(active ? Color.white : Color.primary)
                        .onTapGesture { viewModel.filter = chip.1 }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 左列表

    private var listColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(viewModel.filtered.enumerated()), id: \.element.id) { index, item in
                        row(item: item, selected: index == viewModel.selectedIndex)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onPaste(item, false) }
                            // 单击选中不能再用 onTapGesture：与双击并存时它要等双击超时
                            // 才发火，每次点击都憋 0.3s。simultaneousGesture 第一击立即选中，
                            // 双击的第二击照常触发粘贴 —— 与 NSTableView 的行为一致。
                            .simultaneousGesture(TapGesture().onEnded { viewModel.selectedIndex = index })
                    }
                }
                .padding(8)
            }
            .onChange(of: viewModel.selectedIndex) { _, _ in
                if let item = viewModel.selectedItem {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 300)
    }

    private func row(item: ClipboardItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isConcealed ? "lock.fill" : iconName(item.type))
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
                .background(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(selected ? Color.white : Color.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(previewLine(item))
                    .lineLimit(1)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(verbatim: "\(item.sourceAppName ?? L("common.unknown")) · \(relativeTime(item.createdAt))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
            }
            Spacer(minLength: 0)
            if hoveredItemID == item.id {
                Button {
                    onDelete(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("clipboard.row.deleteHelp")
            }
            if item.isPinned {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white : Color.yellow)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { inside in
            hoveredItemID = inside ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
        }
    }

    // MARK: 右预览

    @ViewBuilder
    private var previewColumn: some View {
        if let item = viewModel.selectedItem {
            VStack(alignment: .leading, spacing: 10) {
                badgeRow(item)

                previewBody(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
                    .background(Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if !viewModel.visibleActions.isEmpty || Self.snippetEligible(item) { actionBar(item) }

                HStack(spacing: 16) {
                    Text("clipboard.preview.source \(item.sourceAppName ?? L("common.unknown"))")
                    if let text = item.text { Text("clipboard.preview.chars \(text.count)") }
                    Text(absoluteTime(item.createdAt))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack {
                Spacer()
                Text("clipboard.preview.empty")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 徽章行 / 表格 / 动作栏

    private func badgeRow(_ item: ClipboardItem) -> some View {
        HStack(spacing: 6) {
            Text("clipboard.preview.header \(typeLabel(item.type))")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(Array(viewModel.matches.enumerated()), id: \.element.id) { index, match in
                let active = index == viewModel.activeMatchIndex
                Text(verbatim: match.badge)
                    .font(.system(size: 10))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(active ? Color.accentColor : Color.primary.opacity(0.09), in: Capsule())
                    .foregroundStyle(active ? Color.white : Color.secondary)
                    .onTapGesture { viewModel.activeMatchIndex = index }
            }

            Spacer(minLength: 0)

            // 「已转换」必须显眼：否则用户不知道 ⏎ 粘出去的是哪个版本。
            if let transformed = viewModel.transformed {
                Text(verbatim: transformed.actionTitle)
                    .font(.system(size: 10))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
                Button("clipboard.tools.revert") { viewModel.transformed = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if item.type == .image {
                Button {
                    onPreviewImage(item)
                } label: {
                    Label("clipboard.preview.open", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if viewModel.isPreviewMaximized {
                Text(verbatim: "\(viewModel.selectedIndex + 1) / \(viewModel.filtered.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rowsTable(_ rows: [FormatRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 86, alignment: .leading)
                    Text(verbatim: row.value)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(row.isWarning ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let copy = row.copyValue {
                        Button {
                            onCopyText(copy)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 面板窄，动作多了会挤 —— 横向可滚。
    ///
    /// ⌘ 序号按 keyboardActions（下拉展开后的顺序）分配：容器不占号，子项的
    /// 序号写进菜单项标题，按 ⌘n 直接触发、不用先打开菜单。
    /// 只有文本类收藏能当片段（与 `ClipboardStore.snippets` 同一口径）。
    private static func snippetEligible(_ item: ClipboardItem) -> Bool {
        item.isPinned && (item.type == .text || item.type == .link)
    }

    private func actionBar(_ item: ClipboardItem) -> some View {
        // uniquingKeysWith 而非 uniqueKeysWithValues：后者遇到重复 id 直接 crash，
        // 而 id 唯一性靠的是各识别器自觉 —— 不值得用崩溃来强制。
        let slots = Dictionary(viewModel.keyboardActions.enumerated().map { ($1.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.visibleActions) { action in
                    if case .menu(let subActions) = action.kind {
                        Menu {
                            ForEach(subActions) { sub in
                                Button {
                                    viewModel.run(sub)
                                } label: {
                                    Text(verbatim: slotTitle(sub, slots))
                                }
                                .disabled(!sub.isEnabled)
                            }
                        } label: {
                            Text(verbatim: action.title)
                                .font(.system(size: 11))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    } else {
                        Button {
                            viewModel.run(action)
                        } label: {
                            Text(verbatim: slotTitle(action, slots))
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!action.isEnabled)
                        .help(action.disabledHint ?? "")
                    }
                }
                // 收藏条目：就地编辑片段（名称/关键字/内容）。放末尾 —— 它属于条目本身，
                // 与前面「对文本做转换」的动作性质不同。设了关键字就直接显示完整触发词。
                if Self.snippetEligible(item) {
                    Button {
                        onEditSnippet(item)
                    } label: {
                        if let keyword = item.keyword, !keyword.isEmpty {
                            Text(verbatim: SnippetExpander.prefix + keyword)
                                .font(.system(size: 11, design: .monospaced))
                        } else {
                            Text("clipboard.tools.action.setKeyword")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// 标题 + ⌘ 序号（keyboardActions 里前 9 个才有）。
    private func slotTitle(_ action: FormatAction, _ slots: [String: Int]) -> String {
        if let slot = slots[action.id], slot < 9 { return "\(action.title)  ⌘\(slot + 1)" }
        return action.title
    }

    @ViewBuilder
    private func previewBody(_ item: ClipboardItem) -> some View {
        // 内嵌图片（二维码）盖过一切文本形态。源图 1024px、显示区约 370pt，
        // 缩放交给默认插值（与钉屏窗一致，实测可扫）。
        if let cg = viewModel.previewImage {
            Image(nsImage: NSImage(cgImage: cg, size: .zero))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            textPreviewBody(item)
        }
    }

    @ViewBuilder
    private func textPreviewBody(_ item: ClipboardItem) -> some View {
        switch item.type {
        case .text, .link:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(viewModel.previewText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if let rows = viewModel.activeMatch?.rows, !rows.isEmpty {
                        Divider()
                        rowsTable(rows)
                    }
                }
            }
        case .image:
            if let filename = item.imageFilename {
                EncryptedImagePreview(filename: filename) { onPreviewImage(item) }
            } else {
                Text("clipboard.preview.missingImage").foregroundStyle(.secondary)
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array((item.text ?? "").split(separator: "\n").enumerated()), id: \.offset) { _, path in
                        Text(String(path))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            Text("clipboard.footer.count \(store.items.count)")
            Spacer()
            hint("←→", L("clipboard.footer.filter"))
            hint("↑↓", L("clipboard.footer.select"))
            hint("⏎", L("clipboard.footer.paste"))
            hint("⌥⏎", L("clipboard.footer.pastePlain"))
            hint("⇥", L("clipboard.footer.expand"))
            hint("⌘P", L("clipboard.footer.pin"))
            hint("⌘⌫", L("clipboard.footer.delete"))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            Text(label)
        }
    }

    // MARK: 辅助

    private func iconName(_ type: ClipboardItemType) -> String {
        switch type {
        case .text: return "textformat"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    private func typeLabel(_ type: ClipboardItemType) -> String {
        switch type {
        case .text: return L("clipboard.type.text")
        case .link: return L("clipboard.type.link")
        case .image: return L("clipboard.type.image")
        case .file: return L("clipboard.type.file")
        }
    }

    private func previewLine(_ item: ClipboardItem) -> String {
        switch item.type {
        case .image:
            return item.imageFilename ?? L("clipboard.type.image")
        case .file:
            let paths = (item.text ?? "").split(separator: "\n")
            if let first = paths.first {
                let name = (String(first) as NSString).lastPathComponent
                return paths.count > 1 ? L("clipboard.row.moreFiles \(name) \(paths.count)") : name
            }
            return L("clipboard.type.file")
        default:
            return (item.text ?? "").replacingOccurrences(of: "\n", with: " ")
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MdHHmm")
        return formatter.string(from: date)
    }
}

/// 加密图片的异步预览：先占位，后台解密 + 降采样解码完成再上图。
/// 同步整图解码会把面板打开的首帧卡住 —— 历史顶部常是几 MB 的 Retina 大截图。
/// 双击开独立预览窗（那边才用原始分辨率）。
private struct EncryptedImagePreview: View {
    let filename: String
    var onOpen: () -> Void

    @State private var image: NSImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) { onOpen() }
            } else if finished {
                Text("clipboard.preview.missingImage").foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: filename) {
            // 换条目立即回占位，避免旧图残留在新条目上。
            image = nil
            finished = false
            let url = ClipboardStore.imagesDir.appendingPathComponent(filename)
            let key = filename
            image = await Task.detached(priority: .userInitiated) {
                ClipboardImagePreview.load(from: url, cacheKey: key)
            }.value
            finished = true
        }
    }
}
