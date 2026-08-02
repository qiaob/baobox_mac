import Foundation

/// 局域网传输 —— 传输记录。
///
/// 只在主线程写（`@MainActor`），会话线程通过 `DispatchQueue.main.async` 上报。
/// 记录只驻内存：服务停止即清空进行中的条目，已完成的保留到本次 App 生命周期结束，
/// 供菜单「最近接收」用。不落盘 —— 传输记录含文件名，属隐私信息，没有持久化的必要。
@MainActor
final class LanDropTransfers: ObservableObject {
    static let shared = LanDropTransfers()

    enum Status: Equatable {
        case receiving
        case done
        case failed(String)
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        let name: String
        /// 期望总字节数（来自 Content-Length）。
        let total: Int
        var received: Int
        var status: Status
        /// 落盘后的最终路径（完成后才有）。
        var path: String?
        let startedAt: Date

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(received) / Double(total))
        }
    }

    /// 最多保留的记录条数（含已完成）。
    private static let maxItems = 50

    @Published private(set) var items: [Item] = []

    private init() {}

    /// 是否有进行中的传输（自动关闭要看这个，不能在传一半时把服务停了）。
    var hasActive: Bool {
        items.contains { $0.status == .receiving }
    }

    var activeCount: Int {
        items.filter { $0.status == .receiving }.count
    }

    /// 进行中传输的整体进度（多文件时取字节加权）。无进行中返回 nil。
    var activeFraction: Double? {
        let active = items.filter { $0.status == .receiving }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(0) { $0 + $1.total }
        guard total > 0 else { return nil }
        let received = active.reduce(0) { $0 + $1.received }
        return min(1, Double(received) / Double(total))
    }

    // MARK: - 变更（全部主线程）

    func begin(id: UUID, name: String, total: Int) {
        items.insert(Item(id: id, name: name, total: total, received: 0,
                          status: .receiving, path: nil, startedAt: Date()),
                     at: 0)
        trim()
    }

    func update(id: UUID, received: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // 已结束的条目不再被迟到的进度回调改写。
        guard items[index].status == .receiving else { return }
        items[index].received = received
    }

    func finish(id: UUID, path: String, received: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].received = received
        items[index].status = .done
        items[index].path = path
    }

    func fail(id: UUID, reason: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status == .receiving else { return }
        items[index].status = .failed(reason)
    }

    /// 服务停止时调用：把仍在进行中的条目标记为中断（连接已随监听一起断掉）。
    func markActiveInterrupted(reason: String) {
        for index in items.indices where items[index].status == .receiving {
            items[index].status = .failed(reason)
        }
    }

    func clear() {
        items.removeAll()
    }

    private func trim() {
        guard items.count > Self.maxItems else { return }
        items.removeLast(items.count - Self.maxItems)
    }
}
