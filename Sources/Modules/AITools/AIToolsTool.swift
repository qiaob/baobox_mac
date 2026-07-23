import AppKit
import SwiftUI

/// Cursor / Codex 助手 —— ToolModule 壳：菜单栏入口、二级菜单与生命周期。
///
/// 菜单结构严格按 DESIGN 第 1 节末尾（常用度顺序）：
///   Codex 状态行(置灰) → 最近 Codex 会话 ≤5 → 浏览全部… → 分隔
///   → Cursor Rules（每项目一个 submenu：列 mdc 文件点击打开 +「写入模板」三项）→ 分隔
///   → Codex 完成通知开关。
/// 两工具都未安装时整体降级为一条置灰引导。
///
/// 菜单构建在 `menuNeedsUpdate` 同步调用，**只读各单例的内存缓存、零磁盘 IO**，
/// 后台刷新由 `activate()` 启动的服务负责。无全局快捷键（纯菜单操作）。
@MainActor
final class AIToolsTool: ToolModule {
    let id = "aitools"
    let name = L("aitools.name")
    let symbolName = "wand.and.stars"

    /// 最近会话在菜单里最多展示的条数。
    private static let recentLimit = 5
    /// 会话标题在菜单里的截断长度。
    private static let titleClip = 30

    private var sessionIndex: CodexSessionIndex { CodexSessionIndex.shared }
    private var cursorIndex: CursorProjectIndex { CursorProjectIndex.shared }
    private var notify: CodexNotify { CodexNotify.shared }

    // MARK: - 生命周期

    func activate() {
        if CodexEnv.isInstalled {
            sessionIndex.refresh()
            notify.refreshState()
            notify.start()
        }
        if CursorEnv.isInstalled || !CursorEnv.projectPaths().isEmpty {
            cursorIndex.refresh()
        }
    }

    func willTerminate() {
        notify.stop()
    }

    // MARK: - 菜单

    func submenuItems() -> [NSMenuItem] {
        let codexInstalled = CodexEnv.isInstalled
        let cursorAvailable = CursorEnv.isInstalled || !cursorIndex.projects.isEmpty

        guard codexInstalled || cursorAvailable else {
            // 两工具都未检测到：仅一条置灰引导，设置入口由框架自动追加。
            return [disabled(L("aitools.menu.notInstalled"))]
        }

        var items: [NSMenuItem] = []

        // —— Codex 状态行 + 最近会话 + 浏览全部 ——
        if codexInstalled {
            items.append(disabled(codexStatusText()))
            let recent = sessionIndex.recentSessions(limit: Self.recentLimit)
            if recent.isEmpty {
                items.append(disabled(L("aitools.menu.noSessions")))
            } else {
                for session in recent {
                    items.append(sessionMenuItem(session))
                }
            }
            items.append(ClosureMenuItem(title: L("aitools.menu.browseSessions")) {
                AIToolsSessionsController.shared.show()
            })
        } else {
            items.append(disabled(L("aitools.menu.codexNotInstalled")))
        }

        // —— Cursor Rules ——
        items.append(.separator())
        items.append(cursorRulesItem())

        // —— Codex 完成通知开关 ——
        if codexInstalled {
            items.append(.separator())
            if notify.isUneditable {
                // config.toml notify 键不可安全编辑：置灰（action 为 nil，autoenablesItems 自动禁用）。
                items.append(disabled(L("aitools.menu.notifications")))
            } else {
                let toggle = ClosureMenuItem(title: L("aitools.menu.notifications")) { [weak self] in
                    self?.toggleNotifications()
                }
                toggle.state = notify.isInstalled ? .on : .off
                items.append(toggle)
            }
        }

        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [] // 纯菜单操作，不占用组合键。
    }

    func settingsTab() -> AnyView {
        AnyView(AIToolsSettingsView())
    }

    // MARK: - 菜单构件

    private func sessionMenuItem(_ session: CodexSessionSummary) -> NSMenuItem {
        let clipped = String(session.title.prefix(Self.titleClip))
        let label = session.projectName.isEmpty ? clipped : "\(session.projectName) — \(clipped)"
        let item = ClosureMenuItem(title: label) {
            TerminalLauncher.run(command: CodexResumeCommand.command(sessionID: session.id),
                                 in: session.projectPath.isEmpty ? nil : session.projectPath)
        }
        item.image = symbolImage("clock.arrow.circlepath")
        return item
    }

    /// 「Cursor Rules」父项：其子菜单每项目一个 submenu。
    private func cursorRulesItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L("aitools.menu.cursorRules"), action: nil, keyEquivalent: "")
        parent.image = symbolImage("doc.text")
        let submenu = NSMenu()

        let projects = cursorIndex.projects
        if projects.isEmpty {
            submenu.addItem(disabled(L("aitools.menu.noProjects")))
        } else {
            for project in projects {
                submenu.addItem(projectSubmenuItem(project))
            }
        }
        parent.submenu = submenu
        return parent
    }

    /// 单个项目的 submenu：mdc 文件（点击打开）+ 写入模板三项。
    private func projectSubmenuItem(_ project: CursorProject) -> NSMenuItem {
        let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
        let menu = NSMenu()

        if project.ruleFileNames.isEmpty {
            menu.addItem(disabled(L("aitools.menu.noRules")))
        } else {
            for url in project.ruleFileURLs {
                let fileItem = ClosureMenuItem(title: url.lastPathComponent) {
                    NSWorkspace.shared.open(url)
                }
                menu.addItem(fileItem)
            }
        }
        if project.hasLegacyCursorrules {
            menu.addItem(disabled(L("aitools.menu.legacyCursorrules")))
        }

        menu.addItem(.separator())
        for template in CursorRuleTemplate.all {
            let path = project.path
            let writeItem = ClosureMenuItem(title: L("aitools.menu.writeTemplate \(template.localizedTitle)")) {
                CursorProjectIndex.shared.writeTemplate(template, toProject: path) { result in
                    if case .failure(let error) = result {
                        Self.presentTemplateError(error)
                    }
                }
            }
            menu.addItem(writeItem)
        }

        item.submenu = menu
        return item
    }

    // MARK: - 动作

    /// 切换 Codex 完成通知：装 = 生成脚本 + 写 config.toml notify；卸 = 移除。
    private func toggleNotifications() {
        if notify.isInstalled {
            notify.remove { _ in }
        } else {
            notify.requestAuthorizationIfNeeded()
            notify.install { ok in
                if !ok { Self.presentInstallFailed() }
            }
        }
    }

    // MARK: - 展示（纯内存，无磁盘 IO）

    /// Codex 状态行：会话总数。
    private func codexStatusText() -> String {
        let count = sessionIndex.sessions.count
        return count > 0 ? L("aitools.menu.sessionCount \(count)") : L("aitools.menu.noSessions")
    }

    // MARK: - 辅助

    private func disabled(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private static func presentTemplateError(_ error: Error) {
        let alert = NSAlert()
        if case CursorEnv.TemplateError.alreadyExists = error {
            alert.messageText = L("aitools.cursor.template.existsTitle")
            alert.informativeText = L("aitools.cursor.template.existsMessage")
        } else {
            alert.messageText = L("aitools.common.writeFailed")
        }
        alert.addButton(withTitle: L("common.ok"))
        alert.runModal()
    }

    private static func presentInstallFailed() {
        let alert = NSAlert()
        alert.messageText = L("aitools.notify.installFailed")
        alert.informativeText = L("aitools.notify.installFailedMessage")
        alert.addButton(withTitle: L("common.ok"))
        alert.runModal()
    }
}
