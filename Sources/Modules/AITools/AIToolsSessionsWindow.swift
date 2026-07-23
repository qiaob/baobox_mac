import AppKit
import SwiftUI

/// Cursor / Codex 助手 —— 轻量 Codex 会话窗口（单页无 Tab，640×420）。
///
/// 仿 `ClaudeCodeCenterController`（NSWindow + NSHostingController，`isReleasedWhenClosed = false`），
/// 但只有一页：搜索 + Codex 会话列表，行操作续接 / 复制命令 / 删除。避免与 Claude 模块互相依赖，
/// 故独立实现，不并入 Claude 中心窗口。

// MARK: - 展示格式化

enum AIToolsFormat {
    /// 相对时间（如「3 分钟前」）。
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Codex 续接命令构造（供窗口与复制按钮共用）。
enum CodexResumeCommand {
    /// 终端执行的续接命令：`codex resume <id>`。
    static func command(sessionID: String) -> String {
        let bin = CodexEnv.findCodexBinary()
        return "\(CodexEnv.shellQuote(bin)) resume \(CodexEnv.shellQuote(sessionID))"
    }

    /// 供「复制命令」用：附带 cd 到项目目录。
    static func fullCommand(sessionID: String, cwd: String) -> String {
        let resume = command(sessionID: sessionID)
        guard !cwd.isEmpty else { return resume }
        return "cd \(CodexEnv.shellQuote(cwd)) && \(resume)"
    }
}

extension CodexEnv {
    /// 单引号安全包裹（供命令拼接）。独立于 ClaudeEnv 以免耦合。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 窗口控制器

@MainActor
final class AIToolsSessionsController {
    static let shared = AIToolsSessionsController()

    private var window: NSWindow?

    private init() {}

    /// 打开会话窗口并触发一次索引刷新。
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AIToolsSessionsView())
            let created = NSWindow(contentViewController: hosting)
            created.title = L("aitools.sessions.title")
            created.styleMask = [.titled, .closable, .resizable]
            created.setContentSize(NSSize(width: 640, height: 420))
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        CodexSessionIndex.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 根视图

struct AIToolsSessionsView: View {
    @ObservedObject private var index = CodexSessionIndex.shared
    @State private var query = ""

    private var filtered: [CodexSessionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return index.sessions }
        let needle = trimmed.lowercased()
        return index.sessions.filter {
            $0.title.lowercased().contains(needle) || $0.projectName.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("aitools.sessions.search", text: $query)
                    .textFieldStyle(.plain)
                if index.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    index.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(Text("aitools.common.refresh"))
            }
            .padding(10)
            Divider()

            if filtered.isEmpty {
                Spacer()
                Text("aitools.sessions.empty")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { session in
                    AIToolsSessionRow(session: session)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// 单条会话行：标题、项目、相对时间 + 操作按钮。
private struct AIToolsSessionRow: View {
    let session: CodexSessionSummary
    @ObservedObject private var index = CodexSessionIndex.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: session.title)
                .lineLimit(1)
            HStack(spacing: 8) {
                if !session.projectName.isEmpty {
                    Text(verbatim: session.projectName)
                    Text(verbatim: "·")
                }
                Text(verbatim: AIToolsFormat.relative(session.lastActivity))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    resume()
                } label: {
                    Label("aitools.sessions.resume", systemImage: "terminal")
                }
                Button {
                    copyCommand()
                } label: {
                    Label("aitools.sessions.copyCommand", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    confirmDelete()
                } label: {
                    Label("aitools.sessions.delete", systemImage: "trash")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func resume() {
        TerminalLauncher.run(command: CodexResumeCommand.command(sessionID: session.id),
                             in: session.projectPath.isEmpty ? nil : session.projectPath)
    }

    private func copyCommand() {
        let command = CodexResumeCommand.fullCommand(sessionID: session.id, cwd: session.projectPath)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = L("aitools.sessions.deleteConfirm.title")
        alert.informativeText = L("aitools.sessions.deleteConfirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("aitools.sessions.delete"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        index.deleteSession(session) { _ in }
    }
}
