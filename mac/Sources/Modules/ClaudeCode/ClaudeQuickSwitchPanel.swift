import AppKit
import SwiftUI

/// Claude Code 助手 —— Spotlight 式快速面板：会话续接 + 最近文件双模式。
///
/// 全局快捷键 / 菜单唤出。会话模式:搜索框 + 会话列表,↑↓ 选择、⏎ 在终端续接、⌘C 复制续接命令;
/// 文件模式(RECENT_FILES.md):列出会话写过的文件,类型筛选 chips,⏎ 按类别偏好应用打开、
/// ⌘⏎ 访达显示、⌘C 复制路径。⇥ 在两模式间切换(本地监听消费,焦点始终留在搜索框)。
/// Esc 或点击面板外关闭。交互与实现完全对齐剪贴板面板(ClipboardPanelController):
/// 非激活 borderless NSPanel + 本地键盘监听;搜索框始终持焦,裸字符留给它输入,
/// 因此「复制」类动作用 ⌘ 组合而非裸字符。会话列表元信息行复用菜单的 SessionRowFormatStore 方案。

/// borderless 非激活面板,必须子类覆写 canBecomeKey 才能接收键盘输入。
final class ClaudeQuickSwitchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 面板两种模式。菜单入口显式指定;快捷键 toggle 沿用上次(进程内记忆)。
enum ClaudePanelMode {
    case sessions
    case files
}

// MARK: - 视图模型

@MainActor
final class ClaudeQuickSwitchViewModel: ObservableObject {
    @Published var query = ""
    @Published var selectedIndex = 0
    @Published var mode: ClaudePanelMode = .sessions
    /// 文件模式的类别筛选;nil = 全部。
    @Published var categoryFilter: ClaudeFileCategory?

    var filtered: [ClaudeSessionSummary] {
        let sessions = ClaudeSessionIndex.shared.sessions
        guard !query.isEmpty else { return sessions }
        let q = query.lowercased()
        return sessions.filter {
            $0.title.lowercased().contains(q)
                || $0.projectName.lowercased().contains(q)
                || $0.projectPath.lowercased().contains(q)
        }
    }

    /// 搜索词过滤后、未按类别筛的文件集合(chips 计数的分母)。
    var queryFilteredFiles: [ClaudeRecentFile] {
        let files = ClaudeFileIndex.shared.files
        guard !query.isEmpty else { return files }
        let q = query.lowercased()
        return files.filter {
            $0.fileName.lowercased().contains(q)
                || $0.filePath.lowercased().contains(q)
                || $0.projectName.lowercased().contains(q)
        }
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
        let list = filtered
        guard list.indices.contains(selectedIndex) else { return nil }
        return list[selectedIndex]
    }

    var selectedFile: ClaudeRecentFile? {
        let list = filteredFiles
        guard list.indices.contains(selectedIndex) else { return nil }
        return list[selectedIndex]
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
        let count = choices.count
        let next = ((current + delta) % count + count) % count
        setCategory(choices[next])
    }

    func moveSelection(_ delta: Int) {
        let count = currentCount
        guard count > 0 else { return }
        selectedIndex = min(max(0, selectedIndex + delta), count - 1)
    }

    func clampSelection() {
        let count = currentCount
        if count == 0 { selectedIndex = 0 }
        else if selectedIndex >= count { selectedIndex = count - 1 }
    }
}

// MARK: - 控制器

@MainActor
final class ClaudeQuickSwitchController: NSObject {
    static let shared = ClaudeQuickSwitchController()

    private let viewModel = ClaudeQuickSwitchViewModel()
    private var panel: ClaudeQuickSwitchWindow?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

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
        ClaudeSessionIndex.shared.refresh()
        ClaudeFileIndex.shared.refresh()
        if let mode { viewModel.mode = mode }
        viewModel.resetForShow()

        let content = ClaudeQuickSwitchView(
            viewModel: viewModel,
            onResume: { [weak self] session in self?.resume(session) },
            onCopy: { [weak self] session in self?.copyCommand(session) },
            onOpenFile: { [weak self] file in self?.openFile(file) }
        )
        let hosting = NSHostingView(rootView: content)

        let panel = ClaudeQuickSwitchWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hosting

        // 居中于鼠标所在屏,略高于正中(Spotlight 习惯位)。
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - 320, y: visible.midY - 140)
            panel.setFrameOrigin(origin)
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        installMonitors()
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: 事件监听

    private func installMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handleKey(event) ? nil : event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeMonitors() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localKeyMonitor = nil
        globalClickMonitor = nil
    }

    /// 返回 true 表示已消费(不再传给搜索框)。裸字符一律放行给搜索框。
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D: // ↓
            viewModel.moveSelection(1)
            return true
        case 0x7E: // ↑
            viewModel.moveSelection(-1)
            return true
        case 0x30: // Tab → 会话/文件模式切换(消费掉,不触发 SwiftUI 焦点遍历)
            viewModel.toggleMode()
            return true
        case 0x7B where viewModel.mode == .files: // ← 切换类型筛选。搜索框有内容时不拦 —— 留给光标移动(同剪贴板面板)。
            guard viewModel.query.isEmpty else { return false }
            viewModel.cycleCategory(-1)
            return true
        case 0x7C where viewModel.mode == .files: // → 同上
            guard viewModel.query.isEmpty else { return false }
            viewModel.cycleCategory(1)
            return true
        case 0x24, 0x4C: // Return / Enter → 会话:续接;文件:打开(⌘⏎ 访达显示)
            switch viewModel.mode {
            case .sessions:
                if let session = viewModel.selectedSession {
                    resume(session)
                }
            case .files:
                if let file = viewModel.selectedFile {
                    if event.modifierFlags.contains(.command) {
                        revealFile(file)
                    } else {
                        openFile(file)
                    }
                }
            }
            return true
        case 0x08 where event.modifierFlags.contains(.command): // ⌘C(C=0x08)→ 会话:复制续接命令;文件:复制路径
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
        case 0x35: // Esc
            hide()
            return true
        default:
            return false
        }
    }

    // MARK: 动作

    private func resume(_ session: ClaudeSessionSummary) {
        hide()
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

    private func copyCommand(_ session: ClaudeSessionSummary) {
        let command = TerminalLauncher.resumeCommandString(sessionID: session.id, in: session.projectPath)
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
    var onCopy: (ClaudeSessionSummary) -> Void
    var onOpenFile: (ClaudeRecentFile) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
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
        .frame(width: 640, height: 420)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        // 置焦点必须晚于 makeKeyAndOrderFront,同剪贴板面板的时序说明。
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            searchFocused = true
        }
        .onChange(of: viewModel.query) { _, _ in viewModel.clampSelection() }
        // segmented 直接改 mode 不经 toggleMode,这里统一归零选中。
        .onChange(of: viewModel.mode) { _, _ in viewModel.selectedIndex = 0 }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.mode == .sessions ? "terminal" : "doc.on.doc")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField(viewModel.mode == .sessions
                          ? "claudecode.quickswitch.placeholder"
                          : "claudecode.files.placeholder",
                      text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
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
        case .sessions: sessionList
        case .files: fileList
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        let list = viewModel.filtered
        if list.isEmpty {
            VStack {
                Spacer()
                Text("claudecode.quickswitch.empty")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, session in
                            row(session: session, selected: index == viewModel.selectedIndex)
                                .id(session.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onResume(session) }
                                .onTapGesture { viewModel.selectedIndex = index }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: viewModel.selectedIndex) { _, _ in
                    if viewModel.mode == .sessions, let session = viewModel.selectedSession {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(session.id, anchor: .center)
                        }
                    }
                }
            }
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

    private func row(session: ClaudeSessionSummary, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .frame(width: 28, height: 28)
                .background(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(selected ? Color.white : Color.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: session.title)
                    .lineLimit(1)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                let meta = format.metadataLine(for: session)
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
        HStack(spacing: 16) {
            switch viewModel.mode {
            case .sessions:
                Text("claudecode.quickswitch.count \(viewModel.filtered.count)")
            case .files:
                Text("claudecode.files.count \(viewModel.filteredFiles.count)")
            }
            Spacer()
            hint("⇥", L("claudecode.quickswitch.hint.switchMode"))
            switch viewModel.mode {
            case .sessions:
                hint("↑↓", L("claudecode.quickswitch.hint.select"))
                hint("⏎", L("claudecode.quickswitch.hint.resume"))
                hint("⌘C", L("claudecode.quickswitch.hint.copy"))
            case .files:
                // 空间所限省略 ↑↓(与会话模式一致,无需重复教学)。
                hint("←→", L("claudecode.files.hint.filter"))
                hint("⏎", L("claudecode.files.hint.open"))
                hint("⌘⏎", L("claudecode.files.hint.reveal"))
                hint("⌘C", L("claudecode.files.hint.copyPath"))
            }
            hint("esc", L("claudecode.quickswitch.hint.close"))
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
}
