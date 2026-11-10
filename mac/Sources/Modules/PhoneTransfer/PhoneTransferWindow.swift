import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 窗口控制器

/// 手机互传窗口。打开即开始会话，关窗即结束（停 HTTP 服务 / 断开 P2P）。
@MainActor
final class PhoneTransferWindowController: NSObject, NSWindowDelegate {
    static let shared = PhoneTransferWindowController()
    private var window: NSWindow?

    private override init() {
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: PhoneTransferRootView())
            // 要拿焦点的普通窗口：在桌面空间建，不叠进别的 App 的全屏空间（见 mac/CLAUDE.md「普通窗口与全屏空间」）。
            let created = DesktopSpaceWindow.make { NSWindow(contentViewController: hosting) }
            created.title = L("phonetransfer.window.title")
            created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            created.setContentSize(NSSize(width: 760, height: 540))
            created.minSize = NSSize(width: 640, height: 460)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        let session = PhoneTransferSession.shared
        if !session.isRunning { session.start() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        PhoneTransferSession.shared.stop()
    }
}

// MARK: - 根视图

struct PhoneTransferRootView: View {
    @ObservedObject private var session = PhoneTransferSession.shared

    var body: some View {
        HStack(spacing: 0) {
            PhoneTransferQRPanel(session: session)
                .frame(width: 290)
                .padding(16)
            Divider()
            PhoneTransferMainPanel(session: session)
                .padding(16)
        }
        .overlay(alignment: .bottomLeading) {
            // 公网模式的宿主 WebView：1×1 挂进视图层级，避免被 WebKit 当作不可见而挂起。
            RTCWebViewHolder(host: session.rtcHost)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }
}

/// 把 `RTCTransferHost.webView` 放进视图层级。
struct RTCWebViewHolder: NSViewRepresentable {
    let host: RTCTransferHost?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let web = host?.webView else {
            view.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if web.superview !== view {
            view.subviews.forEach { $0.removeFromSuperview() }
            web.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            view.addSubview(web)
        }
    }
}

// MARK: - 左栏：模式 + 二维码 + 状态

struct PhoneTransferQRPanel: View {
    @ObservedObject var session: PhoneTransferSession

    private var modeBinding: Binding<PhoneTransferSession.Mode> {
        Binding(get: { session.mode }, set: { session.switchMode($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: modeBinding) {
                Text("phonetransfer.mode.lan").tag(PhoneTransferSession.Mode.lan)
                Text("phonetransfer.mode.internet").tag(PhoneTransferSession.Mode.internet)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(session.mode == .lan ? "phonetransfer.mode.lanHelp" : "phonetransfer.mode.internetHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if session.mode == .lan {
                interfacePicker
            }

            qrBox
                .frame(maxWidth: .infinity)

            statusView

            HStack {
                Button {
                    session.refresh()
                } label: {
                    Label(session.mode == .internet && session.phase != .waiting && session.phase != .starting
                          ? "phonetransfer.button.newSession" : "phonetransfer.button.refresh",
                          systemImage: "arrow.clockwise")
                }
                Button {
                    if let text = session.qrText {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                } label: {
                    Label("phonetransfer.button.copyLink", systemImage: "link")
                }
                .disabled(session.qrText == nil)
            }
            .controlSize(.small)

            Spacer(minLength: 0)

            if session.mode == .lan {
                Text("phonetransfer.lan.plainNote")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("phonetransfer.internet.note")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    // MARK: 网卡

    private var interfaceBinding: Binding<String> {
        Binding(get: { session.lanInterfaceChoice }, set: { session.setLANInterface($0) })
    }

    /// 选过的网卡现在不在了（拔了网线 / 断了 VPN）：菜单里留一项占位，不让选择变成空白。
    private var choiceMissing: Bool {
        let choice = session.lanInterfaceChoice
        return !choice.isEmpty && choice != "*" && !session.interfaces.contains { $0.name == choice }
    }

    private var autoLabel: String {
        let current = session.interfaces.first { $0.ip == session.primaryIP }?.label ?? session.primaryIP
        return L("phonetransfer.lan.interface.auto \(current)")
    }

    private var interfacePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: interfaceBinding) {
                Text(autoLabel).tag("")
                Divider()
                ForEach(session.interfaces) { iface in
                    Text(iface.label).tag(iface.name)
                }
                if choiceMissing {
                    Text(L("phonetransfer.lan.interface.missing \(session.lanInterfaceChoice)"))
                        .tag(session.lanInterfaceChoice)
                }
                Divider()
                Text("phonetransfer.lan.interface.all").tag("*")
            } label: {
                Text("phonetransfer.lan.interface")
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            if session.lanInterfaceChoice == "*" {
                Text("phonetransfer.lan.interface.allNote")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var qrBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .frame(width: 232, height: 232)
            if let text = session.qrText,
               let cg = QRCodeGenerator.image(for: text, minPixels: 440) {
                Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 220, height: 220)))
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .blur(radius: session.phase == .expired ? 6 : 0)
            } else if isFailed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
            }
            if session.phase == .expired {
                Button("phonetransfer.button.expired") { session.refresh() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch session.phase {
            case .idle, .starting:
                Text(session.mode == .lan ? "phonetransfer.status.startingLAN" : "phonetransfer.status.startingSignal")
                    .foregroundStyle(.secondary)
            case .waiting:
                Text("phonetransfer.status.scan")
                if session.mode == .internet {
                    Text(L("phonetransfer.status.signal \(session.signalReady)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .expired:
                Text("phonetransfer.status.expired").foregroundStyle(.secondary)
            case .connecting:
                Text("phonetransfer.status.connecting")
            case .connected:
                if session.mode == .lan {
                    Text(L("phonetransfer.status.connectedLAN \(session.devices.joined(separator: ", "))"))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(session.route == "lan" ? "phonetransfer.status.routeLAN"
                         : session.route == "p2p" ? "phonetransfer.status.routeP2P" : "phonetransfer.status.connected")
                        .foregroundStyle(Color.accentColor)
                    if let name = session.devices.first {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .closed:
                Text("phonetransfer.status.closed").foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                ForEach(session.failureDetail, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                if session.mode == .internet && !session.failureDetail.isEmpty {
                    Text("phonetransfer.tips")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 右栏：请求、发送、记录

struct PhoneTransferMainPanel: View {
    @ObservedObject var session: PhoneTransferSession
    @State private var draft = ""
    @State private var dropTargeted = false
    @State private var preview: PhoneTransferPreviewItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(session.requests) { request in
                requestBanner(request)
            }

            dropZone

            HStack(alignment: .bottom) {
                TextField("phonetransfer.text.placeholder", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button("phonetransfer.text.send") {
                    session.send(text: draft)
                    draft = ""
                }
                .disabled(!session.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Text("phonetransfer.history.title").font(.headline)
                Spacer()
                if !session.transfers.isEmpty || !session.texts.isEmpty {
                    Button("phonetransfer.history.clear") { session.clearHistory() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }

            historyList

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(L("phonetransfer.footer.saveTo \(PhoneTransferSettings.receiveDir.path)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("phonetransfer.footer.open") {
                    let dir = PhoneTransferSettings.receiveDir
                    if PhoneTransferSettings.ensureDirectory(dir) { NSWorkspace.shared.open(dir) }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .sheet(item: $preview) { item in
            PhoneTransferImagePreview(url: item.url, name: item.name)
        }
    }

    private func requestBanner(_ request: PhoneTransferSession.Request) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("phonetransfer.request.title \(request.name)")).font(.headline)
                if let code = request.code {
                    // 和手机上显示的设备码一致再允许（#98）。
                    Text(L("phonetransfer.request.code \(code)")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("phonetransfer.request.subtitle").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("phonetransfer.request.deny") { session.deny(request) }
            Button("phonetransfer.request.allow") { session.approve(request) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(session.canSend ? "phonetransfer.drop.title" : "phonetransfer.drop.waiting")
                .foregroundStyle(.secondary)
            Button("phonetransfer.drop.choose") { chooseFiles() }
                .disabled(!session.canSend)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard session.canSend else { return false }
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let direct = item as? URL {
                        url = direct
                    }
                    guard let url else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            PhoneTransferSession.shared.send(files: [url])
                        }
                    }
                }
            }
            return true
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            session.send(files: panel.urls)
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if session.transfers.isEmpty && session.texts.isEmpty {
            VStack {
                Spacer()
                Text("phonetransfer.history.empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !session.texts.isEmpty {
                    Section("phonetransfer.history.texts") {
                        ForEach(session.texts) { item in
                            textRow(item)
                        }
                    }
                }
                if !session.transfers.isEmpty {
                    Section("phonetransfer.history.files") {
                        ForEach(session.transfers) { item in
                            transferRow(item)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func textRow(_ item: PhoneTransferSession.TextItem) -> some View {
        HStack(alignment: .top) {
            Image(systemName: item.incoming ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(item.incoming ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text(PhoneTransferFormat.time(item.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("phonetransfer.text.copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func transferRow(_ item: PhoneTransferSession.Transfer) -> some View {
        HStack(spacing: 10) {
            leadingIcon(item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                if item.state == .active, item.size > 0 {
                    ProgressView(value: min(1, Double(item.done) / Double(item.size)))
                        .progressViewStyle(.linear)
                }
            }
            Spacer()
            if let url = imageURL(item) {
                PhoneTransferCopyImageButton(url: url)
            }
            if let url = item.url, item.incoming, item.state == .finished {
                Button("phonetransfer.history.reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    /// 能预览 / 复制的图片：收到的要传完，发出的随时可以（文件就在本机）。
    private func imageURL(_ item: PhoneTransferSession.Transfer) -> URL? {
        guard let url = item.url, item.isImage else { return nil }
        if item.incoming && item.state != .finished { return nil }
        return url
    }

    /// 行首：图片是缩略图（点开预览），其他是方向箭头。
    @ViewBuilder
    private func leadingIcon(_ item: PhoneTransferSession.Transfer) -> some View {
        if let url = imageURL(item), let thumbnail = item.thumbnail {
            Button {
                preview = PhoneTransferPreviewItem(url: url, name: item.name)
            } label: {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .help("phonetransfer.image.previewHelp")
        } else {
            Image(systemName: item.incoming ? "arrow.down.circle" : "arrow.up.circle")
                .font(.title2)
                .foregroundStyle(item.incoming ? Color.accentColor : Color.secondary)
                .frame(width: 40, height: 40)
        }
    }

    /// 「2.4 MB · 已接收 · 17:30:12 · 用时 1.2 秒」（REQUIREMENTS §3.4）。
    private func detail(_ item: PhoneTransferSession.Transfer) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)]
        switch item.state {
        case .queued:
            parts.append(L("phonetransfer.state.queued"))
        case .active:
            let percent = item.size > 0 ? Int(Double(item.done) / Double(item.size) * 100) : 0
            parts.append("\(percent)%")
        case .finished:
            parts.append(item.incoming ? L("phonetransfer.state.received") : L("phonetransfer.state.sent"))
            parts.append(contentsOf: timing(item))
        case .failed:
            parts.append(item.note ?? L("phonetransfer.state.failed"))
            parts.append(PhoneTransferFormat.time(item.finishedAt ?? item.createdAt))
        case .shared(let downloads):
            if downloads == 0 {
                parts.append(L("phonetransfer.state.sharedWaiting"))
                parts.append(PhoneTransferFormat.time(item.createdAt))
            } else {
                parts.append(L("phonetransfer.state.downloaded \(downloads)"))
                parts.append(contentsOf: timing(item))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// 传完的时刻 + 用时。
    private func timing(_ item: PhoneTransferSession.Transfer) -> [String] {
        var parts = [PhoneTransferFormat.time(item.finishedAt ?? item.startedAt ?? item.createdAt)]
        if let start = item.startedAt, let finish = item.finishedAt {
            parts.append(L("phonetransfer.time.took \(PhoneTransferFormat.duration(finish.timeIntervalSince(start)))"))
        }
        return parts
    }
}

// MARK: - 图片

struct PhoneTransferPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
}

/// 「复制」：原图写进剪贴板（PNG + TIFF），粘到聊天软件里是图片。复制完闪一下「已复制」。
struct PhoneTransferCopyImageButton: View {
    let url: URL
    var prominent = false
    @State private var copied = false
    @State private var busy = false

    var body: some View {
        if prominent {
            button.buttonStyle(.bordered)
        } else {
            button.buttonStyle(.borderless).controlSize(.small)
        }
    }

    private var button: some View {
        Button(copied ? "phonetransfer.image.copied" : "phonetransfer.image.copy") {
            busy = true
            PhoneTransferImage.copy(url) { ok in
                busy = false
                guard ok else {
                    NSSound.beep()
                    return
                }
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated { copied = false }
                }
            }
        }
        .disabled(busy)
    }
}

/// 窗口里的大图预览（不引 QuickLook）：复制、用「预览」打开、在 Finder 中显示、关闭（Esc）。
struct PhoneTransferImagePreview: View {
    let url: URL
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if failed {
                    Text("phonetransfer.image.loadFailed")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                PhoneTransferCopyImageButton(url: url, prominent: true)
                Button("phonetransfer.image.openPreview") { PhoneTransferImage.openInPreview(url) }
                Button("phonetransfer.history.reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("phonetransfer.image.close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 380, idealHeight: 460)
        .onAppear {
            PhoneTransferImage.load(url, maxPixel: 2400) { loaded in
                if let loaded { image = loaded } else { failed = true }
            }
        }
    }
}
