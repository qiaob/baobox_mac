import AppKit
import SwiftUI

/// Claude Code 助手 —— Spotlight 式快速面板：会话续接 + 最近文件双模式。
///
/// 全局快捷键 / 菜单唤出。会话模式:搜索框 + 会话列表,↑↓ 选择、⏎ 在终端续接、⌘C 复制续接命令;
/// 文件模式(RECENT_FILES.md):列出会话写过的文件,类型筛选 chips,⏎ 按类别偏好应用打开、
/// ⌘⏎ 访达显示、⌘C 复制路径。⇥ 在两模式间切换(本地监听消费,焦点始终留在搜索框)。
/// Esc 或点击面板外关闭。窗口外壳、键码、过滤与选中、会话栏视图与 Codex 助手共用 `Core/QuickSwitch/`(#109);
/// 这里留 Claude 的会话数据源(第二行复用菜单的 SessionRowFormatStore 方案、续接先找正在跑的窗口)
/// 与「最近文件」模式(chips、文件列表、文件动作)。

/// 面板两种模式。菜单入口显式指定;快捷键 toggle 沿用上次(进程内记忆)。
enum ClaudePanelMode {
    case sessions
    case files
}

// MARK: - 会话数据源

/// 面板「会话」栏的 Claude Code 数据源。
@MainActor
struct ClaudeQuickSwitchSource: QuickSwitchSessionSource {
    var sessions: [ClaudeSessionSummary] { ClaudeSessionIndex.shared.sessions }

    func refresh() {
        ClaudeSessionIndex.shared.refresh()
    }

    /// 第二行 = 菜单同款的会话行方案。
    func metadataLine(for session: ClaudeSessionSummary) -> String {
        SessionRowFormatStore.shared.metadataLine(for: session)
    }

    func resume(_ session: ClaudeSessionSummary) {
        // 会话已在某个终端窗口里跑、且能定位到那个窗口时,只把它切到前台;
        // 其余情况(没在跑 / 定位不到宿主终端,如 tmux、SSH)一律照常开新窗口。
        let isNewest = ClaudeSessionIndex.shared.sessions
            .first(where: { $0.projectPath == session.projectPath })?.id == session.id
        let sessionID = session.id
        let projectPath = session.projectPath
        DispatchQueue.global(qos: .userInitiated).async {
            let running = TerminalLauncher.findRunningSession(
                sessionID: sessionID, projectPath: projectPath, isNewestInProject: isNewest)
            DispatchQueue.main.async {
                if let running, TerminalLauncher.focusTerminalWindow(of: running) {
                    return
                }
                TerminalLauncher.resume(sessionID: sessionID, in: projectPath)
            }
        }
    }

    func resumeCommand(for session: ClaudeSessionSummary) -> String {
        TerminalLauncher.resumeCommandString(sessionID: session.id, in: session.projectPath)
    }
}

// MARK: - 视图模型

@MainActor
final class ClaudeQuickSwitchViewModel: ObservableObject {
    @Published var query = ""
    @Published var selectedIndex = 0
    @Published var mode: ClaudePanelMode = .sessions
    /// 文件模式的类别筛选;nil = 全部。
    @Published var categoryFilter: ClaudeFileCategory?

    let source = ClaudeQuickSwitchSource()

    var filtered: [ClaudeSessionSummary] {
        source.sessions(matching: query)
    }

    /// 搜索词过滤后、未按类别筛的文件集合(chips 计数的分母)。匹配文件名 / 全路径 / 项目名,规则同会话。
    var queryFilteredFiles: [ClaudeRecentFile] {
        QuickSwitchSelection.filter(ClaudeFileIndex.shared.files, query: query,
                                    fields: [\.fileName, \.filePath, \.projectName])
    }

    var filteredFiles: [ClaudeRecentFile] {
        let base = queryFilteredFiles
        guard let filter = categoryFilter else { return base }
        return base.filter { $0.category == filter }
    }

    func categoryCount(_ category: ClaudeFileCategory?) -> Int {
        let base = queryFilteredFiles
        guard let category else { return base.count }
        return base.reduce(0) { $0 + ($1.category == category ? 1 : 0) }
    }

    var selectedSession: ClaudeSessionSummary? {
        QuickSwitchSelection.element(filtered, at: selectedIndex)
    }

    var selectedFile: ClaudeRecentFile? {
        QuickSwitchSelection.element(filteredFiles, at: selectedIndex)
    }

    private var currentCount: Int {
        mode == .sessions ? filtered.count : filteredFiles.count
    }

    func resetForShow() {
        // mode 保留(进程内记忆);查询 / 选中 / 类别筛选每次打开归零。
        query = ""
        selectedIndex = 0
        categoryFilter = nil
    }

    func toggleMode() {
        mode = mode == .sessions ? .files : .sessions
        selectedIndex = 0
    }

    func setCategory(_ category: ClaudeFileCategory?) {
        categoryFilter = category
        selectedIndex = 0
    }

    /// ←→ 循环切换类别筛选：全部 → 文档 → 网页 → 代码 → 配置 → 其他 → 全部。
    func cycleCategory(_ delta: Int) {
        let choices: [ClaudeFileCategory?] = [nil] + ClaudeFileCategory.allCases
        let current = choices.firstIndex(where: { $0 == categoryFilter }) ?? 0
        setCategory(choices[QuickSwitchSelection.cycled(current, by: delta, count: choices.count)])
    }

    func moveSelection(_ delta: Int) {
        let count = currentCount
        guard count > 0 else { return }
        selectedIndex = QuickSwitchSelection.moved(selectedIndex, by: delta, count: count)
    }

    func clampSelection() {
        let count = currentCount
        let clamped = QuickSwitchSelection.clamped(selectedIndex, count: count)
        // 什么时候写同原来:空列表总是写 0,否则只在越界时写。
        if count == 0 || clamped != selectedIndex { selectedIndex = clamped }
    }
}

// MARK: - 控制器

@MainActor
final class ClaudeQuickSwitchController: NSObject {
    static let shared = ClaudeQuickSwitchController()

    private let viewModel = ClaudeQuickSwitchViewModel()
    private let host = QuickSwitchPanelHost()

    var isVisible: Bool { host.isVisible }

    /// mode 为 nil 表示沿用上次模式(快捷键语义);菜单入口传显式模式。
    func toggle(mode: ClaudePanelMode? = nil) {
        if isVisible { hide() } else { show(mode: mode) }
    }

    /// 最近文件入口:未开则以文件模式打开;已开且在会话模式则切到文件模式;已是文件模式则收起。
    func showFiles() {
        if isVisible {
            if viewModel.mode == .files {
                hide()
            } else {
                viewModel.mode = .files
                viewModel.selectedIndex = 0
            }
        } else {
            show(mode: .files)
        }
    }

    func show(mode: ClaudePanelMode? = nil) {
        viewModel.source.refresh()
        ClaudeFileIndex.shared.refresh()
        if let mode { viewModel.mode = mode }
        viewModel.resetForShow()

        let content = ClaudeQuickSwitchView(
            viewModel: viewModel,
            onResume: { [weak self] session in self?.resume(session) },
            onOpenFile: { [weak self] file in self?.openFile(file) }
        )
        host.show(content) { [weak self] event in self?.handleKey(event) ?? false }
    }

    func hide() {
        host.hide()
    }

    /// 返回 true 表示已消费(不再传给搜索框)。裸字符一律放行给搜索框。
    private func handleKey(_ event: NSEvent) -> Bool {
        switch QuickSwitchKey(event) {
        case .down:
            viewModel.moveSelection(1)
            return true
        case .up:
            viewModel.moveSelection(-1)
            return true
        case .tab: // 会话/文件模式切换(消费掉,不触发 SwiftUI 焦点遍历)
            viewModel.toggleMode()
            return true
        case .left where viewModel.mode == .files: // ← 切换类型筛选。搜索框有内容时不拦 —— 留给光标移动(同剪贴板面板)。
            guard viewModel.query.isEmpty else { return false }
            viewModel.cycleCategory(-1)
            return true
        case .right where viewModel.mode == .files: // → 同上
            guard viewModel.query.isEmpty else { return false }
            viewModel.cycleCategory(1)
            return true
        case .enter(let command): // 会话:续接;文件:打开(⌘⏎ 访达显示)
            switch viewModel.mode {
            case .sessions:
                if let session = viewModel.selectedSession {
                    resume(session)
                }
            case .files:
                if let file = viewModel.selectedFile {
                    if command {
                        revealFile(file)
                    } else {
                        openFile(file)
                    }
                }
            }
            return true
        case .copy: // ⌘C → 会话:复制续接命令;文件:复制路径
            switch viewModel.mode {
            case .sessions:
                if let session = viewModel.selectedSession {
                    copyCommand(session)
                }
            case .files:
                if let file = viewModel.selectedFile {
                    copyPath(file)
                }
            }
            return true
        case .escape:
            hide()
            return true
        case .left, .right, nil: // 会话模式的 ←→ 与其余按键交给搜索框
            return false
        }
    }

    // MARK: 动作

    private func resume(_ session: ClaudeSessionSummary) {
        hide()
        viewModel.source.resume(session)
    }

    private func copyCommand(_ session: ClaudeSessionSummary) {
        let command = viewModel.source.resumeCommand(for: session)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        hide()
    }

    private func openFile(_ file: ClaudeRecentFile) {
        // 先发起打开再收面板：hide() 会释放面板与承载视图,若从视图手势里调用,
        // 放在打开之后可避免在同一次事件派发中边拆窗口边发起打开。
        ClaudeFileOpener.open(file)
        hide()
    }

    private func revealFile(_ file: ClaudeRecentFile) {
        ClaudeFileOpener.reveal(file)
        hide()
    }

    private func copyPath(_ file: ClaudeRecentFile) {
        ClaudeFileOpener.copyPath(file)
        hide()
    }
}

// MARK: - 视图

struct ClaudeQuickSwitchView: View {
    @ObservedObject var viewModel: ClaudeQuickSwitchViewModel
    @ObservedObject private var index = ClaudeSessionIndex.shared
    @ObservedObject private var fileIndex = ClaudeFileIndex.shared
    @ObservedObject private var format = SessionRowFormatStore.shared
    var onResume: (ClaudeSessionSummary) -> Void
    var onOpenFile: (ClaudeRecentFile) -> Void

    var body: some View {
        QuickSwitchCard {
            searchBar
            Divider()
            if viewModel.mode == .files {
                chipsRow
                Divider()
            }
            listArea
            Divider()
            footer
        }
        .onChange(of: viewModel.query) { _, _ in viewModel.clampSelection() }
        // segmented 直接改 mode 不经 toggleMode,这里统一归零选中。
        .onChange(of: viewModel.mode) { _, _ in viewModel.selectedIndex = 0 }
    }

    private var searchBar: some View {
        QuickSwitchSearchBar(
            symbol: viewModel.mode == .sessions ? "terminal" : "doc.on.doc",
            placeholder: viewModel.mode == .sessions
                ? "claudecode.quickswitch.placeholder"
                : "claudecode.files.placeholder",
            text: $viewModel.query
        ) {
            Picker("", selection: $viewModel.mode) {
                Text("claudecode.quickswitch.mode.sessions").tag(ClaudePanelMode.sessions)
                Text("claudecode.quickswitch.mode.files").tag(ClaudePanelMode.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // 不可获得键盘焦点:否则鼠标点过分段控件后,←→ 会被它吃掉去切分段(而不是切类型筛选)。
            .focusable(false)
        }
    }

    /// 类型筛选 chips(仅文件模式)。计数分母 = 当前搜索词过滤后的集合。
    private var chipsRow: some View {
        HStack(spacing: 6) {
            chip(nil)
            ForEach(ClaudeFileCategory.allCases) { category in
                chip(category)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func chip(_ category: ClaudeFileCategory?) -> some View {
        let active = viewModel.categoryFilter == category
        let title = category?.title ?? L("claudecode.files.category.all")
        let count = viewModel.categoryCount(category)
        return Button {
            viewModel.setCategory(category)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: title)
                Text(verbatim: "\(count)")
                    .foregroundStyle(active ? Color.white.opacity(0.75) : Color.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
            .opacity(count == 0 && !active ? 0.5 : 1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var listArea: some View {
        switch viewModel.mode {
        case .sessions:
            QuickSwitchSessionList(source: viewModel.source,
                                   sessions: viewModel.filtered,
                                   selectedIndex: $viewModel.selectedIndex,
                                   emptyText: "claudecode.quickswitch.empty",
                                   onResume: onResume)
        case .files:
            fileList
        }
    }

    @ViewBuilder
    private var fileList: some View {
        let list = viewModel.filteredFiles
        if list.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                if fileIndex.isRefreshing && fileIndex.files.isEmpty {
                    // 首次全量索引可达数百 MB,给出加载态。
                    ProgressView()
                        .controlSize(.small)
                    Text("claudecode.files.loading")
                        .foregroundStyle(.secondary)
                } else {
                    Text("claudecode.files.empty")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, file in
                            fileRow(file: file, selected: index == viewModel.selectedIndex)
                                .id(file.id)
                                .contentShape(Rectangle())
                                // 文件模式单击即打开(Spotlight / Raycast 惯例);会话模式仍是单击选中、双击续接。
                                .onTapGesture {
                                    viewModel.selectedIndex = index
                                    onOpenFile(file)
                                }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: viewModel.selectedIndex) { _, _ in
                    if viewModel.mode == .files, let file = viewModel.selectedFile {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(file.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func fileRow(file: ClaudeRecentFile, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: ClaudeFileIconCache.icon(forFileName: file.fileName))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.fileName)
                    .lineLimit(1)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(verbatim: "\(file.projectName) · \(file.filePath)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
            }
            Spacer(minLength: 8)
            Text(verbatim: ClaudeFormat.relative(file.lastWritten))
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var footer: some View {
        QuickSwitchFooter {
            switch viewModel.mode {
            case .sessions:
                Text("claudecode.quickswitch.count \(viewModel.filtered.count)")
            case .files:
                Text("claudecode.files.count \(viewModel.filteredFiles.count)")
            }
            Spacer()
            QuickSwitchKeyHint(key: "⇥", label: L("claudecode.quickswitch.hint.switchMode"))
            switch viewModel.mode {
            case .sessions:
                QuickSwitchKeyHint(key: "↑↓", label: L("claudecode.quickswitch.hint.select"))
                QuickSwitchKeyHint(key: "⏎", label: L("claudecode.quickswitch.hint.resume"))
                QuickSwitchKeyHint(key: "⌘C", label: L("claudecode.quickswitch.hint.copy"))
            case .files:
                // 空间所限省略 ↑↓(与会话模式一致,无需重复教学)。
                QuickSwitchKeyHint(key: "←→", label: L("claudecode.files.hint.filter"))
                QuickSwitchKeyHint(key: "⏎", label: L("claudecode.files.hint.open"))
                QuickSwitchKeyHint(key: "⌘⏎", label: L("claudecode.files.hint.reveal"))
                QuickSwitchKeyHint(key: "⌘C", label: L("claudecode.files.hint.copyPath"))
            }
            QuickSwitchKeyHint(key: "esc", label: L("claudecode.quickswitch.hint.close"))
        }
    }
}
