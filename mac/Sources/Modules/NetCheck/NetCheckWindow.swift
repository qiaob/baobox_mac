import AppKit
import SwiftUI

// MARK: - 窗口控制器

/// 网络泄露检测窗口：结果 + 总结，也承载 WebRTC 探测用的隐藏 WebView。见 docs/netcheck/DESIGN.md §4.3。
@MainActor
final class NetCheckWindowController: NSObject, NSWindowDelegate {
    static let shared = NetCheckWindowController()
    private var window: NSWindow?

    private override init() {
        super.init()
    }

    /// 显示窗口；`run` 为 true 时顺手开始一次检测。
    func show(run: Bool = false) {
        if window == nil {
            let hosting = NSHostingController(rootView: NetCheckRootView())
            // 要拿焦点的普通窗口：在桌面空间建（见 mac/CLAUDE.md「普通窗口与全屏空间」）。
            let created = DesktopSpaceWindow.make { NSWindow(contentViewController: hosting) }
            created.title = L("netcheck.window.title")
            created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            created.setContentSize(NSSize(width: 620, height: 600))
            created.minSize = NSSize(width: 520, height: 460)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if run { NetCheckSession.shared.run() }
    }

    func windowWillClose(_ notification: Notification) {
        NetCheckSession.shared.windowClosed()
    }
}

// MARK: - 根视图

struct NetCheckRootView: View {
    @ObservedObject private var session = NetCheckSession.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let outcome = session.outcome {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summaryCards(outcome)
                        itemList(outcome)
                        footnotes(outcome)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
                Text(session.running ? "netcheck.window.running" : "netcheck.window.intro")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(18)
        .overlay(alignment: .bottomLeading) {
            // WebRTC 探测的 WebView：1×1 挂进视图层级，避免被 WebKit 当作不可见而挂起。
            NetCheckWebViewHolder(probe: session.webrtc)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let outcome = session.outcome, !session.running {
                Image(systemName: NetCheckText.symbol(outcome.overall))
                    .font(.title)
                    .foregroundStyle(Self.color(outcome.overall))
                VStack(alignment: .leading, spacing: 2) {
                    Text(NetCheckText.headline(outcome.overall)).font(.title3.bold())
                    Text(L("netcheck.window.checkedAt \(outcome.at.formatted(date: .omitted, time: .standard))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if session.running {
                ProgressView().controlSize(.small)
                Text("netcheck.window.running").font(.title3)
            } else {
                Text("netcheck.window.title").font(.title3.bold())
            }
            Spacer()
            if let outcome = session.outcome {
                Button(copied ? "netcheck.window.copied" : "netcheck.window.copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(NetCheckText.report(outcome), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        MainActor.assumeIsolated { copied = false }
                    }
                }
                .disabled(session.running)
            }
            Button("netcheck.window.run") { session.run() }
                .buttonStyle(.borderedProminent)
                .disabled(session.running)
        }
    }

    private func summaryCards(_ outcome: NetCheckSession.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(outcome.summary.enumerated()), id: \.offset) { _, summary in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: NetCheckText.symbol(summary.verdict))
                        .font(.title2)
                        .foregroundStyle(Self.color(summary.verdict))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(NetCheckText.title(summary.goal)).font(.headline)
                        Text(NetCheckText.detail(summary.reason))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Self.color(summary.verdict).opacity(0.10)))
            }
        }
    }

    private func itemList(_ outcome: NetCheckSession.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("netcheck.window.items").font(.headline)
            ForEach(Array(outcome.findings.enumerated()), id: \.offset) { _, finding in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: NetCheckText.symbol(finding.verdict))
                        .foregroundStyle(Self.color(finding.verdict))
                    Text(NetCheckText.title(finding.item))
                        .fontWeight(.medium)
                        .frame(width: 70, alignment: .leading)
                    Text(NetCheckText.detail(finding.reason))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func footnotes(_ outcome: NetCheckSession.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let words = outcome.dnsConclusion {
                Text(L("netcheck.report.bashws \(words)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !outcome.realDeclared {
                Text("netcheck.note.declare")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let asn = outcome.exitASN, !session.exitAlreadyDeclared {
                Button(L("netcheck.window.declare \(asn) \(outcome.exitNetwork)")) {
                    session.declareExitAsReal()
                }
                .controlSize(.small)
                .help("netcheck.window.declareHelp")
            }
            Text("netcheck.note.gps")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func color(_ verdict: NetCheckVerdict) -> Color {
        switch verdict {
        case .ok: return .green
        case .notice: return .orange
        case .leak: return .red
        case .unknown: return .secondary
        }
    }
}

/// 把 `NetCheckWebRTC.webView` 放进视图层级（照手机互传的 `RTCWebViewHolder`）。
struct NetCheckWebViewHolder: NSViewRepresentable {
    let probe: NetCheckWebRTC?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let web = probe?.webView else {
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
