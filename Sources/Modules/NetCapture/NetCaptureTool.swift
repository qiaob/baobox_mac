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

    // MARK: - 菜单（§4.1，用户草图 7 块）

    func submenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // ① 代理（监听网络）开关 + 代理地址（点击复制）
        items.append(hostingRow(NetCaptureProxyToggleRow()))
        let addr = "\(NetworkInterfaces.primaryIP()):\(NetCaptureEnv.port)"
        items.append(ClosureMenuItem(title: L("netcapture.menu.proxyAddr \(addr)")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(addr, forType: .string)
        })
        items.append(.separator())

        // ② iOS 扫码自动配置 + 内嵌二维码
        items.append(disabled(L("netcapture.menu.scanConfig")))
        items.append(hostingRow(NetCaptureMenuQR(), height: 152))
        items.append(.separator())

        // ③ 证书安装（子菜单：装到 Mac / 二维码 / ADB）
        let certItem = NSMenuItem(title: L("netcapture.menu.cert"), action: nil, keyEquivalent: "")
        certItem.submenu = certSubmenu()
        items.append(certItem)
        items.append(.separator())

        // ④ 本机网络走代理（系统代理开关，仅代理运行时可用）
        items.append(hostingRow(NetCaptureLocalProxyToggleRow()))
        items.append(.separator())

        // ⑤ 打开抓包窗口
        items.append(ClosureMenuItem(title: L("netcapture.menu.openWindow"), hotkeyID: "netcapture.window") {
            NetCaptureWindowController.shared.show()
        })
        items.append(.separator())

        // ⑥ 本地 MCP 开关 + 一键安装到 Claude Code / Codex / Cursor
        items.append(hostingRow(NetCaptureMCPToggleRow()))
        items.append(ClosureMenuItem(title: L("netcapture.menu.mcp.installClaude")) {
            NetCaptureTool.installMCP { try CaptureMCPServer.registerInClaude() }
        })
        items.append(ClosureMenuItem(title: L("netcapture.menu.mcp.installCodex")) {
            NetCaptureTool.installMCP { try CaptureMCPServer.registerInCodex() }
        })
        items.append(ClosureMenuItem(title: L("netcapture.menu.mcp.installCursor")) {
            NetCaptureTool.installMCP { try CaptureMCPServer.registerInCursor() }
        })

        // ⑦ 抓包设置：由框架在 submenu 末尾自动追加「网络抓包设置」，此处不重复。
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

    /// 把一个 SwiftUI 视图包成菜单项（自定义 view 行）。
    private func hostingRow<V: View>(_ view: V, height: CGFloat = 30) -> NSMenuItem {
        let item = NSMenuItem()
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: height)
        hosting.autoresizingMask = [.width]
        item.view = hosting
        return item
    }

    /// 一键安装 MCP：后台执行注册（写配置文件），失败弹提示。
    fileprivate static func installMCP(_ work: @escaping () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work()
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let alert = NSAlert()
                        alert.messageText = L("netcapture.mcp.installFailed")
                        alert.informativeText = error.localizedDescription
                        alert.addButton(withTitle: L("common.ok"))
                        alert.runModal()
                    }
                }
            }
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }
}

// MARK: - 代理（监听网络）开关行

/// 「代理（监听网络）」菜单行：左标题右 switch，绑 `ProxyServer` 启停。
struct NetCaptureProxyToggleRow: View {
    @ObservedObject private var server = ProxyServer.shared

    var body: some View {
        HStack {
            Text("netcapture.menu.proxyToggle")
            Spacer()
            Toggle("", isOn: Binding(
                get: { server.isRunning },
                set: { $0 ? server.start(port: NetCaptureEnv.port) : server.stop() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .tint(Color(nsColor: .controlAccentColor))
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 30)
        .contentShape(Rectangle())
        .environment(\.controlActiveState, .key)
    }
}

// MARK: - 本机网络走代理 开关行

/// 「本机网络走代理」菜单行：控制系统代理指向本机（`SystemProxyController`）。仅代理运行时可用，
/// 避免把系统代理指向未监听的端口导致本机断网。
struct NetCaptureLocalProxyToggleRow: View {
    @ObservedObject private var server = ProxyServer.shared
    @State private var isOn = SystemProxyController.isEnabled

    var body: some View {
        HStack {
            Text("netcapture.menu.localProxy")
                .foregroundStyle(server.isRunning ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(Color(nsColor: .controlAccentColor))
                .disabled(!server.isRunning)
                .onChange(of: isOn) { _, on in
                    let port = NetCaptureEnv.port
                    DispatchQueue.global(qos: .userInitiated).async {
                        if on {
                            // 开启前刷新信任缓存：本机未信任证书时会透传本机 HTTPS，避免断网。
                            MITMCertAuthority.shared.refreshTrustCache()
                            SystemProxyController.enable(port: port)
                        } else {
                            SystemProxyController.restore()
                        }
                    }
                }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 30)
        .contentShape(Rectangle())
        .environment(\.controlActiveState, .key)
        .onAppear { isOn = SystemProxyController.isEnabled }
    }
}

// MARK: - 本地 MCP 开关行

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

// MARK: - 菜单内嵌二维码

/// 「iOS 扫码自动配置」用的菜单内嵌二维码：编码 `http://baobox.proxy/` 配置页。
/// 内容固定（不含变动 IP），故用静态缓存一次生成，避免每次 `menuNeedsUpdate` 重算。
struct NetCaptureMenuQR: View {
    var body: some View {
        VStack(spacing: 0) {
            // 每次构建按当前局域网 IP 现生成（换网络后地址随之更新）；QR 生成是纯 CPU、开销很小。
            if let cg = QRCodeGenerator.image(for: NetworkInterfaces.landingPageURL, minPixels: 160) {
                Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 132, height: 132)))
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
            } else {
                Text("netcapture.qr.unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
            NetCaptureQRPanel()
        }
        .padding(24)
        .frame(width: 340)

        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
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
