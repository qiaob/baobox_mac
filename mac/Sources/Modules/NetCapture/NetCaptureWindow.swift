import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 网络抓包窗口（docs/packet-capture/REQUIREMENTS.md §5.1）：抓包的所有操作都在这里做。
///
/// 三栏：左 = 来源与域名，中 = 请求列表，右 = 详情。还没抓到东西时，中间换成「你想抓什么」的五张卡片。
/// 所有状态读单例的 `@Published`；动作转给 `NetCaptureSession`（场景）与 `FlowStore`（数据）。

// MARK: - 配色

/// 复用设计令牌 accent（浅 #17A398 / 深 #2BC4B8）与方法/状态码配色。
enum NetCaptureColors {
    static var accent: Color { Color(light: 0x17A398, dark: 0x2BC4B8) }

    /// HTTP 方法徽标底色。
    static func method(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return Color(hex: 0x28A745)
        case "POST": return Color(hex: 0x0A84FF)
        case "PUT": return Color(hex: 0xF59E0B)
        case "DELETE": return Color(hex: 0xFF3B30)
        case "PATCH": return Color(hex: 0x8B5CF6)
        default: return Color(hex: 0x8E8E93)
        }
    }

    /// 状态码配色。
    static func status(_ code: Int?) -> Color {
        guard let code else { return Color(hex: 0x8E8E93) }
        switch code / 100 {
        case 2: return Color(hex: 0x28A745)
        case 3: return Color(hex: 0x0A84FF)
        case 4: return Color(hex: 0xF59E0B)
        case 5: return Color(hex: 0xFF3B30)
        default: return Color(hex: 0x8E8E93)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// 浅/深两套色，按系统外观自适应。
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - 窗口控制器

@MainActor
final class NetCaptureWindowController {
    static let shared = NetCaptureWindowController()
    private var window: NSWindow?
    private init() {}

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: NetCaptureRootView())
            // 和别的模块的主窗口一样经 DesktopSpaceWindow 建：否则从全屏 App 里打开时，它会被塞进那个全屏空间，
            // 系统的验证框一弹（装证书时）就跟着空间切换不见了。
            let created = DesktopSpaceWindow.make { NSWindow(contentViewController: hosting) }
            created.title = L("netcapture.window.title")
            created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            created.setContentSize(NSSize(width: 1080, height: 660))
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 根视图

struct NetCaptureRootView: View {
    @ObservedObject private var engine = NetCaptureEngine.shared
    @ObservedObject private var session = NetCaptureSession.shared
    @ObservedObject private var store = FlowStore.shared
    @ObservedObject private var mcp = CaptureMCPServer.shared

    @State private var query = ""
    @State private var methodFilter: Set<String> = []
    @State private var statusFilter: Set<Int> = []
    @State private var selection: Flow.ID?
    @State private var deviceFilter: String?      // nil = 全部
    @State private var hostFilter: String?        // nil = 全部域名
    @State private var phoneSheet: NetCapturePhoneSheet.Platform?
    @State private var renameIP: String?
    @State private var renameText = ""

    private var filtered: [Flow] {
        store.filtered(query: query, methods: methodFilter, statusClasses: statusFilter,
                       device: deviceFilter, host: hostFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reason = NetCaptureEnv.engineUnavailable {
                unavailable(reason)
            } else {
                toolbar
                Divider()
                notices
                if store.flows.isEmpty {
                    NetCaptureScenarioCards(openPhoneSheet: { phoneSheet = $0 })
                } else {
                    HSplitView {
                        sidebar.frame(minWidth: 150, idealWidth: 190, maxWidth: 280)
                        flowList.frame(minWidth: 340, idealWidth: 440)
                        detailPane.frame(minWidth: 340)
                    }
                }
                Divider()
                statusBar
            }
        }
        .frame(minWidth: 900, minHeight: 540)
        .sheet(item: $phoneSheet) { platform in
            NetCapturePhoneSheet(platform: platform) { phoneSheet = nil }
        }
        .sheet(isPresented: Binding(get: { renameIP != nil }, set: { if !$0 { renameIP = nil } })) { renameSheet }
        .onAppear { session.refreshTrust() }
    }

    private func unavailable(_ reason: NetCaptureEnv.EngineUnavailable) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(reason == .needsAppleSilicon ? "netcapture.unavailable.intel" : "netcapture.unavailable.notBundled")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 工具条

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                engine.isActive ? session.stopAll() : session.start()
            } label: {
                Label(engine.isActive ? "netcapture.window.stop" : "netcapture.window.start",
                      systemImage: engine.isActive ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isActive ? .red : NetCaptureColors.accent)
            .disabled(session.working != nil && !engine.isActive)

            sourceMenu

            Button {
                store.clear()
                selection = nil
                hostFilter = nil
            } label: {
                Image(systemName: "trash")
            }
            .help(Text("netcapture.window.clear"))
            .disabled(store.flows.isEmpty)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("netcapture.window.search", text: $query)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 120, maxWidth: 220)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))

            methodChips
            statusChips

            Spacer()

            certBadge
            moreMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 「抓：…」下拉：现在在抓哪些来源，随时增减。
    private var sourceMenu: some View {
        Menu {
            Toggle("netcapture.source.mac", isOn: Binding(
                get: { session.macCaptureOn },
                set: { $0 ? session.startMac() : session.stopMac() }))
            Toggle("netcapture.source.phone", isOn: Binding(
                get: { session.phonePageOn },
                set: { on in
                    session.setLAN(on)
                    if on { phoneSheet = .iOS }
                }))
            Divider()
            Button("netcapture.source.terminal") { session.openTerminal() }
            Button("netcapture.source.copyEnv") { session.copyShellEnv() }
            Button("netcapture.source.simulator") { session.installSimulatorCert() }
            if session.phonePageOn {
                Divider()
                Button("netcapture.source.showQR") { phoneSheet = .iOS }
            }
        } label: {
            Text(sourceSummary)
        }
        .fixedSize()
        .disabled(session.working != nil)
    }

    private var sourceSummary: String {
        var names: [String] = []
        if session.macCaptureOn { names.append(L("netcapture.source.mac")) }
        if session.phonePageOn { names.append(L("netcapture.source.phoneShort")) }
        if names.isEmpty { return L("netcapture.source.none") }
        return L("netcapture.source.summary \(names.joined(separator: " + "))")
    }

    private var methodChips: some View {
        HStack(spacing: 4) {
            ForEach(["GET", "POST", "PUT", "DELETE"], id: \.self) { method in
                chip(title: method, active: methodFilter.contains(method), color: NetCaptureColors.method(method)) {
                    toggle(&methodFilter, method)
                }
            }
        }
    }

    private var statusChips: some View {
        HStack(spacing: 4) {
            ForEach([2, 3, 4, 5], id: \.self) { cls in
                chip(title: "\(cls)xx", active: statusFilter.contains(cls),
                     color: NetCaptureColors.status(cls * 100)) {
                    toggle(&statusFilter, cls)
                }
            }
        }
    }

    private func chip(title: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(active ? color.opacity(0.9) : color.opacity(0.15), in: Capsule())
                .foregroundStyle(active ? .white : color)
        }
        .buttonStyle(.plain)
    }

    /// 证书状态：没装时点一下就装。
    private var certBadge: some View {
        Button {
            if !session.caTrusted { session.installCert() }
        } label: {
            Label(session.caTrusted ? "netcapture.cert.trusted" : "netcapture.cert.untrusted",
                  systemImage: session.caTrusted ? "checkmark.seal.fill" : "seal")
                .foregroundStyle(session.caTrusted ? NetCaptureColors.accent : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(Text(session.caTrusted ? "netcapture.cert.trustedHelp" : "netcapture.cert.untrustedHelp"))
        .disabled(session.working != nil)
    }

    private var moreMenu: some View {
        Menu {
            Toggle("netcapture.mcp.toggle", isOn: Binding(
                get: { mcp.isRunning },
                set: { $0 ? mcp.start() : mcp.stop() }))
            Divider()
            Button("netcapture.settings.exportHar") { exportHAR() }
                .disabled(store.flows.isEmpty)
            Button("netcapture.window.settings") {
                guard let registry = AppDelegate.shared?.registry else { return }
                SettingsWindowController.shared.show(registry: registry, tab: "netcapture")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: 提示条（进度 / 待允许的设备 / 成功或失败）

    @ViewBuilder
    private var notices: some View {
        if let working = session.working {
            noticeRow(icon: nil, tint: .secondary) {
                ProgressView().controlSize(.small)
                Text(verbatim: working)
            }
        }
        ForEach(engine.pendingDevices, id: \.self) { ip in
            noticeRow(icon: "iphone.radiowaves.left.and.right", tint: NetCaptureColors.accent) {
                Text("netcapture.device.pending \(ip)")
                Spacer()
                Button("netcapture.device.deny") { engine.deny(device: ip) }
                Button("netcapture.device.allow") { engine.allow(device: ip) }
                    .buttonStyle(.borderedProminent).tint(NetCaptureColors.accent)
            }
        }
        if let banner = session.banner {
            noticeRow(icon: banner.kind == .problem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                      tint: banner.kind == .problem ? .orange : NetCaptureColors.accent) {
                Text(verbatim: banner.text).textSelection(.enabled)
                Spacer()
                Button { session.banner = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func noticeRow<Content: View>(icon: String?, tint: Color,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).foregroundStyle(tint) }
                content()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(0.08))
            Divider()
        }
    }

    // MARK: 左栏：来源与域名

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sidebarRow(title: L("netcapture.device.all"), count: store.flows.count,
                           selected: deviceFilter == nil && hostFilter == nil, icon: "tray.full") {
                    deviceFilter = nil
                    hostFilter = nil
                    selection = nil
                }
                ForEach(store.devices) { device in
                    sidebarRow(title: device.label, count: device.flowCount,
                               selected: deviceFilter == device.ip && hostFilter == nil,
                               icon: FlowStore.isLoopback(device.ip) ? "laptopcomputer" : "iphone") {
                        deviceFilter = device.ip
                        hostFilter = nil
                        selection = nil
                    }
                    .contextMenu { deviceMenu(ip: device.ip) }
                }

                Text("netcapture.sidebar.hosts")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 2)
                ForEach(store.hosts(device: deviceFilter).prefix(80), id: \.host) { entry in
                    sidebarRow(title: entry.host, count: entry.count,
                               selected: hostFilter == entry.host, icon: nil) {
                        hostFilter = (hostFilter == entry.host) ? nil : entry.host
                        selection = nil
                    }
                }
            }
            .padding(6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sidebarRow(title: String, count: Int, selected: Bool, icon: String?,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).frame(width: 16).foregroundStyle(selected ? Color.white : Color.secondary)
                }
                Text(verbatim: title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(verbatim: "\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? NetCaptureColors.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func deviceMenu(ip: String) -> some View {
        Button {
            renameText = store.alias(ip: ip) ?? ""
            renameIP = ip
        } label: { Label("netcapture.device.rename", systemImage: "pencil") }
        Button(role: .destructive) {
            store.clearDevice(ip: ip)
            if deviceFilter == ip { deviceFilter = nil }
            selection = nil
        } label: { Label("netcapture.device.clear", systemImage: "trash") }
        if !FlowStore.isLoopback(ip), ip != NetCaptureEnv.unknownDeviceKey {
            Button(role: .destructive) {
                engine.deny(device: ip)
            } label: { Label("netcapture.device.block", systemImage: "hand.raised") }
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("netcapture.device.renameTitle").font(.headline)
            TextField("netcapture.device.renamePlaceholder", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack {
                Spacer()
                Button("common.cancel") { renameIP = nil }
                Button("common.ok") {
                    if let ip = renameIP { store.setAlias(ip: ip, renameText) }
                    renameIP = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: 中栏：请求列表

    private var flowList: some View {
        List(Array(filtered.reversed()), selection: $selection) { flow in
            FlowRow(flow: flow).tag(flow.id)
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
    }

    // MARK: 右栏：详情

    @ViewBuilder
    private var detailPane: some View {
        if let id = selection, let flow = store.flows.first(where: { $0.id == id }) {
            FlowDetailView(flow: flow)
        } else {
            VStack {
                Spacer()
                Text("netcapture.window.selectFlow").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: 状态条

    private var statusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle().fill(engine.isRunning ? Color(hex: 0x28C840) : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(statusText)
            }
            if engine.isRunning {
                Divider().frame(height: 12)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(proxyAddress, forType: .string)
                } label: {
                    Text(verbatim: proxyAddress).monospacedDigit()
                }
                .buttonStyle(.plain)
                .help(Text("netcapture.window.copyAddr"))
            }
            Divider().frame(height: 12)
            Text("netcapture.status.counts \(filtered.count) \(store.flows.count)")
            if mcp.isRunning {
                Divider().frame(height: 12)
                Text("netcapture.mcp.running")
            }
            Spacer()
            Text("netcapture.status.memory \(memoryMB)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var statusText: LocalizedStringKey {
        switch engine.state {
        case .running: return "netcapture.status.running"
        case .starting: return "netcapture.status.starting"
        case .failed: return "netcapture.status.failed"
        case .stopped: return "netcapture.status.stopped"
        }
    }

    /// 给别的设备填的代理地址；只听本机时显示 127.0.0.1。
    private var proxyAddress: String {
        let port = engine.port ?? NetCaptureEnv.port
        return "\(engine.lanEnabled ? NetworkInterfaces.primaryIP() : "127.0.0.1"):\(port)"
    }

    private var memoryMB: String {
        String(format: "%.1f", Double(store.estimatedBytes) / (1024 * 1024))
    }

    // MARK: 动作

    private func exportHAR() {
        let data = store.harData(filtered)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
        panel.nameFieldStringValue = "capture.har"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            session.banner = NetCaptureSession.Banner(kind: .problem, text: error.localizedDescription)
        }
    }

    private func toggle(_ set: inout Set<String>, _ value: String) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private func toggle(_ set: inout Set<Int>, _ value: Int) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}

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
                    card(icon: "macwindow.on.rectangle", title: "netcapture.card.simulator.title",
                         detail: "netcapture.card.simulator.detail", note: "netcapture.card.simulator.note") {
                        primary("netcapture.source.simulator") { session.installSimulatorCert() }
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

// MARK: - 请求行

private struct FlowRow: View {
    let flow: Flow

    var body: some View {
        HStack(spacing: 8) {
            // 没解密的连接只知道域名，方法那一格写 TLS。
            Text(verbatim: flow.decrypted ? flow.method : "TLS")
                .font(.caption2.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .frame(width: 58)
                .background(NetCaptureColors.method(flow.method).opacity(flow.decrypted ? 1 : 0.45),
                            in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)

            Text(verbatim: statusText)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(flow.note != nil && flow.statusCode == nil
                                 ? Color(hex: 0xFF3B30) : NetCaptureColors.status(flow.statusCode))
                .frame(width: 30, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(verbatim: flow.host).font(.callout).lineLimit(1)
                    if let badge = flow.protocolBadge {
                        Text(verbatim: badge)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                if !flow.path.isEmpty {
                    Text(verbatim: flow.path).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .foregroundStyle(flow.decrypted ? Color.primary : Color.secondary)
            Spacer(minLength: 6)
            if flow.decrypted {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: flow.durationMs.map { "\($0)ms" } ?? "—")
                        .font(.caption2.monospacedDigit())
                    Text(verbatim: FlowFormat.bytes(flow.responseBytes))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    .help(Text("netcapture.flow.notDecrypted"))
            }
        }
        .padding(.vertical, 2)
        .contextMenu { rowMenu }
    }

    /// 状态码那一格：有响应显示状态码；还在等显示「⋯」；失败显示「✕」；没解密的显示「—」。
    private var statusText: String {
        if let code = flow.statusCode { return String(code) }
        if !flow.decrypted { return "—" }
        if flow.note != nil { return "✕" }
        return "⋯"
    }

    @ViewBuilder
    private var rowMenu: some View {
        if flow.decrypted {
            Button { FlowActions.copy(FlowStore.shared.curl(for: flow)) } label: {
                Label("netcapture.flow.copyCurl", systemImage: "terminal")
            }
            Button { FlowActions.copy(FlowStore.shared.markdown(for: flow)) } label: {
                Label("netcapture.flow.copyMarkdown", systemImage: "doc.text")
            }
            Button { FlowActions.sendToClaude(flow) } label: {
                Label("netcapture.flow.sendToClaude", systemImage: "paperplane")
            }
        }
        Button { FlowActions.copy(flow.decrypted ? flow.url : flow.host) } label: {
            Label("netcapture.flow.copyURL", systemImage: "link")
        }
    }
}

@MainActor
private enum FlowActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 发送到 Claude Code：把这条请求的 Markdown 写临时文件，在终端起 `claude "$(cat file)"`。
    static func sendToClaude(_ flow: Flow) {
        let markdown = FlowStore.shared.markdown(for: flow)
        let dir = NetCaptureEnv.ensureSupportDir().appendingPathComponent("send", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).md")
        do {
            try Data(markdown.utf8).write(to: file)
        } catch {
            StorageWriteFailure.report("netcapture.send", reason: error.localizedDescription)
            return
        }
        let bin = ClaudeEnv.findClaudeBinary() ?? "claude"
        let command = "\(NetCaptureEnv.shellSingleQuote(bin)) \"$(cat \(NetCaptureEnv.shellSingleQuote(file.path)))\""
        TerminalLauncher.run(command: command, in: nil)
    }
}

private enum FlowFormat {
    static func bytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1fMB", Double(bytes) / (1024 * 1024)) }
        if bytes >= 1024 { return String(format: "%.1fKB", Double(bytes) / 1024) }
        return "\(bytes)B"
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }
}

// MARK: - 详情视图

private struct FlowDetailView: View {
    let flow: Flow
    @State private var tab = DetailTab.overview

    enum DetailTab: String, Identifiable {
        case overview, request, response, messages, raw
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .overview: return "netcapture.detail.overview"
            case .request: return "netcapture.detail.request"
            case .response: return "netcapture.detail.response"
            case .messages: return "netcapture.detail.messages"
            case .raw: return "netcapture.detail.raw"
            }
        }
    }

    private var tabs: [DetailTab] {
        guard flow.decrypted else { return [.overview] }
        return flow.isWebSocket ? [.overview, .request, .response, .messages, .raw]
                                : [.overview, .request, .response, .raw]
    }

    /// 换了一条请求后，上一条选的页签这条可能没有。
    private var currentTab: DetailTab { tabs.contains(tab) ? tab : .overview }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: Binding(get: { currentTab }, set: { tab = $0 })) {
                    ForEach(tabs) { t in Text(t.label).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if flow.decrypted {
                    Button { FlowActions.copy(FlowStore.shared.curl(for: flow)) } label: {
                        Image(systemName: "terminal")
                    }
                    .help(Text("netcapture.flow.copyCurl"))
                    Button { FlowActions.sendToClaude(flow) } label: {
                        Image(systemName: "paperplane")
                    }
                    .help(Text("netcapture.flow.sendToClaude"))
                }
            }
            .padding(8)
            Divider()
            ScrollView {
                Group {
                    switch currentTab {
                    case .overview: overview
                    case .request: message(headers: flow.requestHeaders, body: flow.requestBody,
                                           truncated: flow.requestTruncated)
                    case .response: message(headers: flow.responseHeaders, body: flow.responseBody,
                                            truncated: flow.responseTruncated)
                    case .messages: messages
                    case .raw: rawView
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            if flow.decrypted {
                field("netcapture.detail.method", flow.method)
                field("netcapture.detail.url", flow.url)
                field("netcapture.detail.status", flow.statusCode.map(String.init) ?? "—")
                field("netcapture.detail.protocol", flow.isWebSocket ? "WebSocket (\(flow.httpVersion))" : flow.httpVersion)
                field("netcapture.detail.remoteIP", flow.remoteIP ?? "—")
                field("netcapture.detail.started", FlowFormat.time(flow.startedAt))
                field("netcapture.detail.duration", flow.durationMs.map { "\($0)ms" } ?? "—")
                field("netcapture.detail.reqSize", FlowFormat.bytes(flow.requestBytes))
                field("netcapture.detail.respSize", FlowFormat.bytes(flow.responseBytes))
                field("netcapture.detail.contentType", flow.responseContentType ?? "—")
                if let encoding = flow.responseEncoding, !encoding.isEmpty {
                    field("netcapture.detail.encoding", encoding)
                }
                if let note = flow.note {
                    field("netcapture.detail.error", note)
                }
            } else {
                field("netcapture.detail.host", flow.host)
                field("netcapture.detail.started", FlowFormat.time(flow.startedAt))
                Text(flow.undecryptedReason == .outOfScope
                     ? "netcapture.flow.reason.outOfScope" : "netcapture.flow.reason.handshake")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private func field(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(verbatim: value).font(.callout).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func message(headers: [HTTPHeader], body: Data?, truncated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("netcapture.detail.headers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    HStack(alignment: .top, spacing: 6) {
                        Text(verbatim: header.name + ":").font(.caption.monospaced().weight(.medium))
                        Text(verbatim: header.value).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if let body, !body.isEmpty {
                Text("netcapture.detail.body").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                bodyView(body: body, headers: headers)
            } else if !truncated {
                Text("netcapture.detail.noBody").font(.caption).foregroundStyle(.secondary)
            }
            if truncated {
                Text("netcapture.detail.truncated").font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    /// 依据 Content-Type 渲染正文：图片直接预览；JSON 美化；其余文本原样。正文已由引擎解压。
    @ViewBuilder
    private func bodyView(body: Data, headers: [HTTPHeader]) -> some View {
        let contentType = headers.value(for: "Content-Type")?.lowercased() ?? ""
        if contentType.hasPrefix("image/"), let image = NSImage(data: body) {
            Image(nsImage: image)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 320, maxHeight: 320)
        } else if let text = String(data: body, encoding: .utf8) {
            Text(verbatim: Self.pretty(text, contentType: contentType))
                .font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        } else {
            Text("netcapture.detail.binary \(body.count)").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 展示用的文本：JSON 缩进美化；太长只显示前面一段（SwiftUI 的 Text 排几 MB 文字会卡住窗口）。
    private static func pretty(_ text: String, contentType: String) -> String {
        var display = text
        if contentType.contains("json") || text.hasPrefix("{") || text.hasPrefix("["),
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let formatted = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .withoutEscapingSlashes]),
           let string = String(data: formatted, encoding: .utf8) {
            display = string
        }
        let limit = 200_000
        return display.count > limit ? String(display.prefix(limit)) + "\n…" : display
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            if flow.messages.isEmpty {
                Text("netcapture.detail.noMessages").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(flow.messages) { message in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: message.fromClient ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(message.fromClient ? Color(hex: 0x0A84FF) : Color(hex: 0x28A745))
                        .frame(width: 14)
                    Text(verbatim: FlowFormat.time(message.at))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    if let text = message.text {
                        Text(verbatim: text).font(.caption.monospaced()).textSelection(.enabled)
                    } else {
                        Text("netcapture.detail.binary \(message.size)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var rawView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("netcapture.detail.rawRequest").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: rawText(startLine: "\(flow.method) \(flow.path) \(flow.httpVersion)",
                                   headers: flow.requestHeaders, body: flow.requestBody))
                .font(.caption.monospaced()).textSelection(.enabled)
            Divider()
            Text("netcapture.detail.rawResponse").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: rawText(startLine: "\(flow.httpVersion) \(flow.statusCode.map(String.init) ?? "")",
                                   headers: flow.responseHeaders, body: flow.responseBody))
                .font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func rawText(startLine: String, headers: [HTTPHeader], body: Data?) -> String {
        var lines = [startLine]
        for h in headers { lines.append("\(h.name): \(h.value)") }
        lines.append("")
        if let body, let text = String(data: body, encoding: .utf8) {
            lines.append(String(text.prefix(20000)))
        }
        return lines.joined(separator: "\n")
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
