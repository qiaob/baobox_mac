import AppKit
import SwiftUI

// 「配置」页里原来在设置窗口的那几块（docs/packet-capture/CONFIG-LAYOUT.md §2–§3，示意图 mockups/config-layout.html）：
// 这台 Mac 的证书（图 2）、解密 HTTPS 与范围（图 1）、本地 MCP（图 3）、高级 → 端口与上限（图 4）。
// 规则：一个设置只放一个地方 —— 抓包的设置都在这一页，设置窗口那页只剩一个入口。

// MARK: - 表单小部件

/// 右边内容里的一组表单行：圆角底色，行与行之间一条细线（行之间放 `ConfigFormDivider`）。
struct ConfigForm<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
    }
}

struct ConfigFormDivider: View {
    var body: some View { Divider().padding(.leading, 12) }
}

/// 一行：名字（+ 一行小字说明）+ 右边的控件。
struct ConfigFormRow<Trailing: View>: View {
    let title: Text
    var note: Text?
    @ViewBuilder let trailing: () -> Trailing

    init(title: LocalizedStringKey, note: LocalizedStringKey? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(title)
        self.note = note.map { Text($0) }
        self.trailing = trailing
    }

    init(verbatimTitle: String, note: LocalizedStringKey? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = Text(verbatim: verbatimTitle)
        self.note = note.map { Text($0) }
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                title.font(.callout)
                if let note {
                    note.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }
}

/// 「✓ 已信任」「✓ 已注册」这样的绿色小标签；没有的是灰色的「未信任」「未注册」。
struct StatusChip: View {
    let text: LocalizedStringKey
    let ok: Bool

    var body: some View {
        HStack(spacing: 4) {
            if ok { Image(systemName: "checkmark.seal.fill") }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(ok ? NetCaptureColors.accent : Color.secondary)
        .background((ok ? NetCaptureColors.accent : Color.secondary).opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

/// 端口输入框（存进 UserDefaults 的整数）。
struct PortField: View {
    @AppStorage private var value: Int

    init(key: String, fallback: Int) {
        _value = AppStorage(wrappedValue: fallback, key)
    }

    var body: some View {
        TextField("", value: $value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 80)
    }
}

enum ConfigDetailText {
    /// 右边内容的宽度上限（和 WireGuard 设备列表一样宽）。
    static let width: CGFloat = 560
}

// MARK: - 证书 · 这台 Mac（图 2）

/// 原来设置页「HTTPS 证书」那一节：信任状态、移除信任、证书名称、重新生成、清理旧证书。确认框文案不变。
struct ThisMacDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @State private var busy = false
    @State private var hasLegacy = false
    @State private var certName: String?
    @State private var confirmRegenerate = false
    /// 点「重新生成…」那一刻的窗口（抓包窗口），验证框关掉后要把它拿回前台。
    @State private var regenerateOrigin: NSWindow?

    var body: some View {
        ConfigDetail(icon: "checkmark.seal", title: "netcapture.config.cert.thisMac", detail: "netcapture.config.thisMac.detail") {
            ConfigForm {
                ConfigFormRow(title: "netcapture.settings.trustStatus") {
                    StatusChip(text: session.caTrusted ? "netcapture.settings.trusted" : "netcapture.settings.untrusted",
                               ok: session.caTrusted)
                    if session.caTrusted {
                        Button("netcapture.settings.removeTrust", role: .destructive) { removeTrust() }
                            .controlSize(.small).disabled(busy)
                    } else {
                        Button("netcapture.settings.installTrust") { session.installCert() }
                            .controlSize(.small).disabled(busy || session.working != nil)
                    }
                }
                ConfigFormDivider()
                ConfigFormRow(title: "netcapture.settings.certName") {
                    Text(verbatim: certName ?? "—").font(.callout.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(1)
                }
                ConfigFormDivider()
                ConfigFormRow(title: "netcapture.config.thisMac.regenerate", note: "netcapture.config.thisMac.regenerateNote") {
                    Button("netcapture.settings.regenerate") {
                        regenerateOrigin = NSApp.keyWindow
                        confirmRegenerate = true
                    }
                    .controlSize(.small)
                    .disabled(busy || session.working != nil)
                    .alert(Text("netcapture.settings.regenerateTitle"), isPresented: $confirmRegenerate) {
                        Button("netcapture.settings.regenerateConfirm", role: .destructive) { regenerate() }
                        Button("common.cancel", role: .cancel) {}
                    } message: {
                        Text("netcapture.settings.regenerateMessage")
                    }
                }
                // 旧版证书那一行只在钥匙串里还有旧证书时出现。
                if hasLegacy {
                    ConfigFormDivider()
                    ConfigFormRow(title: "netcapture.config.thisMac.legacy", note: "netcapture.config.thisMac.legacyNote") {
                        Button("netcapture.settings.legacyCARemove") { removeLegacy() }.controlSize(.small).disabled(busy)
                    }
                }
            }
            .frame(maxWidth: ConfigDetailText.width)
            Text("netcapture.config.thisMac.note").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        session.refreshTrust()
        DispatchQueue.global(qos: .utility).async {
            let name = CaptureCA.shared.commonName
            let legacy = CaptureCA.shared.hasLegacyCA
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    certName = name
                    hasLegacy = legacy
                }
            }
        }
    }

    /// 换一张新证书（名字是 Baobox Capture CA）。先停抓包：引擎只在启动时读证书。
    private func regenerate() {
        busy = true
        // 不能在这里取 `NSApp.keyWindow`：这个方法是从确认框的按钮里调的，那一刻的前台窗口是确认框自己，
        // 之后再把它「拿回前台」，已经关掉的确认框就又冒出来了（2026-11-21）。
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

// MARK: - 解密 HTTPS（图 1）

/// 开关 + 范围（全部域名，除了下面这些 / 只解密下面这些）+ 对应的名单。两份名单各自保留；改了立即发给引擎。
struct DecryptDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @AppStorage(NetCaptureEnv.Keys.decryptHTTPS) private var decrypt = true
    @AppStorage(NetCaptureEnv.Keys.decryptScope) private var scope = "all"
    @AppStorage(NetCaptureEnv.Keys.allowDomains) private var allowDomains = ""
    @AppStorage(NetCaptureEnv.Keys.denyDomains) private var denyDomains = ""

    var body: some View {
        ConfigDetail(icon: "lock.open", title: "netcapture.config.cert.decrypt", detail: "netcapture.config.decrypt.detail",
                     isOn: Binding(get: { decrypt }, set: { session.setDecryptHTTPS($0) })) {
            VStack(alignment: .leading, spacing: 10) {
                Text("netcapture.settings.scopeMode").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $scope) {
                    Text("netcapture.config.decrypt.scopeAll").tag("all")
                    Text("netcapture.config.decrypt.scopeAllow").tag("allowlist")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text(scope == "allowlist" ? "netcapture.settings.allowDomains" : "netcapture.settings.denyDomains")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 4)
                TextEditor(text: scope == "allowlist" ? $allowDomains : $denyDomains)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 120)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
                Text("netcapture.config.decrypt.note").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: ConfigDetailText.width, alignment: .leading)
        }
        // 正在抓的时候改范围，立即告诉引擎。
        .onChange(of: scope) { _, _ in NetCaptureEngine.shared.applyScopeFromSettings() }
        .onChange(of: allowDomains) { _, _ in NetCaptureEngine.shared.applyScopeFromSettings() }
        .onChange(of: denyDomains) { _, _ in NetCaptureEngine.shared.applyScopeFromSettings() }
    }
}

// MARK: - 工具 · 本地 MCP（图 3）

/// 原来设置页的 MCP 一节 + HTTP 页「…」菜单里的开关。开关记住状态（`netcapture.mcpEnabled`）。
struct MCPDetail: View {
    @ObservedObject private var mcp = CaptureMCPServer.shared
    @AppStorage(NetCaptureEnv.Keys.mcpRedactAuth) private var redact = true
    @State private var inClaude = false
    @State private var inCodex = false

    var body: some View {
        ConfigDetail(icon: "sparkles", title: "netcapture.config.mcp.title", detail: "netcapture.config.mcp.detail",
                     isOn: Binding(get: { mcp.isRunning }, set: { mcp.setEnabled($0) })) {
            ConfigForm {
                ConfigFormRow(title: "netcapture.config.mcp.address") {
                    Text(verbatim: mcp.endpointURL).font(.callout.monospaced()).textSelection(.enabled).lineLimit(1)
                    CopyButton(title: "netcapture.common.copy") { mcp.endpointURL }.controlSize(.small)
                }
                ConfigFormDivider()
                registrationRow("Claude Code", registered: inClaude,
                                register: { try? CaptureMCPServer.registerInClaude() },
                                unregister: { try? CaptureMCPServer.unregisterFromClaude() })
                ConfigFormDivider()
                registrationRow("Codex", registered: inCodex,
                                register: { try? CaptureMCPServer.registerInCodex() },
                                unregister: { try? CaptureMCPServer.unregisterFromCodex() })
                ConfigFormDivider()
                ConfigFormRow(title: "netcapture.config.mcp.redact", note: "netcapture.config.mcp.redactNote") {
                    Toggle("", isOn: $redact).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                ConfigFormDivider()
                ConfigFormRow(title: "netcapture.config.mcp.port", note: "netcapture.config.mcp.portNote") {
                    PortField(key: NetCaptureEnv.Keys.mcpPort, fallback: 9191)
                }
            }
            .frame(maxWidth: ConfigDetailText.width)
            Text("netcapture.config.mcp.note").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: ConfigDetailText.width, alignment: .leading)
        }
        .onAppear { refreshRegistration() }
    }

    private func registrationRow(_ name: String, registered: Bool,
                                 register: @escaping () -> Void, unregister: @escaping () -> Void) -> some View {
        ConfigFormRow(verbatimTitle: name) {
            StatusChip(text: registered ? "netcapture.config.mcp.registered" : "netcapture.config.mcp.notRegistered", ok: registered)
            if registered {
                Button("netcapture.settings.unregister", role: .destructive) { run(unregister) }.controlSize(.small)
            } else {
                Button("netcapture.settings.register") { run(register) }.controlSize(.small)
            }
        }
    }

    /// 写配置文件在后台做，做完重读注册状态。
    private func run(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            DispatchQueue.main.async { MainActor.assumeIsolated { refreshRegistration() } }
        }
    }

    private func refreshRegistration() {
        DispatchQueue.global(qos: .userInitiated).async {
            let claude = CaptureMCPServer.isRegisteredInClaude()
            let codex = CaptureMCPServer.isRegisteredInCodex()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    inClaude = claude
                    inCodex = codex
                }
            }
        }
    }
}

// MARK: - 高级 · 端口与上限（图 4）

/// 原来设置页「通用」一节：代理端口、列表最多保留、单条正文上限、停止时清空。
struct AdvancedDetail: View {
    @AppStorage(NetCaptureEnv.Keys.maxFlows) private var maxFlows = 1000
    @AppStorage(NetCaptureEnv.Keys.bodyCap) private var bodyCap = 5 * 1024 * 1024
    @AppStorage(NetCaptureEnv.Keys.clearOnStop) private var clearOnStop = false

    var body: some View {
        ConfigDetail(icon: "gauge.with.dots.needle.33percent", title: "netcapture.config.advanced.title",
                     detail: "netcapture.config.advanced.detail") {
            ConfigForm {
                ConfigFormRow(title: "netcapture.config.advanced.port", note: "netcapture.config.advanced.portNote") {
                    PortField(key: NetCaptureEnv.Keys.port, fallback: 9090)
                }
                ConfigFormDivider()
                ConfigFormRow(title: "netcapture.config.advanced.maxFlows \(String(maxFlows))", note: "netcapture.config.advanced.maxFlowsNote") {
                    Stepper("", value: $maxFlows, in: 200...5000, step: 100).labelsHidden()
                }
                ConfigFormDivider()
                ConfigFormRow(title: "netcapture.settings.bodyCap", note: "netcapture.config.advanced.bodyCapNote") {
                    Picker("", selection: $bodyCap) {
                        Text(verbatim: "1 MB").tag(1 * 1024 * 1024)
                        Text(verbatim: "5 MB").tag(5 * 1024 * 1024)
                        Text(verbatim: "20 MB").tag(20 * 1024 * 1024)
                    }
                    .labelsHidden().fixedSize()
                }
                ConfigFormDivider()
                ConfigFormRow(title: "netcapture.settings.clearOnStop") {
                    Toggle("", isOn: $clearOnStop).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            .frame(maxWidth: ConfigDetailText.width)
        }
    }
}
