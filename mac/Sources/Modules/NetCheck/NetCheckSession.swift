import Foundation

/// 网络泄露检测的状态：跑一次检测、上次结果。只在用户点了才测（docs/netcheck/DESIGN.md §2），结果只在内存里。
@MainActor
final class NetCheckSession: ObservableObject {
    static let shared = NetCheckSession()

    struct Outcome {
        let at: Date
        let summary: [NetCheckSummary]
        let findings: [NetCheckFinding]
        /// bash.ws 自己的结论文字
        let dnsConclusion: String?
        /// 本次出口的 ASN 与运营方：用来「记为真实网络」
        let exitASN: Int?
        let exitNetwork: String
        /// 检测时有没有声明真实网络
        let realDeclared: Bool

        var overall: NetCheckVerdict {
            NetCheckLogic.overall(findings.map(\.verdict))
        }
    }

    @Published private(set) var running = false
    @Published private(set) var outcome: Outcome?
    /// WebRTC 探测用的隐藏 WebView。检测窗口把它挂进视图层级（不挂会被 WebKit 挂起）。
    @Published private(set) var webrtc: NetCheckWebRTC?

    private init() {}

    /// 起一次检测。已经在跑就不重复起。调用方应当先把检测窗口显示出来（WebView 要在视图层级里）。
    func run() {
        guard !running else { return }
        running = true
        let probe = webrtc ?? NetCheckWebRTC()
        webrtc = probe
        let engine = NetCheckEngine(apiKey: NetCheckKeychain.load() ?? "", dnsProbes: NetCheckSettings.dnsProbes)
        let stun = NetCheckSettings.stunServer
        let realText = NetCheckSettings.realNetworks

        Task { @MainActor in
            async let ipv4 = engine.lookup()
            async let ipv6 = engine.ipv6Exit()
            async let dns = engine.dnsLeak()
            let rtc = await probe.gather(stun: stun)
            let observations = NetCheckObservations(ipv4: await ipv4, ipv6: await ipv6, dns: await dns,
                                                    systemTimezone: NetCheckEngine.systemTimezone, webrtc: rtc)
            let real = NetCheckRealNetworks(parsing: realText)
            let findings = NetCheckLogic.evaluate(observations, real: real)
            var exitASN: Int?
            var exitNetwork = ""
            if case .success(let info) = observations.ipv4 {
                exitASN = info.asn
                exitNetwork = info.network.isEmpty ? info.company : info.network
            }
            var conclusion: String?
            if case .success(let result) = observations.dns { conclusion = result.conclusion }
            self.outcome = Outcome(at: Date(),
                                   summary: NetCheckLogic.summarize(observations, findings: findings),
                                   findings: findings,
                                   dnsConclusion: conclusion,
                                   exitASN: exitASN,
                                   exitNetwork: exitNetwork,
                                   realDeclared: !real.isEmpty)
            self.running = false
        }
    }

    /// 把本次出口记为真实网络（用户关着 VPN 测的那次）。
    func declareExitAsReal() {
        guard let asn = outcome?.exitASN else { return }
        NetCheckSettings.addRealNetwork(asn)
        objectWillChange.send()
    }

    /// 本次出口是不是已经记过。
    var exitAlreadyDeclared: Bool {
        guard let asn = outcome?.exitASN else { return false }
        return NetCheckRealNetworks(parsing: NetCheckSettings.realNetworks).contains(asn)
    }

    /// 窗口关了：没在跑就把 WebView 放掉。
    func windowClosed() {
        guard !running else { return }
        webrtc?.stop()
        webrtc = nil
    }
}
