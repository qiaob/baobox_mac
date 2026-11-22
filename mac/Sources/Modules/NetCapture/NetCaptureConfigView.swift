import AppKit
import SwiftUI

// 抓包窗口的「配置」页（docs/packet-capture/CONTROL.md §2、CONFIG-LAYOUT.md）：左边一列开关，右边是选中那一项的内容。
// 这一页 = 抓包的全部设置（设置窗口那页只剩一个入口）。
//
// 左边四组：证书（这台 Mac、解密 HTTPS 与范围、给其他设备装证书）、抓包来源（本机、手动代理、WireGuard，各一个总开关）、
// 工具（模拟器、终端 / 脚本、Android USB、本地 MCP）、高级（端口与上限）。每项一行，关着开着都只占一行，页面不会越开越长。
// 右边显示选中项的内容：子开关、地址、二维码（默认就够大，手机隔着屏幕能扫）。打开某个总开关时顺便选中它 ——
// 开 WireGuard 接下来就是扫码。打开开关不切标签页：在这一页上通常要连着开几个。

/// 左边列表里能选中的项。
enum NetCaptureConfigItem: Hashable {
    case thisMac, decrypt, certPage, mac, manualProxy, wireguard, simulator, terminal, androidUSB, mcp, advanced
}

struct NetCaptureConfigView: View {
    @ObservedObject private var state = NetCaptureWindowState.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ConfigSidebar()
                .frame(width: 340)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                .padding(.vertical, 16)
                .padding(.trailing, 16)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.configItem {
        case .thisMac: ThisMacDetail()
        case .decrypt: DecryptDetail()
        case .mcp: MCPDetail()
        case .advanced: AdvancedDetail()
        case .certPage: CertPageDetail()
        case .mac: MacDetail()
        case .manualProxy: ManualProxyDetail()
        case .wireguard: WireGuardDetail()
        case .simulator: SimulatorDetail()
        case .terminal: TerminalDetail()
        case .androidUSB: AndroidUSBDetail()
        }
    }
}

// MARK: - 左边：开关列表

private struct ConfigSidebar: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @ObservedObject private var engine = NetCaptureEngine.shared
    @ObservedObject private var state = NetCaptureWindowState.shared
    @ObservedObject private var wireguardDevices = WireGuardDeviceStore.shared
    @ObservedObject private var mcp = CaptureMCPServer.shared
    @AppStorage(NetCaptureEnv.Keys.decryptHTTPS) private var decrypt = true
    @AppStorage(NetCaptureEnv.Keys.decryptScope) private var scope = "all"
    @AppStorage(NetCaptureEnv.Keys.allowDomains) private var allowDomains = ""
    @AppStorage(NetCaptureEnv.Keys.denyDomains) private var denyDomains = ""
    @AppStorage(NetCaptureEnv.Keys.port) private var port = 9090
    @AppStorage(NetCaptureEnv.Keys.maxFlows) private var maxFlows = 1000
    @AppStorage(NetCaptureEnv.Keys.bodyCap) private var bodyCap = 5 * 1024 * 1024
    @AppStorage(NetCaptureEnv.Keys.mcpPort) private var mcpPort = 9191
    @AppStorage(NetCaptureEnv.Keys.macHTTP) private var macHTTP = true
    @AppStorage(NetCaptureEnv.Keys.macWebSocket) private var macWebSocket = true
    @AppStorage(NetCaptureEnv.Keys.macTCP) private var macTCP = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                groupTitle("netcapture.config.cert.title")
                group {
                    // 点开是信任状态、移除信任、证书名称、重新生成、清理旧证书（原来在设置页）。
                    ConfigRow(item: .thisMac, icon: "checkmark.seal", title: "netcapture.config.cert.thisMac") {
                        if session.caTrusted {
                            Label("netcapture.config.cert.trusted", systemImage: "checkmark.seal.fill")
                                .font(.callout).foregroundStyle(NetCaptureColors.accent)
                        } else {
                            Button("netcapture.config.cert.install") { session.installCert() }
                                .controlSize(.small)
                                .disabled(session.working != nil)
                        }
                        chevron
                    }
                    rowDivider
                    // 点开是范围和名单；小字说当前范围。
                    ConfigRow(item: .decrypt, icon: "lock.open", title: "netcapture.config.cert.decrypt",
                              subtitle: decrypt ? scopeSummary : nil) {
                        rowSwitch(Binding(get: { decrypt }, set: { session.setDecryptHTTPS($0) }))
                    }
                    rowDivider
                    ConfigRow(item: .certPage, icon: "qrcode", title: "netcapture.config.cert.otherDevices") {
                        rowSwitch(selecting(.certPage, get: { session.certPageOn }, set: session.setCertPage))
                    }
                }

                groupTitle("netcapture.config.group.sources")
                group {
                    ConfigRow(item: .mac, icon: "laptopcomputer", title: "netcapture.config.mac.title",
                              subtitle: session.macOn ? macSummary : nil) {
                        rowSwitch(selecting(.mac, get: { session.macOn }, set: session.setMac))
                            .disabled(session.working != nil && !session.macOn)
                    }
                    rowDivider
                    ConfigRow(item: .manualProxy, icon: "network", title: "netcapture.config.proxy.title",
                              subtitle: "\(NetworkInterfaces.primaryIP()):\(String(engine.port ?? NetCaptureEnv.port))") {
                        if !engine.pendingDevices.isEmpty {
                            Text(verbatim: "\(engine.pendingDevices.count)")
                                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color(hex: 0xF59E0B)))
                        }
                        rowSwitch(selecting(.manualProxy, get: { session.manualProxyOn }, set: session.setManualProxy))
                    }
                    rowDivider
                    // 开着时小字是「N 台设备」（每台一个端点，不再显示单个端点）。
                    ConfigRow(item: .wireguard, icon: "lock.shield", title: "netcapture.config.wg.title",
                              subtitle: session.wireguardOn ? L("netcapture.wg.deviceCount \(wireguardDevices.devices.count)") : nil) {
                        rowSwitch(selecting(.wireguard, get: { session.wireguardOn }, set: WireGuardUI.setOn))
                    }
                }

                groupTitle("netcapture.config.group.tools")
                group {
                    toolRow(.simulator, icon: "macwindow.on.rectangle", title: "netcapture.config.sim.title")
                    rowDivider
                    toolRow(.terminal, icon: "terminal", title: "netcapture.config.terminal.title")
                    rowDivider
                    toolRow(.androidUSB, icon: "cable.connector", title: "netcapture.config.usb.title")
                    rowDivider
                    ConfigRow(item: .mcp, icon: "sparkles", title: "netcapture.config.mcp.title",
                              subtitle: mcp.isRunning ? "127.0.0.1:\(String(mcpPort))" : nil) {
                        rowSwitch(selecting(.mcp, get: { mcp.isRunning }, set: { mcp.setEnabled($0) }))
                    }
                }

                groupTitle("netcapture.config.group.advanced")
                group {
                    ConfigRow(item: .advanced, icon: "gauge.with.dots.needle.33percent", title: "netcapture.config.advanced.title",
                              subtitle: L("netcapture.config.advanced.summary \(String(port)) \(String(maxFlows)) \(bodyCap / (1024 * 1024))")) {
                        chevron
                    }
                }

                Text("netcapture.settings.privacyStatement")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 10)
            }
            .padding(.leading, 16)
            .padding(.vertical, 16)
        }
    }

    /// 「HTTP · WebSocket · TCP」里开着的那几个。
    private var macSummary: String {
        var parts: [String] = []
        if macHTTP { parts.append("HTTP") }
        if macWebSocket { parts.append("WebSocket") }
        if macTCP { parts.append("TCP") }
        return parts.joined(separator: " · ")
    }

    /// 总开关：打开时顺便选中这一行（右边立刻是它的二维码、子开关）。
    private func selecting(_ item: NetCaptureConfigItem, get: @escaping () -> Bool,
                           set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: { on in
            if on { state.configItem = item }
            set(on)
        })
    }

    private func rowSwitch(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
    }

    private func toolRow(_ item: NetCaptureConfigItem, icon: String, title: LocalizedStringKey) -> some View {
        ConfigRow(item: item, icon: icon, title: title) { chevron }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }

    /// 「解密 HTTPS」那一行的小字：全部域名 / 不解密 N 个域名 / 只解密 N 个域名。
    private var scopeSummary: String {
        let current = DecryptScope.from(setting: scope, allowText: allowDomains, denyText: denyDomains)
        switch current.mode {
        case .all, .none: return L("netcapture.config.decrypt.summaryAll")
        case .deny: return L("netcapture.config.decrypt.summaryDeny \(current.domains.count)")
        case .allow: return L("netcapture.config.decrypt.summaryAllow \(current.domains.count)")
        }
    }

    private func groupTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.top, 8)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 40)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

/// 列表里的一行：图标 + 名字（+ 一行小字）+ 右边的开关或状态。`item` 不为 nil 的行点一下选中，右边显示它的内容。
private struct ConfigRow<Trailing: View>: View {
    var item: NetCaptureConfigItem?
    let icon: String
    let title: LocalizedStringKey
    var subtitle: String?
    @ViewBuilder let trailing: () -> Trailing
    @ObservedObject private var state = NetCaptureWindowState.shared

    private var selected: Bool { item != nil && state.configItem == item }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(NetCaptureColors.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(selected ? NetCaptureColors.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if let item { state.configItem = item }
        }
    }
}

// MARK: - 右边：选中项的内容

enum ConfigDetailMetrics {
    /// 开关、地址这类表单行的最大宽度（右边那块很宽，行拉满的话名字和开关离得太远）。
    static let formWidth: CGFloat = 460
    /// 二维码的边长：不用再点放大就能扫。
    static let qrSide: CGFloat = 220
}

/// 右边那一块：图标 + 标题（+ 这一项的总开关）、一句说明、内容。
struct ConfigDetail<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var isOn: Binding<Bool>?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.title2).foregroundStyle(NetCaptureColors.accent)
                    Text(title).font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    if let isOn {
                        Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                content()
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// 「1 手机装 WireGuard App」这样的一步。
struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(NetCaptureColors.accent))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 小部件

/// 卡片里的一行开关：名字 + 小字说明 + 右边的开关。
private struct OptionRow: View {
    let title: LocalizedStringKey
    var note: LocalizedStringKey?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

/// 卡片里的「名字 值 [复制]」一行。
private struct CopyValueRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            Text(verbatim: value).font(.body.monospaced()).textSelection(.enabled).lineLimit(1)
            Spacer(minLength: 4)
            CopyButton(title: "netcapture.common.copy") { value }.controlSize(.small)
        }
    }
}

/// 二维码；内容为空时是一个虚线占位框，里面一句说明。点一下放大（卡片上的太小，手机隔着屏幕不好扫），再点或点别处收起。
struct QRBox: View {
    let text: String?
    let side: CGFloat
    let placeholder: LocalizedStringKey
    /// 放大后写在二维码下面的一行（端点、网址），让人知道扫的是哪个。
    var caption: String?

    @State private var enlarged = false
    private static let enlargedSide: CGFloat = 380

    var body: some View {
        if let text, let image = QRCodeGenerator.image(for: text, minPixels: Int(Self.enlargedSide * 2)) {
            Button {
                enlarged.toggle()
            } label: {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    .frame(width: side, height: side)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(3)
                    }
            }
            .buttonStyle(.plain)
            .help(Text("netcapture.config.qrEnlarge"))
            .popover(isPresented: $enlarged, arrowEdge: .trailing) {
                VStack(spacing: 10) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none)
                        .frame(width: Self.enlargedSide, height: Self.enlargedSide)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                    if let caption, !caption.isEmpty {
                        Text(verbatim: caption).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: Self.enlargedSide + 28)
                    }
                }
                .padding(16)
                .contentShape(Rectangle())
                .onTapGesture { enlarged = false }
            }
        } else {
            Text(placeholder)
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(10)
                .frame(width: side + 10, height: side + 10)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }
}

// MARK: - 本机

private struct MacDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @AppStorage(NetCaptureEnv.Keys.macHTTP) private var http = true
    @AppStorage(NetCaptureEnv.Keys.macWebSocket) private var webSocket = true
    @AppStorage(NetCaptureEnv.Keys.macTCP) private var tcp = false

    var body: some View {
        ConfigDetail(icon: "laptopcomputer", title: "netcapture.config.mac.title", detail: "netcapture.config.mac.detail",
                     isOn: Binding(get: { session.macOn }, set: { session.setMac($0) })) {
            VStack(alignment: .leading, spacing: 12) {
                OptionRow(title: "netcapture.config.mac.http", isOn: $http)
                OptionRow(title: "netcapture.config.mac.websocket", note: "netcapture.config.mac.websocketNote",
                          isOn: $webSocket)
                OptionRow(title: "netcapture.config.mac.tcp", note: "netcapture.config.mac.tcpNote", isOn: $tcp)
            }
            .frame(maxWidth: ConfigDetailMetrics.formWidth)
            // 总开关关着：变灰但保留取值。
            .disabled(!session.macOn)
            .opacity(session.macOn ? 1 : 0.55)
            if !session.caTrusted, !session.macOn {
                Text("netcapture.config.mac.trustHint").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(session.working != nil && !session.macOn)
        .onChange(of: http) { _, _ in session.macOptionsChanged() }
        .onChange(of: webSocket) { _, _ in session.macOptionsChanged() }
        .onChange(of: tcp) { _, _ in session.macOptionsChanged() }
    }
}

// MARK: - 手动代理

private struct ManualProxyDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @ObservedObject private var engine = NetCaptureEngine.shared
    @AppStorage(NetCaptureEnv.Keys.wifiName) private var wifiName = ""

    var body: some View {
        ConfigDetail(icon: "network", title: "netcapture.config.proxy.title", detail: "netcapture.config.proxy.detail",
                     isOn: Binding(get: { session.manualProxyOn }, set: { session.setManualProxy($0) })) {
            VStack(alignment: .leading, spacing: 10) {
                CopyValueRow(label: "netcapture.config.proxy.host", value: NetworkInterfaces.primaryIP())
                CopyValueRow(label: "netcapture.config.proxy.port", value: String(engine.port ?? NetCaptureEnv.port))
                Text("netcapture.config.proxy.ipNote").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 新设备第一次连上来仍要「允许」（顶上的提示条和通知也有）。
                ForEach(engine.pendingDevices, id: \.self) { ip in
                    HStack(spacing: 6) {
                        Image(systemName: "iphone.radiowaves.left.and.right").foregroundStyle(NetCaptureColors.accent)
                        Text(verbatim: ip).font(.callout.monospaced())
                        Spacer(minLength: 4)
                        Button("netcapture.device.deny") { engine.deny(device: ip) }.controlSize(.small)
                        Button("netcapture.device.allow") { engine.allow(device: ip) }
                            .buttonStyle(.borderedProminent).tint(NetCaptureColors.accent).controlSize(.small)
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Text("netcapture.config.proxy.wifi").font(.callout)
                    TextField("netcapture.config.proxy.wifiPlaceholder", text: $wifiName)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                }
                Text("netcapture.config.proxy.wifiNote").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: ConfigDetailMetrics.formWidth)
        }
    }
}

// MARK: - WireGuard

/// 卡片上只列设备（名字、端口、最近活动、二维码 / 改名 / 删除）；二维码在「添加设备」起好名字之后、或点那台的二维码图标时出现
/// （docs/packet-capture/WIREGUARD-DEVICES.md §6）。开关关着时列表照常显示、能改名删除，添加和二维码是灰的。
private struct WireGuardDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared

    var body: some View {
        ConfigDetail(icon: "lock.shield", title: "netcapture.config.wg.title", detail: "netcapture.config.wg.detail",
                     isOn: Binding(get: { session.wireguardOn }, set: { WireGuardUI.setOn($0) })) {
            WireGuardDeviceList()
            Text("netcapture.config.wg.note").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: WireGuardDeviceList.width, alignment: .leading)
            // 新设备的起始端口跟着 WireGuard 走（原来在设置页，CONFIG-LAYOUT.md §3）。
            ConfigForm {
                ConfigFormRow(title: "netcapture.settings.wireguardPort", note: "netcapture.settings.wireguardPortNote") {
                    PortField(key: NetCaptureEnv.Keys.wireguardPort, fallback: 51820)
                }
            }
            .frame(maxWidth: WireGuardDeviceList.width)
        }
    }
}

// MARK: - 给其他设备装证书

private struct CertPageDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared

    var body: some View {
        ConfigDetail(icon: "qrcode", title: "netcapture.config.cert.otherDevices", detail: "netcapture.config.cert.detail",
                     isOn: Binding(get: { session.certPageOn }, set: { session.setCertPage($0) })) {
            HStack(alignment: .top, spacing: 22) {
                QRBox(text: session.certPageOn ? NetworkInterfaces.landingPageURL : nil, side: ConfigDetailMetrics.qrSide,
                      placeholder: "netcapture.config.qrPlaceholder", caption: NetworkInterfaces.landingPageURL)
                VStack(alignment: .leading, spacing: 10) {
                    if session.certPageOn {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: NetworkInterfaces.landingPageURL)
                                .font(.callout.monospaced()).textSelection(.enabled)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            CopyButton(title: "netcapture.common.copy") { NetworkInterfaces.landingPageURL }
                                .controlSize(.small)
                        }
                        .padding(.bottom, 4)
                    }
                    StepRow(number: 1, text: "netcapture.config.cert.step1")
                    StepRow(number: 2, text: "netcapture.config.cert.step2")
                }
            }
            Text("netcapture.config.cert.pageNote").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 工具

private struct SimulatorDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared

    var body: some View {
        ConfigDetail(icon: "macwindow.on.rectangle", title: "netcapture.config.sim.title",
                     detail: "netcapture.config.sim.detail") {
            VStack(alignment: .leading, spacing: 8) {
                Button("netcapture.config.sim.ios") { session.installSimulatorCert() }
                Button("netcapture.config.sim.android") { session.setUpAndroidEmulators() }
            }
            .disabled(session.working != nil)
        }
    }
}

private struct TerminalDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared

    var body: some View {
        ConfigDetail(icon: "terminal", title: "netcapture.config.terminal.title",
                     detail: "netcapture.config.terminal.detail") {
            VStack(alignment: .leading, spacing: 8) {
                Button("netcapture.config.terminal.open") { session.openTerminal() }
                Button("netcapture.config.terminal.copyEnv") { session.copyShellEnv() }
            }
            .disabled(session.working != nil)
        }
    }
}

/// USB 调试连着的 Android 手机：推证书、在手机上打开 Wi-Fi 设置（代理由人填进当前 Wi-Fi，手机上看得见）。
/// 不再替真手机设隐藏的全局代理：它在 Wi-Fi 设置里看不到、换网络也带着走（CONTROL.md §12）。发现它还开着就提示，给一个清除按钮。
/// 模拟器在「模拟器」那一项里。
private struct AndroidUSBDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @ObservedObject private var engine = NetCaptureEngine.shared
    @State private var adbPath: String?
    @State private var devices: [ADBController.Device] = []
    /// 设了隐藏全局代理的手机：序列号 → `host:port`。
    @State private var hiddenProxies: [String: String] = [:]
    @State private var checked = false
    @State private var busy = false

    private var proxyHost: String { NetworkInterfaces.primaryIP() }
    private var proxyPort: String { String(engine.port ?? NetCaptureEnv.port) }

    var body: some View {
        ConfigDetail(icon: "cable.connector", title: "netcapture.config.usb.title", detail: "netcapture.config.usb.detail") {
            if !checked {
                ProgressView().controlSize(.small)
            } else if adbPath == nil {
                Text("netcapture.settings.adbHint").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if devices.isEmpty {
                HStack(spacing: 8) {
                    Text("netcapture.settings.adbNoDevice").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("netcapture.common.refresh") { refresh() }.disabled(busy)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(devices) { device in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(verbatim: device.model.isEmpty ? device.serial : "\(device.model) (\(device.serial))")
                                    .font(.callout).lineLimit(1)
                                Spacer(minLength: 8)
                                Button("netcapture.config.usb.pushCert") { pushCert(device) }
                                Button("netcapture.config.usb.openWifi") { openWifi(device) }
                            }
                            if let hidden = hiddenProxies[device.serial] {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    Text("netcapture.config.usb.hiddenProxy \(hidden)").font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Button("netcapture.settings.adbClearProxy") { clearProxy(device) }.controlSize(.small)
                                }
                            }
                        }
                        .disabled(busy)
                    }
                }
                .frame(maxWidth: ConfigDetailMetrics.formWidth)

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("netcapture.config.usb.proxyTitle").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("netcapture.config.proxy.host").font(.callout).foregroundStyle(.secondary)
                        Text(verbatim: proxyHost).font(.callout.monospaced()).textSelection(.enabled)
                        CopyButton(title: "netcapture.common.copy") { proxyHost }.controlSize(.small)
                        Text("netcapture.config.proxy.port").font(.callout).foregroundStyle(.secondary).padding(.leading, 8)
                        Text(verbatim: proxyPort).font(.callout.monospaced()).textSelection(.enabled)
                        CopyButton(title: "netcapture.common.copy") { proxyPort }.controlSize(.small)
                    }
                    Text("netcapture.config.usb.proxySteps").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !session.manualProxyOn {
                        Text("netcapture.config.usb.needsProxy").font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: ConfigDetailMetrics.formWidth, alignment: .leading)
                Text("netcapture.config.usb.wireguardHint").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("netcapture.common.refresh") { refresh() }.buttonStyle(.link).disabled(busy)
            }
        }
        .onAppear { if !checked { refresh() } }
    }

    /// 列出手机（模拟器不算），顺便读每台有没有设隐藏的全局代理。
    private func refresh() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let path = ADBController.adbPath()
            let list = path != nil ? ADBController.devices().filter { !$0.serial.hasPrefix("emulator-") } : []
            var hidden: [String: String] = [:]
            for device in list {
                if let value = ADBController.globalProxy(serial: device.serial) { hidden[device.serial] = value }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    adbPath = path
                    devices = list
                    hiddenProxies = hidden
                    busy = false
                    checked = true
                }
            }
        }
    }

    /// 推证书：放进手机的「下载」，再打开离「安装证书」最近的设置页；剩下几步在手机上点。和「手动代理」无关。
    private func pushCert(_ device: ADBController.Device) {
        perform(success: L("netcapture.config.usb.certPushed")) { ADBController.pushAndInstallCert(serial: device.serial) }
    }

    /// 在手机上打开 Wi-Fi 设置，人把上面的主机和端口填进当前网络的代理。
    private func openWifi(_ device: ADBController.Device) {
        perform(success: L("netcapture.config.usb.wifiOpened")) { ADBController.openWifiSettings(serial: device.serial) }
    }

    /// 清掉以前设过的隐藏全局代理，清完重读一遍。
    private func clearProxy(_ device: ADBController.Device) {
        perform(success: L("netcapture.phone.android.cleared"), thenRefresh: true) {
            ADBController.clearProxy(serial: device.serial)
        }
    }

    /// 在后台跑一条 adb 操作，成功 / 失败各给一句提示。
    private func perform(success: String, thenRefresh: Bool = false, _ work: @escaping () -> Bool) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    busy = false
                    session.banner = ok
                        ? NetCaptureSession.Banner(kind: .info, text: success)
                        : NetCaptureSession.Banner(kind: .problem, text: L("netcapture.phone.android.failed"))
                    if thenRefresh { refresh() }
                }
            }
        }
    }
}

// MARK: - 空列表的引导

/// 「HTTP / WebSocket 包」「TCP 包」空着、引擎也没在跑：一句「到『配置』里打开要抓的来源」和一个跳过去的按钮。
struct NetCaptureGoToConfig: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "switch.2").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("netcapture.empty.notCapturing").foregroundStyle(.secondary)
            Button("netcapture.empty.goToConfig") { NetCaptureWindowState.shared.tab = .config }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
