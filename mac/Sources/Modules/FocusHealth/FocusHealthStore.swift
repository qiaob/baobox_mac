import Foundation

/// `~/Library/Application Support/Baobox/FocusHealth/` 下的 items.json（提醒项）、state.json（运行状态）
/// 与 history.jsonl（专注历史，docs/focus-health/HISTORY.md）。
/// 写盘走后台串行队列；睡眠前与退出时同步写（技术设计 §8）。历史的读、追加、重写也排在同一个队列上，先后不乱。
final class FocusHealthStore {
    private let queue = DispatchQueue(label: "com.baobox.app.focushealth.store", qos: .utility)
    private let directory: URL

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Baobox/FocusHealth", isDirectory: true)
    }

    init(directory: URL = FocusHealthStore.defaultDirectory) {
        self.directory = directory
    }

    private var itemsURL: URL { directory.appendingPathComponent("items.json") }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var historyURL: URL { directory.appendingPathComponent("history.jsonl") }

    /// 读盘（启动时一次，两个小 JSON）。没有文件 = 第一次用：给预置四项。
    func load() -> (items: [ReminderItem], state: FocusHealthState) {
        var items = ReminderPreset.defaults()
        if let data = try? Data(contentsOf: itemsURL) {
            if let decoded = try? JSONDecoder().decode([ReminderItem].self, from: data) {
                // 没改过的旧预置换成统一节拍的新默认值（REQUIREMENTS.md §7）。
                items = ReminderPreset.migrated(decoded)
            } else {
                // 整个文件坏了：改名留底，回落预置（下次保存会写出新的 items.json）。
                let bad = itemsURL.appendingPathExtension("bad")
                try? FileManager.default.removeItem(at: bad)
                try? FileManager.default.moveItem(at: itemsURL, to: bad)
            }
        }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }

        var state = FocusHealthState()
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(FocusHealthState.self, from: data) {
            state = decoded
        }
        return (items, state)
    }

    func saveItems(_ items: [ReminderItem]) {
        write(items, to: itemsURL, sync: false)
    }

    func saveState(_ state: FocusHealthState, sync: Bool) {
        write(state, to: stateURL, sync: sync)
    }

    // MARK: - 专注历史（history.jsonl）

    /// 后台读专注历史：看不懂的行跳过（文件里原样留着），400 天前的去掉；去掉过东西（含崩在半截的最后一行）就整份重写一次。
    /// `completion` 在存储队列上调，调用方自己回主线程（标 @Sendable：别让它被推断成主线程隔离的闭包）。
    func loadHistory(now: Date = Date(), completion: @escaping @Sendable ([FocusHistoryRecord]) -> Void) {
        let url = historyURL
        let directory = self.directory
        queue.async {
            guard let data = try? Data(contentsOf: url) else {
                completion([])
                return
            }
            let decoded = FocusHistoryCodec.decodeLines(data)
            let kept = FocusHistoryCodec.pruned(decoded.records, now: now)
            if decoded.truncatedTail || kept.count != decoded.records.count {
                Self.writeHistory(kept, keeping: decoded.unknownLines, to: url, directory: directory)
            }
            completion(kept)
        }
    }

    /// 追加一行（只追加，不改写）。
    func appendHistory(_ record: FocusHistoryRecord) {
        guard let line = FocusHistoryCodec.line(record) else { return }
        let url = historyURL
        let directory = self.directory
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    try line.write(to: url, options: .atomic)
                    return
                }
                // 中途出错时 handle 随作用域释放，文件描述符跟着关掉。
                let handle = try FileHandle(forUpdating: url)
                let size = try handle.seekToEnd()
                var data = line
                // 上一行没写完（崩在半截）：先补一个换行，别把这一行粘到坏行后面一起丢掉。
                if size > 0 {
                    try handle.seek(toOffset: size - 1)
                    if let last = try handle.read(upToCount: 1), last.first != 0x0A { data.insert(0x0A, at: 0) }
                    try handle.seekToEnd()
                }
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                StorageWriteFailure.report(L("storage.what.focusHistory"), reason: error.localizedDescription)
            }
        }
    }

    /// 整份重写（导入合并、启动时补齐内存里多出来的几条）。内存里是看得懂的全部记录；
    /// 文件里看不懂的行（更新版本写的）先读出来，原样留着。
    func rewriteHistory(_ records: [FocusHistoryRecord]) {
        let url = historyURL
        let directory = self.directory
        queue.async {
            let unknown = (try? Data(contentsOf: url)).map { FocusHistoryCodec.decodeLines($0).unknownLines } ?? []
            Self.writeHistory(records, keeping: unknown, to: url, directory: directory)
        }
    }

    /// 等队列里排着的读写做完（测试用；退出时 saveState(sync:) 本来就排在它们后面）。
    func waitForPendingWrites() {
        queue.sync {}
    }

    private static func writeHistory(_ records: [FocusHistoryRecord], keeping unknown: [Data], to url: URL,
                                     directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FocusHistoryCodec.encodeLines(records, keeping: unknown).write(to: url, options: .atomic)
        } catch {
            StorageWriteFailure.report(L("storage.what.focusHistory"), reason: error.localizedDescription)
        }
    }

    /// 写失败报给用户一次、记 fault 日志（#101）；下次保存再试。
    private func write<T: Encodable>(_ value: T, to url: URL, sync: Bool) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            StorageWriteFailure.report(L("storage.what.focus"), reason: error.localizedDescription)
            return
        }
        let directory = self.directory
        let what = L("storage.what.focus")
        let work = {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                StorageWriteFailure.report(what, reason: error.localizedDescription)
            }
        }
        if sync {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }
}
