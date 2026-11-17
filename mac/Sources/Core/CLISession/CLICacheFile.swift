import Foundation

/// 派生数据的磁盘缓存文件（#164 PR6，docs/codex-assistant/DEDUPE-P2.md §2.4 类 7）：会话索引的 index-cache-v2.json、
/// 最近文件索引的 file-index-cache-v1.json，从 `CLISessionIndex` 抽出来两边共用。
///
/// - 启动时同步读（`load`）。
/// - 改了之后防抖（默认 1 秒）：期间再改只留最后一次、重新计时；到点在主线程取**当时**的快照，交给串行写盘队列异步写，不占主线程。
/// - 退出时 `flush` 同步写完再返回（`willTerminate` 返回后进程随时会退出）。写盘队列是串行的：之前排进来、带着旧快照的异步写
///   一定先写完，不会反过来盖掉 flush 写的新快照（#170，DEDUPE.md §5.2 C6）。
///
/// 编码用默认 `JSONEncoder`（文件格式与抽出来之前逐字节相同），写前建父目录。写失败静默：缓存是派生数据，丢了只是下次多扫几个文件，
/// 不走 `StorageWriteFailure`。只依赖 Foundation，进 BaoboxTests（整个 Core/CLISession 目录都进）。主线程调用。
@MainActor
final class CLICacheFile<Snapshot: Codable & Sendable> {
    /// 缓存文件；nil = 不读也不写（Codex 会话索引只在内存里缓存）。
    let url: URL?
    /// 防抖时长（秒）。
    let debounce: TimeInterval
    /// 写盘的串行队列：防抖的落盘在这里异步写，`flush` 在这里同步写。
    private let queue: DispatchQueue
    /// 排着的防抖落盘。
    private var pendingSave: DispatchWorkItem?

    /// - Parameters:
    ///   - url: 缓存文件；nil = 不读不写。
    ///   - queueLabel: 写盘队列的名字（会话索引 `com.baobox.clisession.cachesave`，最近文件索引 `com.baobox.claudecode.fileindex.cachesave`）。
    ///   - debounce: 防抖时长，默认 1 秒（测试传短的）。
    init(url: URL?, queueLabel: String, debounce: TimeInterval = 1.0) {
        self.url = url
        self.debounce = debounce
        self.queue = DispatchQueue(label: queueLabel)
    }

    /// 同步读回上次写下的快照。没有文件、读不了、解不开（坏文件、旧格式）都返回 nil —— 当没有缓存，全部重扫。
    func load() -> Snapshot? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return nil
        }
        return decoded
    }

    /// 安排一次落盘：取消还没到点的那次，`debounce` 秒后在主线程调 `snapshot()` 取当时的快照，交给写盘队列异步写。
    /// `snapshot` 返回 nil 就不写（缓存的主人已经不在了：调用方弱引用自己，同抽出来之前）。没有文件时什么也不做。
    func scheduleSave(_ snapshot: @escaping @MainActor () -> Snapshot?) {
        guard url != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let url = self.url, let value = snapshot() else { return }
                self.queue.async {
                    Self.write(value, to: url)
                }
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// 立即落盘：取消排着的防抖，在写盘队列上**同步**写完再返回（排在前面的异步写先写完）。没有文件时什么也不做。
    func flush(_ snapshot: Snapshot) {
        pendingSave?.cancel()
        pendingSave = nil
        guard let url else { return }
        queue.sync {
            Self.write(snapshot, to: url)
        }
    }

    /// 编码并写盘（只在写盘队列上调）：默认 `JSONEncoder`，写前建父目录，失败静默。
    nonisolated private static func write(_ snapshot: Snapshot, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url)
        }
    }
}
