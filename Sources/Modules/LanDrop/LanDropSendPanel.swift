import AppKit
import SwiftUI

/// 局域网传输 —— 「发送到手机」浮动面板。
///
/// 把文件从访达拖进这个面板，它才会出现在手机端的下载列表里；没拖进来的东西手机一概看不到。
/// 面板同时显示二维码，拖完就能扫。关闭面板不清空列表（可能正在下载），
/// **停止服务才清空**——见 `LanDropServer.teardown()`。
///
/// 面板结构照 `NetCaptureCertQR` 的先例，但内容视图是一个注册了拖放的 `NSView`，
/// SwiftUI 内容作为其子视图：AppKit 沿视图树找**注册过拖放类型**的最深视图，
/// `NSHostingView` 没注册，于是拖拽自然落到外层的 `FileDropView` 上。
@MainActor
enum LanDropSendPanel {
    private final class Holder { var panel: NSPanel? }
    private static let holder = Holder()

    static func show() {
        if let existing = holder.panel {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let dropState = LanDropDropState()
        let hosting = NSHostingView(rootView: LanDropSendPanelView(dropState: dropState))
        let container = FileDropView(state: dropState)
        container.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = L("landrop.send.title")
        panel.contentView = container
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        holder.panel = panel
    }
}

/// 拖放高亮状态（AppKit 视图 → SwiftUI 内容）。
@MainActor
final class LanDropDropState: ObservableObject {
    @Published var isTargeted = false
}

// MARK: - 接收拖入文件的容器视图

/// 注册 `.fileURL` 的容器视图：拖进来的文件交给 `LanDropShare`，并顺手把服务开起来
/// （拖进来却没开服务，手机什么也拿不到，那次拖拽就白费了）。
final class FileDropView: NSView {
    private let state: LanDropDropState

    init(state: LanDropDropState) {
        self.state = state
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(from: sender).isEmpty else { return [] }
        MainActor.assumeIsolated { state.isTargeted = true }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { state.isTargeted = false }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        MainActor.assumeIsolated { state.isTargeted = false }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = urls(from: sender)
        guard !dropped.isEmpty else { return false }
        MainActor.assumeIsolated {
            state.isTargeted = false
            LanDropShare.shared.add(urls: dropped)
            if !LanDropServer.shared.isRunning {
                LanDropServer.shared.start()
            }
        }
        return true
    }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }
}

// MARK: - 面板内容

struct LanDropSendPanelView: View {
    @ObservedObject var dropState: LanDropDropState
    @ObservedObject private var share = LanDropShare.shared
    @ObservedObject private var server = LanDropServer.shared
    @ObservedObject private var access = LanDropAccess.shared

    var body: some View {
        VStack(spacing: 14) {
            dropZone

            if !share.lastRejected.isEmpty {
                Text("landrop.send.rejected \(share.lastRejected.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            if share.items.isEmpty {
                Spacer()
                Text("landrop.send.empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                fileList
                qrSection
            }
        }
        .padding(20)
        .frame(width: 360)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(dropState.isTargeted ? Color.accentColor : Color.secondary)
            Text("landrop.send.dropHere")
                .font(.callout.weight(.medium))
            Text("landrop.send.dropHint")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("landrop.send.choose") { chooseFiles() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(dropState.isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("landrop.send.sharing \(share.items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("landrop.send.clear") { LanDropShare.shared.clear() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(share.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: item.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(verbatim: LanDropEnv.formatBytes(item.size))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                LanDropShare.shared.remove(id: item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    @ViewBuilder
    private var qrSection: some View {
        if let link = server.shareURL, let cg = QRCodeGenerator.image(for: link, minPixels: 150) {
            VStack(spacing: 6) {
                Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 132, height: 132)))
                    .interpolation(.none)
                Text("landrop.send.scanToDownload")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("landrop.send.rotate") { LanDropServer.shared.rotatePairCode() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else if server.isRunning {
            // 配对码是一次性的，用掉或过期后这里会变成一个按钮而不是一个失效的码。
            VStack(spacing: 6) {
                Text("landrop.send.pairExpired")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("landrop.send.rotate") { LanDropServer.shared.rotatePairCode() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else {
            Text("landrop.send.starting")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false   // 分享目录 = 开放浏览，与安全模型冲突
        panel.allowsMultipleSelection = true
        panel.prompt = L("landrop.send.choosePrompt")
        guard panel.runModal() == .OK else { return }
        LanDropShare.shared.add(urls: panel.urls)
        if !LanDropServer.shared.isRunning {
            LanDropServer.shared.start()
        }
    }
}
