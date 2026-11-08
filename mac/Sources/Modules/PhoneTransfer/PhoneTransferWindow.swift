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
            let created = NSWindow(contentViewController: hosting)
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
    }

    private func requestBanner(_ request: PhoneTransferSession.Request) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("phonetransfer.request.title \(request.name)")).font(.headline)
                Text("phonetransfer.request.subtitle").font(.caption).foregroundStyle(.secondary)
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
            Text(item.text)
                .lineLimit(4)
                .textSelection(.enabled)
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
            Image(systemName: item.incoming ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(item.incoming ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(detail(item)).font(.caption).foregroundStyle(.secondary)
                if item.state == .active, item.size > 0 {
                    ProgressView(value: min(1, Double(item.done) / Double(item.size)))
                        .progressViewStyle(.linear)
                }
            }
            Spacer()
            if let url = item.url, item.incoming, item.state == .finished {
                Button("phonetransfer.history.reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    private func detail(_ item: PhoneTransferSession.Transfer) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        let state: String
        switch item.state {
        case .queued:
            state = L("phonetransfer.state.queued")
        case .active:
            let percent = item.size > 0 ? Int(Double(item.done) / Double(item.size) * 100) : 0
            state = "\(percent)%"
        case .finished:
            state = item.incoming ? L("phonetransfer.state.received") : L("phonetransfer.state.sent")
        case .failed:
            state = L("phonetransfer.state.failed")
        case .shared(let downloads):
            state = downloads == 0 ? L("phonetransfer.state.sharedWaiting")
                                   : L("phonetransfer.state.downloaded \(downloads)")
        }
        return "\(size) · \(state)"
    }
}
