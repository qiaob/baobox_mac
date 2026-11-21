import AppKit
import SwiftUI

// 抓包窗口里「还没开始抓」时的五张场景卡片，和接手机的配置面板（二维码 + 步骤 + Android 的 ADB 一键）。
// 从 NetCaptureWindow.swift 原样搬出来（docs/packet-capture/TOOLS.md §7）。

// MARK: - 五张场景卡片（还没抓到东西时）

/// 「你想抓什么」：每张卡片一个场景，点一下该做的配置全部自动做（REQUIREMENTS §3）。
struct NetCaptureScenarioCards: View {
    @ObservedObject private var engine = NetCaptureEngine.shared
    @ObservedObject private var session = NetCaptureSession.shared
    let openPhoneSheet: (NetCapturePhoneSheet.Platform) -> Void

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(engine.isRunning ? "netcapture.cards.waiting" : "netcapture.cards.title")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 26)
                LazyVGrid(columns: columns, spacing: 14) {
                    card(icon: "laptopcomputer", title: "netcapture.card.mac.title",
                         detail: "netcapture.card.mac.detail", note: "netcapture.card.mac.note") {
                        if session.macCaptureOn {
                            Button("netcapture.card.mac.stop") { session.stopMac() }
                        } else {
                            primary("netcapture.card.mac.start") { session.startMac() }
                        }
                    }
                    card(icon: "terminal", title: "netcapture.card.terminal.title",
                         detail: "netcapture.card.terminal.detail", note: nil) {
                        primary("netcapture.source.terminal") { session.openTerminal() }
                        Button("netcapture.source.copyEnv") { session.copyShellEnv() }
                    }
                    card(icon: "iphone", title: "netcapture.card.ios.title",
                         detail: "netcapture.card.ios.detail", note: "netcapture.card.ios.note") {
                        primary("netcapture.card.ios.start") {
                            session.setLAN(true)
                            openPhoneSheet(.iOS)
                        }
                    }
                    card(icon: "candybarphone", title: "netcapture.card.android.title",
                         detail: "netcapture.card.android.detail", note: "netcapture.card.android.note") {
                        primary("netcapture.card.android.start") {
                            session.setLAN(true)
                            openPhoneSheet(.android)
                        }
                    }
                    // 两个平台的模拟器都从这张卡片进。Android 模拟器在 adb 看来就是一台设备，
                    // 所以它的按钮打开的是和「Android」卡片同一个面板（里面会列出模拟器）。
                    card(icon: "macwindow.on.rectangle", title: "netcapture.card.simulator.title",
                         detail: "netcapture.card.simulator.detail", note: nil) {
                        primary("netcapture.source.simulator") { session.installSimulatorCert() }
                        Button("netcapture.card.simulator.android") {
                            session.setLAN(true)
                            openPhoneSheet(.android)
                        }
                    }
                }
                .padding(.horizontal, 24)
                Text("netcapture.settings.privacyStatement")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func primary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(NetCaptureColors.accent)
    }

    private func card<Buttons: View>(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey,
                                     note: LocalizedStringKey?,
                                     @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.title3).foregroundStyle(NetCaptureColors.accent).frame(width: 26)
                Text(title).font(.headline)
            }
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { buttons() }
                .disabled(session.working != nil)
                .padding(.top, 2)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }
}

// MARK: - 手机配置面板

/// 接手机：左边一个二维码（手机扫了打开配置页：装证书、配代理、关代理），右边是这个平台要做的几步。
/// Android 多一块：连着 USB 调试的设备可以一键设代理、推证书。
struct NetCapturePhoneSheet: View {
    enum Platform: String, Identifiable {
        case iOS, android
        var id: String { rawValue }
    }

    let platform: Platform
    let close: () -> Void

    @ObservedObject private var engine = NetCaptureEngine.shared
    @State private var adbPath: String?
    @State private var devices: [ADBController.Device] = []
    @State private var busy = false
    @State private var adbChecked = false
    @State private var lastResult: String?
    @AppStorage(NetCaptureEnv.Keys.wifiName) private var wifiName = ""

    private var proxyAddress: String { "\(NetworkInterfaces.primaryIP()):\(engine.port ?? NetCaptureEnv.port)" }

    var body: some View {
        VStack(spacing: 16) {
            Text(platform == .iOS ? "netcapture.phone.title.ios" : "netcapture.phone.title.android")
                .font(.headline)
            HStack(alignment: .top, spacing: 24) {
                qrColumn
                VStack(alignment: .leading, spacing: 10) {
                    if platform == .iOS { iosSteps } else { androidSteps }
                }
                .frame(width: 330, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("common.ok") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .onAppear { if platform == .android { refreshADB() } }
    }

    private var qrColumn: some View {
        VStack(spacing: 8) {
            if let cg = QRCodeGenerator.image(for: NetworkInterfaces.landingPageURL, minPixels: 300) {
                Image(decorative: cg, scale: 1).resizable().interpolation(.none)
                    .frame(width: 200, height: 200)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            } else {
                Text("netcapture.qr.unavailable").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 212, height: 212)
            }
            Text(verbatim: NetworkInterfaces.landingPageURL)
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 6) {
                Text("netcapture.phone.proxy").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: proxyAddress).font(.callout.monospaced()).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(proxyAddress, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(Text("netcapture.window.copyAddr"))
            }
        }
    }

    private var iosSteps: some View {
        Group {
            step(1, "netcapture.phone.ios.step1")
            step(2, "netcapture.phone.ios.step2")
            step(3, "netcapture.phone.ios.step3")
            step(4, "netcapture.phone.ios.step4")
            step(5, "netcapture.phone.ios.step5")
            Divider()
            HStack {
                Text("netcapture.phone.wifiName")
                TextField("", text: $wifiName).textFieldStyle(.roundedBorder)
            }
            Text("netcapture.phone.wifiHint").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var androidSteps: some View {
        Text("netcapture.phone.android.usb").font(.subheadline.weight(.medium))
        if !adbChecked {
            ProgressView().controlSize(.small)
        } else if adbPath == nil {
            Text("netcapture.settings.adbHint").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if devices.isEmpty {
            HStack {
                Text("netcapture.settings.adbNoDevice").font(.caption).foregroundStyle(.secondary)
                Button("netcapture.common.refresh") { refreshADB() }.disabled(busy)
            }
        } else {
            ForEach(devices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: device.model.isEmpty ? device.serial : "\(device.model) (\(device.serial))")
                        .font(.callout)
                    HStack {
                        Button("netcapture.phone.android.setup") { setUp(device) }
                            .buttonStyle(.borderedProminent).tint(NetCaptureColors.accent)
                        Button("netcapture.settings.adbClearProxy") { clearProxy(device) }
                    }
                    .disabled(busy)
                }
            }
            if let lastResult {
                Text(verbatim: lastResult).font(.caption).foregroundStyle(.secondary)
            }
        }
        Divider()
        Text("netcapture.phone.android.manual").font(.subheadline.weight(.medium))
        step(1, "netcapture.phone.android.step1")
        step(2, "netcapture.phone.android.step2")
        Text("netcapture.card.android.note").font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "\(number)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(NetCaptureColors.accent))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: ADB

    private func refreshADB() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let path = ADBController.adbPath()
            let list = path != nil ? ADBController.devices() : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    adbPath = path
                    devices = list
                    busy = false
                    adbChecked = true
                }
            }
        }
    }

    /// 一键：设代理 + 推证书。模拟器（序列号以 emulator- 开头）访问宿主机要用 10.0.2.2。
    private func setUp(_ device: ADBController.Device) {
        busy = true
        let port = engine.port ?? NetCaptureEnv.port
        let ip = device.serial.hasPrefix("emulator-") ? "10.0.2.2" : NetworkInterfaces.primaryIP()
        DispatchQueue.global(qos: .userInitiated).async {
            let proxied = ADBController.setProxy(serial: device.serial, ip: ip, port: port)
            let pushed = ADBController.pushAndInstallCert(serial: device.serial)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    busy = false
                    lastResult = (proxied && pushed) ? L("netcapture.phone.android.done")
                                                     : L("netcapture.phone.android.failed")
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
                    lastResult = ok ? L("netcapture.phone.android.cleared") : L("netcapture.phone.android.failed")
                }
            }
        }
    }
}

// MARK: - 设备设置面板

/// 工具条「设备设置」点开的面板：按设备列出接进来要做的事。只负责「怎么配」，不改变正在抓谁。
struct NetCaptureDeviceSetup: View {
    enum Action { case iOS, android, iosSimulator, terminal, copyEnv }

    let perform: (Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("netcapture.setup.title").font(.headline).padding(.bottom, 8)
            row(icon: "iphone", title: "netcapture.card.ios.title", detail: "netcapture.setup.ios.detail") {
                Button("netcapture.setup.ios.action") { perform(.iOS) }
            }
            Divider()
            row(icon: "candybarphone", title: "netcapture.setup.android.title", detail: "netcapture.setup.android.detail") {
                Button("netcapture.setup.android.action") { perform(.android) }
            }
            Divider()
            row(icon: "macwindow.on.rectangle", title: "netcapture.setup.simulator.title",
                detail: "netcapture.setup.simulator.detail") {
                Button("netcapture.setup.simulator.ios") { perform(.iosSimulator) }
                Button("netcapture.setup.simulator.android") { perform(.android) }
            }
            Divider()
            row(icon: "terminal", title: "netcapture.card.terminal.title", detail: "netcapture.setup.terminal.detail") {
                Button("netcapture.source.terminal") { perform(.terminal) }
                Button("netcapture.source.copyEnv") { perform(.copyEnv) }
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private func row<Buttons: View>(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey,
                                    @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(NetCaptureColors.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { buttons() }.controlSize(.small).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}
