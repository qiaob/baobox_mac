import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 网络抓包窗口（docs/packet-capture/REQUIREMENTS.md §5.1）：抓包的所有操作都在这里做。
///
/// 三栏：左 = 来源与域名，中 = 请求列表，右 = 详情（NetCaptureDetailView.swift）。还没抓到东西时，中间换成「你想抓什么」的五张卡片。
/// 所有状态读单例的 `@Published`；动作转给 `NetCaptureSession`（场景）、`FlowStore`（数据与筛选）、`MockRuleStore`（Mock）。

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

extension Color {
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
    @ObservedObject private var mockRules = MockRuleStore.shared

    @State private var query = ""
    @State private var selection: Flow.ID?
    @State private var phoneSheet: NetCapturePhoneSheet.Platform?
    @State private var renameIP: String?
    @State private var renameText = ""
    @State private var replayDraft: ReplayDraft?
    @State private var mockEditing: MockEditing?
    @State private var showMockRules = false

    /// 请求列表此刻显示的行（筛选条件在 `store.filter`，全文搜索在 `query`）。
    private var filtered: [Flow] { store.filtered(query: query) }

    var body: some View {
        VStack(spacing: 0) {
            if let reason = NetCaptureEnv.engineUnavailable {
                unavailable(reason)
            } else {
                // 一次重绘只筛一遍：列表和状态条用同一份。
                let visible = filtered
                toolbar
                Divider()
                notices
                // 卡片页只在「没在抓、列表也空」时出现；一开始抓（引擎进入 starting）就切到三栏，不等第一条请求。
                // 启动失败且列表为空：留在卡片页，失败原因在上面的提示条里。
                if store.flows.isEmpty && !engine.isActive {
                    NetCaptureScenarioCards(openPhoneSheet: { phoneSheet = $0 })
                } else {
                    // 详情最宽：左栏和请求列表给定宽度，窗口拉宽时多出来的都给详情（分隔线照样能拖）。
                    NetCaptureColumns {
                        sidebar
                    } list: {
                        flowList(visible)
                    } detail: {
                        detailPane
                    }
                }
                Divider()
                statusBar(visibleCount: visible.count)
            }
        }
        // 三栏都到最小宽度时要 862（ColumnLayout.minimumTotal），工具条在 900 下也不换行。
        .frame(minWidth: 900, minHeight: 540)
        .sheet(item: $phoneSheet) { platform in
            NetCapturePhoneSheet(platform: platform) { phoneSheet = nil }
        }
        .sheet(isPresented: Binding(get: { renameIP != nil }, set: { if !$0 { renameIP = nil } })) { renameSheet }
        .sheet(item: $replayDraft) { draft in
            NetCaptureReplaySheet(draft: draft,
                                  onCancel: { replayDraft = nil },
                                  onSend: { request in
                                      replayDraft = nil
                                      send(request)
                                  })
        }
        .sheet(item: $mockEditing) { editing in
            MockRuleEditor(editing: editing,
                           onSave: { rule in
                               mockRules.save(rule)
                               mockEditing = nil
                           },
                           onDelete: nil,
                           onCancel: { mockEditing = nil })
        }
        .sheet(isPresented: $showMockRules) {
            MockRulesSheet { showMockRules = false }
        }
        .onAppear {
            session.refreshTrust()
            mockRules.load()
        }
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
        HStack(spacing: 8) {
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
                store.updateFilter { $0.host = nil }
            } label: {
                Image(systemName: "trash")
            }
            .help(Text("netcapture.window.clear"))
            .disabled(store.flows.isEmpty)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("netcapture.window.search", text: $query)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 70, maxWidth: 220)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))

            methodChips
            statusChips

            Spacer()

            mockButton
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
            Divider()
            Toggle("netcapture.source.phone", isOn: Binding(
                get: { session.phonePageOn },
                set: { on in
                    session.setLAN(on)
                    if on { phoneSheet = .iOS }
                }))
            if session.phonePageOn {
                Button("netcapture.source.showQR") { phoneSheet = .iOS }
            }
            // 卡片页上「Android」「模拟器」两张卡片的按钮：切到三栏以后卡片看不见了，入口在这里。
            Button("netcapture.card.android.start") {
                session.setLAN(true)
                phoneSheet = .android
            }
            Divider()
            Button("netcapture.source.terminal") { session.openTerminal() }
            Button("netcapture.source.copyEnv") { session.copyShellEnv() }
            Divider()
            Button("netcapture.source.simulator") { session.installSimulatorCert() }
            Button("netcapture.card.simulator.android") {
                session.setLAN(true)
                phoneSheet = .android
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
                chip(title: method, active: store.filter.methods.contains(method),
                     color: NetCaptureColors.method(method)) {
                    store.updateFilter { $0.methods.formSymmetricDifference([method]) }
                }
            }
        }
    }

    private var statusChips: some View {
        HStack(spacing: 4) {
            ForEach([2, 3, 4, 5], id: \.self) { cls in
                chip(title: "\(cls)xx", active: store.filter.statusClasses.contains(cls),
                     color: NetCaptureColors.status(cls * 100)) {
                    store.updateFilter { $0.statusClasses.formSymmetricDifference([cls]) }
                }
            }
        }
    }

    private func chip(title: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(active ? color.opacity(0.9) : color.opacity(0.15), in: Capsule())
                .foregroundStyle(active ? .white : color)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// 「Mock」：点开是规则列表；有启用的规则时写成「Mock 2」。
    private var mockButton: some View {
        Button {
            showMockRules = true
        } label: {
            Text(verbatim: mockRules.enabledCount > 0 ? "Mock \(mockRules.enabledCount)" : "Mock")
        }
        .help(Text("netcapture.mock.toolbarHelp"))
        .fixedSize()
    }

    /// 证书状态：没装时点一下就装。
    private var certBadge: some View {
        Button {
            if !session.caTrusted { session.installCert() }
        } label: {
            // 窗口窄时只留图标（悬停仍有说明），工具条不换行。
            ViewThatFits(in: .horizontal) {
                Label(session.caTrusted ? "netcapture.cert.trusted" : "netcapture.cert.untrusted",
                      systemImage: session.caTrusted ? "checkmark.seal.fill" : "seal")
                    .fixedSize()
                Image(systemName: session.caTrusted ? "checkmark.seal.fill" : "seal")
            }
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

    /// 顶部固定「过滤域名」；中间来源与域名随内容滚动；底部固定「隐藏未解密」与「已隐藏 N 个域名」（TOOLS.md §1）。
    private var sidebar: some View {
        VStack(spacing: 0) {
            NetCaptureFilterField(placeholder: "netcapture.filter.hosts", text: Binding(
                get: { store.filter.hostTerms.text },
                set: { text in store.updateFilter { $0.hostTerms = TermFilter(text: text) } }))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let filter = store.filter
                    let counts = store.sidebarCounts
                    sidebarRow(title: L("netcapture.device.all"), count: counts.total,
                               selected: filter.device == nil && filter.host == nil, icon: "tray.full") {
                        store.updateFilter {
                            $0.device = nil
                            $0.host = nil
                        }
                        selection = nil
                    }
                    ForEach(store.devices) { device in
                        sidebarRow(title: device.label, count: counts.byDevice[device.ip] ?? 0,
                                   selected: filter.device == device.ip && filter.host == nil,
                                   icon: FlowStore.isLoopback(device.ip) ? "laptopcomputer" : "iphone") {
                            store.updateFilter {
                                $0.device = device.ip
                                $0.host = nil
                            }
                            selection = nil
                        }
                        .contextMenu { deviceMenu(ip: device.ip) }
                    }

                    Text("netcapture.sidebar.hosts")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 2)
                    ForEach(counts.hosts.prefix(80), id: \.host) { entry in
                        sidebarRow(title: entry.host, count: entry.count,
                                   selected: filter.host == entry.host, icon: nil) {
                            store.updateFilter { $0.host = ($0.host == entry.host) ? nil : entry.host }
                            selection = nil
                        }
                    }
                }
                .padding(6)
            }
            Divider()
            sidebarFooter
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 左栏底部：「隐藏未解密」开关；有隐藏的域名时多一行「已隐藏 N 个域名」，菜单里逐个显示或全部显示。
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("netcapture.filter.hideUndecrypted", isOn: Binding(
                get: { store.filter.hideUndecrypted },
                set: { on in store.updateFilter { $0.hideUndecrypted = on } }))
                .toggleStyle(.checkbox)
            let hidden = store.filter.hiddenHosts.sorted()
            if !hidden.isEmpty {
                Menu {
                    ForEach(hidden, id: \.self) { host in
                        Button(L("netcapture.filter.show \(host)")) { store.unhide(host: host) }
                    }
                    Divider()
                    Button("netcapture.filter.showAll") { store.unhideAll() }
                } label: {
                    Text("netcapture.filter.hiddenCount \(hidden.count)")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            if store.filter.device == ip { store.updateFilter { $0.device = nil } }
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

    /// 顶部固定「过滤 URL」（和左栏的「过滤域名」同一水平线、同样式），下面是列表。
    private func flowList(_ visible: [Flow]) -> some View {
        VStack(spacing: 0) {
            NetCaptureFilterField(placeholder: "netcapture.filter.urls", text: Binding(
                get: { store.filter.urlTerms.text },
                set: { text in store.updateFilter { $0.urlTerms = TermFilter(text: text) } }))
            Divider()
            // 只有列表空了才去数被藏掉的条数。
            let hidden = visible.isEmpty ? store.hiddenByFilters(query: query) : 0
            if store.flows.isEmpty {
                waitingNotice
            } else if hidden > 0 {
                filteredOutNotice(hidden)
            } else {
                List(Array(visible.reversed()), selection: $selection) { flow in
                    FlowRow(flow: flow).tag(flow.id)
                        .contextMenu { rowMenu(flow) }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
            }
        }
    }

    /// 已经在抓、一条请求都还没有：说一声在等，下面一行小字是在抓什么（和工具条「抓：…」同一句）。
    private var waitingNotice: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("netcapture.cards.waiting").foregroundStyle(.secondary)
            if session.macCaptureOn || session.phonePageOn {
                Text(verbatim: sourceSummary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 有抓到的请求，却被隐藏名单 / 「隐藏未解密」/ 两个过滤输入框滤空了：说清楚，并给一个清掉输入框的按钮。
    private func filteredOutNotice(_ hidden: Int) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("netcapture.filter.hiddenFlows \(hidden)").foregroundStyle(.secondary)
            if !store.filter.hostTerms.text.isEmpty || !store.filter.urlTerms.text.isEmpty {
                Button("netcapture.filter.clear") { store.clearFilterTexts() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowMenu(_ flow: Flow) -> some View {
        Button { store.updateFilter { $0.host = flow.host } } label: {
            Label("netcapture.filter.onlyHost", systemImage: "scope")
        }
        Button {
            // 正看着的那条要被藏起来了：详情别还停在一条列表里看不到的请求上。
            if let id = selection, store.flows.first(where: { $0.id == id })?.host == flow.host { selection = nil }
            store.hide(host: flow.host)
        } label: {
            Label("netcapture.filter.hideHost", systemImage: "eye.slash")
        }
        Divider()
        if flow.decrypted {
            Button { replay(flow) } label: {
                Label("netcapture.replay.action", systemImage: "arrow.clockwise")
            }
            Button { replayDraft = ReplayDraft(flow: flow) } label: {
                Label("netcapture.replay.editAction", systemImage: "square.and.pencil")
            }
            Button { mockEditing = MockEditing(flow: flow) } label: {
                Label("netcapture.mock.action", systemImage: "theatermasks")
            }
            Divider()
            Button { FlowActions.copy(FlowStore.shared.curl(for: flow)) } label: {
                Label("netcapture.flow.copyCurl", systemImage: "doc.on.doc")
            }
            Button { FlowActions.copy(FlowStore.shared.markdown(for: flow)) } label: {
                Label("netcapture.flow.copyMarkdown", systemImage: "doc.text")
            }
        }
        Button { FlowActions.copy(flow.decrypted ? flow.url : flow.host) } label: {
            Label("netcapture.flow.copyURL", systemImage: "link")
        }
    }

    // MARK: 右栏：详情

    @ViewBuilder
    private var detailPane: some View {
        if let id = selection, let flow = store.flows.first(where: { $0.id == id }) {
            FlowDetailView(flow: flow, commands: FlowCommands(
                replay: { replay($0) },
                editAndReplay: { replayDraft = ReplayDraft(flow: $0) },
                mock: { mockEditing = MockEditing(flow: $0) }))
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

    private func statusBar(visibleCount: Int) -> some View {
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
            Text("netcapture.status.counts \(visibleCount) \(store.flows.count)")
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

    /// 原样重发。
    private func replay(_ flow: Flow) {
        send(ReplayRequest(id: UUID(), method: flow.method, url: flow.url,
                           headers: flow.requestHeaders, body: flow.requestBody))
    }

    /// 发出去的请求是列表里新的一行：先选中它（id 是这边定的），并让它看得见 ——
    /// 重发的来源是本机，正看着别的设备时回到「全部」；改了 URL 换了域名时取消左栏选中的域名。
    private func send(_ request: ReplayRequest) {
        let host = URLComponents(string: request.url)?.host?.lowercased()
        store.updateFilter { filter in
            if let device = filter.device, !FlowStore.isLoopback(device) { filter.device = nil }
            if let selected = filter.host, selected != host { filter.host = nil }
        }
        selection = request.id
        session.replay(request)
    }

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
}

// MARK: - 过滤输入框

/// 左栏顶部「过滤域名」与请求列表顶部「过滤 URL」：同一个样式、同样高，两边并排在一条水平线上。
/// 每敲一个字列表就跟着变；有内容时右边一个 ×。语法见 Logic/FlowFilter.swift 的 `TermFilter`。
struct NetCaptureFilterField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    /// 两个输入框所在那一条的高度（两栏对齐靠它）。
    static let rowHeight: CGFloat = 34

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(text.isEmpty ? Color.secondary : NetCaptureColors.accent)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("netcapture.filter.clearField"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .padding(.horizontal, 6)
        .frame(height: Self.rowHeight)
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
                        Self.badge(Text(verbatim: badge), tint: .secondary)
                    }
                    // 「重发」翻译；mock、h2、WS 这类不翻译（TOOLS.md §7）。
                    if flow.isReplay {
                        Self.badge(Text("netcapture.flow.replayBadge"), tint: NetCaptureColors.accent)
                    }
                    if flow.mockRuleID != nil {
                        Self.badge(Text(verbatim: "mock"), tint: Color(hex: 0x8B5CF6))
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
    }

    private static func badge(_ text: Text, tint: Color) -> some View {
        text
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize()
    }

    /// 状态码那一格：有响应显示状态码；还在等显示「⋯」；失败显示「✕」；没解密的显示「—」。
    private var statusText: String {
        if let code = flow.statusCode { return String(code) }
        if !flow.decrypted { return "—" }
        if flow.note != nil { return "✕" }
        return "⋯"
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
