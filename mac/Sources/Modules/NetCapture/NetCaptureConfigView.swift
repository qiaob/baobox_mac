import AppKit
import SwiftUI

// 抓包窗口的「配置」页（docs/packet-capture/CONTROL.md §2）：左边一列开关，右边是选中那一项的内容。
//
// 左边三组：证书（这台 Mac 信任没有、解密 HTTPS、给其他设备装证书）、抓包来源（本机、手动代理、WireGuard，各一个总开关）、
// 工具（模拟器、终端 / 脚本、Android USB）。每项一行，关着开着都只占一行，页面不会越开越长。
// 右边显示选中项的内容：子开关、地址、二维码（默认就够大，手机隔着屏幕能扫）。打开某个总开关时顺便选中它 ——
// 开 WireGuard 接下来就是扫码。打开开关不切标签页：在这一页上通常要连着开几个。

/// 左边列表里能选中的项（「这台 Mac」「解密 HTTPS」两行自己就是全部内容，不能选）。
enum NetCaptureConfigItem: Hashable {
    case certPage, mac, manualProxy, wireguard, simulator, terminal, androidUSB
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
    @AppStorage(NetCaptureEnv.Keys.decryptHTTPS) private var decrypt = true
    @AppStorage(NetCaptureEnv.Keys.macHTTP) private var macHTTP = true
    @AppStorage(NetCaptureEnv.Keys.macWebSocket) private var macWebSocket = true
    @AppStorage(NetCaptureEnv.Keys.macTCP) private var macTCP = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                groupTitle("netcapture.config.cert.title")
                group {
                    ConfigRow(icon: "checkmark.seal", title: "netcapture.config.cert.thisMac") {
                        if session.caTrusted {
                            Label("netcapture.config.cert.trusted", systemImage: "checkmark.seal.fill")
                                .font(.callout).foregroundStyle(NetCaptureColors.accent)
                        } else {
                            Button("netcapture.config.cert.install") { session.installCert() }
                                .controlSize(.small)
                                .disabled(session.working != nil)
                        }
                    }
                    rowDivider
                    ConfigRow(icon: "lock.open", title: "netcapture.config.cert.decrypt") {
                        Button("netcapture.config.cert.scope") {
                            guard let registry = AppDelegate.shared?.registry else { return }
                            SettingsWindowController.shared.show(registry: registry, tab: "netcapture")
                        }
                        .buttonStyle(.link).controlSize(.small)
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
                    ConfigRow(item: .wireguard, icon: "lock.shield", title: "netcapture.config.wg.title",
                              subtitle: session.wireguardOn ? session.wireguardEndpoint : nil) {
                        rowSwitch(selecting(.wireguard, get: { session.wireguardOn }, set: session.setWireGuard))
                    }
                }

                groupTitle("netcapture.config.group.tools")
                group {
                    toolRow(.simulator, icon: "macwindow.on.rectangle", title: "netcapture.config.sim.title")
                    rowDivider
                    toolRow(.terminal, icon: "terminal", title: "netcapture.config.terminal.title")
                    rowDivider
                    toolRow(.androidUSB, icon: "cable.connector", title: "netcapture.config.usb.title")
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
        ConfigRow(item: item, icon: icon, title: title) {
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
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
private struct ConfigDetail<Content: View>: View {
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
private struct StepRow: View {
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
private struct QRBox: View {
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

private struct WireGuardDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared

    var body: some View {
        ConfigDetail(icon: "lock.shield", title: "netcapture.config.wg.title", detail: "netcapture.config.wg.detail",
                     isOn: Binding(get: { session.wireguardOn }, set: { session.setWireGuard($0) })) {
            HStack(alignment: .top, spacing: 22) {
                // 关着时不显示任何和密钥有关的东西。
                QRBox(text: session.wireguardOn ? session.wireguardClientConfig() : nil, side: ConfigDetailMetrics.qrSide,
                      placeholder: "netcapture.config.qrPlaceholder", caption: session.wireguardEndpoint)
                VStack(alignment: .leading, spacing: 10) {
                    if session.wireguardOn {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("netcapture.config.wg.endpoint").font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: session.wireguardEndpoint).font(.title3.monospaced()).textSelection(.enabled)
                                .lineLimit(1).minimumScaleFactor(0.7)
                            CopyButton(title: "netcapture.config.wg.copy") { session.wireguardClientConfig() ?? "" }
                                .controlSize(.small)
                        }
                        .padding(.bottom, 4)
                    }
                    StepRow(number: 1, text: "netcapture.config.wg.step1")
                    StepRow(number: 2, text: "netcapture.config.wg.step2")
                    StepRow(number: 3, text: "netcapture.config.wg.step3")
                }
            }
            Text("netcapture.config.wg.note").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

/// USB 调试连着的 Android 手机：一键设代理（指向 Mac 的局域网 IP）+ 推证书、清代理。模拟器在「模拟器」那一项里。
private struct AndroidUSBDetail: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @ObservedObject private var engine = NetCaptureEngine.shared
    @State private var adbPath: String?
    @State private var devices: [ADBController.Device] = []
    @State private var checked = false
    @State private var busy = false

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
                ForEach(devices) { device in
                    HStack(spacing: 8) {
                        Text(verbatim: device.model.isEmpty ? device.serial : "\(device.model) (\(device.serial))")
                            .font(.callout).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("netcapture.config.usb.setUp") { setUp(device) }
                        Button("netcapture.settings.adbClearProxy") { clearProxy(device) }
                    }
                    .disabled(busy)
                }
                .frame(maxWidth: ConfigDetailMetrics.formWidth)
                Button("netcapture.common.refresh") { refresh() }.buttonStyle(.link).disabled(busy)
            }
        }
        .onAppear { if !checked { refresh() } }
    }

    private func refresh() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let path = ADBController.adbPath()
            let list = path != nil ? ADBController.devices().filter { !$0.serial.hasPrefix("emulator-") } : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    adbPath = path
                    devices = list
                    busy = false
                    checked = true
                }
            }
        }
    }

    /// 手机经 Wi-Fi 连 Mac 的代理：要「手动代理」开着，没开只提示，不替用户开（同模拟器对「本机」的做法）。
    private func setUp(_ device: ADBController.Device) {
        guard session.manualProxyOn else {
            session.banner = NetCaptureSession.Banner(kind: .info, text: L("netcapture.config.usb.needsProxy"))
            return
        }
        busy = true
        let port = engine.port ?? NetCaptureEnv.port
        let ip = NetworkInterfaces.primaryIP()
        DispatchQueue.global(qos: .userInitiated).async {
            let proxied = ADBController.setProxy(serial: device.serial, ip: ip, port: port)
            let pushed = ADBController.pushAndInstallCert(serial: device.serial)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    busy = false
                    session.banner = (proxied && pushed)
                        ? NetCaptureSession.Banner(kind: .info, text: L("netcapture.phone.android.done"))
                        : NetCaptureSession.Banner(kind: .problem, text: L("netcapture.phone.android.failed"))
                }
            }
        }
    }

    private func clearProxy(_ device: ADBController.Device) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = ADBController.clearProxy(serial: device.serial)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    busy = false
                    session.banner = ok
                        ? NetCaptureSession.Banner(kind: .info, text: L("netcapture.phone.android.cleared"))
                        : NetCaptureSession.Banner(kind: .problem, text: L("netcapture.phone.android.failed"))
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
