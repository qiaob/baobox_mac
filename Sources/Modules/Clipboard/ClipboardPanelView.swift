import SwiftUI
import AppKit

@MainActor
final class ClipboardPanelViewModel: ObservableObject {
    @Published var query = ""
    @Published var typeFilter: ClipboardItemType?
    @Published var selectedIndex = 0

    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    var filtered: [ClipboardItem] {
        store.items.filter { item in
            (typeFilter == nil || item.type == typeFilter) && matches(item)
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

    private func matches(_ item: ClipboardItem) -> Bool {
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
                listColumn
                Divider()
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
            Image(systemName: iconName(item.type))
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
                Text("clipboard.preview.header \(typeLabel(item.type))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                previewBody(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
                    .background(Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))

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

    @ViewBuilder
    private func previewBody(_ item: ClipboardItem) -> some View {
        switch item.type {
        case .text, .link:
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .image:
            if let name = item.imageFilename,
               let image = NSImage(contentsOf: ClipboardStore.imagesDir.appendingPathComponent(name)) {
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
        HStack(spacing: 16) {
            Text("clipboard.footer.count \(store.items.count)")
            Spacer()
            hint("↑↓", L("clipboard.footer.select"))
            hint("⏎", L("clipboard.footer.paste"))
            hint("⌥⏎", L("clipboard.footer.pastePlain"))
            hint("⌘P", L("clipboard.footer.pin"))
            hint("⌘⌫", L("clipboard.footer.delete"))
        }
        .font(.system(size: 11.5))
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
