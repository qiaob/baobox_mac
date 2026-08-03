import Foundation

/// 一台已配对的设备。
struct LanDropDevice: Identifiable, Sendable, Equatable {
    /// 设备凭证。**只在配对那一次经 302 与 cookie 下发，从不出现在二维码里。**
    let id: String
    let ip: String
    let pairedAt: Date
}

/// 局域网传输 —— 访问控制（权威状态，线程安全）。
///
/// ## 为什么不是「二维码里放一个长期访问码」
///
/// 长期码只要服务还开着就一直有效：二维码被拍照、被转发、被别人瞟一眼记下，
/// 之后随时可以用。加再多 URL 参数也不解决这个问题——参数多寡与强度无关。
///
/// 所以改成**配对制**：
///
/// ```
/// 二维码  →  http://ip:port/?p=<配对码>      配对码：一次性、2 分钟内有效
///          ↓ 首次访问
///        服务端校验 → 作废该配对码 → 颁发设备凭证（302 + cookie）→ 立刻换一个新配对码
///          ↓
/// 之后所有请求  →  ?k=<设备凭证> 或 cookie，并（默认）校验来源 IP 与配对时一致
/// ```
///
/// 于是：
/// - 二维码被拍下 → 只要已被人扫过一次就作废，别人再扫是 404；
/// - 拍下但没人用 → 2 分钟后自动作废；
/// - 拿到别人的设备凭证 → IP 对不上照样 404；
/// - 「换一个码」「断开所有设备」是随时可用的急停。
///
/// 配对码用掉后**自动换新**，所以给第二台设备扫码不需要任何额外操作。
///
/// ## 并发
///
/// 会话要在自己的连接队列上同步校验，故权威状态放在这个 `NSLock` 保护的类里
/// （照 `FlowSnapshotStore` 的先例），UI 那份是 `LanDropAccess` 的只读镜像。
final class LanDropAccessStore: @unchecked Sendable {
    static let shared = LanDropAccessStore()

    /// 配对码有效期：够扫码 + 打开浏览器，又短到拍照转发基本来不及。
    static let pairTTL: TimeInterval = 120

    private let lock = NSLock()
    private var pairCode: String?
    private var pairIssuedAt = Date.distantPast
    private var devices: [LanDropDevice] = []
    private var bindIP = true
    private var running = false

    /// 状态变化时回调（换码 / 新设备 / 断开）。由 `LanDropServer` 接到主线程去刷新 UI 与发通知。
    var onChange: (@Sendable (String?) -> Void)?

    private init() {}

    // MARK: - 生命周期

    /// 服务启动：签发第一个配对码，清空历史设备。
    func start(bindIP: Bool) {
        lock.lock()
        self.bindIP = bindIP
        self.running = true
        self.devices = []
        self.pairCode = LanDropEnv.randomID(length: 16)
        self.pairIssuedAt = Date()
        lock.unlock()
        onChange?(nil)
    }

    /// 服务停止：配对码与所有设备凭证一并作废。
    func stop() {
        lock.lock()
        running = false
        pairCode = nil
        pairIssuedAt = .distantPast
        devices = []
        lock.unlock()
        onChange?(nil)
    }

    /// 手动换码：旧码立即作废（二维码随之刷新）。
    func rotatePairCode() {
        lock.lock()
        guard running else { lock.unlock(); return }
        pairCode = LanDropEnv.randomID(length: 16)
        pairIssuedAt = Date()
        lock.unlock()
        onChange?(nil)
    }

    /// 断开所有已配对设备（凭证立即失效，手机需重新扫码）。
    func disconnectAll() {
        lock.lock()
        devices = []
        lock.unlock()
        onChange?(nil)
    }

    // MARK: - 查询（供 UI / 二维码）

    /// 当前有效的配对码；已过期返回 nil。
    var currentPairCode: String? {
        lock.lock(); defer { lock.unlock() }
        guard running, let code = pairCode,
              Date().timeIntervalSince(pairIssuedAt) < Self.pairTTL else { return nil }
        return code
    }

    /// 配对码剩余有效秒数（过期或未运行为 0）。
    var pairRemaining: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard running, pairCode != nil else { return 0 }
        return max(0, Self.pairTTL - Date().timeIntervalSince(pairIssuedAt))
    }

    var deviceSnapshot: [LanDropDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices
    }

    // MARK: - 校验（供会话，任意线程）

    /// 消费配对码，颁发设备凭证。
    ///
    /// 校验不通过（码不对 / 已被用掉 / 已过期 / 服务未运行）一律返回 nil，调用方回 404。
    /// 成功后**立刻签发新的配对码**——否则第二台设备就没码可扫了。
    func consumePair(code: String, ip: String?) -> String? {
        lock.lock()
        guard running, let expected = pairCode,
              Date().timeIntervalSince(pairIssuedAt) < Self.pairTTL,
              LanDropAccessStore.constantTimeEqual(code, expected) else {
            lock.unlock()
            return nil
        }
        let device = LanDropDevice(id: LanDropEnv.randomID(length: 32),
                                   ip: ip ?? "",
                                   pairedAt: Date())
        devices.append(device)
        // 一次性：用掉即换新码。
        pairCode = LanDropEnv.randomID(length: 16)
        pairIssuedAt = Date()
        lock.unlock()
        onChange?(device.ip)
        return device.id
    }

    /// 校验设备凭证。开启 IP 绑定时，来源 IP 必须与配对时一致。
    func authorize(token: String, ip: String?) -> Bool {
        guard !token.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        guard running else { return false }
        guard let device = devices.first(where: { LanDropAccessStore.constantTimeEqual($0.id, token) }) else {
            return false
        }
        guard bindIP else { return true }
        // 绑定开启但配对时没取到 IP（极少见）：不因此把用户挡在门外。
        guard !device.ip.isEmpty, let ip, !ip.isEmpty else { return true }
        return device.ip == ip
    }

    /// 全量比较（不短路），避免按前缀逐字节试探的时序侧信道。
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }
}

/// 访问控制的 UI 镜像：菜单与面板观察它，权威状态在 `LanDropAccessStore`。
@MainActor
final class LanDropAccess: ObservableObject {
    static let shared = LanDropAccess()

    @Published private(set) var pairCode: String?
    @Published private(set) var devices: [LanDropDevice] = []

    private init() {}

    /// 从权威存储拉一次快照。由 `LanDropServer` 在状态变化时调用（已在主线程）。
    func refresh() {
        pairCode = LanDropAccessStore.shared.currentPairCode
        devices = LanDropAccessStore.shared.deviceSnapshot
    }
}
