import Foundation

/// 抓包引擎：包内 `mitmdump` 子进程的启停与通信（docs/packet-capture/TECH_DESIGN.md §3）。
///
/// 开始抓包 = 起进程，停止 = 进程退出，关着的时候没有任何后台开销。进程带着桥脚本
/// （Resources/NetCapture/baobox_bridge.py）：它把每条请求从标准输出一行一个 JSON 推过来，
/// 这边从标准输入给它发指令。不开额外端口。
///
/// `state` 是「抓包是否在进行」的唯一事实源，窗口、菜单、MCP 都看它。变成 `failed`（起不来、意外退出、启动超时）时
/// `NetCaptureSession` 在它的订阅里把开关全部复位、还原系统代理。
@MainActor
final class NetCaptureEngine: ObservableObject {
    static let shared = NetCaptureEngine()

    enum State: Equatable {
        case stopped
        case starting
        case running(UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    /// 这次运行（或正在启动的这次）的监听组合；没在跑是 nil。变了就要重启（`restart`）。
    @Published private(set) var listeners: EngineListeners?
    /// 桥那边几个开关此刻的值（暂停、手动代理、本机 TCP、配置页端口）；变了发指令（`apply(flags:)`），不用重启。
    private(set) var flags = BridgeFlags()
    /// 连上来了、还在等用户点允许的局域网设备（来源 IP）。
    @Published private(set) var pendingDevices: [String] = []
    /// 引擎报告的版本号（就绪后才有）。
    @Published private(set) var engineVersion = ""
    /// 这次运行用的正文上限（设置改了要下次启动才生效；MCP 的 get_config 报此刻在用的值）。
    private(set) var runningBodyCap: Int?

    /// 用户允许过的设备。只在这次 App 运行期间有效，不存盘；引擎重启（切换监听范围）时带过去。
    private var allowedDevices: Set<String> = []

    var isRunning: Bool { if case .running = state { return true }; return false }
    /// 正在启动或已在运行：这时再点开始什么也不做。
    var isActive: Bool {
        switch state {
        case .starting, .running: return true
        case .stopped, .failed: return false
        }
    }

    /// 当前监听的端口；没在运行时为 nil。
    var port: UInt16? { if case .running(let port) = state { return port }; return nil }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var reader: EngineOutputReader?
    /// 每次启动加一。旧进程的回调晚到时靠它认出来、丢掉。
    private var generation = 0

    /// 等引擎就绪的上限。正常约 1 秒。
    private static let startTimeout: TimeInterval = 8

    private init() {}

    // MARK: - 启停

    /// 启动引擎。已经在启动或运行就忽略（要换监听组合，用 `restart`）。
    func start(listeners: EngineListeners, flags: BridgeFlags) {
        guard !isActive else { return }
        guard NetCaptureEnv.engineUnavailable == nil, let script = NetCaptureEnv.bridgeScriptURL else {
            state = .failed(L("netcapture.error.engineMissing"))
            return
        }
        generation += 1
        let current = generation
        self.listeners = listeners
        self.flags = flags
        pendingDevices = []
        state = .starting

        // 证书要在引擎第一次启动之前就按 Baobox 的名字做好，否则引擎会自己生成一张叫 mitmproxy 的
        // （`CaptureCA.ensureGenerated`）。只有头一次会走后台这一支，多等约 1 秒。
        if CaptureCA.shared.isGenerated {
            launch(script: script, generation: current)
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                CaptureCA.shared.ensureGenerated()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.generation == current, self.state == .starting else { return }
                        self.launch(script: script, generation: current)
                    }
                }
            }
        }
    }

    private func launch(script: URL, generation current: Int) {
        guard let listening = listeners else { return }
        let confDir = NetCaptureEnv.engineConfDir
        try? FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        let bodyCap = NetCaptureEnv.bodyCap
        runningBodyCap = bodyCap

        let process = Process()
        process.executableURL = NetCaptureEnv.engineURL
        // 监听：HTTP 代理（听本机或局域网）、只听本机的 SOCKS5、开着时每台 WireGuard 设备一个（docs/packet-capture/CONTROL.md §2.1）。
        process.arguments = listening.modeArguments + [
            "--set", "confdir=\(confDir.path)",
            // 超过上限的正文直接流过去，不在引擎里攒着；这样的请求标「已截断」。
            "--set", "stream_large_bodies=\(bodyCap)",
            // -q：引擎自己不往标准输出写东西，那里只走桥的事件。
            "-q",
            "-s", script.path,
            "--set", "baobox_body_cap=\(bodyCap)",
            "--set", "baobox_scope=\(NetCaptureEnv.decryptScope.json)",
            "--set", "baobox_allowed=\(allowedDevices.sorted().joined(separator: ","))",
            // 隧道里的设备访问 Mac 用的是它的局域网地址：桥据此认出「发给这台 Mac 自己的」（配置页、证书检测）。
            "--set", "baobox_lan_ip=\(NetworkInterfaces.primaryIP())",
        ] + flags.optionArguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let reader = EngineOutputReader { [weak self] events in
            self?.handle(events, generation: current)
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            reader.consume(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            reader.consumeError(handle.availableData)
        }
        process.terminationHandler = { [weak self] finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let message = reader.errorTail()
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.processDidExit(generation: current, status: status, message: message)
                }
            }
        }

        do {
            try process.run()
        } catch {
            listeners = nil
            state = .failed(error.localizedDescription)
            return
        }
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.reader = reader

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current, self.state == .starting else { return }
                self.teardown()
                self.listeners = nil
                self.state = .failed(L("netcapture.error.engineTimeout"))
            }
        }
    }

    /// 停止引擎：发 `shutdown`，1 秒没退就结束进程。状态立刻变成已停止。
    func stop() {
        guard process != nil || state != .stopped else { return }
        teardown()
        pendingDevices = []
        listeners = nil
        state = .stopped
    }

    /// 换监听组合：停了再起（约 1 秒）。允许过的设备、暂停与否（在 `flags` 里）都带过去；列表不动。
    func restart(listeners: EngineListeners, flags: BridgeFlags) {
        teardown()
        state = .stopped
        start(listeners: listeners, flags: flags)
    }

    /// 桥的开关变了：只发变了的那几条指令。还在启动时也不会丢：进程还没起（在等证书生成）时，起的时候用的就是新值；
    /// 已经起了、桥还没开始读，指令在管道里等着，桥就绪后按顺序读到。
    func apply(flags next: BridgeFlags) {
        let commands = flags.commands(toReach: next)
        flags = next
        commands.forEach(send)
    }

    /// 结束当前进程并让它的回调作废。
    private func teardown() {
        generation += 1
        guard let process else { return }
        if let stdinHandle {
            // 先礼后兵：shutdown 指令 + 关管道（桥读到结束也会自己退）。
            try? stdinHandle.write(contentsOf: CaptureCommand.shutdown.line)
            try? stdinHandle.close()
        }
        self.process = nil
        self.stdinHandle = nil
        self.reader = nil
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if process.isRunning { process.terminate() }
        }
    }

    /// App 退出时用：不等，直接结束进程。
    func terminateNow() {
        generation += 1
        if let stdinHandle { try? stdinHandle.close() }
        if let process, process.isRunning { process.terminate() }
        process = nil
        stdinHandle = nil
        reader = nil
        listeners = nil
        state = .stopped
    }

    private func processDidExit(generation finished: Int, status: Int32, message: String) {
        // 我们自己叫停的（generation 已经变了）不算意外。
        guard finished == generation else { return }
        process = nil
        stdinHandle = nil
        reader = nil
        pendingDevices = []
        let detail = Self.explain(message, port: listeners?.port ?? NetCaptureEnv.port)
        listeners = nil
        state = .failed(detail.isEmpty ? L("netcapture.error.engineExited \(Int(status))") : detail)
    }

    /// 把引擎的报错翻成人话。认得的只有「端口被占」，其余原样给最后一行。
    private static func explain(_ stderr: String, port: UInt16) -> String {
        let lower = stderr.lowercased()
        if lower.contains("address already in use") || lower.contains("errno 48") {
            // 引擎开了两个端口（代理、SOCKS），报错里写着是哪一个；认不出来就说代理端口。
            // 端口号当字符串传：按数字格式化会带千分位（「9,090」）。
            let busy = CaptureEngineLog.busyPort(in: stderr) ?? port
            return L("netcapture.error.portInUse \(String(busy))")
        }
        // 认不出来的：给第一行（引擎把具体原因放在前面，最后一行只是「启动出错，退出」）。
        return stderr.split(separator: "\n").first.map(String.init) ?? ""
    }

    // MARK: - 指令

    /// 给引擎发一条指令。没在运行就丢掉。
    func send(_ command: CaptureCommand) {
        guard let stdinHandle else { return }
        try? stdinHandle.write(contentsOf: command.line)
    }

    /// 设置里的解密范围变了，告诉正在跑的引擎。
    func applyScopeFromSettings() {
        send(.scope(NetCaptureEnv.decryptScope))
    }

    func allow(device ip: String) {
        allowedDevices.insert(ip)
        pendingDevices.removeAll { $0 == ip }
        send(.allowDevice(ip))
    }

    func deny(device ip: String) {
        allowedDevices.remove(ip)
        pendingDevices.removeAll { $0 == ip }
        send(.denyDevice(ip))
    }

    // MARK: - 事件

    private func handle(_ events: [CaptureEvent], generation eventGeneration: Int) {
        guard eventGeneration == generation else { return }
        for event in events {
            switch event {
            case .running(let version):
                engineVersion = version
                // 引擎每次起来都是空的 Mock 规则表：先把规则发过去，再让等着就绪的事（重发…）去跑。
                MockRuleStore.shared.pushToEngine()
                if state == .starting, let listeners { state = .running(listeners.port) }
            case .device(let client):
                guard !allowedDevices.contains(client), !pendingDevices.contains(client) else { continue }
                pendingDevices.append(client)
                NetCaptureSession.shared.announcePendingDevice(client)
            case .replayFailed(let id, let message):
                NetCaptureSession.shared.replayDidFail(id: id, message: message)
            default:
                continue
            }
        }
        FlowStore.shared.apply(events)
        TCPStore.shared.apply(events)
        // 配置页 WireGuard 设备的「最近活动」：要在两个列表落完之后看（响应、TCP 数据靠它们找回是哪台）。
        WireGuardDeviceStore.shared.noteActivity(events)
    }
}

// MARK: - 读引擎输出

/// 在管道的回调线程上把字节切成行、解成事件，攒一小批再回主线程交出去（约定 1：`@Published` 只在主线程写）。
/// 攒批：主线程还没来得及取走上一批时，新事件接着往同一批里放，流量大的时候自然合并。
private final class EngineOutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = CaptureLineBuffer()
    private var pending: [CaptureEvent] = []
    private var flushScheduled = false
    private var errorText = ""
    private let deliver: @MainActor ([CaptureEvent]) -> Void

    init(deliver: @escaping @MainActor ([CaptureEvent]) -> Void) {
        self.deliver = deliver
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let prefix = Data(CaptureEvent.linePrefix.utf8)
        for line in buffer.append(data) {
            if let event = CaptureEvent.parse(line: line) {
                pending.append(event)
            } else if line.prefix(prefix.count) != prefix, let text = String(data: line, encoding: .utf8) {
                // 不是事件行：引擎自己的日志。-q 下只有出错才会有（比如端口被占），而且是打在标准输出上的，
                // 留着给异常退出时说明原因。
                appendError(text + "\n")
            }
        }
        let schedule = !pending.isEmpty && !flushScheduled
        if schedule { flushScheduled = true }
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.flush() }
        }
    }

    @MainActor
    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        if !batch.isEmpty { deliver(batch) }
    }

    /// 标准错误：引擎异常退出时拿来说明原因。
    func consumeError(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        appendError(text)
        lock.unlock()
    }

    /// 只留最后 4 KB。调用方已持锁。
    private func appendError(_ text: String) {
        errorText += text
        if errorText.count > 4096 { errorText = String(errorText.suffix(4096)) }
    }

    func errorTail() -> String {
        lock.lock(); defer { lock.unlock() }
        return errorText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
