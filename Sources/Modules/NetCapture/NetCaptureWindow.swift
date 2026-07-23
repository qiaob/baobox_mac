import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 网络抓包中心窗口（Proxyman 式两栏）+ 窗口控制器。
///
/// 控制器仿 `ClaudeCodeCenterController`（NSWindow + NSHostingController，
/// `isReleasedWhenClosed = false`）。尺寸 980×620，可缩放。所有状态读单例 `@Published`，
/// UI 只做展示与交互；开始/停止/清空等动作转发到 `ProxyServer` / `FlowStore`。

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
        guard let code else { return Color(hex: 0xB0524B) } // 无响应/错误：灰红
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
            let created = NSWindow(contentViewController: hosting)
            created.title = L("netcapture.window.title")
            created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            created.setContentSize(NSSize(width: 980, height: 620))
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
    @ObservedObject private var server = ProxyServer.shared
    @ObservedObject private var store = FlowStore.shared
    @ObservedObject private var mcp = CaptureMCPServer.shared

    @State private var query = ""
    @State private var methodFilter: Set<String> = []
    @State private var statusFilter: Set<Int> = []
    @State private var selection: Flow.ID?
    @State private var showQR = false

    private var filtered: [Flow] {
        store.filtered(query: query, methods: methodFilter, statusClasses: statusFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.flows.isEmpty {
                emptyState
            } else {
                HSplitView {
                    flowList
                        .frame(minWidth: 360, idealWidth: 420, maxWidth: 620)
                    detailPane
                        .frame(minWidth: 380)
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 860, minHeight: 520)
        .sheet(isPresented: $showQR) { qrSheet }
    }

    // MARK: 工具条

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                toggleCapture()
            } label: {
                Label(server.isRunning ? "netcapture.window.stop" : "netcapture.window.start",
                      systemImage: server.isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(server.isRunning ? .red : NetCaptureColors.accent)

            Button {
                store.clear()
                selection = nil
            } label: {
                Label("netcapture.window.clear", systemImage: "trash")
            }
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

            proxyAddressControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    private var proxyAddressControls: some View {
        HStack(spacing: 8) {
            let addr = "\(NetworkInterfaces.primaryIP()):\(NetCaptureEnv.port)"
            Text(verbatim: addr)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(addr, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(Text("netcapture.window.copyAddr"))
            Button { showQR = true } label: { Image(systemName: "qrcode") }
                .buttonStyle(.borderless)
                .help(Text("netcapture.window.showQR"))
            // MCP 徽标。
            Image(systemName: mcp.isRunning ? "circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(mcp.isRunning ? NetCaptureColors.accent : .secondary)
                .help(Text(mcp.isRunning ? "netcapture.mcp.running" : "netcapture.mcp.stopped"))
        }
    }

    // MARK: Flow 列表

    private var flowList: some View {
        List(Array(filtered.reversed()), selection: $selection) { flow in
            FlowRow(flow: flow).tag(flow.id)
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
    }

    // MARK: 详情

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

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "network")
                .font(.system(size: 56))
                .foregroundStyle(NetCaptureColors.accent)
            Text(server.isRunning ? "netcapture.empty.waiting" : "netcapture.empty.title")
                .font(.title3.weight(.medium))
            if !server.isRunning {
                Button {
                    toggleCapture()
                } label: {
                    Label("netcapture.window.start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(NetCaptureColors.accent)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("netcapture.empty.step1", systemImage: "1.circle")
                Label("netcapture.empty.step2 \(NetworkInterfaces.primaryIP()) \(Int(NetCaptureEnv.port))", systemImage: "2.circle")
                Label("netcapture.empty.step3", systemImage: "3.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Button { showQR = true } label: {
                Label("netcapture.window.showQR", systemImage: "qrcode")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 状态条

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("netcapture.status.counts \(filtered.count) \(store.flows.count)")
            Divider().frame(height: 12)
            Text(serverStatusText)
            Divider().frame(height: 12)
            Text(mcp.isRunning ? "netcapture.mcp.running" : "netcapture.mcp.stopped")
            Spacer()
            Text("netcapture.status.memory \(memoryMB)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var serverStatusText: LocalizedStringKey {
        switch server.state {
        case .running: return "netcapture.status.running"
        case .starting: return "netcapture.status.starting"
        case .failed: return "netcapture.status.failed"
        case .stopped: return "netcapture.status.stopped"
        }
    }

    private var memoryMB: String {
        String(format: "%.1f", Double(store.estimatedBytes) / (1024 * 1024))
    }

    // MARK: QR sheet

    private var qrSheet: some View {
        VStack(spacing: 16) {
            Text("netcapture.qr.title").font(.headline)
            NetCaptureQRPanel()
            Button("common.ok") { showQR = false }
        }
        .padding(28)
    }

    // MARK: 动作

    private func toggleCapture() {
        if server.isRunning { server.stop() }
        else { server.start(port: NetCaptureEnv.port) }
    }

    private func toggle(_ set: inout Set<String>, _ value: String) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private func toggle(_ set: inout Set<Int>, _ value: Int) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}

// MARK: - Flow 行

private struct FlowRow: View {
    let flow: Flow

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: flow.method)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(NetCaptureColors.method(flow.method), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .frame(width: 52)

            Text(verbatim: flow.statusCode.map(String.init) ?? "—")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(NetCaptureColors.status(flow.statusCode))
                .frame(width: 30, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: flow.host).font(.callout).lineLimit(1)
                Text(verbatim: flow.path).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: flow.durationMs.map { "\($0)ms" } ?? "—")
                    .font(.caption2.monospacedDigit())
                Text(verbatim: byteString(flow.responseBytes))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !flow.decrypted {
                Image(systemName: "lock.slash").font(.caption2).foregroundStyle(.secondary)
                    .help(Text("netcapture.flow.notDecrypted"))
            }
        }
        .padding(.vertical, 2)
        .contextMenu { rowMenu }
    }

    @ViewBuilder
    private var rowMenu: some View {
        Button { copy(FlowStore.shared.curl(for: flow)) } label: { Label("netcapture.flow.copyCurl", systemImage: "terminal") }
        Button { copy(FlowStore.shared.markdown(for: flow)) } label: { Label("netcapture.flow.copyMarkdown", systemImage: "doc.text") }
        Button { sendToClaude() } label: { Label("netcapture.flow.sendToClaude", systemImage: "paperplane") }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 发送到 Claude Code：把该 flow 的 Markdown 写临时文件，在终端起 `claude -p "$(cat file)"`。
    private func sendToClaude() {
        let markdown = FlowStore.shared.markdown(for: flow)
        let dir = NetCaptureEnv.ensureSupportDir().appendingPathComponent("send", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).md")
        guard (try? markdown.data(using: .utf8)?.write(to: file)) != nil else { return }
        let bin = ClaudeEnv.findClaudeBinary() ?? "claude"
        let command = "\(NetCaptureEnv.shellSingleQuote(bin)) -p \"$(cat \(NetCaptureEnv.shellSingleQuote(file.path)))\""
        TerminalLauncher.run(command: command, in: nil)
    }

    private func byteString(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return String(format: "%.1fMB", Double(bytes) / (1024 * 1024)) }
        if bytes >= 1024 { return String(format: "%.1fKB", Double(bytes) / 1024) }
        return "\(bytes)B"
    }
}

// MARK: - 详情视图

private struct FlowDetailView: View {
    let flow: Flow
    @State private var tab = DetailTab.overview

    enum DetailTab: String, CaseIterable, Identifiable {
        case overview, request, response, raw
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .overview: return "netcapture.detail.overview"
            case .request: return "netcapture.detail.request"
            case .response: return "netcapture.detail.response"
            case .raw: return "netcapture.detail.raw"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { t in Text(t.label).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .overview: overview
                    case .request: message(headers: flow.requestHeaders, body: flow.requestBody, truncated: flow.requestTruncated, isResponse: false)
                    case .response: message(headers: flow.responseHeaders, body: flow.responseBody, truncated: flow.responseTruncated, isResponse: true)
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
            field("netcapture.detail.method", flow.method)
            field("netcapture.detail.url", flow.url)
            field("netcapture.detail.status", flow.statusCode.map(String.init) ?? "—")
            field("netcapture.detail.remoteIP", flow.remoteIP ?? "—")
            field("netcapture.detail.duration", flow.durationMs.map { "\($0)ms" } ?? "—")
            field("netcapture.detail.reqSize", "\(flow.requestBytes) B")
            field("netcapture.detail.respSize", "\(flow.responseBytes) B")
            field("netcapture.detail.contentType", flow.responseContentType ?? "—")
            if let note = flow.note {
                field("netcapture.detail.note", note)
            }
            if !flow.decrypted {
                Text("netcapture.flow.notDecryptedHint").font(.caption).foregroundStyle(.secondary)
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
    private func message(headers: [HTTPHeader], body: Data?, truncated: Bool, isResponse: Bool) -> some View {
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
                if truncated {
                    Text("netcapture.detail.truncated").font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text("netcapture.detail.noBody").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 依据 Content-Type 渲染 body：图片直接预览；JSON 美化；其余文本原样。
    @ViewBuilder
    private func bodyView(body: Data, headers: [HTTPHeader]) -> some View {
        let contentType = headers.value(for: "Content-Type")?.lowercased() ?? ""
        let decoded = HTTPBodyCodec.decodedForDisplay(body: body, headers: headers)
        if contentType.hasPrefix("image/"), let image = NSImage(data: decoded.data) {
            Image(nsImage: image)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 320, maxHeight: 320)
        } else if let text = String(data: decoded.data, encoding: .utf8) {
            let display = prettyIfJSON(text, contentType: contentType)
            Text(verbatim: display)
                .font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            if let note = decoded.note {
                Text(verbatim: note).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text("netcapture.detail.binary \(decoded.data.count)").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// JSON 内容尝试美化（缩进）；非 JSON 原样返回。
    private func prettyIfJSON(_ text: String, contentType: String) -> String {
        guard contentType.contains("json") || text.hasPrefix("{") || text.hasPrefix("[") else { return text }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8) else { return text }
        return string
    }

    private var rawView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("netcapture.detail.rawRequest").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: rawText(startLine: "\(flow.method) \(flow.path) HTTP/1.1",
                                   headers: flow.requestHeaders, body: flow.requestBody))
                .font(.caption.monospaced()).textSelection(.enabled)
            Divider()
            Text("netcapture.detail.rawResponse").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: rawText(startLine: "HTTP/1.1 \(flow.statusCode.map(String.init) ?? "")",
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

// MARK: - 单一配置网页二维码面板（§16.2）

/// 一个二维码，编码 `http://baobox.proxy/`——手机扫码打开自适应配置页（装证书 / 配代理 / 关代理）。
/// 下方展示代理 `IP:端口`（可复制）与「ADB 一键（Android）」入口（打开抓包窗口，ADB 操作在设置里）。
///
/// 复用于窗口 QR sheet、设置页 QR sheet、菜单证书二维码浮层。
struct NetCaptureQRPanel: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("netcapture.qr.page.title").font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center).frame(maxWidth: 300)
            Text(verbatim: NetworkInterfaces.landingPageURL)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            qrImage(NetworkInterfaces.landingPageURL)
            HStack(spacing: 6) {
                Text(verbatim: proxyAddr).font(.caption.monospaced())
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(proxyAddr, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(Text("netcapture.window.copyAddr"))
            }
            Text("netcapture.qr.page.hint").font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
            Button("netcapture.menu.cert.adbPush") {
                NetCaptureWindowController.shared.show()
            }
            .buttonStyle(.link)
        }
    }

    private var proxyAddr: String { "\(NetworkInterfaces.primaryIP()):\(NetCaptureEnv.port)" }

    @ViewBuilder
    private func qrImage(_ text: String) -> some View {
        if let cg = QRCodeGenerator.image(for: text, minPixels: 300) {
            Image(decorative: cg, scale: 1).resizable().interpolation(.none)
                .frame(width: 240, height: 240)
                .background(Color.white).padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        }
    }
}
