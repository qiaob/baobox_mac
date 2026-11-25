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

    /// 快速入口：测速、IP 检测（打开窗口到那一页并开始）、菜单栏网速的开关。不加快捷键（约定 6）。
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
            LauncherCommand(id: "netcheck.liveSpeed", title: liveOn ? L("netcheck.live.hide") : L("netcheck.menu.liveSpeed"),
                            keywords: ["网速", "菜单栏", "menu bar", "network speed"], symbolName: "arrow.up.arrow.down") { _ in
                NetSpeedStatusItem.shared.setEnabled(!NetCheckSettings.liveSpeedEnabled)
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(NetCheckSettingsView())
    }

    func activate() {
        // 不自动测：每次检测 / 测速都会把出口 IP 告诉第三方服务，只在用户点了才发。
        // 菜单栏网速开着就把状态项摆出来（只读本机网卡计数，不联网）。
        NetSpeedStatusItem.shared.apply()
    }

    func willTerminate() {
        NetSpeedTestSession.shared.stop()
        NetSpeedStatusItem.shared.shutdown()
    }
}
