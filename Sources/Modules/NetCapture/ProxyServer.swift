import Foundation
import Network

/// 代理主体：`NWListener` 监听所有接口、为每个连接构造 `ProxyConnection`、管理生命周期。
///
/// 关闭 = 彻底停：`listener.cancel()`、取消所有活动连接、还原系统代理、清空 flow 缓冲、
/// 停 MCP（由 Tool 壳协调）、释放 identity 缓存。关闭后无任何后台线程/监听存活（关闭态零开销）。
@MainActor
final class ProxyServer: ObservableObject {
    static let shared = ProxyServer()

    enum State: Equatable {
        case stopped
        case starting
        case running(UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.baobox.netcapture.proxy")
    private let registry = ConnectionRegistry()

    var isRunning: Bool { if case .running = state { return true }; return false }

    private init() {}

    // MARK: - 启停

    /// 启动代理监听。已在运行则忽略。绑所有接口便于手机连。
    func start(port: UInt16) {
        guard case .running = state else {
            beginStart(port: port)
            return
        }
    }

    private func beginStart(port: UInt16) {
        state = .starting
        // 预生成 CA（后台），保证首个 HTTPS 连接不必等冷启。
        queue.async { MITMCertAuthority.shared.ensureCA() }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 不设 requiredLocalEndpoint → 绑所有接口（0.0.0.0），手机用局域网 IP 直连。
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort) else {
            state = .failed(L("netcapture.error.listenFailed"))
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] newState in
            // Network 队列回调 → 回主线程改 @Published。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch newState {
                    case .ready:
                        self.state = .running(port)
                        // 开启 Mac 本地抓包（若设置开）：把系统代理指向本机。后台执行。
                        if NetCaptureEnv.autoSystemProxy {
                            self.queue.async { SystemProxyController.enable(port: port) }
                        }
                    case .failed(let error):
                        self.state = .failed("\(error)")
                        self.stop()
                    default:
                        break
                    }
                }
            }
        }

        listener.newConnectionHandler = { [weak self] nwConnection in
            guard let self else { nwConnection.cancel(); return }
            let connection = ProxyConnection(client: nwConnection,
                                             queue: DispatchQueue(label: "com.baobox.netcapture.conn"),
                                             ca: MITMCertAuthority.shared) { [weak self] finished in
                self?.registry.remove(finished)
            }
            self.registry.add(connection)
            connection.start()
        }

        listener.start(queue: queue)
    }

    /// 停止：取消监听与所有连接，还原系统代理，释放缓冲与 identity 缓存。
    func stop() {
        listener?.cancel()
        listener = nil
        registry.cancelAll()
        // 还原系统代理（后台）。
        queue.async {
            SystemProxyController.restore()
            MITMCertAuthority.shared.flushMemoryCache()
        }
        if NetCaptureEnv.clearOnStop {
            FlowStore.shared.clear()
        }
        state = .stopped
    }
}

// MARK: - 活动连接登记

/// 线程安全的活动连接登记表。持强引用保活；连接完成时自行移除；`cancelAll` 供停止时清场。
final class ConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]

    func add(_ connection: ProxyConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
    }

    func remove(_ connection: ProxyConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let all = Array(connections.values)
        connections.removeAll(keepingCapacity: false)
        lock.unlock()
        for connection in all { connection.cancel() }
    }
}
