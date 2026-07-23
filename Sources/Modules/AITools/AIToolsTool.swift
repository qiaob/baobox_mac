import AppKit
import SwiftUI

/// Codex 助手 —— ToolModule 壳：菜单栏入口、二级菜单与生命周期。
///
/// 菜单结构（常用度顺序，DESIGN §4.1）：
///   状态行(置灰) N 个会话 · 今日 $X（估算） → 最近会话 ≤5 → 浏览会话 / 用量… → 分隔
///   → 用量报表…（两行副标题：5 小时 + 本周）→ 分隔 → 完成通知开关。
/// 未安装 Codex 时整体降级为一条置灰引导。
///
/// 菜单构建在 `menuNeedsUpdate` 同步调用，**只读各单例的内存缓存、零磁盘 IO**，
/// 后台刷新由 `activate()` 启动的服务负责。无全局快捷键（纯菜单操作）。
@MainActor
final class AIToolsTool: ToolModule {
    let id = "aitools"
    let name = L("aitools.name")
    let symbolName = "chevron.left.forwardslash.chevron.right"

    /// 最近会话在菜单里最多展示的条数。
    private static let recentLimit = 5
    /// 会话标题在菜单里的截断长度。
    private static let titleClip = 30

    private var sessionIndex: CodexSessionIndex { CodexSessionIndex.shared }
    private var usage: CodexUsageStore { CodexUsageStore.shared }
    private var notify: CodexNotify { CodexNotify.shared }

    // MARK: - 生命周期

    func activate() {
        guard CodexEnv.isInstalled else { return }
        sessionIndex.refresh()
        usage.startAutoRefresh()
        notify.refreshState()
        notify.start()
    }

    func willTerminate() {
        usage.stopAutoRefresh()
        notify.stop()
    }

    // MARK: - 菜单

    func submenuItems() -> [NSMenuItem] {
        guard CodexEnv.isInstalled else {
            // 未检测到 Codex：仅一条置灰引导，设置入口由框架自动追加。
            return [disabled(L("aitools.menu.notInstalled"))]
        }

        var items: [NSMenuItem] = []

        // —— 状态行：会话数 + 今日估算花费 ——
        items.append(disabled(statusText()))

        // —— 最近会话 ≤5 ——
        let recent = sessionIndex.recentSessions(limit: Self.recentLimit)
        if recent.isEmpty {
            items.append(disabled(L("aitools.menu.noSessions")))
        } else {
            for session in recent {
                items.append(sessionMenuItem(session))
            }
        }
        items.append(ClosureMenuItem(title: L("aitools.menu.browse")) {
            AIToolsCenterController.shared.show(tab: .sessions)
        })

        // —— 用量报表…（两行副标题：5 小时 + 本周）——
        items.append(.separator())
        let usageItem = ClosureMenuItem(title: L("aitools.menu.usageReport")) {
            AIToolsCenterController.shared.show(tab: .usage)
        }
        usageItem.attributedTitle = Self.multiLineTitle(L("aitools.menu.usageReport"), subtitles: quotaSubtitles())
        items.append(usageItem)

        // —— 完成通知开关 ——
        items.append(.separator())
        if notify.isUneditable {
            // config.toml notify 键不可安全编辑：置灰。
            items.append(disabled(L("aitools.menu.notifications")))
        } else {
            let toggle = ClosureMenuItem(title: L("aitools.menu.notifications")) { [weak self] in
                self?.toggleNotifications()
            }
            toggle.state = notify.isInstalled ? .on : .off
            items.append(toggle)
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

    /// 状态行：会话数 + 今日估算花费（无用量则仅会话数）。
    private func statusText() -> String {
        let count = sessionIndex.sessions.count
        if let today = usage.todayTotals {
            return L("aitools.menu.status \(count) \(AIToolsFormat.cost(today.costUSD))")
        }
        return count > 0 ? L("aitools.menu.sessionCount \(count)") : L("aitools.menu.noSessions")
    }

    /// 额度副标题：两行——5 小时窗口 + 本周窗口；无对应窗口时各自降级文案。
    private func quotaSubtitles() -> [String] {
        var lines: [String] = []
        if let window = usage.fiveHourWindow {
            let tokens = AIToolsFormat.tokens(window.totals.totalTokens)
            let cost = AIToolsFormat.cost(window.totals.costUSD)
            let countdown = AIToolsFormat.countdown(window.secondsUntilReset)
            lines.append(L("aitools.menu.quota5h \(tokens) \(cost) \(countdown)"))
        } else {
            lines.append(L("aitools.menu.noWindow"))
        }
        if let week = usage.weeklyWindow {
            let tokens = AIToolsFormat.tokens(week.totals.totalTokens)
            let cost = AIToolsFormat.cost(week.totals.costUSD)
            let countdown = AIToolsFormat.countdownLong(week.secondsUntilReset)
            lines.append(L("aitools.menu.quotaWeek \(tokens) \(cost) \(countdown)"))
        } else {
            lines.append(L("aitools.menu.noWeekWindow"))
        }
        return lines
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

    /// 多行菜单项：标题正常字号，每条副标题小号次要色，以 `\n` 逐行拼接。无副标题则退化为单行。
    private static func multiLineTitle(_ title: String, subtitles: [String]) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.systemFontSize)]
        )
        for subtitle in subtitles where !subtitle.isEmpty {
            result.append(NSAttributedString(
                string: "\n" + subtitle,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        return result
    }

    private static func presentInstallFailed() {
        let alert = NSAlert()
        alert.messageText = L("aitools.notify.installFailed")
        alert.informativeText = L("aitools.notify.installFailedMessage")
        alert.addButton(withTitle: L("common.ok"))
        alert.runModal()
    }
}
