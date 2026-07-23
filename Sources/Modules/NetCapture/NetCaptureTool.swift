import AppKit
import SwiftUI

/// 网络抓包 —— ToolModule 壳：菜单栏入口、二级菜单、主开关、MCP 开关、证书子菜单、
/// 快捷键（出厂不绑定）与生命周期。
///
/// 菜单构建在 `menuNeedsUpdate` 同步调用，只读各单例的内存状态、零磁盘 IO。
/// `activate()` **不**自动开代理（关闭态零开销原则），仅还原可能的崩溃残留系统代理。
@MainActor
final class NetCaptureTool: ToolModule {
    let id = "netcapture"
    let name = L("netcapture.name")
    let symbolName = "network"

    private var server: ProxyServer { ProxyServer.shared }
    private var store: FlowStore { FlowStore.shared }
    private var mcp: CaptureMCPServer { CaptureMCPServer.shared }

    // MARK: - 生命周期

    func activate() {
        NetCaptureEnv.registerDefaults()
        // 不自动开代理；仅还原崩溃残留的系统代理（防上次异常退出留下指向本机的代理导致断网）。
        DispatchQueue.global(qos: .utility).async {
            SystemProxyController.restoreIfLeftover()
        }
    }

    func willTerminate() {
        // 兜底：停代理（内部还原系统代理）、停 MCP。
        server.stop()
        mcp.stop()
    }

    // MARK: - 菜单（§4.1）

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // —— 状态行（置灰）——
        items.append(disabled(statusText()))
        items.append(.separator())

        // —— 主开关：开始 / 停止抓包 ——
        let toggleTitle = server.isRunning ? L("netcapture.menu.stop") : L("netcapture.menu.start")
        items.append(ClosureMenuItem(title: toggleTitle, hotkeyID: "netcapture.toggle") { [weak self] in
            self?.toggleCapture()
        })
        items.append(ClosureMenuItem(title: L("netcapture.menu.openWindow"), hotkeyID: "netcapture.window") {
            NetCaptureWindowController.shared.show()
        })
        items.append(.separator())

        // —— 代理地址（置灰信息行，点击复制）——
        let addr = "\(NetworkInterfaces.primaryIP()):\(NetCaptureEnv.port)"
        let addrItem = ClosureMenuItem(title: L("netcapture.menu.proxyAddr \(addr)")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(addr, forType: .string)
        }
        items.append(addrItem)

        // —— 证书子菜单 ——
        let certItem = NSMenuItem(title: L("netcapture.menu.cert"), action: nil, keyEquivalent: "")
        certItem.submenu = certSubmenu()
        items.append(certItem)
        items.append(.separator())

        // —— 本地 MCP 开关（custom view switch 行）——
        let mcpItem = NSMenuItem()
        let hosting = NSHostingView(rootView: NetCaptureMCPToggleRow())
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        hosting.autoresizingMask = [.width]
        mcpItem.view = hosting
        items.append(mcpItem)

        return items
    }

    private func certSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: L("netcapture.menu.cert.installMac")) {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = MITMCertAuthority.shared.installTrust()
                if !result.ok {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let alert = NSAlert()
                            alert.messageText = L("netcapture.settings.trustFailed")
                            if !result.message.isEmpty { alert.informativeText = result.message }
                            alert.addButton(withTitle: L("common.ok"))
                            alert.runModal()
                        }
                    }
                }
            }
        })
        menu.addItem(ClosureMenuItem(title: L("netcapture.menu.cert.showQR")) {
            NetCaptureCertQR.show()
        })
        menu.addItem(ClosureMenuItem(title: L("netcapture.menu.cert.adbPush")) {
            NetCaptureWindowController.shared.show() // ADB 一键在设置/窗口里操作
        })
        return menu
    }

    func hotkeys() -> [HotkeyDefinition] {
        [
            HotkeyDefinition(
                id: "netcapture.toggle",
                title: L("netcapture.hotkey.toggle"),
                subtitle: L("netcapture.hotkey.toggle.subtitle"),
                defaultCombo: nil // 出厂不绑定
            ) { [weak self] in
                self?.toggleCapture()
            },
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

    // MARK: - 动作 / 展示

    private func toggleCapture() {
        if server.isRunning { server.stop() }
        else { server.start(port: NetCaptureEnv.port) }
    }

    /// 状态行：抓包中 · 127.0.0.1:9090 · N 条；停止时「未开启」。
    private func statusText() -> String {
        switch server.state {
        case .running(let port):
            return L("netcapture.menu.status \("127.0.0.1:\(port)") \(store.flows.count)")
        case .starting:
            return L("netcapture.status.starting")
        case .failed:
            return L("netcapture.status.failed")
        case .stopped:
            return L("netcapture.menu.off")
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }
}

// MARK: - MCP 开关菜单行

/// 「本地 MCP」菜单行：左标题右 switch（仿 `NotifyToggleMenuRow`）。开时副标题显示 endpoint。
struct NetCaptureMCPToggleRow: View {
    @ObservedObject private var mcp = CaptureMCPServer.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("netcapture.mcp.toggle")
                if mcp.isRunning {
                    Text(verbatim: mcp.endpointURL)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { mcp.isRunning },
                set: { $0 ? mcp.start() : mcp.stop() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            // 菜单里的 NSHostingView 不继承 App 强调色，需显式指定。
            .tint(Color(nsColor: .controlAccentColor))
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 30)
        .contentShape(Rectangle())
        .environment(\.controlActiveState, .key)
    }
}

// MARK: - 证书二维码浮层

/// 菜单「显示证书下载二维码」用的极简浮动面板（复用 QRCodeGenerator）。
@MainActor
enum NetCaptureCertQR {
    private final class Holder { var panel: NSPanel? }
    private static let holder = Holder()

    static func show() {
        holder.panel?.orderOut(nil)
        let view = VStack(spacing: 12) {
            Text("netcapture.qr.title").font(.headline)
            Text(verbatim: NetworkInterfaces.certDownloadURL)
                .font(.callout.monospaced()).foregroundStyle(.secondary)
            if let cg = QRCodeGenerator.image(for: NetworkInterfaces.certDownloadURL, minPixels: 300) {
                Image(decorative: cg, scale: 1).resizable().interpolation(.none)
                    .frame(width: 240, height: 240)
            }
            Text("netcapture.qr.hint").font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 280)
        }
        .padding(24)
        .frame(width: 320)
        .background(Color.white)

        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = L("netcapture.qr.title")
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        holder.panel = panel
    }
}
