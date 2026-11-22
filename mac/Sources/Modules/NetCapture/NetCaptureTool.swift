import AppKit
import SwiftUI

/// 网络抓包 —— ToolModule 壳：菜单栏入口、快捷键与生命周期。
///
/// 抓包的所有操作都在窗口里做，菜单只负责把窗口打开（docs/packet-capture/REQUIREMENTS.md §5.2）；
/// 正在抓的时候多一行状态和「停止抓包」，因为窗口关掉后抓包还在继续，得有个不开窗口也能停的地方。
///
/// 菜单构建在 `menuNeedsUpdate` 同步调用，只读各单例的内存状态、零磁盘 IO。
/// `activate()` 不起引擎（关闭时零开销），只还原上次异常退出可能留下的系统代理。
@MainActor
final class NetCaptureTool: ToolModule {
    let id = "netcapture"
    let name = L("netcapture.name")
    let symbolName = "network"

    private var engine: NetCaptureEngine { NetCaptureEngine.shared }

    // MARK: - 生命周期

    func activate() {
        NetCaptureEnv.registerDefaults()
        // Mock 规则在后台读进来，引擎起来时要发给它（docs/packet-capture/TOOLS.md §4）。
        MockRuleStore.shared.load()
        // WireGuard 设备表在后台读进来；首次启动新版本时把原来那一份密钥迁成第一台设备（docs/packet-capture/WIREGUARD-DEVICES.md §3）。
        WireGuardDeviceStore.shared.load()
        // 本地 MCP 记住开关：上次开着就接着开（CONFIG-LAYOUT.md §3）。只听本机。
        CaptureMCPServer.shared.startIfEnabled()
        // 上次崩溃时系统代理可能还指着已经不存在的引擎，那样整机断网；启动时补一次还原。
        DispatchQueue.global(qos: .utility).async {
            SystemProxyController.restoreIfLeftover()
        }
    }

    func willTerminate() {
        NetCaptureSession.shared.terminate()
        CaptureMCPServer.shared.stop()
    }

    // MARK: - 菜单

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        switch NetCaptureEnv.engineUnavailable {
        case .needsAppleSilicon:
            return [disabled(L("netcapture.unavailable.intel"))]
        case .notBundled:
            return [disabled(L("netcapture.unavailable.notBundled"))]
        case nil:
            break
        }

        if engine.isActive, NetCaptureSession.shared.capturing {
            items.append(disabled(L("netcapture.menu.status \(FlowStore.shared.flows.count)")))
            items.append(ClosureMenuItem(title: L("netcapture.menu.stop")) {
                NetCaptureSession.shared.stopAll()
            })
        } else if engine.isActive {
            // 没在抓包，但「给其他设备装证书」开着（证书页和引擎都在听局域网）：窗口关了也要能在这里关掉。
            items.append(disabled(L("netcapture.menu.certPageOn")))
            items.append(ClosureMenuItem(title: L("netcapture.menu.certPageOff")) {
                NetCaptureSession.shared.stopAll()
            })
        }
        items.append(ClosureMenuItem(title: L("netcapture.menu.openWindow"), hotkeyID: "netcapture.window") {
            NetCaptureWindowController.shared.show()
        })
        // 「网络抓包设置…」由框架在末尾追加。
        return items
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "netcapture.window",
                title: L("netcapture.hotkey.window"),
                subtitle: L("netcapture.hotkey.window.subtitle"),
                defaultCombo: nil // 出厂不绑定
            ) {
                NetCaptureWindowController.shared.show()
            },
        ]
    }

    func settingsTab() -> AnyView {
        AnyView(NetCaptureSettingsView())
    }

    /// 「网络抓包设置…」打开抓包窗口的「配置」页：抓包的设置都在那里（docs/packet-capture/CONFIG-LAYOUT.md §1）。
    var settingsAction: (@MainActor () -> Void)? {
        { NetCaptureWindowController.shared.showConfig() }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
