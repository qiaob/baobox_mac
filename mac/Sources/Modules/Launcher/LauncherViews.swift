import AppKit
import SwiftUI

// 快速入口面板的视图（docs/launcher/TECH_DESIGN.md §4）：输入框 + 结果列表，外框、行的样子沿用快速切换面板和剪贴板面板。
// 面板不是当前 App 的窗口，系统控件会按「非活动窗口」发灰，所以选中高亮、图标底这些都由 SwiftUI 自己画（同 SelectionButtons.swift）。
// 输入框是包了一层的 NSTextField：要拿到输入法是否正在组字（`hasMarkedText()`），组字时 ⏎ / ↑ ↓ / Esc 交给输入法。

// MARK: - 尺寸

enum LauncherLayout {
    static let width: CGFloat = 680
    static let cornerRadius: CGFloat = 14
    static let searchBarHeight: CGFloat = 56
    static let rowHeight: CGFloat = 40
    /// 计算结果那一行：大一号的结果 + 一行「理解成了什么」。
    static let calculationRowHeight: CGFloat = 58
    /// 列表上下的留白。
    static let listPadding: CGFloat = 6
    /// 最多显示几行，超出滚动；半行露在外面提示还能往下滚。
    static let maxVisibleRows: CGFloat = 8.5
    /// 「没有结果」/ 提示文字那一行。
    static let messageHeight: CGFloat = 40
    /// 面板最下面那行不可选的小字提示（快捷键和别的启动器撞了，§9），含上面的分隔线。
    static let noticeHeight: CGFloat = 30

    /// 一行的高度。
    static func rowHeight(for row: LauncherRow) -> CGFloat {
        switch row.style {
        case .standard: return rowHeight
        case .calculation: return calculationRowHeight
        }
    }

    /// 列表最多显示多高：8.5 行，超出滚动。前几行里有比普通行高的（计算结果）就多给它高出来的那一截，
    /// 底下照样露出半行，看得出还能往下滚。
    static func maxListHeight(rowHeights: [CGFloat]) -> CGFloat {
        let extra = rowHeights.prefix(Int(maxVisibleRows.rounded(.up))).reduce(CGFloat(0)) { $0 + max(0, $1 - rowHeight) }
        return maxVisibleRows * rowHeight + extra
    }

    /// 面板在这种内容下的高度（窗口顶边固定、向下长）。
    static func height(for content: LauncherPanelContent) -> CGFloat {
        switch content {
        case .hint, .noResults, .searching:
            return searchBarHeight + 1 + messageHeight
        case .results(let rowHeights):
            let total = rowHeights.reduce(CGFloat(0), +)
            let cap = maxListHeight(rowHeights: rowHeights)
            // 没超时上下都留白；超了底下露出的半行就是边，不再加留白。
            let padding = total > cap ? listPadding : listPadding * 2
            return searchBarHeight + 1 + min(total, cap) + padding
        }
    }

    /// 结果最多时的高度（定位时保证这么高也放得下）：第一行是计算结果、后面一长串，最下面还有一行提示。
    static var maxHeight: CGFloat {
        height(for: .results([calculationRowHeight] + Array(repeating: rowHeight, count: Int(maxVisibleRows) + 1)))
            + noticeHeight
    }
}

/// 输入框下面显示什么。
enum LauncherPanelContent: Equatable {
    /// 输入为空、也没有用过的行：一行提示。
    case hint
    /// 输入了，但一个都没中。
    case noResults
    /// 一行都还没有、后台的结果（路径、文件）还没回来。
    case searching
    /// 有结果：值是每一行的高度（计算结果那一行比普通行高）。
    case results([CGFloat])
}

// MARK: - 状态

/// 面板的显示状态。只在主线程改；控制器负责搜索和执行，这里只记显示和选中。
@MainActor
final class LauncherPanelModel: ObservableObject {
    @Published private(set) var rows: [LauncherRow] = []
    @Published private(set) var content: LauncherPanelContent = .hint
    @Published private(set) var selectedIndex = 0
    /// 选中哪一行、这次输入以来用户手动选过没有（规则见 `LauncherSelectionState`）。
    private var selection = LauncherSelectionState()
    /// 每换一批结果 +1：列表回到顶上。
    @Published private(set) var resultsVersion = 0

    /// 输入框的引用：控制器经它设文字、给焦点、问输入法是否在组字。
    let field = LauncherFieldHandle()
    /// 输入框里上屏的文字变了（组字中的不算）。
    var onTextChange: (String) -> Void = { _ in }
    /// 执行第 N 行（单击）。
    var onRun: (Int) -> Void = { _ in }
    /// 文件图标（App、文件、文件夹行）。
    var iconForFile: (String) -> NSImage? = { _ in nil }
    /// 图片条目的缩略图（参数是行 id）：缓存里有就给，没有就在后台去取、先返回 nil，取到后 `thumbnailsChanged()`。
    var thumbnailForRow: (String) -> NSImage? = { _ in nil }
    /// 输入里挂着的图片（输入框左边的小标签）；nil = 没挂。
    @Published var attachment: LauncherAttachmentChip?
    /// 每取到一批缩略图 +1：列表重画、换上缩略图。
    @Published private(set) var thumbnailsVersion = 0
    /// 列表最下面一行不可选的小字提示（快捷键确实和 Raycast 撞了，§9）；nil = 不显示。呼出时定，换了快捷键 / 退出那个 App 后下次就没了。
    @Published var notice: String?

    func thumbnailsChanged() {
        thumbnailsVersion += 1
    }

    /// 鼠标上次的位置：悬停只有在鼠标真的动过之后才改选中行 —— 面板出现在鼠标下面、
    /// 打字换了一批结果、键盘选行之后，停着不动的鼠标下面换了一行，都不算。
    private var hoverBaseline: NSPoint?

    var panelHeight: CGFloat { LauncherLayout.height(for: content) + (notice == nil ? 0 : LauncherLayout.noticeHeight) }

    /// 换一批结果。`emptyInput`：查询词为空（没结果时显示提示，而不是「没有结果」）。
    /// `newInput`：输入变了 → 选中第一行，「手动选过」清零；false = 同一个输入、后台结果回来（文件、路径、搜索键、识别结果）——
    /// 没手动选过选中第一行，手动选过留在他选的那一行（`LauncherSelectionState.rowsChanged`，PR 11 复查后定）。
    /// `searching`：后台的结果还没回来，一行都没有时显示「正在查找」而不是「没有结果」。
    func setRows(_ rows: [LauncherRow], emptyInput: Bool, newInput: Bool = true, searching: Bool = false) {
        let scrollsToTop = selection.rowsChanged(from: self.rows.map(\.id), to: rows.map(\.id), newInput: newInput)
        self.rows = rows
        if rows.isEmpty {
            content = searching ? .searching : (emptyInput ? .hint : .noResults)
        } else {
            content = .results(rows.map(LauncherLayout.rowHeight(for:)))
        }
        selectedIndex = selection.index
        if scrollsToTop { resultsVersion += 1 }
        resetHoverBaseline()
    }

    /// ↑ ↓：到头不循环。算手动选过。
    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection.move(by: delta, rowCount: rows.count)
        selectedIndex = selection.index
        resetHoverBaseline()
    }

    /// 鼠标悬停在第 N 行上（鼠标真的动过才算；换了一行算手动选过）。
    func hover(_ index: Int) {
        let location = NSEvent.mouseLocation
        guard location != hoverBaseline else { return }
        hoverBaseline = location
        selection.hover(index, rowCount: rows.count)
        selectedIndex = selection.index
    }

    func resetHoverBaseline() {
        hoverBaseline = NSEvent.mouseLocation
    }
}

// MARK: - 输入框

/// 控制器拿输入框用：设文字、给焦点、问输入法是否在组字。
@MainActor
final class LauncherFieldHandle {
    fileprivate(set) weak var field: LauncherTextField?

    /// 输入法正在组字（拼音还没上屏）：这时 ⏎ / ↑ ↓ / Esc 都归输入法。
    var isComposing: Bool {
        (field?.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
    }

    func setText(_ text: String) {
        field?.stringValue = text
    }

    /// 把输入框的内容整个换成 `text`、光标放到末尾（Tab 补全路径）。走编辑器的 `insertText`，
    /// 和打字一样会回调文字变化，也能 ⌘Z 撤销；输入框不在编辑时直接设文字（这时不会回调，调用方自己刷新）。
    func replaceText(_ text: String) {
        guard let field else { return }
        guard let editor = field.currentEditor() as? NSTextView else {
            field.stringValue = text
            return
        }
        editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    }

    /// 标准编辑动作（粘贴、拷贝、剪切、全选、撤销、重做）。
    enum Edit { case paste, copy, cut, selectAll, undo, redo }

    /// 直接对输入框的编辑器执行编辑动作，不经主菜单（面板是 key、Baobox 不是前台 App 时主菜单的快捷键不生效）。
    /// 返回 false = 输入框不在编辑，或这一步现在做不了（没有可撤销的）。
    func perform(_ edit: Edit) -> Bool {
        guard let editor = field?.currentEditor() else { return false }
        switch edit {
        case .paste: editor.paste(nil)
        case .copy: editor.copy(nil)
        case .cut: editor.cut(nil)
        case .selectAll: editor.selectAll(nil)
        case .undo:
            guard let manager = editor.undoManager, manager.canUndo else { return false }
            manager.undo()
        case .redo:
            guard let manager = editor.undoManager, manager.canRedo else { return false }
            manager.redo()
        }
        return true
    }

    /// 让输入框拿焦点。NSTextField 成为第一响应者时会全选里面的文字，所以保留的上次输入直接打字就覆盖。
    func focus() {
        guard let field, let window = field.window else { return }
        window.makeFirstResponder(field)
    }

    /// 输入框不在编辑时才给焦点（已经在编辑就不动：再给一次会全选，接着打的字会把刚放进去的路径覆盖掉）。
    func focusIfNeeded() {
        guard field?.currentEditor() == nil else { return }
        focus()
    }
}

/// 输入框本体。进了窗口还没拿到焦点就自己要一次（兜底：控制器在显示后已经同步给过焦点）。
final class LauncherTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                // 已经在编辑就别再要：再要一次会全选，用户刚打的字会被下一个字覆盖。
                guard let self, let window = self.window, self.currentEditor() == nil else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}

struct LauncherSearchField: NSViewRepresentable {
    let handle: LauncherFieldHandle
    /// 输入框为空时的提示（挂着图片时换一句）。
    var placeholder: String = L("launcher.placeholder")
    let onTextChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> LauncherTextField {
        let field = LauncherTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.textColor = .labelColor
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        // 不让长输入把面板撑宽。
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handle.field = field
        return field
    }

    func updateNSView(_ field: LauncherTextField, context: Context) {
        // 文字以输入框为准，这里不回写（组字时回写会打断输入法）。
        context.coordinator.onTextChange = onTextChange
        handle.field = field
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onTextChange: (String) -> Void

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
        }

        /// 上屏的文字变了才搜：组字中的拼音（`wei'xin`）不算，从编辑器的文字里去掉标记的那段。
        /// 直接读编辑器，不读 `stringValue`：后者会先提交编辑，组字时可能打断输入法。
        func controlTextDidChange(_ notification: Notification) {
            guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else {
                if let field = notification.object as? NSTextField { onTextChange(field.stringValue) }
                return
            }
            var text = editor.string
            if editor.hasMarkedText() {
                let marked = editor.markedRange()
                let string = text as NSString
                if marked.location != NSNotFound, NSMaxRange(marked) <= string.length {
                    text = string.replacingCharacters(in: marked, with: "")
                }
            }
            onTextChange(text)
        }

        /// 面板的键盘监听已经处理了这些键；这里兜底：别让 Tab 把焦点移走、⏎ / Esc 结束编辑。
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
                 #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
                 #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - 面板

/// 面板外框：毛玻璃、圆角 14、细描边，高度跟内容走、顶边固定（窗口比内容高的那一刻，内容贴着顶边）。
struct LauncherPanelView: View {
    @ObservedObject var model: LauncherPanelModel

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            switch model.content {
            case .hint:
                message("launcher.hint.empty")
            case .noResults:
                message("launcher.noResults")
            case .searching:
                message("launcher.searching")
            case .results:
                resultList
            }
            if let notice = model.notice {
                Divider()
                noticeLine(notice)
            }
        }
        .frame(width: LauncherLayout.width, height: model.panelHeight, alignment: .top)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: LauncherLayout.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LauncherLayout.cornerRadius, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
            // 挂着的图片（§5.5）：放大镜和文字之间一个小标签，输入框跟着变窄。
            if let attachment = model.attachment {
                LauncherAttachmentChipView(chip: attachment)
            }
            LauncherSearchField(handle: model.field,
                                placeholder: model.attachment == nil ? L("launcher.placeholder") : L("launcher.placeholder.image")) {
                [weak model] text in
                model?.onTextChange(text)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: LauncherLayout.searchBarHeight)
    }

    private func message(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(height: LauncherLayout.messageHeight)
    }

    /// 最下面那行提示：小字、不可选（不是一行结果，键盘、鼠标都选不到）。
    private func noticeLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(verbatim: text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .frame(height: LauncherLayout.noticeHeight - 1)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    // 读一下：缩略图到了要重画（`thumbnailForRow` 本身不是被观察的值）。
                    let _ = model.thumbnailsVersion
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        LauncherResultRow(row: row,
                                          shortcutNumber: index < 9 ? index + 1 : nil,
                                          selected: index == model.selectedIndex,
                                          fileIcon: fileIcon(for: row))
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.onRun(index) }
                            .onContinuousHover { phase in
                                if case .active = phase { model.hover(index) }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, LauncherLayout.listPadding)
            }
            .onChange(of: model.selectedIndex) { _, index in
                guard model.rows.indices.contains(index) else { return }
                proxy.scrollTo(model.rows[index].id)
            }
            .onChange(of: model.resultsVersion) { _, _ in
                if let first = model.rows.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    private func fileIcon(for row: LauncherRow) -> NSImage? {
        switch row.icon {
        case .file(let path): return model.iconForFile(path)
        case .thumbnail: return model.thumbnailForRow(row.id)
        default: return nil
        }
    }
}

/// 结果行：图标 + 标题（+ 灰色副标题）+ 右侧来源小字 + ⌘N；选中时强调色底、白字（自己画，不看窗口是否活动）。
/// 计算结果那一行更醒目：结果用大一号的字，下面一行小字写它是怎么理解的。
struct LauncherResultRow: View {
    let row: LauncherRow
    /// 前 9 行显示 ⌘1…⌘9。
    let shortcutNumber: Int?
    let selected: Bool
    /// App、文件的真实图标；命令为 nil（用 SF Symbol）。
    let fileIcon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            icon
            titleBlock
            Spacer(minLength: 12)
            Text(verbatim: row.source)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            if let shortcutNumber {
                Text(verbatim: "⌘\(shortcutNumber)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.8))
                    .frame(width: 26, alignment: .trailing)
            } else {
                Color.clear.frame(width: 26, height: 1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: LauncherLayout.rowHeight(for: row))
        .background(selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var titleBlock: some View {
        switch row.style {
        case .standard:
            // 副标题（文件所在目录）跟在标题后面、同一行：行高不变。标题先占够，副标题放不下时中间截断。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: row.title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .layoutPriority(1)
                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                }
            }
        case .calculation(let interpretation, let failed):
            VStack(alignment: .leading, spacing: 2) {
                // 出错时这里是一句说明（「不能除以零」），不是结果：字小一号、用次要色，别让人当成答案。
                Text(verbatim: row.title)
                    .font(failed ? .system(size: 16, weight: .medium) : .system(size: 20, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white.opacity(failed ? 0.85 : 1) : (failed ? Color.secondary : Color.primary))
                if !interpretation.isEmpty {
                    Text(verbatim: interpretation)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let fileIcon, case .thumbnail = row.icon {
            LauncherThumbnailIcon(image: fileIcon, selected: selected)
        } else if let fileIcon {
            Image(nsImage: fileIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
        } else if case .swatch(let color) = row.icon {
            LauncherColorSwatch(color: color, selected: selected)
        } else if let name = symbolName {
            Image(systemName: name)
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
                .background(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(selected ? Color.white : Color.primary)
        } else {
            Color.clear.frame(width: 26, height: 26)
        }
    }

    /// SF Symbol 图标：命令行的图标；缩略图还没取到时的占位。
    private var symbolName: String? {
        switch row.icon {
        case .symbol(let name): return name
        case .thumbnail(let placeholder): return placeholder
        default: return nil
        }
    }
}
