import Foundation

/// IP 检测的状态：跑一次检测、上次结果（一张表）。只在用户点了才测（docs/netcheck/DESIGN.md §2），结果只在内存里。
@MainActor
final class NetCheckSession: ObservableObject {
    static let shared = NetCheckSession()

    struct Outcome {
        let at: Date
        let table: NetCheckTable
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

        Task { @MainActor in
            async let ipv4 = engine.lookup()
            async let ipv6 = engine.ipv6Exit()
            async let dns = engine.dnsLeak()
            let rtc = await probe.gather(stun: stun)
            let v4 = await ipv4
            let v6 = await ipv6
            // 网页拿到的地址和 IPv4 / IPv6 那一行都不同时，另查归属（最多 3 个；查不到就只显示地址）
            var lookups: [String: NetCheckIPInfo] = [:]
            for address in NetCheckCompare.addressesToLookUp(rtc, ipv4: v4, ipv6: v6) {
                if case .success(let info) = await engine.lookup(address) { lookups[address] = info }
            }
            let observations = NetCheckObservations(ipv4: v4, ipv6: v6, dns: await dns,
                                                    systemTimezone: NetCheckEngine.systemTimezone, webrtc: rtc,
                                                    webrtcLookups: lookups)
            self.outcome = Outcome(at: Date(), table: NetCheckCompare.table(observations))
            self.running = false
        }
    }

    /// 窗口关了：没在跑就把 WebView 放掉。
    func windowClosed() {
        guard !running else { return }
        webrtc?.stop()
        webrtc = nil
    }
}
