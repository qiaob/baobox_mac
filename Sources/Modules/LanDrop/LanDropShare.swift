import Foundation

/// 一个被显式分享给手机的文件。
///
/// `id` 是随机句柄：手机侧从头到尾**只见得到它**，见不到任何路径。下载请求带 id 而非路径，
/// 于是「路径穿越」这类问题在协议层面就不存在——服务端根本不接受路径输入。
struct LanDropSharedItem: Identifiable, Sendable, Equatable {
    let id: String
    let url: URL
    let name: String
    let size: Int
}

/// 分享列表的线程安全快照：会话在连接队列上读。
/// 照 `FlowSnapshotStore` 的先例——`@MainActor` 那份供 UI，这份供后台。
final class LanDropShareSnapshot: @unchecked Sendable {
    static let shared = LanDropShareSnapshot()
    private let lock = NSLock()
    private var items: [LanDropSharedItem] = []
    private init() {}

    func set(_ newItems: [LanDropSharedItem]) {
        lock.lock(); items = newItems; lock.unlock()
    }

    func get() -> [LanDropSharedItem] {
        lock.lock(); defer { lock.unlock() }; return items
    }

    /// 按句柄取。取不到（已移除 / 服务已停）返回 nil，调用方回 404。
    func item(id: String) -> LanDropSharedItem? {
        lock.lock(); defer { lock.unlock() }
        return items.first { $0.id == id }
    }
}

/// 局域网传输 —— Mac → 手机方向的分享列表。
///
/// **只暴露用户拖进来（或显式选中）的文件**，绝不提供目录浏览：服务端没有「列目录」「按路径读」
/// 的路由，手机能拿到的就是这份列表里的东西。停止服务即清空，句柄随之失效。
@MainActor
final class LanDropShare: ObservableObject {
    static let shared = LanDropShare()

    /// 最多同时分享的文件数，防止误拖一整个目录的内容进来。
    static let maxItems = 20

    @Published private(set) var items: [LanDropSharedItem] = []
    /// 上次添加时被忽略的项（文件夹 / 读不到的文件），供面板提示一次。
    @Published private(set) var lastRejected: [String] = []

    private init() {}

    /// 加入分享。目录被忽略——分享目录等于开放浏览，与本模块的安全模型冲突，
    /// 要发整个文件夹请自行压缩后再拖。
    func add(urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            guard items.count < Self.maxItems else {
                rejected.append(url.lastPathComponent)
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                rejected.append(url.lastPathComponent)
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes?[.size] as? Int else {
                rejected.append(url.lastPathComponent)
                continue
            }
            // 同一个文件重复拖入不重复占位。
            if items.contains(where: { $0.url == url }) { continue }
            items.append(LanDropSharedItem(id: LanDropEnv.randomID(length: 16),
                                           url: url,
                                           name: url.lastPathComponent,
                                           size: size))
        }
        lastRejected = rejected
        sync()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        sync()
    }

    func clear() {
        items.removeAll()
        lastRejected = []
        sync()
    }

    var totalBytes: Int {
        items.reduce(0) { $0 + $1.size }
    }

    private func sync() {
        LanDropShareSnapshot.shared.set(items)
    }
}
