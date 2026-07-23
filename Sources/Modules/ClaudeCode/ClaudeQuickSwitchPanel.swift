import AppKit
import SwiftUI

/// Claude Code 助手 —— Spotlight 式快速续接面板。
///
/// 全局快捷键 / 菜单唤出:搜索框 + 会话列表,↑↓ 选择、⏎ 在终端续接、⌘C 复制续接命令、
/// Esc 或点击面板外关闭。交互与实现完全对齐剪贴板面板(ClipboardPanelController):
/// 非激活 borderless NSPanel + 本地键盘监听;搜索框始终持焦,裸字符留给它输入,
/// 因此「复制命令」用 ⌘C 而非裸 c。列表元信息行复用菜单的 SessionRowFormatStore 方案。

/// borderless 非激活面板,必须子类覆写 canBecomeKey 才能接收键盘输入。
final class ClaudeQuickSwitchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - 视图模型

@MainActor
final class ClaudeQuickSwitchViewModel: ObservableObject {
    @Published var query = ""
    @Published var selectedIndex = 0

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

    var selectedSession: ClaudeSessionSummary? {
        let list = filtered
        guard list.indices.contains(selectedIndex) else { return nil }
        return list[selectedIndex]
    }

    func resetForShow() {
        query = ""
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

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        ClaudeSessionIndex.shared.refresh()
        viewModel.resetForShow()

        let content = ClaudeQuickSwitchView(
            viewModel: viewModel,
            onResume: { [weak self] session in self?.resume(session) },
            onCopy: { [weak self] session in self?.copyCommand(session) }
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
        case 0x24, 0x4C: // Return / Enter → 续接
            if let session = viewModel.selectedSession {
                resume(session)
            }
            return true
        case 0x08 where event.modifierFlags.contains(.command): // ⌘C(C=0x08)→ 复制续接命令
            if let session = viewModel.selectedSession {
                copyCommand(session)
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
}

// MARK: - 视图

struct ClaudeQuickSwitchView: View {
    @ObservedObject var viewModel: ClaudeQuickSwitchViewModel
    @ObservedObject private var index = ClaudeSessionIndex.shared
    @ObservedObject private var format = SessionRowFormatStore.shared
    var onResume: (ClaudeSessionSummary) -> Void
    var onCopy: (ClaudeSessionSummary) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
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
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField("claudecode.quickswitch.placeholder", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var listArea: some View {
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
                    if let session = viewModel.selectedSession {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(session.id, anchor: .center)
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

    private var footer: some View {
        HStack(spacing: 16) {
            Text("claudecode.quickswitch.count \(viewModel.filtered.count)")
            Spacer()
            hint("↑↓", L("claudecode.quickswitch.hint.select"))
            hint("⏎", L("claudecode.quickswitch.hint.resume"))
            hint("⌘C", L("claudecode.quickswitch.hint.copy"))
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
