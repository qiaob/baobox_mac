import AppKit
import SwiftUI

// MARK: - 窗口控制器

/// 窗口里的两页（顶部分段切换）。见 docs/netcheck/SPEED.md。
enum NetCheckPage: Hashable {
    case leak, speed
}

/// 窗口此刻在哪一页：菜单 / 快速入口打开窗口时可以指定。
@MainActor
final class NetCheckWindowState: ObservableObject {
    static let shared = NetCheckWindowState()
    @Published var page: NetCheckPage = .leak
    private init() {}
}

/// 网络检测窗口：泄露检测（结果 + 总结，也承载 WebRTC 探测用的隐藏 WebView）与测速两页。
/// 见 docs/netcheck/DESIGN.md §4.3、docs/netcheck/SPEED.md §1.3。
@MainActor
final class NetCheckWindowController: NSObject, NSWindowDelegate {
    static let shared = NetCheckWindowController()
    private var window: NSWindow?

    private override init() {
        super.init()
    }

    /// 显示窗口。`page` 为 nil 时停在上次那一页；`start` 为 true 时顺手开始那一页的检测 / 测速
    /// （另一样正在跑时不开始：两者不并行）。
    func show(page: NetCheckPage? = nil, start: Bool = false) {
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
        if let page { NetCheckWindowState.shared.page = page }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        guard start else { return }
        switch NetCheckWindowState.shared.page {
        case .leak:
            if !NetSpeedTestSession.shared.running { NetCheckSession.shared.run() }
        case .speed:
            NetSpeedTestSession.shared.start()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NetCheckSession.shared.windowClosed()
        // 测速随窗口停（泄露检测照旧：关窗口不打断）
        NetSpeedTestSession.shared.stop()
    }
}

// MARK: - 根视图

struct NetCheckRootView: View {
    @ObservedObject private var state = NetCheckWindowState.shared
    @ObservedObject private var session = NetCheckSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(selection: $state.page) {
                Text("netcheck.page.leak").tag(NetCheckPage.leak)
                Text("netcheck.page.speed").tag(NetCheckPage.speed)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)

            switch state.page {
            case .leak: NetCheckLeakView()
            case .speed: NetSpeedPageView()
            }
        }
        .padding(18)
        .overlay(alignment: .bottomLeading) {
            // WebRTC 探测的 WebView：1×1 挂进视图层级，避免被 WebKit 当作不可见而挂起。放在两页外面：切到测速页也还挂着。
            NetCheckWebViewHolder(probe: session.webrtc)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 泄露检测页

struct NetCheckLeakView: View {
    @ObservedObject private var session = NetCheckSession.shared
    @ObservedObject private var speed = NetSpeedTestSession.shared
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
                Text("netcheck.leak.title").font(.title3.bold())
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
                // 测速正在跑时也不能开始（两者不并行）
                .disabled(session.running || speed.running)
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

// MARK: - 测速页

/// 测速页（docs/netcheck/SPEED.md §1.3）：未开始 → 一句说明；进行中 → 阶段名、这一刻的大号数字、进度条，按钮变「停止」；
/// 结束 → 三个数并排、「经 … · 出口 …」、用了多少流量，按钮「再测一次」「复制结果」。
struct NetSpeedPageView: View {
    @ObservedObject private var speed = NetSpeedTestSession.shared
    @ObservedObject private var leak = NetCheckSession.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if speed.running {
                Spacer()
                running
                Spacer()
            } else if let result = speed.result {
                results(result)
                Spacer()
            } else {
                Spacer()
                Text("netcheck.speed.intro")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if speed.running {
                ProgressView().controlSize(.small)
                Text("netcheck.speed.running").font(.title3)
            } else if let result = speed.result {
                VStack(alignment: .leading, spacing: 2) {
                    Text("netcheck.speed.title").font(.title3.bold())
                    Text(L("netcheck.speed.testedAt \(result.at.formatted(date: .omitted, time: .standard))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("netcheck.speed.title").font(.title3.bold())
            }
            Spacer()
            if speed.running {
                Button("netcheck.speed.stop") { speed.stop() }
            } else {
                if let result = speed.result {
                    Button(copied ? "netcheck.window.copied" : "netcheck.speed.copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(NetCheckText.speedReport(result), forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            MainActor.assumeIsolated { copied = false }
                        }
                    }
                }
                Button(speed.result == nil ? "netcheck.speed.start" : "netcheck.speed.again") { speed.start() }
                    .buttonStyle(.borderedProminent)
                    // 泄露检测正在跑时不能开始（两者不并行）
                    .disabled(leak.running)
            }
        }
    }

    // MARK: 进行中

    private var running: some View {
        let phase = speed.phase ?? .latency
        let reading = Self.reading(phase, speed.liveValue)
        return VStack(spacing: 10) {
            Text(NetCheckText.title(phase))
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: reading.number)
                    .font(.system(size: 56, weight: .semibold).monospacedDigit())
                Text(verbatim: reading.unit)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: reading.detail ?? " ")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            ProgressView(value: speed.overallFraction)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
    }

    /// 大号数字、单位、下面那行小字。还没有数时是「—」。
    static func reading(_ phase: NetSpeedPhase, _ value: Double?) -> (number: String, unit: String, detail: String?) {
        switch phase {
        case .latency:
            return (value.map { NetSpeedFormat.milliseconds($0) } ?? "—", "ms", nil)
        case .download, .upload:
            return (value.map { NetSpeedFormat.mbps($0) } ?? "—", "Mbps", value.map { NetSpeedFormat.rate($0) })
        }
    }

    // MARK: 结果

    private func results(_ result: NetSpeedResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 三张一样高：卡片撑满这一行，这一行按最高的那张定高
            HStack(alignment: .top, spacing: 10) {
                card(.download, result)
                card(.upload, result)
                card(.latency, result)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                if let via = NetCheckText.via(result.server) {
                    Text(verbatim: via)
                        .textSelection(.enabled)
                }
                Text(verbatim: NetCheckText.used(result))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private static func symbol(_ phase: NetSpeedPhase) -> String {
        switch phase {
        case .download: return "arrow.down.circle.fill"
        case .upload: return "arrow.up.circle.fill"
        case .latency: return "stopwatch.fill"
        }
    }

    /// 一项结果：标题、大号数字与单位、下面一行小字（MB/s 或抖动）；没测出来时写「没测出来」和原因。
    private func card(_ phase: NetSpeedPhase, _ result: NetSpeedResult) -> some View {
        let value: (number: String, unit: String, detail: String?)?
        let failure: String?
        switch phase {
        case .latency:
            switch result.latency {
            case .success(let latency):
                value = (NetSpeedFormat.milliseconds(latency.median), "ms", NetCheckText.jitter(latency))
                failure = nil
            case .failure(let why):
                value = nil
                failure = why.message
            }
        case .download, .upload:
            switch phase == .download ? result.download : result.upload {
            case .success(let rate):
                value = (NetSpeedFormat.mbps(rate), "Mbps", NetSpeedFormat.rate(rate))
                failure = nil
            case .failure(let why):
                value = nil
                failure = why.message
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            Label(NetCheckText.title(phase), systemImage: Self.symbol(phase))
                .font(.headline)
                .foregroundStyle(value == nil ? Color.secondary : Color.accentColor)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: value.number)
                        .font(.system(size: 32, weight: .semibold).monospacedDigit())
                    Text(verbatim: value.unit)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: value.detail ?? " ")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("netcheck.speed.failed")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: failure ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill((value == nil ? Color.secondary : Color.accentColor).opacity(0.10)))
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
