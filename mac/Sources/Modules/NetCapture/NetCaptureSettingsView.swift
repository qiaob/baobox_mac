import AppKit
import SwiftUI

/// 网络抓包设置（docs/packet-capture/REQUIREMENTS.md §5.3）：一项一行。
/// 抓什么、怎么接设备这些开关都在抓包窗口的「配置」页里，这里只放不常改的东西（端口、上限、解密范围、证书、MCP）。
/// 重操作（证书安装、MCP 注册）在后台队列执行，完成回主线程更新状态。
struct NetCaptureSettingsView: View {
    var body: some View {
        Form {
            if let reason = NetCaptureEnv.engineUnavailable {
                SwiftUI.Section {
                    Text(reason == .needsAppleSilicon ? "netcapture.unavailable.intel" : "netcapture.unavailable.notBundled")
                        .foregroundStyle(.secondary)
                }
            } else {
                SwiftUI.Section {
                    Button("netcapture.menu.openWindow") { NetCaptureWindowController.shared.show() }
                    Text("netcapture.settings.intro").font(.caption).foregroundStyle(.secondary)
                }
                NetCaptureGeneralSection()
                NetCaptureScopeSection()
                NetCaptureCertSection()
                NetCaptureMCPSection()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 通用

private struct NetCaptureGeneralSection: View {
    @AppStorage(NetCaptureEnv.Keys.port) private var port = 9090
    @AppStorage(NetCaptureEnv.Keys.maxFlows) private var maxFlows = 1000
    @AppStorage(NetCaptureEnv.Keys.bodyCap) private var bodyCap = 5 * 1024 * 1024
    @AppStorage(NetCaptureEnv.Keys.clearOnStop) private var clearOnStop = false
    @AppStorage(NetCaptureEnv.Keys.wireguardPort) private var wireguardPort = 51820

    var body: some View {
        SwiftUI.Section("netcapture.settings.general") {
            HStack {
                Text("netcapture.settings.port")
                Spacer()
                TextField("", value: $port, format: .number.grouping(.never))
                    .frame(width: 80).multilineTextAlignment(.trailing)
            }
            Stepper(value: $maxFlows, in: 200...5000, step: 100) {
                Text("netcapture.settings.maxFlows \(maxFlows)")
            }
            Picker("netcapture.settings.bodyCap", selection: $bodyCap) {
                Text(verbatim: "1 MB").tag(1 * 1024 * 1024)
                Text(verbatim: "5 MB").tag(5 * 1024 * 1024)
                Text(verbatim: "20 MB").tag(20 * 1024 * 1024)
            }
            Toggle("netcapture.settings.clearOnStop", isOn: $clearOnStop)
            // 一台设备想换钥匙：删掉再添加（docs/packet-capture/WIREGUARD-DEVICES.md §6）。
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("netcapture.settings.wireguardPort")
                    Text("netcapture.settings.wireguardPortNote").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("", value: $wireguardPort, format: .number.grouping(.never))
                    .frame(width: 80).multilineTextAlignment(.trailing)
            }
            Text("netcapture.settings.generalHint").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 解密范围

private struct NetCaptureScopeSection: View {
    @AppStorage(NetCaptureEnv.Keys.decryptScope) private var scope = "all"
    @AppStorage(NetCaptureEnv.Keys.allowDomains) private var allowDomains = ""
    @AppStorage(NetCaptureEnv.Keys.denyDomains) private var denyDomains = ""

    var body: some View {
        SwiftUI.Section("netcapture.settings.scope") {
            Picker("netcapture.settings.scopeMode", selection: $scope) {
                Text("netcapture.settings.scopeAll").tag("all")
                Text("netcapture.settings.scopeAllowlist").tag("allowlist")
            }
            if scope == "allowlist" {
                domainEditor("netcapture.settings.allowDomains", text: $allowDomains)
            } else {
                domainEditor("netcapture.settings.denyDomains", text: $denyDomains)
            }
            Text("netcapture.settings.scopeHint").font(.caption).foregroundStyle(.secondary)
        }
        // 正在抓的时候改范围，立即告诉引擎。
        .onChange(of: scope) { _, _ in NetCaptureEngine.shared.applyScopeFromSettings() }
        .onChange(of: allowDomains) { _, _ in NetCaptureEngine.shared.applyScopeFromSettings() }
        .onChange(of: denyDomains) { _, _ in NetCaptureEngine.shared.applyScopeFromSettings() }
    }

    private func domainEditor(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.caption.monospaced())
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
        }
    }
}

// MARK: - 证书

private struct NetCaptureCertSection: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @State private var busy = false
    @State private var hasLegacy = CaptureCA.shared.hasLegacyCA
    @State private var certName = CaptureCA.shared.commonName
    @State private var confirmRegenerate = false
    /// 点「重新生成…」那一刻的窗口（设置窗口），验证框关掉后要把它拿回前台。
    @State private var regenerateOrigin: NSWindow?

    var body: some View {
        SwiftUI.Section("netcapture.settings.cert") {
            HStack {
                Text("netcapture.settings.trustStatus")
                Spacer()
                Text(session.caTrusted ? "netcapture.settings.trusted" : "netcapture.settings.untrusted")
                    .foregroundStyle(session.caTrusted ? .green : .secondary)
                if session.caTrusted {
                    Button("netcapture.settings.removeTrust", role: .destructive) { removeTrust() }.disabled(busy)
                } else {
                    Button("netcapture.settings.installTrust") { session.installCert() }
                        .disabled(busy || session.working != nil)
                }
            }
            HStack {
                Text("netcapture.settings.certName")
                Spacer()
                Text(verbatim: certName ?? "—").foregroundStyle(.secondary).textSelection(.enabled)
                Button("netcapture.settings.regenerate") {
                    regenerateOrigin = NSApp.keyWindow
                    confirmRegenerate = true
                }
                    .disabled(busy || session.working != nil)
                    .alert(Text("netcapture.settings.regenerateTitle"), isPresented: $confirmRegenerate) {
                        Button("netcapture.settings.regenerateConfirm", role: .destructive) { regenerate() }
                        Button("common.cancel", role: .cancel) {}
                    } message: {
                        Text("netcapture.settings.regenerateMessage")
                    }
            }
            if hasLegacy {
                HStack {
                    Text("netcapture.settings.legacyCA")
                    Spacer()
                    Button("netcapture.settings.legacyCARemove") { removeLegacy() }.disabled(busy)
                }
            }
            if let banner = session.banner, banner.kind == .problem {
                Text(verbatim: banner.text).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("netcapture.settings.certHint").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            session.refreshTrust()
            certName = CaptureCA.shared.commonName
        }
    }

    /// 换一张新证书（名字是 Baobox Capture CA）。先停抓包：引擎只在启动时读证书。
    private func regenerate() {
        busy = true
        // 不能在这里取 `NSApp.keyWindow`：这个方法是从确认框的按钮里调的，那一刻的前台窗口是确认框自己。
        // 之后再把它「拿回前台」，已经关掉的确认框就又冒出来了（2026-11-21 用户遇到：做完了还在弹；
        // 探针里确认过，取到的是 `_NSAlertPanel`，对它 `makeKeyAndOrderFront` 后它重新可见）。
        let origin = regenerateOrigin
        session.stopAll()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CaptureCA.shared.regenerate()
            let name = CaptureCA.shared.commonName
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    busy = false
                    certName = name
                    session.bringBack(origin)
                    session.refreshTrust()
                }
            }
        }
    }

    private func removeTrust() {
        busy = true
        let origin = NSApp.keyWindow
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CaptureCA.shared.removeTrust()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    busy = false
                    session.bringBack(origin)
                    session.refreshTrust()
                }
            }
        }
    }

    private func removeLegacy() {
        busy = true
        let origin = NSApp.keyWindow
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CaptureCA.shared.removeLegacyCA()
            let still = CaptureCA.shared.hasLegacyCA
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    busy = false
                    hasLegacy = still
                    session.bringBack(origin)
                }
            }
        }
    }
}

// MARK: - MCP

private struct NetCaptureMCPSection: View {
    @ObservedObject private var mcp = CaptureMCPServer.shared
    @AppStorage(NetCaptureEnv.Keys.mcpPort) private var mcpPort = 9191
    @AppStorage(NetCaptureEnv.Keys.mcpRedactAuth) private var redact = true
    @State private var inClaude = false
    @State private var inCodex = false

    var body: some View {
        SwiftUI.Section("netcapture.settings.mcp") {
            Toggle("netcapture.settings.mcpEnabled", isOn: Binding(
                get: { mcp.isRunning },
                set: { $0 ? mcp.start() : mcp.stop() }
            ))
            HStack {
                Text("netcapture.settings.mcpPort")
                Spacer()
                TextField("", value: $mcpPort, format: .number.grouping(.never))
                    .frame(width: 80).multilineTextAlignment(.trailing)
            }
            registrationRow("netcapture.settings.registerClaude", registered: inClaude,
                            register: { try? CaptureMCPServer.registerInClaude() },
                            unregister: { try? CaptureMCPServer.unregisterFromClaude() })
            registrationRow("netcapture.settings.registerCodex", registered: inCodex,
                            register: { try? CaptureMCPServer.registerInCodex() },
                            unregister: { try? CaptureMCPServer.unregisterFromCodex() })
            Toggle("netcapture.settings.mcpRedact", isOn: $redact)
            Text("netcapture.settings.mcpHint \(mcp.endpointURL)").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { refreshRegistration() }
    }

    private func registrationRow(_ title: LocalizedStringKey, registered: Bool,
                                 register: @escaping () -> Void, unregister: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if registered {
                Button("netcapture.settings.unregister", role: .destructive) { run(unregister) }
            } else {
                Button("netcapture.settings.register") { run(register) }
            }
        }
    }

    private func run(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            refreshRegistration()
        }
    }

    private func refreshRegistration() {
        DispatchQueue.global(qos: .userInitiated).async {
            let claude = CaptureMCPServer.isRegisteredInClaude()
            let codex = CaptureMCPServer.isRegisteredInCodex()
            DispatchQueue.main.async { MainActor.assumeIsolated { inClaude = claude; inCodex = codex } }
        }
    }
}
