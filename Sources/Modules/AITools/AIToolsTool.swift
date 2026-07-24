import AppKit
import SwiftUI

/// Codex 助手 —— ToolModule 壳：菜单栏入口、二级菜单、快速续接面板热键与生命周期。
///
/// 菜单结构（对齐 Claude Code 助手）：
///   状态行(置灰) → 分隔 → 快速续接… → 浏览会话历史… → 分隔
///   → 用量报表…（两行副标题：5 小时 + 本周）→ 分隔 → 完成通知开关行。
/// 未安装 Codex 时整体降级为一条置灰引导。
///
/// 菜单构建在 `menuNeedsUpdate` 同步调用，**只读各单例的内存缓存、零磁盘 IO**，
/// 后台刷新由 `activate()` 启动的服务负责。
@MainActor
final class AIToolsTool: ToolModule {
    let id = "aitools"
    let name = L("aitools.name")
    let symbolName = "chevron.left.forwardslash.chevron.right"

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
        items.append(.separator())

        // —— 快速续接（Spotlight 面板）——
        items.append(ClosureMenuItem(title: L("aitools.menu.quickSwitch"), hotkeyID: "aitools.quickswitch") {
            AIToolsQuickSwitchController.shared.toggle()
        })
        // —— 浏览会话历史 ——
        items.append(ClosureMenuItem(title: L("aitools.menu.browseSessions"), hotkeyID: "aitools.center") {
            AIToolsCenterController.shared.show(tab: .sessions)
        })

        // —— 用量报表…（两行副标题：5 小时 + 本周）——
        items.append(.separator())
        let usageItem = ClosureMenuItem(title: L("aitools.menu.usageReport")) {
            AIToolsCenterController.shared.show(tab: .usage)
        }
        usageItem.attributedTitle = Self.multiLineTitle(L("aitools.menu.usageReport"), subtitles: quotaSubtitles())
        items.append(usageItem)

        // —— 完成通知开关行（SwiftUI switch，仿 Claude 版）——
        items.append(.separator())
        let notifyItem = NSMenuItem()
        let hosting = NSHostingView(rootView: AIToolsNotifyToggleMenuRow())
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        hosting.autoresizingMask = [.width]
        notifyItem.view = hosting
        items.append(notifyItem)

        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "aitools.center",
                title: L("aitools.hotkey.center"),
                subtitle: L("aitools.hotkey.center.subtitle"),
                defaultCombo: nil // 出厂不绑定
            ) {
                AIToolsCenterController.shared.show(tab: .sessions)
            },
            HotkeyDefinition(
                id: "aitools.quickswitch",
                title: L("aitools.hotkey.quickswitch"),
                subtitle: L("aitools.hotkey.quickswitch.subtitle"),
                defaultCombo: nil // 出厂不绑定，避免与 claudecode.quickswitch 的 ⌃⇧Space 冲突
            ) {
                AIToolsQuickSwitchController.shared.toggle()
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(AIToolsSettingsView())
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
}

// MARK: - 完成通知开关行

/// 「完成通知」菜单行：左标题右 switch（仿 ClaudeCode 的 `NotifyToggleMenuRow`）。
/// 语义：开 = 已写入 config.toml notify 键（`CodexNotify.isInstalled`）；`isUneditable` 时置灰。
struct AIToolsNotifyToggleMenuRow: View {
    @ObservedObject private var notify = CodexNotify.shared

    var body: some View {
        HStack {
            Text("aitools.menu.notifications")
            Spacer()
            Toggle("", isOn: Binding(
                get: { notify.isInstalled },
                set: { on in
                    if on {
                        notify.requestAuthorizationIfNeeded()
                        notify.install { ok in
                            if !ok { AIToolsNotifyToggleMenuRow.presentInstallFailed() }
                        }
                    } else {
                        notify.remove { _ in }
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(Color(nsColor: .controlAccentColor))
            .disabled(notify.isUneditable)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 30)
        .contentShape(Rectangle())
        .environment(\.controlActiveState, .key)
    }

    /// 安装失败提示（回主线程弹）。
    static func presentInstallFailed() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = L("aitools.notify.installFailed")
                alert.informativeText = L("aitools.notify.installFailedMessage")
                alert.addButton(withTitle: L("common.ok"))
                alert.runModal()
            }
        }
    }
}
