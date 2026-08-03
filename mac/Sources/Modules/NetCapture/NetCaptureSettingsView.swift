import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 网络抓包设置：代理 / HTTPS 证书 / 解密范围 / MCP / ADB / 隐私。
/// 重操作（CA 生成、信任安装、adb、MCP 注册）在后台队列执行，完成回主线程更新状态。
struct NetCaptureSettingsView: View {
    var body: some View {
        Form {
            NetCaptureProxySection()
            NetCaptureCertSection()
            NetCaptureScopeSection()
            NetCaptureMCPSection()
            NetCaptureADBSection()
            NetCapturePrivacySection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - 代理

private struct NetCaptureProxySection: View {
    @AppStorage(NetCaptureEnv.Keys.port) private var port = 9090
    @AppStorage(NetCaptureEnv.Keys.autoSystemProxy) private var autoProxy = false
    @AppStorage(NetCaptureEnv.Keys.serviceName) private var serviceName = ""
    @AppStorage(NetCaptureEnv.Keys.maxFlows) private var maxFlows = 1000
    @AppStorage(NetCaptureEnv.Keys.bodyCap) private var bodyCap = 5 * 1024 * 1024

    var body: some View {
        SwiftUI.Section("netcapture.settings.proxy") {
            HStack {
                Text("netcapture.settings.port")
                Spacer()
                TextField("", value: $port, format: .number.grouping(.never))
                    .frame(width: 80).multilineTextAlignment(.trailing)
            }
            Toggle("netcapture.settings.autoProxy", isOn: $autoProxy)
            HStack {
                Text("netcapture.settings.serviceName")
                Spacer()
                TextField("netcapture.settings.serviceAuto", text: $serviceName)
                    .frame(width: 160).multilineTextAlignment(.trailing)
            }
            Stepper(value: $maxFlows, in: 200...5000, step: 100) {
                Text("netcapture.settings.maxFlows \(maxFlows)")
            }
            Picker("netcapture.settings.bodyCap", selection: $bodyCap) {
                Text(verbatim: "1 MB").tag(1 * 1024 * 1024)
                Text(verbatim: "5 MB").tag(5 * 1024 * 1024)
                Text(verbatim: "20 MB").tag(20 * 1024 * 1024)
            }
            Text("netcapture.settings.portHint").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - HTTPS 证书

private struct NetCaptureCertSection: View {
    @State private var caGenerated = MITMCertAuthority.shared.isCAGenerated
    @State private var trusted = false
    @State private var busy = false
    @State private var showQR = false

    var body: some View {
        SwiftUI.Section("netcapture.settings.cert") {
            HStack {
                Text("netcapture.settings.caStatus")
                Spacer()
                Text(caGenerated ? "netcapture.settings.caGenerated" : "netcapture.settings.caMissing")
                    .foregroundStyle(caGenerated ? .green : .secondary)
                if !caGenerated {
                    Button("netcapture.settings.generateCA") { generateCA() }
                        .disabled(busy)
                }
            }
            HStack {
                Text("netcapture.settings.trustStatus")
                Spacer()
                Text(trusted ? "netcapture.settings.trusted" : "netcapture.settings.untrusted")
                    .foregroundStyle(trusted ? .green : .orange)
                Button("netcapture.common.recheck") { recheckTrust() }.disabled(busy)
            }
            if trusted {
                Button("netcapture.settings.removeTrust", role: .destructive) { removeTrust() }.disabled(busy)
            } else {
                Button("netcapture.settings.installTrust") { installTrust() }.disabled(busy)
            }
            Button("netcapture.window.showQR") { showQR = true }
            Text("netcapture.settings.certHint").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { recheckTrust() }
        .sheet(isPresented: $showQR) {
            VStack(spacing: 14) {
                Text("netcapture.qr.title").font(.headline)
                NetCaptureQRPanel()
                Button("common.ok") { showQR = false }
            }.padding(24)
        }
    }

    private func generateCA() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = MITMCertAuthority.shared.ensureCA()
            DispatchQueue.main.async { MainActor.assumeIsolated { caGenerated = ok; busy = false } }
        }
    }

    private func recheckTrust() {
        DispatchQueue.global(qos: .userInitiated).async {
            let generated = MITMCertAuthority.shared.isCAGenerated
            let isTrusted = generated && MITMCertAuthority.shared.isTrusted()
            DispatchQueue.main.async { MainActor.assumeIsolated { caGenerated = generated; trusted = isTrusted } }
        }
    }

    private func installTrust() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MITMCertAuthority.shared.installTrust()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    busy = false
                    if result.ok { recheckTrust() }
                    else { alert(L("netcapture.settings.trustFailed"), result.message) }
                }
            }
        }
    }

    private func removeTrust() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = MITMCertAuthority.shared.removeTrust()
            DispatchQueue.main.async { MainActor.assumeIsolated { busy = false; recheckTrust(); _ = result } }
        }
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        if !message.isEmpty { a.informativeText = message }
        a.addButton(withTitle: L("common.ok"))
        a.runModal()
    }
}

// MARK: - 解密范围

private struct NetCaptureScopeSection: View {
    @AppStorage(NetCaptureEnv.Keys.decryptScope) private var scope = "all"
    @AppStorage(NetCaptureEnv.Keys.allowDomains) private var allowDomains = ""
    @AppStorage(NetCaptureEnv.Keys.denyDomains) private var denyDomains = ""
    @AppStorage(NetCaptureEnv.Keys.decryptRemote) private var decryptRemote = false

    var body: some View {
        SwiftUI.Section("netcapture.settings.scope") {
            Picker("netcapture.settings.scopeMode", selection: $scope) {
                Text("netcapture.settings.scopeAll").tag("all")
                Text("netcapture.settings.scopeAllowlist").tag("allowlist")
            }
            .pickerStyle(.radioGroup)
            if scope == "allowlist" {
                domainEditor("netcapture.settings.allowDomains", text: $allowDomains)
            } else {
                domainEditor("netcapture.settings.denyDomains", text: $denyDomains)
            }
            Text("netcapture.settings.scopeHint").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("netcapture.settings.decryptRemote", isOn: $decryptRemote)
            Text("netcapture.settings.decryptRemoteHint").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func domainEditor(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.caption.monospaced())
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
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
            HStack {
                Text("netcapture.settings.registerClaude")
                Spacer()
                if inClaude {
                    Button("netcapture.settings.unregister", role: .destructive) { unregisterClaude() }
                } else {
                    Button("netcapture.settings.register") { registerClaude() }
                }
            }
            HStack {
                Text("netcapture.settings.registerCodex")
                Spacer()
                if inCodex {
                    Button("netcapture.settings.unregister", role: .destructive) { unregisterCodex() }
                } else {
                    Button("netcapture.settings.register") { registerCodex() }
                }
            }
            Toggle("netcapture.settings.mcpRedact", isOn: $redact)
            Text("netcapture.settings.mcpHint \(mcp.endpointURL)").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { refreshRegistration() }
    }

    private func refreshRegistration() {
        DispatchQueue.global(qos: .userInitiated).async {
            let claude = CaptureMCPServer.isRegisteredInClaude()
            let codex = CaptureMCPServer.isRegisteredInCodex()
            DispatchQueue.main.async { MainActor.assumeIsolated { inClaude = claude; inCodex = codex } }
        }
    }

    private func registerClaude() {
        DispatchQueue.global(qos: .userInitiated).async {
            try? CaptureMCPServer.registerInClaude(); refreshRegistration()
        }
    }
    private func unregisterClaude() {
        DispatchQueue.global(qos: .userInitiated).async {
            try? CaptureMCPServer.unregisterFromClaude(); refreshRegistration()
        }
    }
    private func registerCodex() {
        DispatchQueue.global(qos: .userInitiated).async {
            try? CaptureMCPServer.registerInCodex(); refreshRegistration()
        }
    }
    private func unregisterCodex() {
        DispatchQueue.global(qos: .userInitiated).async {
            try? CaptureMCPServer.unregisterFromCodex(); refreshRegistration()
        }
    }
}

// MARK: - ADB

private struct NetCaptureADBSection: View {
    @State private var adbPath: String?
    @State private var devices: [ADBController.Device] = []
    @State private var busy = false

    var body: some View {
        SwiftUI.Section("netcapture.settings.adb") {
            HStack {
                Text("netcapture.settings.adbStatus")
                Spacer()
                if let path = adbPath {
                    Text(verbatim: path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("netcapture.settings.adbMissing").foregroundStyle(.orange)
                }
                Button("netcapture.common.refresh") { refresh() }.disabled(busy)
            }
            if adbPath == nil {
                Text("netcapture.settings.adbHint").font(.caption).foregroundStyle(.secondary)
            } else if devices.isEmpty {
                Text("netcapture.settings.adbNoDevice").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: device.model.isEmpty ? device.serial : "\(device.model) (\(device.serial))")
                            .font(.callout)
                        HStack {
                            Button("netcapture.settings.adbSetProxy") { setProxy(device) }.disabled(busy)
                            Button("netcapture.settings.adbClearProxy") { clearProxy(device) }.disabled(busy)
                            Button("netcapture.settings.adbPushCert") { pushCert(device) }.disabled(busy)
                        }
                    }
                }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let path = ADBController.adbPath()
            let list = path != nil ? ADBController.devices() : []
            DispatchQueue.main.async { MainActor.assumeIsolated { adbPath = path; devices = list; busy = false } }
        }
    }

    private func setProxy(_ device: ADBController.Device) {
        busy = true
        let ip = NetworkInterfaces.primaryIP()
        let port = NetCaptureEnv.port
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ADBController.setProxy(serial: device.serial, ip: ip, port: port)
            DispatchQueue.main.async { MainActor.assumeIsolated { busy = false } }
        }
    }
    private func clearProxy(_ device: ADBController.Device) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ADBController.clearProxy(serial: device.serial)
            DispatchQueue.main.async { MainActor.assumeIsolated { busy = false } }
        }
    }
    private func pushCert(_ device: ADBController.Device) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = MITMCertAuthority.shared.ensureCA()
            _ = ADBController.pushAndInstallCert(serial: device.serial)
            DispatchQueue.main.async { MainActor.assumeIsolated { busy = false } }
        }
    }
}

// MARK: - 隐私

private struct NetCapturePrivacySection: View {
    @AppStorage(NetCaptureEnv.Keys.clearOnStop) private var clearOnStop = true

    var body: some View {
        SwiftUI.Section("netcapture.settings.privacy") {
            Toggle("netcapture.settings.clearOnStop", isOn: $clearOnStop)
            Button("netcapture.settings.exportHar") { exportHAR() }
                .disabled(FlowStore.shared.flows.isEmpty)
            Text("netcapture.settings.privacyStatement").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func exportHAR() {
        let flows = FlowStore.shared.flows
        let data = FlowStore.shared.harData(flows)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
        panel.nameFieldStringValue = "capture.har"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
