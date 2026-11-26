import Foundation

/// IP 检测的状态：跑一次检测、上次结果（一张表）。只在用户点了才测（docs/netcheck/DESIGN.md §2），结果只在内存里。
@MainActor
final class NetCheckSession: ObservableObject {
    static let shared = NetCheckSession()

    struct Outcome {
        let at: Date
        let table: NetCheckTable
        /// 检测那一刻的本机网络环境快照（纯本地只读）
        let environment: NetCheckEnvironment?
    }

    @Published private(set) var running = false
    @Published private(set) var outcome: Outcome?
    /// 当前本机网络环境（代理 / 隧道 / 系统 DNS / 局域网 IP），纯本地只读，不发网络请求。
    @Published private(set) var environment: NetCheckEnvironment?
    /// WebRTC 探测用的隐藏 WebView。检测窗口把它挂进视图层级（不挂会被 WebKit 挂起）。
    @Published private(set) var webrtc: NetCheckWebRTC?
    /// 检测中关了窗口：跑完再放掉 WebView。
    private var releaseWhenDone = false

    private init() {}

    /// 刷新本机网络环境（纯本地只读，在后台队列读完回主线程更新）。
    func refreshEnvironment() {
        DispatchQueue.global(qos: .utility).async {
            let snapshot = NetCheckEnvironmentReader.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NetCheckSession.shared.environment = snapshot
                }
            }
        }
    }

    /// 起一次检测。已经在跑就不重复起。调用方应当先把检测窗口显示出来（WebView 要在视图层级里）。
    func run() {
        guard !running else { return }
        running = true
        let probe = webrtc ?? NetCheckWebRTC()
        webrtc = probe
        let engine = NetCheckEngine(apiKey: NetCheckKeychain.load() ?? "", dnsProbes: NetCheckSettings.dnsProbes)
        let stun = NetCheckSettings.stunServer

        Task { @MainActor in
            let envTask = Task.detached(priority: .utility) { NetCheckEnvironmentReader.read() }
            async let ipv4 = engine.lookup()
            async let ipv6 = engine.ipv6Exit()
            async let dns = engine.dnsLeak()
            let rtc = await probe.gather(stun: stun)
            let v4 = await ipv4
            var ipv4Measured = false
            if case .success = v4 { ipv4Measured = true }
            let v6 = NetCheckLogic.resolveIPv6(await ipv6, ipv4Measured: ipv4Measured)
            // 网页拿到的地址和 IPv4 / IPv6 那一行都不同时，另查归属（最多 3 个；查不到就只显示地址）
            var lookups: [String: NetCheckIPInfo] = [:]
            for address in NetCheckCompare.addressesToLookUp(rtc, ipv4: v4, ipv6: v6) {
                if case .success(let info) = await engine.lookup(address) { lookups[address] = info }
            }
            let env = await envTask.value
            let observations = NetCheckObservations(ipv4: v4, ipv6: v6, dns: await dns,
                                                    systemTimezone: NetCheckEngine.systemTimezone, webrtc: rtc,
                                                    webrtcLookups: lookups)
            let now = Date()
            self.environment = env
            self.outcome = Outcome(at: now, table: NetCheckCompare.table(observations, at: now), environment: env)
            self.running = false
            if self.releaseWhenDone {
                self.releaseWhenDone = false
                self.releaseWebView()
            }
        }
    }

    /// 窗口关了：没在跑就把 WebView 放掉；正在跑就等跑完再放。
    func windowClosed() {
        guard !running else {
            releaseWhenDone = true
            return
        }
        releaseWebView()
    }

    /// 窗口又打开了：检测中关窗口时记下的「跑完再放」作废，顺手刷新一次本机环境（不联网）。
    func windowOpened() {
        releaseWhenDone = false
        refreshEnvironment()
    }

    private func releaseWebView() {
        webrtc?.stop()
        webrtc = nil
    }
}
