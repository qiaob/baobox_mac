import AppKit
import SwiftUI

/// 网络泄露检测模块壳：菜单里放上次的结论与两行总结，检测在窗口里跑（WebRTC 的 WebView 要挂在窗口上）。
/// 只在用户点了才测。见 docs/netcheck/DESIGN.md。
@MainActor
final class NetCheckTool: ToolModule {
    let id = "netcheck"
    let name = L("netcheck.name")
    let symbolName = "shield.lefthalf.filled"

    private var session: NetCheckSession { NetCheckSession.shared }

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if session.running {
            items.append(NSMenuItem(title: L("netcheck.window.running"), action: nil, keyEquivalent: ""))
        } else if let outcome = session.outcome {
            let ago = CLIFormat.relative(outcome.at)
            items.append(NSMenuItem(title: L("netcheck.menu.status \(NetCheckText.headline(outcome.overall)) \(ago)"),
                                    action: nil, keyEquivalent: ""))
            for summary in outcome.summary {
                items.append(NSMenuItem(title: NetCheckText.line(summary), action: nil, keyEquivalent: ""))
            }
        } else {
            items.append(NSMenuItem(title: L("netcheck.menu.never"), action: nil, keyEquivalent: ""))
        }
        items.append(.separator())
        if session.running {
            // action 为 nil 的项由 NSMenu 自动置灰
            items.append(NSMenuItem(title: L("netcheck.menu.run"), action: nil, keyEquivalent: ""))
        } else {
            items.append(ClosureMenuItem(title: L("netcheck.menu.run")) {
                NetCheckWindowController.shared.show(run: true)
            })
        }
        items.append(ClosureMenuItem(title: L("netcheck.menu.open")) {
            NetCheckWindowController.shared.show()
        })
        return items
    }

    func hotkeys() -> [HotkeyDefinition] { [] }

    func settingsTab() -> AnyView {
        AnyView(NetCheckSettingsView())
    }

    func activate() {
        // 不自动测：每次检测都会把出口 IP 告诉第三方服务，只在用户点了才发
    }
}
