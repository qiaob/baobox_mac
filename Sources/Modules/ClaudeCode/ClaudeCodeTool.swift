import AppKit
import SwiftUI

/// Claude Code 助手 —— ToolModule 壳：菜单栏入口、二级菜单、快捷键与生命周期。
///
/// 菜单结构严格按 TECH_DESIGN 3.7（状态行 → 最近会话 → 浏览历史 → 额度行 →
/// 用量报表 / 今日改动 → 通知开关；未安装时降级为一条引导文案）。
/// 菜单构建在 `menuNeedsUpdate` 同步调用，**只读各单例的内存缓存、零磁盘 IO**，
/// 后台刷新由 `activate()` 启动的服务负责。所有用户可见文案走 L() / SwiftUI key。
@MainActor
final class ClaudeCodeTool: ToolModule {
    let id = "claudecode"
    let name = L("claudecode.name")
    let symbolName = "terminal"

    /// 最近会话在菜单里最多展示的条数。
    private static let recentLimit = 5
    /// 会话标题在菜单里的截断长度。
    private static let titleClip = 30

    private var live: ClaudeLiveStatus { ClaudeLiveStatus.shared }
    private var index: ClaudeSessionIndex { ClaudeSessionIndex.shared }
    private var usage: ClaudeUsageStore { ClaudeUsageStore.shared }
    private var hooks: ClaudeHooksManager { ClaudeHooksManager.shared }

    // MARK: - 生命周期

    func activate() {
        // 未安装也不启动重服务，避免无谓的文件监听；菜单会显示降级文案。
        guard ClaudeEnv.isInstalled else { return }
        live.start()
        index.refresh()
        usage.startAutoRefresh()
        hooks.refreshState()
    }

    func willTerminate() {
        index.flushCache()
        usage.stopAutoRefresh()
        live.stop()
    }

    // MARK: - 菜单

    func submenuItems() -> [NSMenuItem] {
        guard ClaudeEnv.isInstalled else {
            // 未检测到 Claude Code：仅一条置灰引导，设置入口由框架自动追加。
            return [disabled(L("claudecode.menu.notInstalled"))]
        }

        var items: [NSMenuItem] = []

        // —— 状态行（置灰）——
        items.append(disabled(statusText()))
        items.append(.separator())

        // —— 最近会话 ——
        let recent = index.recentSessions(limit: Self.recentLimit)
        if recent.isEmpty {
            items.append(disabled(L("claudecode.menu.noSessions")))
        } else {
            for session in recent {
                let clipped = String(session.title.prefix(Self.titleClip))
                let item = ClosureMenuItem(title: "\(session.projectName) — \(clipped)") {
                    TerminalLauncher.resume(sessionID: session.id, in: session.projectPath)
                }
                item.image = symbolImage("clock.arrow.circlepath")
                items.append(item)
            }
        }
        items.append(ClosureMenuItem(title: L("claudecode.menu.browseSessions"),
                                     hotkeyID: "claudecode.center") {
            ClaudeCodeCenterController.shared.show(tab: .sessions)
        })
        items.append(.separator())

        // —— 额度行（置灰）——
        items.append(disabled(quotaText()))
        items.append(ClosureMenuItem(title: L("claudecode.menu.usageReport")) {
            ClaudeCodeCenterController.shared.show(tab: .usage)
        })
        items.append(ClosureMenuItem(title: L("claudecode.menu.todayChanges")) {
            ClaudeCodeCenterController.shared.show(tab: .audit)
        })
        items.append(.separator())

        // —— 通知开关 ——
        let notify = ClosureMenuItem(title: L("claudecode.menu.notifications")) { [weak self] in
            self?.toggleNotifications()
        }
        notify.state = ClaudeNotifierSettings.enabled ? .on : .off
        items.append(notify)

        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "claudecode.center",
                title: L("claudecode.hotkey.center"),
                subtitle: L("claudecode.hotkey.center.subtitle"),
                // 出厂不绑定（同取色器惯例），用户在快捷键页自行设置。
                defaultCombo: nil
            ) {
                ClaudeCodeCenterController.shared.show(tab: .sessions)
            }
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(ClaudeCodeSettingsView())
    }

    // MARK: - 动作

    /// 切换完成 / 等待通知总开关。开启时申请授权，并在缺 hooks 时自动装事件上报。
    private func toggleNotifications() {
        let newValue = !ClaudeNotifierSettings.enabled
        UserDefaults.standard.set(newValue, forKey: ClaudeNotifierSettings.enabledKey)
        guard newValue else { return }
        ClaudeNotifier.shared.requestAuthorizationIfNeeded()
        if !hooks.isReporterInstalled {
            hooks.installReporter { _ in }
        }
    }

    // MARK: - 展示（纯内存，无磁盘 IO）

    /// 状态行：运行 / 等待汇总 + 今日估算花费。
    private func statusText() -> String {
        var parts: [String] = []
        if let summary = live.summaryLine() {
            parts.append(summary)
        }
        if let today = usage.todayTotals {
            parts.append(L("claudecode.menu.today \(ClaudeFormat.cost(today.costUSD))"))
        }
        return parts.isEmpty ? L("claudecode.menu.noActivity") : parts.joined(separator: " · ")
    }

    /// 额度行：当前 5 小时窗口的用量 / 估算花费 / 倒计时；无窗口时降级文案。
    private func quotaText() -> String {
        guard let window = usage.currentWindow else {
            return L("claudecode.menu.noWindow")
        }
        let tokens = ClaudeFormat.tokens(window.totals.totalTokens)
        let cost = ClaudeFormat.cost(window.totals.costUSD)
        let countdown = ClaudeFormat.countdown(window.secondsUntilReset)
        return L("claudecode.menu.quota \(tokens) \(cost) \(countdown)")
    }

    // MARK: - 辅助

    /// 置灰信息行（action 为 nil，NSMenu autoenablesItems 自动禁用）。
    private func disabled(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}
