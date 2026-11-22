import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 网络抓包窗口（docs/packet-capture/CONTROL.md §1）：抓包的所有操作都在这里做。
///
/// 最上面一行三个标签页「配置 / HTTP / WebSocket 包 / TCP 包」，右边是引擎状态和两个全局按钮（暂停 / 继续、停止全部）。
/// 「配置」页在 NetCaptureConfigView.swift，「TCP 包」页在 NetCaptureTCPView.swift；「HTTP / WebSocket 包」页在这里：
/// 三栏，左 = 来源与域名，中 = 请求列表，右 = 详情（NetCaptureDetailView.swift）。
/// 所有状态读单例的 `@Published`；动作转给 `NetCaptureSession`（开关）、`FlowStore`（数据与筛选）、`MockRuleStore`（Mock）。

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

/// 窗口当前在哪个标签页。放在窗口外面：打开窗口时控制器要按引擎状态选一个（CONTROL.md §1）。
enum NetCaptureTab: String {
    case config, http, tcp
}

@MainActor
final class NetCaptureWindowState: ObservableObject {
    static let shared = NetCaptureWindowState()
    @Published var tab: NetCaptureTab = .config
    /// 「配置」页左边选中的那一项。放在这里：切到别的标签页再回来还是它。
    @Published var configItem: NetCaptureConfigItem = .mac
    /// WireGuard 设备的小窗（添加 / 看二维码 / 改名）。挂在根视图上：设备栏右键改名时也用它。
    @Published var wireguardDialog: WireGuardDialog?
    /// 等用户确认删除的那台 WireGuard 设备。
    @Published var wireguardDeleteID: String?
    /// 配置页设备列表里高亮的那一台（设备栏右键「在配置页里管理…」跳过去时选中它）。
    @Published var focusedWireGuardDevice: String?
    private init() {}
}

@MainActor
final class NetCaptureWindowController {
    static let shared = NetCaptureWindowController()
    private var window: NSWindow?
    private init() {}

    /// 打开窗口并切到「配置」页（菜单栏「网络抓包设置…」、HTTP 页「抓包设置…」、设置窗口里的按钮）。
    func showConfig(item: NetCaptureConfigItem? = nil) {
        show()
        NetCaptureWindowState.shared.tab = .config
        if let item { NetCaptureWindowState.shared.configItem = item }
    }

    func show() {
        // 打开窗口时（新建，或关掉后再打开）：引擎在跑就停在「HTTP / WebSocket 包」，否则停在「配置」。已经开着就不动。
        if window?.isVisible != true {
            let capturing = NetCaptureEngine.shared.isActive && NetCaptureSession.shared.capturing
            NetCaptureWindowState.shared.tab = capturing ? .http : .config
        }
        if window == nil {
            let hosting = NSHostingController(rootView: NetCaptureRootView())
            // 和别的模块的主窗口一样经 DesktopSpaceWindow 建：否则从全屏 App 里打开时，它会被塞进那个全屏空间，
            // 系统的验证框一弹（装证书时）就跟着空间切换不见了。
            let created = DesktopSpaceWindow.make { NSWindow(contentViewController: hosting) }
            created.title = L("netcapture.window.title")
            created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            created.setContentSize(NSSize(width: 1180, height: 700))
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 根视图

/// 选中标签的轮廓：上面两个圆角，底边不封口（描边时底下那条线不画，标签和页面连在一起）。
struct NetCaptureTabOutline: Shape {
    var radius: CGFloat = 7
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

struct NetCaptureRootView: View {
    @ObservedObject private var engine = NetCaptureEngine.shared
    @ObservedObject private var session = NetCaptureSession.shared
    @ObservedObject private var store = FlowStore.shared
    @ObservedObject private var tcp = TCPStore.shared
    @ObservedObject private var mcp = CaptureMCPServer.shared
    @ObservedObject private var mockRules = MockRuleStore.shared
    @ObservedObject private var windowState = NetCaptureWindowState.shared

    @State private var query = ""
    /// 列表里高亮的那一行。
    @State private var selection: Flow.ID?
    /// 详情区显示的那一条。和 `selection` 分开：点列表空白处，系统表格会把选中清掉，详情不该跟着消失。
    @State private var shownID: Flow.ID?
    @State private var renameIP: String?
    @State private var renameText = ""
    @State private var replayDraft: ReplayDraft?
    @State private var mockEditing: MockEditing?
    @State private var showMockRules = false
    @Environment(\.colorScheme) private var colorScheme

    /// 请求列表此刻显示的行（筛选条件在 `store.filter`，全文搜索在 `query`）。
    private var filtered: [Flow] { store.filtered(query: query) }

    var body: some View {
        VStack(spacing: 0) {
            if let reason = NetCaptureEnv.engineUnavailable {
                unavailable(reason)
            } else {
                tabBar
                notices
                switch windowState.tab {
                case .config: NetCaptureConfigView()
                case .http: httpPage
                case .tcp: NetCaptureTCPView()
                }
            }
        }
        // 三栏都到最小宽度时要 862（ColumnLayout.minimumTotal），标签条和工具条在 900 下也不换行。
        .frame(minWidth: 900, minHeight: 560)
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
        // WireGuard 设备的小窗与删除确认（配置页、设备栏右键都从这里弹）。
        .sheet(item: $windowState.wireguardDialog) { dialog in
            WireGuardDeviceSheet(dialog: dialog) { windowState.wireguardDialog = nil }
        }
        .wireguardDeleteConfirmation()
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

    // MARK: 标签条

    /// 三个标签页 + 右边的引擎状态、暂停 / 继续、停止全部。放不下时先收掉状态里的地址文字，标签名不截断。
    /// 文件夹标签的样子：标签栏底色压暗，选中的标签和下面的页面同色、底边不封口，盖住它那一段分隔线，
    /// 看得出下面这一页属于哪个标签（原来是一个浮着的小胶囊，像筛选控件，和页面没有关联）。
    private var tabBar: some View {
        ZStack(alignment: .bottom) {
            Divider()
            ViewThatFits(in: .horizontal) {
                tabBarRow(showAddress: true)
                tabBarRow(showAddress: false)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.07))
    }

    private func tabBarRow(showAddress: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(spacing: 2) {
                tabButton(.config, title: "netcapture.tab.config", symbol: "slider.horizontal.3", count: nil)
                tabButton(.http, title: "netcapture.tab.http", symbol: "arrow.left.arrow.right", count: store.flows.count)
                tabButton(.tcp, title: "netcapture.tab.tcp", symbol: "point.3.connected.trianglepath.dotted", count: tcp.connections.count)
            }
            .fixedSize()

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                engineStatus(showAddress: showAddress)

                Button {
                    session.setPaused(!session.paused)
                } label: {
                    Label(session.paused ? "netcapture.window.resume" : "netcapture.window.pause",
                          systemImage: session.paused ? "play.fill" : "pause.fill")
                }
                .disabled(!(engine.isRunning && session.capturing))
                .help(Text("netcapture.window.pauseHelp"))
                .fixedSize()

                if engine.isActive, session.capturing {
                    Button {
                        session.stopAll()
                    } label: {
                        Label("netcapture.window.stopAll", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help(Text("netcapture.window.stopAllHelp"))
                    .fixedSize()
                }
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
    }

    private func tabButton(_ tab: NetCaptureTab, title: LocalizedStringKey, symbol: String, count: Int?) -> some View {
        let selected = windowState.tab == tab
        return Button {
            windowState.tab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? NetCaptureColors.accent : Color.secondary)
                Text(title).lineLimit(1)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? NetCaptureColors.accent : Color.secondary)
                }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, 8)
            .background {
                if selected {
                    NetCaptureTabOutline().fill(Color(nsColor: .windowBackgroundColor))
                    NetCaptureTabOutline().stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        // 标签比标签栏矮一截，顶上露出压暗的底色。
        .padding(.top, 7)
    }

    /// 「● 运行中 192.168.0.9:9090」。点地址复制。
    private func engineStatus(showAddress: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText).font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            if showAddress, engine.isRunning, session.capturing {
                Button {
                    FlowActions.copy(proxyAddress)
                } label: {
                    Text(verbatim: proxyAddress).font(.callout.monospacedDigit()).lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("netcapture.window.copyAddr"))
                .fixedSize()
            }
        }
    }

    /// 右上角说的是「在不在抓包」。只开着「给其他设备装证书」时引擎也在跑，但没有来源，算已停止。
    private var shownState: NetCaptureEngine.State {
        if case .failed = engine.state { return engine.state }
        return session.capturing ? engine.state : .stopped
    }

    private var statusText: LocalizedStringKey {
        switch shownState {
        case .running: return session.paused ? "netcapture.status.paused" : "netcapture.status.running"
        case .starting: return "netcapture.status.starting"
        case .failed: return "netcapture.status.failed"
        case .stopped: return "netcapture.status.stopped"
        }
    }

    private var statusColor: Color {
        switch shownState {
        case .running: return session.paused ? Color(hex: 0xF59E0B) : Color(hex: 0x28C840)
        case .starting: return Color(hex: 0xF59E0B).opacity(0.6)
        case .failed: return Color(hex: 0xFF3B30)
        case .stopped: return Color.secondary.opacity(0.5)
        }
    }

    /// 代理地址：听局域网时是 Mac 的局域网 IP，否则 127.0.0.1。
    private var proxyAddress: String {
        let port = engine.port ?? NetCaptureEnv.port
        return "\(engine.listeners?.lan == true ? NetworkInterfaces.primaryIP() : "127.0.0.1"):\(port)"
    }

    // MARK: 提示条（进度 / 暂停 / 待允许的设备 / 成功或失败）

    @ViewBuilder
    private var notices: some View {
        if let working = session.working {
            noticeRow(icon: nil, tint: .secondary) {
                ProgressView().controlSize(.small)
                Text(verbatim: working)
            }
        }
        if session.paused, engine.isRunning {
            noticeRow(icon: "pause.circle.fill", tint: Color(hex: 0xF59E0B)) {
                Text("netcapture.notice.paused")
                Spacer()
                Button("netcapture.window.resume") { session.setPaused(false) }
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

    // MARK: 「HTTP / WebSocket 包」页

    private var httpPage: some View {
        // 一次重绘只筛一遍：列表和状态条用同一份。
        let visible = filtered
        return VStack(spacing: 0) {
            httpToolbar
            Divider()
            // 详情最宽：左栏和请求列表给定宽度，窗口拉宽时多出来的都给详情（分隔线照样能拖）。
            NetCaptureColumns {
                sidebar
            } list: {
                flowList(visible)
            } detail: {
                detailPane
            }
            Divider()
            statusBar(visibleCount: visible.count)
        }
    }

    /// `[🗑] [全文搜索…] GET POST PUT DELETE  2xx 3xx 4xx 5xx  WS        [Mock] [⋯]`。
    private var httpToolbar: some View {
        HStack(spacing: 8) {
            Button {
                store.clear()
                clearSelection()
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
                    .frame(minWidth: 70, idealWidth: 140, maxWidth: 240)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))

            methodChips
            statusChips
            // 「WS」：只看 WebSocket（它们和 HTTP 请求在同一张列表里）。
            chip(title: "WS", active: store.filter.webSocketOnly, color: NetCaptureColors.accent) {
                store.updateFilter { $0.webSocketOnly.toggle() }
            }
            .help(Text("netcapture.filter.webSocketOnly"))

            Spacer(minLength: 0)

            mockButton
            moreMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    private var moreMenu: some View {
        // 本地 MCP 的开关在配置页「工具 → 本地 MCP」（一个设置只放一个地方，CONFIG-LAYOUT.md §1）。
        Menu {
            Button("netcapture.settings.exportHar") { exportHAR() }
                .disabled(store.flows.isEmpty)
            Button("netcapture.window.captureSettings") { windowState.tab = .config }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                        clearSelection()
                    }
                    ForEach(store.devices) { device in
                        sidebarRow(title: device.label, count: counts.byDevice[device.key] ?? 0,
                                   selected: filter.device == device.key && filter.host == nil,
                                   icon: NetCaptureDevice.symbol(device.key)) {
                            store.updateFilter {
                                $0.device = device.key
                                $0.host = nil
                            }
                            clearSelection()
                        }
                        .contextMenu { deviceMenu(key: device.key) }
                    }

                    Text("netcapture.sidebar.hosts")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 2)
                    ForEach(counts.hosts.prefix(80), id: \.host) { entry in
                        sidebarRow(title: entry.host, count: entry.count,
                                   selected: filter.host == entry.host, icon: nil) {
                            store.updateFilter { $0.host = ($0.host == entry.host) ? nil : entry.host }
                            clearSelection()
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

    /// 设备栏右键。隧道设备：重命名（改设备表里的名字，配置页一起变）、清空、在配置页里管理；没有「屏蔽」（隧道设备不走「允许」）。
    /// 局域网设备和本机：重命名（别名）、清空、屏蔽（本机不能屏蔽）。
    @ViewBuilder
    private func deviceMenu(key: String) -> some View {
        if let id = WireGuardDeviceTable.deviceID(fromKey: key) {
            if WireGuardDeviceStore.shared.device(id: id) != nil {
                Button {
                    windowState.wireguardDialog = .rename(deviceID: id)
                } label: { Label("netcapture.device.rename", systemImage: "pencil") }
            }
            clearDeviceButton(key: key)
            Divider()
            Button {
                windowState.focusedWireGuardDevice = id
                windowState.configItem = .wireguard
                windowState.tab = .config
            } label: { Label("netcapture.device.manage", systemImage: "lock.shield") }
        } else {
            Button {
                renameText = store.alias(ip: key) ?? ""
                renameIP = key
            } label: { Label("netcapture.device.rename", systemImage: "pencil") }
            clearDeviceButton(key: key)
            if !FlowStore.isLoopback(key), key != NetCaptureEnv.unknownDeviceKey {
                Button(role: .destructive) {
                    engine.deny(device: key)
                } label: { Label("netcapture.device.block", systemImage: "hand.raised") }
            }
        }
    }

    /// 「清空这台设备的包」：HTTP 和 TCP 两页里这台的都清掉。
    private func clearDeviceButton(key: String) -> some View {
        Button(role: .destructive) {
            store.clearDevice(key: key)
            tcp.clearDevice(key: key)
            if store.filter.device == key { store.updateFilter { $0.device = nil } }
            clearSelection()
        } label: { Label("netcapture.device.clear", systemImage: "trash") }
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
                emptyNotice
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
        .onChange(of: selection) { _, new in
            keepShownFlow(selected: new, listed: { id in visible.contains { $0.id == id } })
        }
    }

    /// 有意关掉详情（清空列表、换设备 / 域名、藏掉正在看的域名）。
    private func clearSelection() {
        shownID = nil
        selection = nil
    }

    /// 选了一行就显示它；选中被系统清掉（点了列表空白处）而详情还开着，下一拍把那一行选回去。
    /// 那一行已经不在列表里（被过滤掉了）就不选回去，详情照旧留着。
    private func keepShownFlow(selected: Flow.ID?, listed: (Flow.ID) -> Bool) {
        if let selected {
            shownID = selected
            return
        }
        guard let keep = shownID, listed(keep) else { return }
        DispatchQueue.main.async {
            if selection == nil, shownID == keep { selection = keep }
        }
    }

    /// 一条请求都还没有：引擎在跑说在等；没在跑请他去「配置」里打开要抓的来源。
    @ViewBuilder
    private var emptyNotice: some View {
        if engine.isActive, session.capturing {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("netcapture.http.waiting").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            NetCaptureGoToConfig()
        }
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
            if let id = shownID, store.flows.first(where: { $0.id == id })?.host == flow.host { clearSelection() }
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
        if let id = shownID, let flow = store.flows.first(where: { $0.id == id }) {
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

    /// 条数、MCP、内存。引擎状态和代理地址在最上面的标签条右边。
    private func statusBar(visibleCount: Int) -> some View {
        HStack(spacing: 12) {
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
