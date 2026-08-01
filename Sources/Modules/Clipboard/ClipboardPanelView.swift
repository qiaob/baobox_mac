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

    @Published var query = ""
    @Published var typeFilter: ClipboardItemType?
    @Published var selectedIndex = 0 { didSet { refreshDetection() } }

    /// 当前选中条目命中的格式，按优先级升序。
    @Published private(set) var matches: [FormatMatch] = []
    /// 徽章行选中的那一个。切格式要清掉转换结果 —— 两个格式的转换不该串。
    @Published var activeMatchIndex = 0 { didSet { transformed = nil } }
    /// 预览缓冲：执行转换动作后的结果。
    @Published var transformed: TransformState?
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
            (typeFilter == nil || item.type == typeFilter) && matchesQuery(item)
        }
    }

    var selectedItem: ClipboardItem? {
        let list = filtered
        guard list.indices.contains(selectedIndex) else { return nil }
        return list[selectedIndex]
    }

    func resetForShow() {
        query = ""
        typeFilter = nil
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
        // 搜索/过滤会让同一个 selectedIndex 指向另一条，识别结果必须跟着重算。
        refreshDetection()
    }

    // MARK: - 格式识别

    /// 只对**当前选中的这一条**跑，纯内存、不落盘。绝不在 ClipboardMonitor 入库时跑 ——
    /// 那是 0.3s 轮询的热路径。
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

    /// 转换动作的输入：已转换过就在结果上接着转，否则用条目原文。
    /// **不用 `rendered`** —— 那只是展示（如 JWT 解码视图），不是可再转换的源。
    var transformInput: String {
        transformed?.text ?? (selectedItem?.text ?? "")
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

    func run(_ action: FormatAction) {
        guard action.isEnabled else { return }
        switch action.kind {
        case .transform(let transform):
            guard let result = transform(transformInput) else { return }
            transformed = TransformState(actionTitle: action.title, text: result)
        case .terminal(let terminal):
            terminal(previewText)
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

    @FocusState private var searchFocused: Bool
    @State private var hoveredItemID: UUID?

    private let typeChips: [(String, ClipboardItemType?)] = [
        (L("clipboard.chip.all"), nil), (L("clipboard.chip.text"), .text),
        (L("clipboard.chip.link"), .link), (L("clipboard.chip.image"), .image),
        (L("clipboard.chip.file"), .file)
    ]

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
        .frame(width: 660, height: 420)
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
        .onChange(of: viewModel.typeFilter) { _, _ in viewModel.clampSelection() }
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
                    let active = viewModel.typeFilter == chip.1
                    Text(chip.0)
                        .font(.caption)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(active ? Color.accentColor : Color.primary.opacity(0.07),
                                    in: Capsule())
                        .foregroundStyle(active ? Color.white : Color.primary)
                        .onTapGesture { viewModel.typeFilter = chip.1 }
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
                            .onTapGesture { viewModel.selectedIndex = index }
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

                if !viewModel.visibleActions.isEmpty { actionBar }

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
    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(viewModel.visibleActions.enumerated()), id: \.element.id) { index, action in
                    Button {
                        viewModel.run(action)
                    } label: {
                        Text(verbatim: index < 9 ? "\(action.title)  ⌘\(index + 1)" : action.title)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!action.isEnabled)
                    .help(action.disabledHint ?? "")
                }
            }
            .padding(.vertical, 1)
        }
    }

    @ViewBuilder
    private func previewBody(_ item: ClipboardItem) -> some View {
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
            // 图片是加密落盘的，不能直接 NSImage(contentsOf:)。
            if let name = item.imageFilename,
               let data = ClipboardCrypto.read(from: ClipboardStore.imagesDir.appendingPathComponent(name)),
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
