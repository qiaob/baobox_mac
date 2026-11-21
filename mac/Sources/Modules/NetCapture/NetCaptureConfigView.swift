import AppKit
import SwiftUI

// 抓包窗口的「配置」页（docs/packet-capture/CONTROL.md §2）：第一行是证书卡片，单独占一整行（它是另外三张的前提，不是抓包来源）；
// 第二行三张抓包来源：本机、手动代理、WireGuard，每张右上角一个总开关（证书卡片的总开关是里面的「给其他设备装证书」）；
// 最下面一排三张次要卡片（模拟器、终端 / 脚本、Android USB），只有按钮。打开开关不切标签页：在这一页上通常要连着开几个。

struct NetCaptureConfigView: View {
    /// 窗口够宽时三张抓包来源排一行；窄了 WireGuard 另起一行（一行三张时每张不到 300 宽，二维码旁边放不下字）。
    private static let threeColumnWidth: CGFloat = 1080

    var body: some View {
        GeometryReader { proxy in
            page(threeColumns: proxy.size.width >= Self.threeColumnWidth)
        }
    }

    private func page(threeColumns: Bool) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                CertificateCard()
                    .fixedSize(horizontal: false, vertical: true)
                // 同一行的卡片一样高。
                if threeColumns {
                    HStack(alignment: .top, spacing: 14) {
                        MacCard()
                        ManualProxyCard()
                        WireGuardCard(stacked: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        MacCard()
                        ManualProxyCard()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    WireGuardCard(stacked: false)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 14) {
                    SimulatorCard()
                    TerminalCard()
                    AndroidUSBCard()
                }
                .fixedSize(horizontal: false, vertical: true)
                Text("netcapture.settings.privacyStatement")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 卡片外框

/// 一张卡片：图标 + 标题（+ 右上角的总开关）、一句说明、内容。`compact` 是下面那排次要卡片。
struct ConfigCard<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var isOn: Binding<Bool>?
    var compact = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(compact ? .body : .title3)
                    .foregroundStyle(NetCaptureColors.accent)
                    .frame(width: compact ? 20 : 26)
                Text(title).font(compact ? .subheadline.weight(.semibold) : .headline)
                Spacer(minLength: 8)
                if let isOn {
                    Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
                        .controlSize(compact ? .small : .regular)
                }
            }
            Text(detail).font(compact ? .caption : .callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(compact ? 12 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

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

private struct MacCard: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @AppStorage(NetCaptureEnv.Keys.macHTTP) private var http = true
    @AppStorage(NetCaptureEnv.Keys.macWebSocket) private var webSocket = true
    @AppStorage(NetCaptureEnv.Keys.macTCP) private var tcp = false

    var body: some View {
        ConfigCard(icon: "laptopcomputer", title: "netcapture.config.mac.title", detail: "netcapture.config.mac.detail",
                   isOn: Binding(get: { session.macOn }, set: { session.setMac($0) })) {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow(title: "netcapture.config.mac.http", isOn: $http)
                OptionRow(title: "netcapture.config.mac.websocket", note: "netcapture.config.mac.websocketNote",
                          isOn: $webSocket)
                OptionRow(title: "netcapture.config.mac.tcp", note: "netcapture.config.mac.tcpNote", isOn: $tcp)
            }
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

private struct ManualProxyCard: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @ObservedObject private var engine = NetCaptureEngine.shared
    @AppStorage(NetCaptureEnv.Keys.wifiName) private var wifiName = ""
    @AppStorage(NetCaptureEnv.Keys.port) private var port = 9090

    var body: some View {
        ConfigCard(icon: "network", title: "netcapture.config.proxy.title", detail: "netcapture.config.proxy.detail",
                   isOn: Binding(get: { session.manualProxyOn }, set: { session.setManualProxy($0) })) {
            VStack(alignment: .leading, spacing: 6) {
                CopyValueRow(label: "netcapture.config.proxy.host", value: NetworkInterfaces.primaryIP())
                CopyValueRow(label: "netcapture.config.proxy.port", value: String(engine.port ?? NetCaptureEnv.port))
                Text("netcapture.config.proxy.ipNote").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(session.manualProxyOn ? 1 : 0.55)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("netcapture.config.proxy.wifi").font(.callout)
                    TextField("netcapture.config.proxy.wifiPlaceholder", text: $wifiName)
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                }
                Text("netcapture.config.proxy.wifiNote").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - WireGuard

private struct WireGuardCard: View {
    /// 三张一行时卡片窄：二维码在上、说明在下；单独一行时左右排。
    let stacked: Bool
    @ObservedObject private var session = NetCaptureSession.shared

    var body: some View {
        ConfigCard(icon: "lock.shield", title: "netcapture.config.wg.title", detail: "netcapture.config.wg.detail",
                   isOn: Binding(get: { session.wireguardOn }, set: { session.setWireGuard($0) })) {
            if stacked {
                HStack(alignment: .top, spacing: 12) {
                    qr
                    if session.wireguardOn { endpoint }
                }
                note
            } else {
                HStack(alignment: .top, spacing: 12) {
                    qr
                    VStack(alignment: .leading, spacing: 6) {
                        if session.wireguardOn { endpoint }
                        note
                    }
                }
            }
        }
    }

    // 关着时不显示任何和密钥有关的东西。
    private var qr: some View {
        QRBox(text: session.wireguardOn ? session.wireguardClientConfig() : nil, side: 132,
              placeholder: "netcapture.config.qrPlaceholder", caption: session.wireguardEndpoint)
    }

    private var endpoint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("netcapture.config.wg.endpoint").font(.caption).foregroundStyle(.secondary)
            Text(verbatim: session.wireguardEndpoint).font(.body.monospaced()).textSelection(.enabled)
                .lineLimit(1).minimumScaleFactor(0.8)
            CopyButton(title: "netcapture.config.wg.copy") { session.wireguardClientConfig() ?? "" }
                .controlSize(.small)
        }
    }

    private var note: some View {
        Text("netcapture.config.wg.note").font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 证书

/// 单独占第一行，里面也只有一行：左边是这台 Mac 的两项（信任、解密 HTTPS），右边是「给其他设备装证书」和它的二维码。
private struct CertificateCard: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @AppStorage(NetCaptureEnv.Keys.decryptHTTPS) private var decrypt = true

    var body: some View {
        ConfigCard(icon: "checkmark.seal", title: "netcapture.config.cert.title", detail: "netcapture.config.cert.detail") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    thisMac
                    decryptRow
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                Divider()
                otherDevices
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var thisMac: some View {
        HStack(spacing: 8) {
            Text("netcapture.config.cert.thisMac").font(.callout)
            Spacer(minLength: 8)
            if session.caTrusted {
                Label("netcapture.config.cert.trusted", systemImage: "checkmark.seal.fill")
                    .font(.callout).foregroundStyle(NetCaptureColors.accent)
            } else {
                Button("netcapture.config.cert.install") { session.installCert() }
                    .controlSize(.small)
                    .disabled(session.working != nil)
            }
        }
    }

    private var decryptRow: some View {
        HStack(spacing: 8) {
            Text("netcapture.config.cert.decrypt").font(.callout)
            Button("netcapture.config.cert.scope") {
                guard let registry = AppDelegate.shared?.registry else { return }
                SettingsWindowController.shared.show(registry: registry, tab: "netcapture")
            }
            .buttonStyle(.link).controlSize(.small)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { decrypt }, set: { session.setDecryptHTTPS($0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }

    private var otherDevices: some View {
        HStack(alignment: .top, spacing: 12) {
            QRBox(text: session.certPageOn ? NetworkInterfaces.landingPageURL : nil, side: 84,
                  placeholder: "netcapture.config.qrPlaceholder", caption: NetworkInterfaces.landingPageURL)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("netcapture.config.cert.otherDevices").font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(get: { session.certPageOn }, set: { session.setCertPage($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                if session.certPageOn {
                    Text(verbatim: NetworkInterfaces.landingPageURL)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text("netcapture.config.cert.pageNote").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 次要卡片

private struct SimulatorCard: View {
    @ObservedObject private var session = NetCaptureSession.shared

    var body: some View {
        ConfigCard(icon: "macwindow.on.rectangle", title: "netcapture.config.sim.title",
                   detail: "netcapture.config.sim.detail", compact: true) {
            VStack(alignment: .leading, spacing: 6) {
                Button("netcapture.config.sim.ios") { session.installSimulatorCert() }
                Button("netcapture.config.sim.android") { session.setUpAndroidEmulators() }
            }
            .controlSize(.small)
            .disabled(session.working != nil)
        }
    }
}

private struct TerminalCard: View {
    @ObservedObject private var session = NetCaptureSession.shared

    var body: some View {
        ConfigCard(icon: "terminal", title: "netcapture.config.terminal.title",
                   detail: "netcapture.config.terminal.detail", compact: true) {
            VStack(alignment: .leading, spacing: 6) {
                Button("netcapture.config.terminal.open") { session.openTerminal() }
                Button("netcapture.config.terminal.copyEnv") { session.copyShellEnv() }
            }
            .controlSize(.small)
            .disabled(session.working != nil)
        }
    }
}

/// USB 调试连着的 Android 手机：一键设代理（指向 Mac 的局域网 IP）+ 推证书、清代理。模拟器在「模拟器」卡片里。
private struct AndroidUSBCard: View {
    @ObservedObject private var session = NetCaptureSession.shared
    @ObservedObject private var engine = NetCaptureEngine.shared
    @State private var adbPath: String?
    @State private var devices: [ADBController.Device] = []
    @State private var checked = false
    @State private var busy = false

    var body: some View {
        ConfigCard(icon: "cable.connector", title: "netcapture.config.usb.title",
                   detail: "netcapture.config.usb.detail", compact: true) {
            if !checked {
                ProgressView().controlSize(.small)
            } else if adbPath == nil {
                Text("netcapture.settings.adbHint").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if devices.isEmpty {
                HStack(spacing: 6) {
                    Text("netcapture.settings.adbNoDevice").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("netcapture.common.refresh") { refresh() }.controlSize(.small).disabled(busy)
                }
            } else {
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: device.model.isEmpty ? device.serial : "\(device.model) (\(device.serial))")
                            .font(.caption).lineLimit(1)
                        HStack(spacing: 6) {
                            Button("netcapture.config.usb.setUp") { setUp(device) }
                            Button("netcapture.settings.adbClearProxy") { clearProxy(device) }
                        }
                        .controlSize(.small)
                        .disabled(busy)
                    }
                }
                Button("netcapture.common.refresh") { refresh() }.controlSize(.small).buttonStyle(.link).disabled(busy)
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

    /// 手机经 Wi-Fi 连 Mac 的代理：要「手动代理」开着，没开只提示，不替用户开（同模拟器卡片对「本机」的做法）。
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
