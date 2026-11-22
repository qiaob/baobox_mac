import AppKit
import Combine
import Foundation

/// 抓包的总开关协调（docs/packet-capture/CONTROL.md §2）。窗口、菜单、MCP 都从这里进。
///
/// 「配置」页四张卡片各有一个总开关：本机、手动代理、WireGuard、给其他设备装证书。**任意一个开着引擎就在跑，全关就停**；
/// 引擎听哪些端口由开关决定，变了就重启一次（`reconcile`）。总开关不跨启动保存（Baobox 开机自启，不能一启动就改系统代理、开监听），
/// 子开关和各种取值存在 UserDefaults。次要卡片里的操作（终端、模拟器、重发）需要引擎时只起引擎，之后由「停止全部」停。
@MainActor
final class NetCaptureSession: ObservableObject {
    static let shared = NetCaptureSession()

    /// 窗口顶部的一条提示（成功或失败），用户点 × 关掉。
    struct Banner: Equatable {
        enum Kind { case info, problem }
        var kind: Kind
        var text: String
    }

    /// 「本机」：系统代理指向引擎（证书没信任时打开它会先弹系统验证框）。
    @Published private(set) var macOn = false
    /// 「手动代理」：引擎听局域网，局域网设备（放行后）能拿它当代理。
    @Published private(set) var manualProxyOn = false
    /// 「WireGuard」：引擎给每台设备开一个 WireGuard 监听（设备表在 `WireGuardDeviceStore`）。
    @Published private(set) var wireguardOn = false
    /// 用户最后一次对 WireGuard 开关的意图。设备表还在读时先开后关，读完的回调照这个来，不再把它打开。
    private var wireguardWanted = false
    /// 「给其他设备装证书」：配置页服务开着，卡片上显示二维码。
    @Published private(set) var certPageOn = false
    /// 暂停：HTTP 和 TCP 都不记录新的（CONTROL.md §5）。不记住，引擎每次新启动都从「记录中」开始。
    @Published private(set) var paused = false
    /// 正在做一件要等的事（装证书、起引擎…）时的说明，窗口据此显示进度、禁用按钮。
    @Published private(set) var working: String?
    @Published var banner: Banner?
    /// CA 是否已被这台 Mac 信任（`refreshTrust` 更新）。
    @Published private(set) var caTrusted = false

    private let engine = NetCaptureEngine.shared
    /// 次要卡片（终端、模拟器）、重发、MCP 起的引擎：四个总开关都关着也让它跑，直到「停止全部」。
    @Published private(set) var engineOnly = false
    /// 等引擎就绪后要做的事；引擎起不来就丢掉。
    private var whenRunning: [() -> Void] = []
    private var stateSink: AnyCancellable?
    /// 改系统代理的串行队列：先开后关的顺序不能乱（`networksetup` 要在后台跑）。
    private let proxyQueue = DispatchQueue(label: "com.baobox.netcapture.system-proxy", qos: .userInitiated)

    private init() {
        stateSink = engine.$state.sink { [weak self] state in
            // sink 在 @Published 的 willSet 里同步调用，这时读 engine.state 还是旧值，所以用传进来的。
            MainActor.assumeIsolated { self?.engineStateChanged(state) }
        }
    }

    private func engineStateChanged(_ state: NetCaptureEngine.State) {
        switch state {
        case .running:
            let actions = whenRunning
            whenRunning = []
            // 让 @Published 先落值，再跑后续（它们会读 engine.port）。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.working = nil
                    self.applySystemProxy()
                    actions.forEach { $0() }
                }
            }
        case .failed(let message):
            engineFailed()
            banner = Banner(kind: .problem, text: message)
        case .stopped, .starting:
            break
        }
    }

    /// 四个总开关有没有开着的（引擎跑不跑看它）。
    var anyCardOn: Bool { anySourceOn || certPageOn }
    /// 三个抓包来源有没有开着的。
    var anySourceOn: Bool { macOn || manualProxyOn || wireguardOn }
    /// **是不是在抓包**：有来源开着，或者工具（终端、模拟器、重发、MCP）让引擎跑着。窗口右上角的状态、暂停、停止全部、
    /// 菜单都看它，不看引擎进程在不在 —— 只开「给其他设备装证书」时引擎也在跑（配置页的证书检测要连它），
    /// 但什么都不抓，不能显示成「运行中」。
    var capturing: Bool { anySourceOn || engineOnly }

    // MARK: - 引擎跟着开关走

    private var desiredListeners: EngineListeners {
        EngineListeners(port: NetCaptureEnv.port,
                        // 「给其他设备装证书」开着也要听局域网：配置页的证书检测要连代理端口。拿它当代理用会被桥拒绝（`lanProxy`）。
                        lan: manualProxyOn || certPageOn,
                        wireguard: wireguardOn ? WireGuardDeviceStore.shared.listeners : [])
    }

    private var desiredFlags: BridgeFlags {
        BridgeFlags(record: !paused,
                    lanProxy: manualProxyOn,
                    macTCP: macOn && NetCaptureEnv.macTCP,
                    pagePort: certPageOn ? NetCaptureEnv.configPagePort : 0)
    }

    /// 让引擎和开关对上：该停就停；没在跑就起；监听组合变了重启一次（列表不丢、暂停照旧）；只是桥的开关变了就发指令。
    private func reconcile() {
        ConfigPageServer.shared.manualProxyOn = manualProxyOn
        guard anyCardOn || engineOnly else {
            if engine.state != .stopped { shutDownEngine() }
            return
        }
        let listeners = desiredListeners
        if engine.isActive {
            if engine.listeners != listeners {
                engine.restart(listeners: listeners, flags: desiredFlags)
            } else {
                engine.apply(flags: desiredFlags)
            }
        } else {
            guard NetCaptureEnv.engineUnavailable == nil else {
                banner = Banner(kind: .problem, text: L("netcapture.error.engineMissing"))
                return
            }
            // 新启动：从「记录中」开始（暂停不记住）。
            paused = false
            working = L("netcapture.working.starting")
            engine.start(listeners: listeners, flags: desiredFlags)
        }
    }

    /// 四个开关都关了（或「停止全部」）：引擎退出；列表是否清空看设置。
    private func shutDownEngine() {
        whenRunning = []
        working = nil
        paused = false
        engine.stop()
        if NetCaptureEnv.clearOnStop {
            FlowStore.shared.clear()
            TCPStore.shared.clear()
        }
    }

    /// 引擎没在跑就只起引擎（**不动系统代理**），就绪后执行 `then`；已经在跑就直接执行。
    /// 次要卡片、重发、MCP 用它（docs/packet-capture/TOOLS.md §3）。
    func ensureEngine(then: @escaping () -> Void) {
        // 没有来源开着：从现在起引擎是为这个工具跑的（算在抓包，要「停止全部」才停）。引擎可能已经因为
        // 「给其他设备装证书」在跑了，所以先记下再看它在不在跑 —— 否则关掉证书页会把工具用着的引擎一起停掉。
        if !anySourceOn { engineOnly = true }
        if engine.isRunning {
            then()
            return
        }
        whenRunning.append(then)
        if !engine.isActive { reconcile() }
    }

    // MARK: - 全局：暂停、停止全部

    /// 暂停 / 继续：对 HTTP 和 TCP 同时生效，只在引擎运行时有意义。引擎因开关重启时保持。
    func setPaused(_ on: Bool) {
        guard engine.isActive, paused != on else { return }
        paused = on
        engine.apply(flags: desiredFlags)
    }

    /// 「停止全部」：四个总开关全关（引擎停、系统代理还原、配置页关）。列表是否清空看设置。
    func stopAll() {
        let hadMac = macOn
        macOn = false
        manualProxyOn = false
        wireguardOn = false
        wireguardWanted = false
        certPageOn = false
        engineOnly = false
        ConfigPageServer.shared.stop()
        ConfigPageServer.shared.manualProxyOn = false
        if hadMac { proxyQueue.async { SystemProxyController.restore() } }
        shutDownEngine()
    }

    /// App 退出：同步收尾，不留进程、不留指向自己的系统代理。
    func terminate() {
        engine.terminateNow()
        ConfigPageServer.shared.stop()
        proxyQueue.sync { SystemProxyController.restore() }
    }

    /// 引擎起不来或自己退了（崩溃、端口被占、启动超时）：开关全回到关，系统代理不能再指着它，否则整机断网。
    private func engineFailed() {
        whenRunning = []
        working = nil
        paused = false
        macOn = false
        manualProxyOn = false
        wireguardOn = false
        wireguardWanted = false
        certPageOn = false
        engineOnly = false
        ConfigPageServer.shared.stop()
        ConfigPageServer.shared.manualProxyOn = false
        proxyQueue.async { SystemProxyController.restore() }
    }

    // MARK: - 重发（TOOLS.md §3）

    /// 让引擎把这条请求再发一次。引擎没在跑就先只起引擎，就绪后再发。
    /// 发出去的请求是列表里新的一行，id 就是 `request.id`（调用方据此先选中它）。
    func replay(_ request: ReplayRequest) {
        FlowStore.shared.noteReplay(request)
        ensureEngine { [weak self] in self?.engine.send(.replay(request)) }
    }

    /// 引擎说重发没发出去（URL 不合法等）：顶部提示条显示原因。
    func replayDidFail(id: UUID?, message: String) {
        let reason = message.isEmpty ? L("netcapture.replay.failedUnknown") : message
        banner = Banner(kind: .problem, text: L("netcapture.replay.failed \(reason)"))
    }

    // MARK: - 本机

    /// 「本机」总开关。
    func setMac(_ on: Bool) {
        on ? startMac() : stopMac()
    }

    /// MCP 的 `start_capture`：证书已受信就打开「本机」，否则只起引擎（不替用户弹验证框）。
    func startFromAutomation() {
        startMac(interactive: false, engineOnlyIfUntrusted: true)
    }

    /// 打开「本机」：CA 没被信任就先装（`interactive` 时系统弹验证框），再起引擎、把系统代理指过去。
    /// 证书没装成就不动系统代理 —— 否则本机所有 HTTPS 都会报证书错误。
    func startMac(interactive: Bool = true, engineOnlyIfUntrusted: Bool = false) {
        guard !macOn, working == nil else { return }
        guard NetCaptureEnv.engineUnavailable == nil else {
            banner = Banner(kind: .problem, text: L("netcapture.error.engineMissing"))
            return
        }
        working = L("netcapture.working.cert")
        let origin = interactive ? NSApp.keyWindow : nil
        DispatchQueue.global(qos: .userInitiated).async {
            let ca = CaptureCA.shared
            var trusted = ca.ensureGenerated() && ca.isTrusted()
            var outcome = CaptureCA.TrustResult(ok: trusted)
            if !trusted, interactive {
                outcome = ca.installTrust()
                trusted = outcome.ok && ca.isTrusted()
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.caTrusted = trusted
                    self.working = nil
                    if interactive { self.bringBack(origin) }
                    guard trusted else {
                        if engineOnlyIfUntrusted {
                            self.ensureEngine {}
                        } else {
                            self.reportCertFailure(outcome)
                        }
                        return
                    }
                    self.banner = nil
                    self.macOn = true
                    // 引擎已在跑就立刻指系统代理；没在跑，就绪时 `engineStateChanged` 会指。
                    self.reconcile()
                    if self.engine.isRunning { self.applySystemProxy() }
                }
            }
        }
    }

    /// 关「本机」：系统代理还原。引擎看别的开关决定停不停。
    func stopMac() {
        guard macOn else { return }
        macOn = false
        proxyQueue.async { SystemProxyController.restore() }
        reconcile()
    }

    /// 「本机」的子开关变了（HTTP / HTTPS、WebSocket、TCP）：重新应用系统代理，告诉桥记不记本机的 TCP。
    func macOptionsChanged() {
        guard macOn else { return }
        applySystemProxy()
        reconcile()
    }

    /// 按子开关把系统代理指向引擎：HTTP / HTTPS 开着设 HTTP 代理；WebSocket 或 TCP 开着设 SOCKS 代理（苹果的网络库只让
    /// WebSocket 走 SOCKS；本机的原始 TCP 也只有走系统 SOCKS 的程序才进得来）。都关着等于还原。
    private func applySystemProxy() {
        guard macOn, let port = engine.port else { return }
        let http: UInt16? = NetCaptureEnv.macHTTP ? port : nil
        let socks: UInt16? = (NetCaptureEnv.macWebSocket || NetCaptureEnv.macTCP)
            ? EngineListeners.neighbour(of: port, offset: 2) : nil
        proxyQueue.async { SystemProxyController.apply(httpPort: http, socksPort: socks) }
    }

    /// 系统的验证框关掉以后，前台会回到之前那个 App，把我们的窗口盖住 —— Baobox 没有 Dock 图标，
    /// 用户只看到窗口「没了」。所以每次弹过验证框，都把发起操作的那个窗口重新拿到最前面。
    /// 只拿回还开着的窗口：被别的 App 盖住的窗口仍然算「可见」，而已经关掉的（用户关了，或是一个点完就消失的
    /// 确认框）不是 —— 对后者 `makeKeyAndOrderFront` 会让它重新冒出来。
    func bringBack(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// 证书没装成：用户自己点了取消就什么也不说；否则把系统给的原因原样显示出来。
    private func reportCertFailure(_ outcome: CaptureCA.TrustResult) {
        guard !outcome.cancelled else { return }
        var text = L("netcapture.problem.certNotTrusted")
        if !outcome.message.isEmpty { text += "\n" + outcome.message }
        banner = Banner(kind: .problem, text: text)
    }

    // MARK: - 手动代理

    /// 「手动代理」总开关：引擎听局域网（变了就重启一次），桥放行局域网设备拿它当代理（新设备仍要「允许」）。
    func setManualProxy(_ on: Bool) {
        guard manualProxyOn != on else { return }
        manualProxyOn = on
        reconcile()
    }

    /// 新设备连上来了，等用户点允许。窗口里有提示条；这里再发一条通知，窗口没开着也看得到。
    func announcePendingDevice(_ ip: String) {
        let notice = Notice(source: "netcapture",
                            level: .bubble,
                            title: L("netcapture.device.pending \(ip)"),
                            actions: [
                                Notice.Action(id: "allow", label: L("netcapture.device.allow"), role: .primary),
                                Notice.Action(id: "deny", label: L("netcapture.device.deny")),
                            ],
                            dedupeKey: "netcapture.device.\(ip)",
                            icon: "network")
        NotifyCenter.shared.post(notice) { [weak self] action in
            guard let self else { return }
            if action == "allow" { self.engine.allow(device: ip) } else if action == "deny" { self.engine.deny(device: ip) }
        }
    }

    // MARK: - WireGuard

    /// 「WireGuard」总开关。打开时等设备表读完（首次启动新版本时要先迁移），再让引擎给每台设备开一个监听。
    /// 一台设备都没有也照样打开（窗口会接着弹出「添加设备」）。
    func setWireGuard(_ on: Bool) {
        wireguardWanted = on
        guard on else {
            guard wireguardOn else { return }
            wireguardOn = false
            reconcile()
            return
        }
        guard !wireguardOn else { return }
        WireGuardDeviceStore.shared.ensureLoaded { [weak self] in
            guard let self, self.wireguardWanted, !self.wireguardOn else { return }
            self.wireguardOn = true
            self.reconcile()
        }
    }

    /// 设备加了或删了：WireGuard 开着就让引擎换监听（监听只能启动时定，重启一次；别的设备断一下再自己连上）。改名不走这里。
    func wireguardDevicesChanged() {
        guard wireguardOn else { return }
        reconcile()
    }

    // MARK: - 证书

    /// 「给其他设备装证书」总开关：配置页服务开 / 关；引擎跟着听局域网（证书检测要连代理端口）。
    func setCertPage(_ on: Bool) {
        guard certPageOn != on else { return }
        certPageOn = on
        if on {
            ConfigPageServer.shared.start(port: NetCaptureEnv.configPagePort)
            DispatchQueue.global(qos: .userInitiated).async { CaptureCA.shared.ensureGenerated() }
        } else {
            ConfigPageServer.shared.stop()
        }
        reconcile()
    }

    /// 「解密 HTTPS」：存下来，正在跑的引擎立刻换解密范围。
    func setDecryptHTTPS(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: NetCaptureEnv.Keys.decryptHTTPS)
        engine.applyScopeFromSettings()
    }

    /// 重新查一次 CA 的信任状态（窗口出现时、装 / 移除之后调）。
    func refreshTrust() {
        DispatchQueue.global(qos: .utility).async {
            let trusted = CaptureCA.shared.isGenerated && CaptureCA.shared.isTrusted()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.caTrusted = trusted } }
        }
    }

    /// 单独点「安装并信任」（证书卡片、设置页）。
    func installCert() {
        guard working == nil else { return }
        working = L("netcapture.working.cert")
        let origin = NSApp.keyWindow
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = CaptureCA.shared.installTrust()
            let trusted = outcome.ok && CaptureCA.shared.isTrusted()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.working = nil
                    self.caTrusted = trusted
                    self.bringBack(origin)
                    if trusted { self.banner = nil } else { self.reportCertFailure(outcome) }
                }
            }
        }
    }

    // MARK: - 终端 / 脚本

    /// 开一个已经带好代理和证书环境变量的终端会话。
    func openTerminal() {
        prepareShellEnv { lines in
            let port = self.engine.port ?? NetCaptureEnv.port
            let hello = "echo " + CaptureShellEnv.quote(L("netcapture.terminal.hello \(String(port))"))
            let command = (lines + [hello, "exec \"${SHELL:-/bin/zsh}\" -l"]).joined(separator: "\n")
            TerminalLauncher.run(command: command, in: nil)
        }
    }

    /// 把那几行 `export` 复制到剪贴板，贴进已经开着的终端用。
    func copyShellEnv() {
        prepareShellEnv { lines in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            self.banner = Banner(kind: .info, text: L("netcapture.terminal.copied"))
        }
    }

    /// 起引擎 + 写合并证书文件，然后把 `export` 行交给 `then`。
    private func prepareShellEnv(then: @escaping ([String]) -> Void) {
        ensureEngine { [weak self] in
            guard let self else { return }
            let port = self.engine.port ?? NetCaptureEnv.port
            DispatchQueue.global(qos: .userInitiated).async {
                let bundle = CaptureCA.shared.writeBundle()
                let caPath = CaptureCA.shared.certURL.path
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let bundle else {
                            self.banner = Banner(kind: .problem, text: L("netcapture.problem.bundle"))
                            return
                        }
                        then(CaptureShellEnv.exportLines(port: port, bundlePath: bundle.path, caPath: caPath))
                    }
                }
            }
        }
    }

    // MARK: - 模拟器

    /// 给已启动的 iOS 模拟器装根证书。模拟器的网络走这台 Mac 的系统代理，所以要「本机」开着；没开只提示，不替用户开。
    func installSimulatorCert() {
        guard working == nil else { return }
        guard macOn else {
            banner = Banner(kind: .info, text: L("netcapture.simulator.needsMac"))
            return
        }
        working = L("netcapture.working.simulator")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CaptureCA.shared.installIntoBootedSimulators()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.working = nil
                    self.banner = result.ok
                        ? Banner(kind: .info, text: L("netcapture.simulator.done"))
                        : Banner(kind: .problem, text: L("netcapture.simulator.failed \(result.message)"))
                }
            }
        }
    }

    /// 设置已启动的 Android 模拟器：代理指向 `10.0.2.2:<端口>`（模拟器里看这台 Mac 的回环）+ 推证书。只要引擎在跑。
    func setUpAndroidEmulators() {
        guard working == nil else { return }
        ensureEngine { [weak self] in
            guard let self else { return }
            self.working = L("netcapture.working.emulator")
            let port = self.engine.port ?? NetCaptureEnv.port
            DispatchQueue.global(qos: .userInitiated).async {
                let emulators = ADBController.adbPath() == nil
                    ? [] : ADBController.devices().filter { $0.serial.hasPrefix("emulator-") }
                let done = emulators.filter {
                    ADBController.setProxy(serial: $0.serial, ip: "10.0.2.2", port: port)
                        && ADBController.pushAndInstallCert(serial: $0.serial)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.working = nil
                        if emulators.isEmpty {
                            self.banner = Banner(kind: .problem, text: L("netcapture.emulator.none"))
                        } else if done.count == emulators.count {
                            self.banner = Banner(kind: .info, text: L("netcapture.phone.android.done"))
                        } else {
                            self.banner = Banner(kind: .problem, text: L("netcapture.phone.android.failed"))
                        }
                    }
                }
            }
        }
    }
}
