import AppKit
import SwiftUI

/// Codex 助手 —— Spotlight 式快速续接面板（对齐 `ClaudeQuickSwitchPanel`）。
///
/// 全局快捷键 / 菜单唤出：搜索框 + 会话列表，↑↓ 选择、⏎ 在终端续接（`codex resume <id>`）、
/// ⌘C 复制续接命令、Esc 或点击面板外关闭。非激活 borderless NSPanel + 本地键盘监听；
/// 搜索框始终持焦，裸字符留给它输入，故「复制命令」用 ⌘C 而非裸 c。
/// 与 Claude 版的差异：数据源为 `CodexSessionIndex`；续接 MVP 直接开新终端窗口（不做窗口聚焦，
/// 因 `TerminalLauncher.findRunningSession` 只认 claude 进程）；行元信息用 `AIToolsFormat.relative` 简单拼装。

/// borderless 非激活面板，必须子类覆写 canBecomeKey 才能接收键盘输入。
final class AIToolsQuickSwitchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - 视图模型

@MainActor
final class AIToolsQuickSwitchViewModel: ObservableObject {
    @Published var query = ""
    @Published var selectedIndex = 0

    var filtered: [CodexSessionSummary] {
        let sessions = CodexSessionIndex.shared.sessions
        guard !query.isEmpty else { return sessions }
        let q = query.lowercased()
        return sessions.filter {
            $0.title.lowercased().contains(q)
                || $0.projectName.lowercased().contains(q)
                || $0.projectPath.lowercased().contains(q)
        }
    }

    var selectedSession: CodexSessionSummary? {
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
final class AIToolsQuickSwitchController: NSObject {
    static let shared = AIToolsQuickSwitchController()

    private let viewModel = AIToolsQuickSwitchViewModel()
    private var panel: AIToolsQuickSwitchWindow?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        CodexSessionIndex.shared.refresh()
        viewModel.resetForShow()

        let content = AIToolsQuickSwitchView(
            viewModel: viewModel,
            onResume: { [weak self] session in self?.resume(session) },
            onCopy: { [weak self] session in self?.copyCommand(session) }
        )
        let hosting = NSHostingView(rootView: content)

        let panel = AIToolsQuickSwitchWindow(
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

        // 居中于鼠标所在屏，略高于正中（Spotlight 习惯位）。
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

    /// 返回 true 表示已消费（不再传给搜索框）。裸字符一律放行给搜索框。
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
        case 0x08 where event.modifierFlags.contains(.command): // ⌘C（C=0x08）→ 复制续接命令
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

    private func resume(_ session: CodexSessionSummary) {
        hide()
        // MVP：直接开新终端窗口续接（不做已开窗口聚焦，Codex 侧无该能力）。
        TerminalLauncher.run(command: CodexResumeCommand.command(sessionID: session.id),
                             in: session.projectPath.isEmpty ? nil : session.projectPath)
    }

    private func copyCommand(_ session: CodexSessionSummary) {
        let command = CodexResumeCommand.fullCommand(sessionID: session.id, cwd: session.projectPath)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        hide()
    }
}

// MARK: - 视图

struct AIToolsQuickSwitchView: View {
    @ObservedObject var viewModel: AIToolsQuickSwitchViewModel
    @ObservedObject private var index = CodexSessionIndex.shared
    var onResume: (CodexSessionSummary) -> Void
    var onCopy: (CodexSessionSummary) -> Void

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
        // 置焦点必须晚于 makeKeyAndOrderFront。
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            searchFocused = true
        }
        .onChange(of: viewModel.query) { _, _ in viewModel.clampSelection() }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField("aitools.quickswitch.placeholder", text: $viewModel.query)
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
                Text("aitools.quickswitch.empty")
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

    private func row(session: CodexSessionSummary, selected: Bool) -> some View {
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
                let meta = metaLine(session)
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

    /// 行元信息：项目名 · 相对时间（无项目名时仅相对时间）。
    private func metaLine(_ session: CodexSessionSummary) -> String {
        let relative = AIToolsFormat.relative(session.lastActivity)
        return session.projectName.isEmpty ? relative : "\(session.projectName) · \(relative)"
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("aitools.quickswitch.count \(viewModel.filtered.count)")
            Spacer()
            hint("↑↓", L("aitools.quickswitch.hint.select"))
            hint("⏎", L("aitools.quickswitch.hint.resume"))
            hint("⌘C", L("aitools.quickswitch.hint.copy"))
            hint("esc", L("aitools.quickswitch.hint.close"))
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
