import AppKit
import Foundation
import Network

/// 局域网传输 —— 接收服务。唯一事实源：菜单与设置页都观察本单例。
///
/// 关闭 = 彻底停：`listener.cancel()`、掐断所有在途连接、token 作废、取消空闲排程。
/// 关闭后无任何监听 / 线程存活（同 NetCapture 的「关闭态零开销」原则）。
@MainActor
final class LanDropServer: ObservableObject {
    static let shared = LanDropServer()

    enum State: Equatable {
        case stopped
        case starting
        case running(UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.baobox.landrop.listener")
    private let registry = LanDropSessionRegistry()

    /// 本次会话的访问码；停止即作废。只驻内存，不落盘。
    private(set) var token: String = ""

    private var lastActivity = Date()
    /// 排程代次：stop / restart 后旧的到期检查凭此失效。
    private var generation = 0
    /// 是否已有一次到期检查在路上（保证同时最多一个，不随上传进度堆积任务）。
    private var idleCheckPending = false
    private var sleepObservers: [NSObjectProtocol] = []

    private init() {}

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// 当前监听端口（未运行为 nil）。
    var runningPort: UInt16? {
        if case .running(let port) = state { return port }
        return nil
    }

    /// 手机要访问的地址（含访问码）。未运行返回 nil。
    var shareURL: String? {
        guard let port = runningPort else { return nil }
        return "http://\(NetworkInterfaces.primaryIP()):\(port)/?k=\(token)"
    }

    /// 不含访问码的地址，仅供展示 / 复制排查用。
    var displayAddress: String? {
        guard let port = runningPort else { return nil }
        return "\(NetworkInterfaces.primaryIP()):\(port)"
    }

    // MARK: - 启停

    /// 空闲自动关闭的截止时刻（`nil` = 不自动关或未运行）。菜单据此显示剩余时间。
    var autoStopAt: Date? {
        let timeout = LanDropEnv.idleTimeout
        guard isRunning, timeout > 0 else { return nil }
        return lastActivity.addingTimeInterval(timeout)
    }

    func toggle() {
        if isRunning || state == .starting {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard case .stopped = stateOrFailedReset() else { return }

        // 保存目录不可写时不开服务——总比手机传了半天才发现落不了盘强。
        guard LanDropEnv.ensureSaveDirectory() != nil else {
            state = .failed(L("landrop.error.saveDirUnwritable"))
            return
        }

        token = Self.makeToken()
        state = .starting
        LanDropNotify.requestAuthorizationIfNeeded()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 不设 requiredLocalEndpoint → 绑所有接口，手机才连得上。
        let desired = LanDropEnv.port
        let listener: NWListener
        if let nwPort = NWEndpoint.Port(rawValue: desired), let made = try? NWListener(using: params, on: nwPort) {
            listener = made
        } else if let fallback = try? NWListener(using: params) {
            // 端口被占 → 交给系统分配。地址与二维码都按实际端口现算，对用户透明。
            listener = fallback
        } else {
            state = .failed(L("landrop.error.listenFailed"))
            return
        }
        self.listener = listener

        let config = LanDropSession.Config(token: token,
                                           saveDir: LanDropEnv.saveDirectoryURL,
                                           maxFileSize: LanDropEnv.maxFileSize)
        listener.newConnectionHandler = { [registry] connection in
            LanDropSession(connection: connection, config: config, registry: registry).start()
        }
        listener.stateUpdateHandler = { [weak self] newState in
            // Network 队列回调 → 回主线程改 @Published。
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch newState {
                    case .ready:
                        let port = listener.port?.rawValue ?? desired
                        self.state = .running(port)
                        self.noteActivity()
                        self.installSleepObservers()
                    case .failed(let error):
                        self.state = .failed("\(error)")
                        self.teardown()
                    case .cancelled:
                        if self.isRunning { self.state = .stopped }
                    default:
                        break
                    }
                }
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        teardown()
        state = .stopped
    }

    /// 「全部完成后自动关闭」：由会话在每个文件落盘后调用。
    func stopIfDoneAndConfigured() {
        guard LanDropEnv.stopWhenDone, isRunning, !LanDropTransfers.shared.hasActive else { return }
        stop()
    }

    private func teardown() {
        generation += 1   // 在路上的到期检查凭此失效
        removeSleepObservers()
        registry.cancelAll()
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        token = ""
        LanDropTransfers.shared.markActiveInterrupted(reason: L("landrop.error.interrupted"))
    }

    /// `.failed` 是终态展示用的，再次点开关时要能从失败态重新开始。
    private func stateOrFailedReset() -> State {
        if case .failed = state {
            state = .stopped
        }
        return state
    }

    // MARK: - 活动与空闲自动关闭

    /// 新连接、收到字节、传输完成时调用，刷新空闲计时。会话线程 hop 到主线程后调用。
    ///
    /// 只刷新时间戳、不重排任务：上传中每 0.2 秒就会来一次，重排会把主队列塞满几千个待执行任务。
    /// 真正的判断留给已排在路上的那一次检查——它到点时按最新的 `lastActivity` 决定是关还是续排。
    func noteActivity() {
        lastActivity = Date()
        guard isRunning else { return }
        scheduleIdleCheck()
    }

    /// 排一次到期检查（同时最多一个）。项目里没有 `Timer` 的先例，用 `asyncAfter` + 代次校验实现同等效果。
    private func scheduleIdleCheck() {
        let timeout = LanDropEnv.idleTimeout
        guard timeout > 0, !idleCheckPending else { return }
        idleCheckPending = true

        let token = generation
        let delay = max(1, lastActivity.addingTimeInterval(timeout).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.idleCheckFired(generation: token)
            }
        }
    }

    private func idleCheckFired(generation token: Int) {
        idleCheckPending = false
        guard token == generation, isRunning else { return }
        let timeout = LanDropEnv.idleTimeout
        guard timeout > 0 else { return }

        // 传输进行中绝不关（哪怕已超时）——正在传的文件优先于空闲策略。
        if LanDropTransfers.shared.hasActive {
            lastActivity = Date()
            scheduleIdleCheck()
            return
        }
        if Date().timeIntervalSince(lastActivity) >= timeout {
            stop()
        } else {
            scheduleIdleCheck()   // 期间有过活动 → 按新的 lastActivity 续排
        }
    }

    // MARK: - 睡眠 / 锁屏自动关闭

    private func installSleepObservers() {
        guard sleepObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    LanDropServer.shared.stop()
                }
            }
            sleepObservers.append(observer)
        }
    }

    private func removeSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers { center.removeObserver(observer) }
        sleepObservers.removeAll()
    }

    // MARK: - 访问码

    /// 32 字符 URL-safe 随机串。
    private static func makeToken() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in
            alphabet[Int(generator.next(upperBound: UInt64(alphabet.count)))]
        })
    }
}
