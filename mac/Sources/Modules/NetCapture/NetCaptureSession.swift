import AppKit
import Combine
import Foundation

/// 抓包的场景协调（docs/packet-capture/REQUIREMENTS.md §3、TECH_DESIGN.md §6）。
///
/// 用户点的是「我要抓这台 Mac / 抓手机 / 抓终端 / 抓模拟器」，这里把每个场景背后的配置做掉：
/// 起引擎、装证书、指系统代理、开局域网监听、开配置页。停止时逐个还原。
/// 引擎本身的启停在 `NetCaptureEngine`；窗口、菜单、MCP 都从这里进。
@MainActor
final class NetCaptureSession: ObservableObject {
    static let shared = NetCaptureSession()

    /// 窗口顶部的一条提示（成功或失败），用户点 × 关掉。
    struct Banner: Equatable {
        enum Kind { case info, problem }
        var kind: Kind
        var text: String
    }

    /// 「这台 Mac」是否开着：系统代理正指向引擎。
    @Published private(set) var macCaptureOn = false
    /// 手机配置页是否开着（与引擎的局域网监听同开同关）。
    @Published private(set) var phonePageOn = false
    /// 正在做一件要等的事（装证书、起引擎…）时的说明，窗口据此显示进度、禁用按钮。
    @Published private(set) var working: String?
    @Published var banner: Banner?
    /// CA 是否已被这台 Mac 信任（`refreshTrust` 更新）。
    @Published private(set) var caTrusted = false

    private let engine = NetCaptureEngine.shared
    /// 等引擎就绪后要做的事；引擎起不来就丢掉。
    private var whenRunning: [() -> Void] = []
    private var stateSink: AnyCancellable?

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
            DispatchQueue.main.async { MainActor.assumeIsolated { actions.forEach { $0() } } }
        case .failed(let message):
            whenRunning = []
            working = nil
            banner = Banner(kind: .problem, text: message)
        case .stopped, .starting:
            break
        }
    }

    // MARK: - 开始 / 停止

    /// 窗口上的「开始」：照上次的来。上次抓的是这台 Mac（也是第一次的默认）就走 `startMac`，否则只起引擎。
    func start() {
        let lastMac = UserDefaults.standard.object(forKey: NetCaptureEnv.Keys.lastMacCapture) as? Bool ?? true
        if lastMac { startMac() } else { ensureEngine {} }
    }

    /// MCP 的 `start_capture`：证书已受信就照「这台 Mac」来，否则只起引擎（不弹密码框）。
    func startFromAutomation() {
        guard !engine.isActive else { return }
        startMac(interactive: false, engineOnlyIfUntrusted: true)
    }

    /// 全部停下：引擎退出、系统代理还原、配置页关掉。列表是否清空看设置。
    func stopAll() {
        whenRunning = []
        working = nil
        engine.stop()
        ConfigPageServer.shared.stop()
        phonePageOn = false
        if macCaptureOn {
            macCaptureOn = false
            DispatchQueue.global(qos: .userInitiated).async { SystemProxyController.restore() }
        }
        if NetCaptureEnv.clearOnStop { FlowStore.shared.clear() }
    }

    /// App 退出：同步收尾，不留进程、不留指向自己的系统代理。
    func terminate() {
        engine.terminateNow()
        ConfigPageServer.shared.stop()
        SystemProxyController.restore()
    }

    /// 引擎自己退了（崩溃、端口被占、启动超时）：系统代理不能再指着它，否则整机断网。
    func engineDidStopUnexpectedly() {
        whenRunning = []
        working = nil
        ConfigPageServer.shared.stop()
        phonePageOn = false
        macCaptureOn = false
        DispatchQueue.global(qos: .userInitiated).async { SystemProxyController.restore() }
    }

    /// 引擎没在跑就只起引擎（**不动系统代理**），就绪后执行 `then`；已经在跑就直接执行。
    /// 重发用它（docs/packet-capture/TOOLS.md §3）；各个场景的开始也都先走这里。
    func ensureEngine(lan: Bool? = nil, then: @escaping () -> Void) {
        if engine.isRunning {
            then()
            return
        }
        whenRunning.append(then)
        if !engine.isActive {
            working = L("netcapture.working.starting")
            whenRunning.append { [weak self] in self?.working = nil }
            // 用过手机配置之后，每次开始都连手机一起：听局域网、开配置页。
            if NetCaptureEnv.phoneEnabled, !phonePageOn {
                phonePageOn = true
                startPhonePage()
            }
            engine.start(port: NetCaptureEnv.port, lan: lan ?? phonePageOn)
        }
    }

    // MARK: - 重发（TOOLS.md §3）

    /// 让引擎把这条请求再发一次。引擎没在跑就先只起引擎，就绪后再发。
    /// 发出去的请求是列表里新的一行，id 就是 `request.id`（调用方据此先选中它）。
    func replay(_ request: ReplayRequest) {
        ensureEngine { [weak self] in self?.engine.send(.replay(request)) }
    }

    /// 引擎说重发没发出去（URL 不合法等）：顶部提示条显示原因。
    func replayDidFail(id: UUID?, message: String) {
        let reason = message.isEmpty ? L("netcapture.replay.failedUnknown") : message
        banner = Banner(kind: .problem, text: L("netcapture.replay.failed \(reason)"))
    }

    // MARK: - 这台 Mac

    /// 抓这台 Mac：CA 没被信任就先装（`interactive` 时会弹管理员密码框），再起引擎、把系统代理指过去。
    /// 证书没装成就不动系统代理 —— 否则本机所有 HTTPS 都会报证书错误。
    func startMac(interactive: Bool = true, engineOnlyIfUntrusted: Bool = false) {
        guard !macCaptureOn, working == nil else { return }
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
                            return
                        }
                        self.reportCertFailure(outcome)
                        return
                    }
                    self.banner = nil
                    self.ensureEngine { [weak self] in self?.pointSystemProxyAtEngine() }
                }
            }
        }
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

    private func pointSystemProxyAtEngine() {
        guard let port = engine.port else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            SystemProxyController.enable(port: port, socksPort: EngineListeners.neighbour(of: port, offset: 2))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.macCaptureOn = true
                    UserDefaults.standard.set(true, forKey: NetCaptureEnv.Keys.lastMacCapture)
                }
            }
        }
    }

    /// 不再抓这台 Mac：系统代理还原。引擎继续跑（可能还在抓手机或终端）。
    func stopMac() {
        guard macCaptureOn else { return }
        macCaptureOn = false
        UserDefaults.standard.set(false, forKey: NetCaptureEnv.Keys.lastMacCapture)
        DispatchQueue.global(qos: .userInitiated).async { SystemProxyController.restore() }
    }

    // MARK: - 手机与平板

    /// 开 / 关局域网监听。引擎的监听地址只能在启动时定，所以已在跑就重启一次（约 1 秒；系统代理指的端口不变）。
    /// 同时开 / 关手机配置页（装证书、配代理用的那个网页）。
    /// 用户不用自己开这个开关：打开手机配置（二维码 / Android 设备）时调 `setLAN(true)`，并记下来，
    /// 以后每次开始抓包都听局域网（见 `ensureEngine`）。关只在设置页（`setPhoneAllowed(false)`）。
    func setLAN(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: NetCaptureEnv.Keys.phoneEnabled)
        guard on != phonePageOn || on != engine.lanEnabled else { return }
        phonePageOn = on
        if on {
            startPhonePage()
        } else {
            ConfigPageServer.shared.stop()
        }
        if engine.isActive {
            guard engine.lanEnabled != on else { return }
            engine.restart(port: NetCaptureEnv.port, lan: on)
        } else if on {
            ensureEngine(lan: true) {}
        }
    }

    /// 设置页的「允许手机和平板连接」：记下来；引擎正在跑就立刻生效（重启一次引擎），没在跑就等下次开始。
    func setPhoneAllowed(_ on: Bool) {
        if engine.isActive {
            setLAN(on)
        } else {
            UserDefaults.standard.set(on, forKey: NetCaptureEnv.Keys.phoneEnabled)
        }
    }

    private func startPhonePage() {
        ConfigPageServer.shared.start(port: NetCaptureEnv.configPagePort)
        DispatchQueue.global(qos: .userInitiated).async { CaptureCA.shared.ensureGenerated() }
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

    // MARK: - iOS 模拟器

    /// 给已启动的 iOS 模拟器装根证书。模拟器的网络走这台 Mac，所以随后把「这台 Mac」也开起来。
    func installSimulatorCert() {
        guard working == nil else { return }
        working = L("netcapture.working.simulator")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CaptureCA.shared.installIntoBootedSimulators()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.working = nil
                    if result.ok {
                        self.banner = Banner(kind: .info, text: L("netcapture.simulator.done"))
                        self.startMac()
                    } else {
                        self.banner = Banner(kind: .problem,
                                             text: L("netcapture.simulator.failed \(result.message)"))
                    }
                }
            }
        }
    }

    // MARK: - 证书状态

    /// 重新查一次 CA 的信任状态（窗口出现时、装 / 移除之后调）。
    func refreshTrust() {
        DispatchQueue.global(qos: .utility).async {
            let trusted = CaptureCA.shared.isGenerated && CaptureCA.shared.isTrusted()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.caTrusted = trusted } }
        }
    }

    /// 单独点「安装证书」（窗口右上角、设置页）。
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
}
