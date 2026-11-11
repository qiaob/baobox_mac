import Combine
import Foundation

/// 一次刷新的纯逻辑（#109）：修改时间差 < 1 ms 且大小相同的文件复用上一轮的记录，其余调 `scan`；摘要按 lastActivity 新→旧。
/// 后台线程调用；测试直接喂文件清单与假的 `scan`，不碰磁盘。
enum CLISessionScanner<Format: CLISessionFormat> {

    /// 文件没变：修改时间差 < 1 ms（缓存里存的是秒数浮点）且大小相同。
    static func isUnchanged(_ record: Format.Record, _ file: CLISessionFile) -> Bool {
        abs(record.modified - file.modified.timeIntervalSince1970) < 0.001 && record.size == file.size
    }

    /// 没变的复用 `previous`（键 = 文件路径），变了的与新出现的调 `scan`：返回 nil 的这次跳过，既不进缓存也不进列表；
    /// `files` 里已经没有的文件不带进新缓存。摘要按 lastActivity 新→旧排序（比较器与两个模块原来的相同）。
    static func refresh(
        files: [CLISessionFile],
        previous: [String: Format.Record],
        scan: (CLISessionFile) -> Format.Record? = Format.scan
    ) -> (summaries: [Format.Summary], cache: [String: Format.Record]) {
        var summaries: [Format.Summary] = []
        var cache: [String: Format.Record] = [:]

        for file in files {
            let path = file.url.path

            // 复用未变文件。
            if let record = previous[path], isUnchanged(record, file) {
                cache[path] = record
                summaries.append(Format.summary(of: record, fileURL: file.url))
                continue
            }

            if let record = scan(file) {
                cache[path] = record
                summaries.append(Format.summary(of: record, fileURL: file.url))
            }
        }

        summaries.sort { $0.lastActivity > $1.lastActivity }
        return (summaries, cache)
    }
}

/// 会话索引基类（#109，docs/codex-assistant/DEDUPE.md §4.1）：刷新（进行中不重入、后台扫描、没变的文件复用）、排序、
/// 删除、导出外壳、可选的磁盘缓存（1 秒防抖、退出 flush）、清理旧会话。
///
/// 模块写一个非泛型子类放 `static let shared`（泛型类型里不能有静态存储属性），子类只加自己独有的功能；
/// `@Published` 全在这里，子类不加。`@Published` 只在主线程写；重 IO 都在后台，完成回调在主线程。
@MainActor
class CLISessionIndex<Format: CLISessionFormat>: ObservableObject {
    /// 新→旧排序。
    @Published private(set) var sessions: [Format.Summary] = []
    /// 是否正在刷新（供 UI 显示转圈）。
    @Published private(set) var isRefreshing = false

    /// 快扫缓存：键 = 文件路径。仅主线程读写。
    private var cache: [String: Format.Record] = [:]
    /// 去抖 / 防重入标记。
    private var refreshing = false
    private var saveWorkItem: DispatchWorkItem?

    /// 有磁盘缓存文件就同步读入（发生在首次取 `shared` 时，即模块的 `activate`，不在菜单构建里）。
    init() {
        loadCache()
    }

    /// 从路径取展示名（末段）。经继承在子类名下照旧能调（`ClaudeSessionIndex.projectName(fromPath:)`…）。
    nonisolated static func projectName(fromPath path: String) -> String {
        CLISessionPaths.projectName(fromPath: path)
    }

    // MARK: - 刷新

    /// 后台快扫全部会话文件 → 回主线程发布 → 有缓存文件时安排 1 秒后落盘。去抖，进行中不重入。
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        isRefreshing = true
        let previousCache = cache        // 主线程快照，传入后台
        DispatchQueue.global(qos: .utility).async {
            let (summaries, newCache) = CLISessionScanner<Format>.refresh(
                files: Format.sessionFiles(),
                previous: previousCache
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sessions = summaries
                    self.cache = newCache
                    self.refreshing = false
                    self.isRefreshing = false
                    self.scheduleCacheSave()
                }
            }
        }
    }

    // MARK: - 删除 / 导出 / 清理

    /// 删除单个会话文件。回调是否成功（主线程），成功则从内存索引移除。
    func deleteSession(_ summary: Format.Summary, completion: @escaping (Bool) -> Void) {
        let url = summary.fileURL
        let id = summary.id
        DispatchQueue.global(qos: .utility).async {
            let ok = (try? FileManager.default.removeItem(at: url)) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok {
                        self.sessions.removeAll { $0.id == id }
                        self.cache.removeValue(forKey: url.path)
                        self.scheduleCacheSave()
                    }
                }
                completion(ok)
            }
        }
    }

    /// 把一个会话导出为 Markdown 文本（格式的 `markdown`，后台解析，回主线程回调）。读失败回调 nil。
    func exportMarkdown(_ summary: Format.Summary, completion: @escaping (String?) -> Void) {
        let url = summary.fileURL
        let title = summary.title
        DispatchQueue.global(qos: .utility).async {
            let markdown = Format.markdown(fileURL: url, title: title)
            DispatchQueue.main.async {
                completion(markdown)
            }
        }
    }

    /// 删除早于 N 天（按修改时间）的会话 jsonl（`Format.logRoot` 下递归）。删完先 `refresh()`，再回调（删除文件数，释放字节数）。
    func cleanup(olderThanDays days: Int, completion: @escaping (Int, Int64) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let (count, bytes) = CLISessionFiles.removeJSONL(under: Format.logRoot, olderThanDays: days)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refresh()
                }
                completion(count, bytes)
            }
        }
    }

    /// App 退出前立即落盘缓存（取消防抖；写盘本身仍派到后台，见 DEDUPE.md §5.2 C6）。没有缓存文件时什么也不做。
    func flushCache() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveCacheNow()
    }

    // MARK: - 缓存持久化

    private func scheduleCacheSave() {
        guard Format.cacheFileURL != nil else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveCacheNow()
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// 缓存是派生数据：写失败照旧静默（丢了只是下次多扫几个文件）。
    private func saveCacheNow() {
        guard let url = Format.cacheFileURL else { return }
        let snapshot = cache
        DispatchQueue.global(qos: .utility).async {
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

    private func loadCache() {
        guard let url = Format.cacheFileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Format.Record].self, from: data) else {
            return
        }
        cache = decoded
    }
}
