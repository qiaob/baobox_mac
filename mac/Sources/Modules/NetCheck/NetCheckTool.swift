import AppKit
import SwiftUI

/// 网络检测模块壳：IP 检测（docs/netcheck/COMPARE.md、DESIGN.md）+ 测速与菜单栏实时网速（docs/netcheck/SPEED.md）。
/// 菜单里放上次检测的结论、上次测速；检测和测速都在窗口里跑（WebRTC 的 WebView 要挂在窗口上）。只在用户点了才测。
@MainActor
final class NetCheckTool: ToolModule {
    let id = "netcheck"
    let name = L("netcheck.name")
    let symbolName = "network"

    private var session: NetCheckSession { NetCheckSession.shared }

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if session.running {
            items.append(NSMenuItem(title: L("netcheck.window.running"), action: nil, keyEquivalent: ""))
        } else if let outcome = session.outcome {
            items.append(NSMenuItem(title: NetCheckText.menuLine(outcome), action: nil, keyEquivalent: ""))
        } else {
            items.append(NSMenuItem(title: L("netcheck.menu.never"), action: nil, keyEquivalent: ""))
        }
        items.append(.separator())
        if session.running || NetSpeedTestSession.shared.running {
            // action 为 nil 的项由 NSMenu 自动置灰（测速和 IP 检测不并行）
            items.append(NSMenuItem(title: L("netcheck.menu.run"), action: nil, keyEquivalent: ""))
        } else {
            items.append(ClosureMenuItem(title: L("netcheck.menu.run")) {
                NetCheckWindowController.shared.show(page: .ip, start: true)
            })
        }
        items.append(ClosureMenuItem(title: L("netcheck.menu.open")) {
            NetCheckWindowController.shared.show()
        })

        items.append(.separator())
        items.append(ClosureMenuItem(title: L("netcheck.menu.diag")) {
            NetCheckWindowController.shared.show(page: .diag)
        })
        items.append(ClosureMenuItem(title: L("netcheck.menu.ports")) {
            NetCheckWindowController.shared.showPorts()
        })
        items.append(.separator())
        if let result = NetSpeedTestSession.shared.result {
            items.append(NSMenuItem(title: NetCheckText.menuLine(result), action: nil, keyEquivalent: ""))
        }
        items.append(Self.speedTestMenuItem())
        let live = ClosureMenuItem(title: L("netcheck.menu.liveSpeed")) {
            NetSpeedStatusItem.shared.setEnabled(!NetCheckSettings.liveSpeedEnabled)
        }
        live.state = NetCheckSettings.liveSpeedEnabled ? .on : .off
        items.append(live)
        return items
    }

    /// 「测速」：打开窗口到测速页并开始。正在测时是一行置灰的「正在测速…」，IP 检测正在跑时置灰。
    /// 菜单栏网速那个状态项的小菜单也用它。
    static func speedTestMenuItem() -> NSMenuItem {
        if NetSpeedTestSession.shared.running {
            return NSMenuItem(title: L("netcheck.menu.speedRunning"), action: nil, keyEquivalent: "")
        }
        if NetCheckSession.shared.running {
            return NSMenuItem(title: L("netcheck.menu.speed"), action: nil, keyEquivalent: "")
        }
        return ClosureMenuItem(title: L("netcheck.menu.speed")) {
            NetCheckWindowController.shared.show(page: .speed, start: true)
        }
    }

    func hotkeys() -> [HotkeyDefinition] { [] }

    /// 快速入口：测速、IP 检测、网络诊断、本机端口、菜单栏网速开关，以及针对 URL 和 `:端口` 的文字动作。不加快捷键（约定 6）。
    func launcherCommands() -> [LauncherCommand] {
        let liveOn = NetCheckSettings.liveSpeedEnabled
        return [
            LauncherCommand(id: "netcheck.speedTest", title: L("netcheck.menu.speed"),
                            keywords: ["speedtest", "speed test", "网速", "测网速"], symbolName: "speedometer") { _ in
                NetCheckWindowController.shared.show(page: .speed, start: true)
            },
            LauncherCommand(id: "netcheck.ipCheck", title: L("netcheck.ip.title"),
                            keywords: ["ip", "出口", "泄露", "leak", "vpn", "dns"], symbolName: "shield.lefthalf.filled") { _ in
                NetCheckWindowController.shared.show(page: .ip, start: true)
            },
            LauncherCommand(id: "netcheck.diag", title: L("netcheck.menu.diag"),
                            keywords: ["diag", "ping", "dns", "tls", "http", "诊断", "连通性"], symbolName: "stethoscope") { _ in
                NetCheckWindowController.shared.show(page: .diag, start: true)
            },
            LauncherCommand(id: "netcheck.ports", title: L("netcheck.menu.ports"),
                            keywords: ["port", "ports", "lsof", "kill", "端口", "监听", "占用"], symbolName: "door.left.hand.open") { _ in
                NetCheckWindowController.shared.showPorts()
            },
            LauncherCommand(id: "netcheck.liveSpeed", title: liveOn ? L("netcheck.live.hide") : L("netcheck.menu.liveSpeed"),
                            keywords: ["网速", "菜单栏", "menu bar", "network speed"], symbolName: "arrow.up.arrow.down") { _ in
                NetSpeedStatusItem.shared.setEnabled(!NetCheckSettings.liveSpeedEnabled)
            },
            LauncherCommand.textAction(
                id: "netcheck.diagTarget",
                title: L("netcheck.launcher.diagTarget"),
                symbolName: "stethoscope",
                suggestion: LauncherSuggestionTraits(kinds: [.url], priority: 45),
                hint: "要诊断的域名、网址或 host:port",
                appliesTo: { NetDiagLogic.parseTarget($0) != nil }
            ) { text in
                NetCheckWindowController.shared.showDiagnostic(target: text)
            },
            LauncherCommand.textAction(
                id: "netcheck.findPort",
                title: L("netcheck.launcher.findPort"),
                symbolName: "door.left.hand.open",
                suggestion: LauncherSuggestionTraits(kinds: Set(LauncherTextKind.allCases), priority: 25, leading: true),
                hint: "端口号（如 :3000 或 port 3000）",
                appliesTo: { NetPortLogic.extractPortQuery($0) != nil }
            ) { text in
                let query = NetPortLogic.extractPortQuery(text) ?? text
                NetCheckWindowController.shared.showPorts(filter: query)
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(NetCheckSettingsView())
    }

    func activate() {
        // 不自动测：每次检测 / 测速都会把出口 IP 告诉第三方服务，只在用户点了才发。
        // 菜单栏网速开着就把状态项摆出来（只读本机网卡计数，不联网）。推到下一轮主循环：模块的 activate() 早于
        // Baobox 主图标的创建，这时建的状态项拿不到主图标的位置、摆不到它旁边。
        DispatchQueue.main.async {
            MainActor.assumeIsolated { NetSpeedStatusItem.shared.apply() }
        }
    }

    func willTerminate() {
        NetSpeedTestSession.shared.stop()
        NetDiagSession.shared.stopAll()
        NetSpeedStatusItem.shared.shutdown()
    }
}
