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

        // —— 会话入口:快速续接面板 + 中心窗口(菜单不再平铺最近会话)——
        items.append(ClosureMenuItem(title: L("claudecode.menu.quickSwitch"),
                                     hotkeyID: "claudecode.quickswitch") {
            ClaudeQuickSwitchController.shared.toggle()
        })
        items.append(ClosureMenuItem(title: L("claudecode.menu.browseSessions"),
                                     hotkeyID: "claudecode.center") {
            ClaudeCodeCenterController.shared.show(tab: .sessions)
        })
        items.append(.separator())

        // —— 用量:报表入口带额度副标题(替代原独立置灰额度行,减一行)——
        let usageItem = ClosureMenuItem(title: L("claudecode.menu.usageReport")) {
            ClaudeCodeCenterController.shared.show(tab: .usage)
        }
        usageItem.attributedTitle = Self.twoLineTitle(L("claudecode.menu.usageReport"), subtitle: quotaText())
        items.append(usageItem)
        items.append(ClosureMenuItem(title: L("claudecode.menu.todayChanges")) {
            ClaudeCodeCenterController.shared.show(tab: .audit)
        })
        items.append(.separator())

        // —— 通知开关(右侧 switch 样式,点击不收起菜单)——
        let notify = NSMenuItem()
        let hosting = NSHostingView(rootView: NotifyToggleMenuRow())
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        hosting.autoresizingMask = [.width]
        notify.view = hosting
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
            },
            HotkeyDefinition(
                id: "claudecode.quickswitch",
                title: L("claudecode.hotkey.quickswitch"),
                subtitle: L("claudecode.hotkey.quickswitch.subtitle"),
                // ⌃⇧Space:Spotlight 语义,系统默认未占用;可在快捷键页改绑。
                defaultCombo: KeyCombo(keyCode: 0x31, carbonModifiers: KeyCombo.control | KeyCombo.shift)
            ) {
                ClaudeQuickSwitchController.shared.toggle()
            }
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(ClaudeCodeSettingsView())
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

    /// 两行菜单项:标题正常字号,副标题小号次要色。副标题为空则退化为单行。
    private static func twoLineTitle(_ title: String, subtitle: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.systemFontSize)]
        )
        guard !subtitle.isEmpty else { return result }
        result.append(NSAttributedString(
            string: "\n" + subtitle,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return result
    }

}

// MARK: - 通知开关菜单行

/// 「完成 / 等待通知」菜单行:左标题右 switch(替代原对号)。custom view 菜单项
/// 点击开关不收起菜单。开启时申请通知授权并自动安装缺失的 hooks 上报。
struct NotifyToggleMenuRow: View {
    @AppStorage(ClaudeNotifierSettings.enabledKey) private var enabled = false

    var body: some View {
        HStack {
            Text("claudecode.menu.notifications")
            Spacer()
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                // 菜单里的 NSHostingView 不继承 App 强调色,需显式指定,否则开态灰白。
                .tint(Color(nsColor: .controlAccentColor))
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 30)
        .contentShape(Rectangle())
        // 菜单窗口永远不是 key window,SwiftUI 会按「非激活」把开关渲染成灰色;
        // 菜单弹出即用户焦点所在,强制按激活态渲染才能显出强调色。
        .environment(\.controlActiveState, .key)
        .onChange(of: enabled) { _, newValue in
            guard newValue else { return }
            ClaudeNotifier.shared.requestAuthorizationIfNeeded()
            let hooks = ClaudeHooksManager.shared
            if !hooks.isReporterInstalled {
                hooks.installReporter { _ in }
            }
        }
    }
}
