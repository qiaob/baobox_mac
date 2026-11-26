import AppKit
import SwiftUI

// MARK: - 窗口控制器

/// 窗口里的四页（顶部分段切换）：IP 检测、测速、诊断、端口。
enum NetCheckPage: Hashable {
    case ip, speed, diag, ports
}

/// 窗口此刻在哪一页：菜单 / 快速入口打开窗口时可以指定。
@MainActor
final class NetCheckWindowState: ObservableObject {
    static let shared = NetCheckWindowState()
    @Published var page: NetCheckPage = .ip
    private init() {}
}

/// 网络检测窗口：IP 检测（一张表，也承载 WebRTC 探测用的隐藏 WebView）、测速、诊断与本机端口四页。
/// 见 docs/netcheck/COMPARE.md §1、docs/netcheck/SPEED.md §1.3。
@MainActor
final class NetCheckWindowController: NSObject, NSWindowDelegate {
    static let shared = NetCheckWindowController()
    private var window: NSWindow?

    private override init() {
        super.init()
    }

    /// 显示窗口。`page` 为 nil 时停在上次那一页；`start` 为 true 时顺手开始那一页的检测 / 测速 / 刷新。
    func show(page: NetCheckPage? = nil, start: Bool = false) {
        if window == nil {
            let hosting = NSHostingController(rootView: NetCheckRootView())
            // 要拿焦点的普通窗口：在桌面空间建（见 mac/CLAUDE.md「普通窗口与全屏空间」）。
            let created = DesktopSpaceWindow.make { NSWindow(contentViewController: hosting) }
            created.title = L("netcheck.window.title")
            created.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            created.setContentSize(NSSize(width: 720, height: 600))
            created.minSize = NSSize(width: 540, height: 460)
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()
            window = created
        }
        if let page { NetCheckWindowState.shared.page = page }
        NetCheckSession.shared.windowOpened()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        guard start else { return }
        switch NetCheckWindowState.shared.page {
        case .ip:
            if !NetSpeedTestSession.shared.running { NetCheckSession.shared.run() }
        case .speed:
            NetSpeedTestSession.shared.start()
        case .diag:
            NetDiagSession.shared.runServiceChecks()
        case .ports:
            NetPortSession.shared.refresh()
        }
    }

    /// 打开诊断页并针对给定目标立即执行全链路诊断（供快速入口文字动作调用）。
    func showDiagnostic(target: String) {
        show(page: .diag, start: false)
        NetDiagSession.shared.runDiagnostic(raw: target)
    }

    /// 打开本机端口页并按搜索词过滤刷新（供快速入口 `:3000` 等调用）。
    func showPorts(filter: String? = nil) {
        if let filter { NetPortSession.shared.searchText = filter }
        show(page: .ports, start: true)
    }

    func windowWillClose(_ notification: Notification) {
        NetCheckSession.shared.windowClosed()
        // 测速与诊断随窗口停（IP 检测照旧：关窗口不打断）
        NetSpeedTestSession.shared.stop()
        NetDiagSession.shared.stopAll()
    }
}

// MARK: - 根视图

struct NetCheckRootView: View {
    @ObservedObject private var state = NetCheckWindowState.shared
    @ObservedObject private var session = NetCheckSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(selection: $state.page) {
                Text("netcheck.page.ip").tag(NetCheckPage.ip)
                Text("netcheck.page.speed").tag(NetCheckPage.speed)
                Text("netcheck.page.diag").tag(NetCheckPage.diag)
                Text("netcheck.page.ports").tag(NetCheckPage.ports)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)

            switch state.page {
            case .ip: NetCheckIPView()
            case .speed: NetSpeedPageView()
            case .diag: NetCheckDiagView()
            case .ports: NetCheckPortView()
            }
        }
        .padding(18)
        .overlay(alignment: .bottomLeading) {
            // WebRTC 探测的 WebView：1×1 挂进视图层级，避免被 WebKit 当作不可见而挂起。放在各页外面：切页也还挂着。
            NetCheckWebViewHolder(probe: session.webrtc)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - IP 检测页

/// IP 检测页（docs/netcheck/COMPARE.md §1）：一行结论（一致 / 不一致）+ 一张表（IPv4、IPv6、DNS、WebRTC、时区 ×
/// IP、国家 / 地区、归属），对不上的格子里的字标红。没有哪一行是「正确值」。
struct NetCheckIPView: View {
    @ObservedObject private var session = NetCheckSession.shared
    @ObservedObject private var speed = NetSpeedTestSession.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let env = session.environment ?? session.outcome?.environment {
                environmentCard(env)
            }
            if let outcome = session.outcome {
                // 外面给多宽，表就按比例分多宽（量的是外面的空间，不是表自己，不会越量越宽）
                GeometryReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            table(outcome.table, at: outcome.at, width: proxy.size.width)
                            Divider()
                            Text("netcheck.note.gps")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: proxy.size.width, alignment: .leading)
                    }
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

    /// 本机网络环境摘要（纯本地只读）：局域网接口、系统 DNS、系统代理、活跃隧道。
    private func environmentCard(_ env: NetCheckEnvironment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                envItem(label: "netcheck.env.lan", value: NetCheckText.envLAN(env), active: env.lan != nil, monospaced: true)
                envItem(label: "netcheck.env.dns", value: NetCheckText.envDNS(env), active: !env.dnsServers.isEmpty, monospaced: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                envItem(label: "netcheck.env.proxy", value: NetCheckText.envProxy(env), active: !env.proxy.isEmpty, monospaced: true)
                envItem(label: "netcheck.env.tunnel", value: NetCheckText.envTunnels(env), active: !env.tunnels.isEmpty, monospaced: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func envItem(label: LocalizedStringKey, value: String, active: Bool, monospaced: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(monospaced && active ? .caption.monospaced() : .caption)
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if session.running {
                ProgressView().controlSize(.small)
                Text("netcheck.window.running").font(.title3)
            } else if let outcome = session.outcome {
                let conclusion = outcome.table.conclusion
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: NetCheckText.conclusion(conclusion))
                        .font(.title3.bold())
                        .foregroundStyle(Self.isInconsistent(conclusion) ? Color.red : Color.primary)
                    Text(verbatim: subtitle(outcome))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("netcheck.menu.never").font(.title3.bold())
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

    /// 「检测于 15:32:10 · 对不上的：国家、归属」
    private func subtitle(_ outcome: NetCheckSession.Outcome) -> String {
        let at = L("netcheck.window.checkedAt \(outcome.at.formatted(date: .omitted, time: .standard))")
        guard let mismatches = NetCheckText.mismatches(outcome.table.conclusion) else { return at }
        return at + " · " + mismatches
    }

    static func isInconsistent(_ conclusion: NetCheckConclusion) -> Bool {
        if case .inconsistent = conclusion { return true }
        return false
    }

    // MARK: 表

    private static let labelWidth: CGFloat = 100
    private static let spacing: CGFloat = 10

    /// 三列的宽：IP 30%、国家 / 地区 28%、归属 42%。
    private static func columnWidths(_ width: CGFloat) -> (address: CGFloat, country: CGFloat, owner: CGFloat) {
        let rest = max(240, width - labelWidth - spacing * 3)
        return (floor(rest * 0.30), floor(rest * 0.28), floor(rest * 0.42))
    }

    private func table(_ table: NetCheckTable, at date: Date, width: CGFloat) -> some View {
        let widths = Self.columnWidths(width)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
                Color.clear.frame(width: Self.labelWidth, height: 1)
                Text("netcheck.column.ip").frame(width: widths.address, alignment: .leading)
                Text("netcheck.column.country").frame(width: widths.country, alignment: .leading)
                Text("netcheck.column.owner").frame(width: widths.owner, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                Divider()
                rowView(row, at: date, widths: widths)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowView(_ row: NetCheckRow, at date: Date, widths: (address: CGFloat, country: CGFloat, owner: CGFloat)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure = row.failure {
                HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
                    label(row, isFirst: true)
                    Text(verbatim: NetCheckText.failure(failure))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(Array(row.lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
                    label(row, isFirst: index == 0)
                    cell(line.address, monospaced: true, at: date).frame(width: widths.address, alignment: .leading)
                    cell(line.country, at: date).frame(width: widths.country, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        cell(line.owner, at: date)
                        if !line.flags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(Array(line.flags.enumerated()), id: \.offset) { _, flag in
                                    Text(verbatim: NetCheckText.flag(flag))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                }
                            }
                        }
                    }
                    .frame(width: widths.owner, alignment: .leading)
                }
            }
        }
    }

    /// 行首：小圆点（这一行有红字是红色，没有是灰色；没测出来是灰色问号）+ 行名。只在一行的第一条显示。
    @ViewBuilder
    private func label(_ row: NetCheckRow, isFirst: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isFirst {
                if row.failure != nil {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(row.hasMismatch ? Color.red : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                Text(verbatim: NetCheckText.title(row))
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.labelWidth, alignment: .leading)
    }

    /// 一格：标红的字是红色；「没有」「没查到」这类说明和不参加比较的是灰色。地址用等宽字体，都可以选中复制。
    private func cell(_ cell: NetCheckCell, monospaced: Bool = false, at date: Date) -> some View {
        let isData: Bool
        var isAddress = false
        switch cell.value {
        case .text: isData = true; isAddress = monospaced
        case .place, .servers, .systemZone, .ipZone: isData = true
        default: isData = false
        }
        let base: Font = .callout
        // 不参加比较的（公共 DNS 的国家）是灰色、不会红
        let plain = isData && !cell.muted ? Color.primary : Color.secondary
        return Text(verbatim: NetCheckText.value(cell.value, at: date))
            .font(isAddress ? base.monospaced() : base)
            .foregroundStyle(cell.mismatch ? Color.red : plain)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - 测速页

/// 测速页（docs/netcheck/SPEED.md §1.3）：未开始 → 一句说明；进行中 → 阶段名、这一刻的大号数字、进度条，按钮变「停止」；
/// 结束 → 三个数并排、「经 … · 出口 …」、用了多少流量，按钮「再测一次」「复制结果」。
struct NetSpeedPageView: View {
    @ObservedObject private var speed = NetSpeedTestSession.shared
    @ObservedObject private var ipCheck = NetCheckSession.shared
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
                    // IP 检测正在跑时不能开始（两者不并行）
                    .disabled(ipCheck.running)
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

    /// 一项结果：标题、大号数字与单位、下面小字（MB/s，或抖动与负载延迟）；没测出来时写「没测出来」和原因。
    private func card(_ phase: NetSpeedPhase, _ result: NetSpeedResult) -> some View {
        let value: (number: String, unit: String, details: [String])?
        let failure: String?
        switch phase {
        case .latency:
            switch result.latency {
            case .success(let latency):
                let details = [NetCheckText.jitter(latency), NetCheckText.loadedLatency(latency)].compactMap { $0 }
                value = (NetSpeedFormat.milliseconds(latency.median), "ms", details)
                failure = nil
            case .failure(let why):
                value = nil
                failure = why.message
            }
        case .download, .upload:
            switch phase == .download ? result.download : result.upload {
            case .success(let rate):
                value = (NetSpeedFormat.mbps(rate), "Mbps", [NetSpeedFormat.rate(rate)])
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
                if value.details.isEmpty {
                    Text(verbatim: " ")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(value.details.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
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
