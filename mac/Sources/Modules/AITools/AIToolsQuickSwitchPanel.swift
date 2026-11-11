import AppKit
import SwiftUI

/// Codex 助手 —— Spotlight 式快速续接面板（对齐 `ClaudeQuickSwitchPanel`）。
///
/// 全局快捷键 / 菜单唤出：搜索框 + 会话列表，↑↓ 选择、⏎ 在终端续接（`codex resume <id>`）、
/// ⌘C 复制续接命令、Esc 或点击面板外关闭。窗口外壳、键码、过滤与选中、会话栏视图与 Claude 版共用
/// `Core/QuickSwitch/`（#109），这里只有 Codex 的会话数据源、薄视图模型与控制器。
/// 与 Claude 版的差异：数据源为 `CodexSessionIndex`；续接 MVP 直接开新终端窗口（不做窗口聚焦，
/// 按进程找正在跑的会话只有 Claude 那边有、只认 claude 进程）；行元信息用 `AIToolsFormat.relative` 简单拼装；
/// 没有文件模式，Tab 不拦。

// MARK: - 会话数据源

/// 面板「会话」栏的 Codex 数据源。
@MainActor
struct CodexQuickSwitchSource: QuickSwitchSessionSource {
    var sessions: [CodexSessionSummary] { CodexSessionIndex.shared.sessions }

    func refresh() {
        CodexSessionIndex.shared.refresh()
    }

    /// 行元信息：项目名 · 相对时间（无项目名时仅相对时间）。
    func metadataLine(for session: CodexSessionSummary) -> String {
        let relative = AIToolsFormat.relative(session.lastActivity)
        return session.projectName.isEmpty ? relative : "\(session.projectName) · \(relative)"
    }

    func resume(_ session: CodexSessionSummary) {
        // MVP：直接开新终端窗口续接（不做已开窗口聚焦，Codex 侧无该能力）。
        TerminalLauncher.run(command: CodexResumeCommand.command(sessionID: session.id),
                             in: session.projectPath.isEmpty ? nil : session.projectPath)
    }

    func resumeCommand(for session: CodexSessionSummary) -> String {
        CodexResumeCommand.fullCommand(sessionID: session.id, cwd: session.projectPath)
    }
}

// MARK: - 视图模型

@MainActor
final class AIToolsQuickSwitchViewModel: ObservableObject {
    @Published var query = ""
    @Published var selectedIndex = 0

    let source = CodexQuickSwitchSource()

    var filtered: [CodexSessionSummary] {
        source.sessions(matching: query)
    }

    var selectedSession: CodexSessionSummary? {
        QuickSwitchSelection.element(filtered, at: selectedIndex)
    }

    func resetForShow() {
        query = ""
        selectedIndex = 0
    }

    func moveSelection(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selectedIndex = QuickSwitchSelection.moved(selectedIndex, by: delta, count: count)
    }

    func clampSelection() {
        let count = filtered.count
        let clamped = QuickSwitchSelection.clamped(selectedIndex, count: count)
        // 什么时候写同原来：空列表总是写 0，否则只在越界时写。
        if count == 0 || clamped != selectedIndex { selectedIndex = clamped }
    }
}

// MARK: - 控制器

@MainActor
final class AIToolsQuickSwitchController: NSObject {
    static let shared = AIToolsQuickSwitchController()

    private let viewModel = AIToolsQuickSwitchViewModel()
    private let host = QuickSwitchPanelHost()

    var isVisible: Bool { host.isVisible }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        viewModel.source.refresh()
        viewModel.resetForShow()

        let content = AIToolsQuickSwitchView(
            viewModel: viewModel,
            onResume: { [weak self] session in self?.resume(session) }
        )
        host.show(content) { [weak self] event in self?.handleKey(event) ?? false }
    }

    func hide() {
        host.hide()
    }

    /// 返回 true 表示已消费（不再传给搜索框）。裸字符一律放行给搜索框。
    private func handleKey(_ event: NSEvent) -> Bool {
        switch QuickSwitchKey(event) {
        case .down:
            viewModel.moveSelection(1)
            return true
        case .up:
            viewModel.moveSelection(-1)
            return true
        case .enter: // Return / Enter（带不带 ⌘ 都一样）→ 续接
            if let session = viewModel.selectedSession {
                resume(session)
            }
            return true
        case .copy: // ⌘C → 复制续接命令
            if let session = viewModel.selectedSession {
                copyCommand(session)
            }
            return true
        case .escape:
            hide()
            return true
        case .left, .right, .tab, nil: // ←→、Tab 与其余按键交给搜索框（Tab 不拦，同原来）
            return false
        }
    }

    // MARK: 动作

    private func resume(_ session: CodexSessionSummary) {
        hide()
        viewModel.source.resume(session)
    }

    private func copyCommand(_ session: CodexSessionSummary) {
        let command = viewModel.source.resumeCommand(for: session)
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

    var body: some View {
        QuickSwitchCard {
            QuickSwitchSearchBar(symbol: "chevron.left.forwardslash.chevron.right",
                                 placeholder: "aitools.quickswitch.placeholder",
                                 text: $viewModel.query)
            Divider()
            QuickSwitchSessionList(source: viewModel.source,
                                   sessions: viewModel.filtered,
                                   selectedIndex: $viewModel.selectedIndex,
                                   emptyText: "aitools.quickswitch.empty",
                                   onResume: onResume)
            Divider()
            QuickSwitchFooter {
                Text("aitools.quickswitch.count \(viewModel.filtered.count)")
                Spacer()
                QuickSwitchKeyHint(key: "↑↓", label: L("aitools.quickswitch.hint.select"))
                QuickSwitchKeyHint(key: "⏎", label: L("aitools.quickswitch.hint.resume"))
                QuickSwitchKeyHint(key: "⌘C", label: L("aitools.quickswitch.hint.copy"))
                QuickSwitchKeyHint(key: "esc", label: L("aitools.quickswitch.hint.close"))
            }
        }
        .onChange(of: viewModel.query) { _, _ in viewModel.clampSelection() }
    }
}
