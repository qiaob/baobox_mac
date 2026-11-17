import AppKit
import SwiftUI
import UniformTypeIdentifiers

// 中心窗口的「会话」页（#164 PR3，docs/codex-assistant/DEDUPE-P2.md §2.4 类 1）：Claude Code 助手与 Codex 助手的中心窗口共用这一份。
// 两边原来各写一份，一份实现只能二选一，统一成 Claude 那版（D4）：行 = 标题 + 第二行，悬停时右侧浮出四个图标按钮（行高不跳），
// 斑马纹，右键菜单带图标；导出取两边好的一半（存盘框限定 .md + 写盘失败说原因）。
// 第二行、续接、复制的命令来自数据源（`CLISessionSource`，与快速切换面板同一个）；列表、刷新、导出、删除走会话索引。

/// 会话页的文案：各模块用自己的 key（D5，`Localizable.xcstrings` 不动）。
/// SwiftUI 里显示的传 key；AppKit 弹窗用的由模块 `L()` 取好（界面语言重启才换，早取晚取一样）。
struct CLISessionsPageStrings {
    /// 搜索框占位、空列表、刷新按钮的悬停说明、行的悬停说明。
    let search, empty, refreshHelp, rowHint: LocalizedStringKey
    /// 四个动作：悬停按钮的说明与右键菜单项。
    let resume, copyCommand, export, delete: LocalizedStringKey
    /// 导出失败弹窗的标题；删除确认弹窗的标题、正文与确认按钮。
    let exportFailed, deleteConfirmTitle, deleteConfirmMessage, deleteButton: String
    /// 标题清洗完为空时导出的文件名（不带 .md）：Claude "session"、Codex "codex-session"。
    let exportFileFallback: String
}

/// 中心窗口「会话」页：搜索（去首尾空格，标题 / 项目名，`CLISessionsPageSearch`）+ 转圈 + 刷新 + 斑马纹列表。
/// 行 = 标题 + 第二行，悬停时右侧浮出四个图标按钮，双击续接，右键四项。
struct CLISessionsPage<Format: CLISessionFormat, Source: CLISessionSource>: View where Source.Session == Format.Summary {
    @ObservedObject private var index: CLISessionIndex<Format>
    private let source: Source
    private let strings: CLISessionsPageStrings
    @State private var query = ""
    /// 每次构造都不同（同 `QuickSwitchSessionList`）：第二行依赖数据源背后、参数里看不出的状态（Claude 的会话行方案、相对时间），
    /// 参数都没变时 SwiftUI 会跳过这个 body。模块的外层视图观察那份状态（Claude：`SessionRowFormatStore`），一变就重建本页。
    private let renderToken = UUID()

    init(index: CLISessionIndex<Format>, source: Source, strings: CLISessionsPageStrings) {
        _index = ObservedObject(wrappedValue: index)
        self.source = source
        self.strings = strings
    }

    private var filtered: [Format.Summary] {
        CLISessionsPageSearch.filter(index.sessions, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(strings.search, text: $query)
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
                .help(Text(strings.refreshHelp))
            }
            .padding(10)
            Divider()

            if filtered.isEmpty {
                Spacer()
                Text(strings.empty)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { session in
                    CLISessionsPageRow(session: session, meta: source.metadataLine(for: session),
                                       index: index, source: source, strings: strings)
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
            }
        }
    }
}

/// 单条会话行：标题 + 第二行（数据源给；空串也放一个 Text，同原来 Claude 的行），操作按钮悬停浮现，双击续接，右键菜单提供全部操作。
/// 第二行由页面算好传进来：页面重画时它跟着变，行就跟着重画。
private struct CLISessionsPageRow<Format: CLISessionFormat, Source: CLISessionSource>: View where Source.Session == Format.Summary {
    let session: Format.Summary
    let meta: String
    let index: CLISessionIndex<Format>
    let source: Source
    let strings: CLISessionsPageStrings
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: session.title)
                    .lineLimit(1)
                Text(verbatim: meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if hovering {
                actionButtons
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(TapGesture(count: 2).onEnded { resume() })
        .contextMenu { menuItems }
        .help(Text(strings.rowHint))
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            iconButton("terminal", help: strings.resume) { resume() }
            iconButton("doc.on.doc", help: strings.copyCommand) { copyResumeCommand() }
            iconButton("square.and.arrow.up", help: strings.export) { exportMarkdown() }
            Button(role: .destructive) {
                confirmDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(Text(strings.delete))
        }
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(Text(help))
    }

    @ViewBuilder
    private var menuItems: some View {
        Button { resume() } label: { Label(strings.resume, systemImage: "terminal") }
        Button { copyResumeCommand() } label: { Label(strings.copyCommand, systemImage: "doc.on.doc") }
        Button { exportMarkdown() } label: { Label(strings.export, systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive) { confirmDelete() } label: { Label(strings.delete, systemImage: "trash") }
    }

    private func resume() {
        source.resume(session)
    }

    private func copyResumeCommand() {
        let command = source.resumeCommand(for: session)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func exportMarkdown() {
        index.exportMarkdown(session) { markdown in
            MainActor.assumeIsolated {
                guard let markdown else {
                    Self.alert(title: strings.exportFailed, message: "")
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
                panel.nameFieldStringValue = CLISessionMarkdown.exportFileName(
                    title: session.title, fallback: strings.exportFileFallback) + ".md"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try markdown.data(using: .utf8)?.write(to: url)
                } catch {
                    Self.alert(title: strings.exportFailed, message: error.localizedDescription)
                }
            }
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = strings.deleteConfirmTitle
        alert.informativeText = strings.deleteConfirmMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: strings.deleteButton)
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        index.deleteSession(session) { _ in }
    }

    private static func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        if !message.isEmpty { alert.informativeText = message }
        alert.addButton(withTitle: L("common.ok"))
        alert.runModal()
    }
}
