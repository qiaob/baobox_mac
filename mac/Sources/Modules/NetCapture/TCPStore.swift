import Foundation

/// 「TCP 包」页的数据（docs/packet-capture/CONTROL.md §4）。只在内存里；条数上限和 HTTP 列表用同一个设置。
/// 事件怎么落进来、协议怎么认在 Logic/TCPLog.swift；这里包一层给界面（`@Published`）和 MCP（线程安全快照）。
@MainActor
final class TCPStore: ObservableObject {
    static let shared = TCPStore()

    /// 旧 → 新；界面倒过来显示。
    @Published private(set) var connections: [TCPConnection] = []

    private var log = TCPLog()

    private init() {}

    /// 引擎推来的一批事件（与 TCP 无关的忽略）。
    func apply(_ events: [CaptureEvent]) {
        guard log.apply(events, maxConnections: NetCaptureEnv.maxFlows) else { return }
        connections = log.connections
        TCPSnapshotStore.shared.set(connections)
    }

    func clear() {
        log.removeAll()
        connections = []
        TCPSnapshotStore.shared.set([])
    }
}

extension TCPConnection {
    /// 来源设备（工具条的设备筛选、MCP 的 `device` 参数）。
    var deviceKey: String { client ?? NetCaptureEnv.unknownDeviceKey }

    /// 列表和筛选菜单里的协议名；认不出是 nil（显示「未知」）。
    var protocolLabel: String? { detected?.label }
}

/// 连接列表的线程安全快照，给 MCP 的连接队列读（同 `FlowSnapshotStore`）。
final class TCPSnapshotStore: @unchecked Sendable {
    static let shared = TCPSnapshotStore()
    private let lock = NSLock()
    private var connections: [TCPConnection] = []
    private init() {}

    func set(_ new: [TCPConnection]) { lock.lock(); connections = new; lock.unlock() }
    func get() -> [TCPConnection] { lock.lock(); defer { lock.unlock() }; return connections }
}
