import Foundation

/// 听写历史：`~/Library/Application Support/Baobox/Dictation/history.json`（只存文字，见技术设计 §8）。
/// 内存里一份（菜单、历史窗口直接读它，零磁盘 IO），改动后在后台串行队列写盘；退出时同步写。
@MainActor
final class DictationHistoryStore: ObservableObject {
    @Published private(set) var records: [DictationRecord] = []

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.baobox.app.dictation.history", qos: .utility)
    private var loadRequested = false
    /// 读盘完成之前不写：免得用（还没读进来的）空列表盖掉磁盘上的历史。
    private var loaded = false
    private var pendingSave = false

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Baobox/Dictation", isDirectory: true)
    }

    init(directory: URL = DictationHistoryStore.defaultDirectory) {
        fileURL = directory.appendingPathComponent("history.json")
    }

    /// 启动时调一次：后台读盘，读完回主线程合进内存（按 `limit` 截断）。
    func load(limit: Int) {
        guard !loadRequested else { return }
        loadRequested = true
        let url = fileURL
        queue.async {
            let disk = Self.read(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishLoading(disk, limit: limit)
                }
            }
        }
    }

    /// 只给预览 / 离屏渲染用：直接放进内存，不读不写盘。
    func preview(_ records: [DictationRecord]) {
        loadRequested = true
        self.records = records
    }

    func add(_ record: DictationRecord, limit: Int) {
        records = DictationHistoryCodec.adding(record, to: records, limit: limit)
        save()
    }

    func delete(_ id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    func clear() {
        records = []
        save()
    }

    /// 导入备份：合并好的整份列表（新的在前、已按上限截断，见 `DictationHistoryCodec.importing`）。
    /// 还没读完盘时，读完会照常把盘上的接在后面（`finishLoading`）。
    func replace(with records: [DictationRecord]) {
        self.records = records
        save()
    }

    /// 改了条数上限：多出来的旧记录删掉。
    func trim(to limit: Int) {
        let cap = DictationHistoryCodec.clampLimit(limit)
        guard records.count > cap else { return }
        records.removeLast(records.count - cap)
        save()
    }

    /// App 退出：同步写完。
    func flush() {
        guard loaded, pendingSave else { return }
        pendingSave = false
        guard let data = DictationHistoryCodec.encode(records) else { return }
        let url = fileURL
        queue.sync {
            Self.write(data, to: url)
        }
    }

    private func finishLoading(_ disk: [DictationRecord], limit: Int) {
        loaded = true
        records = DictationHistoryCodec.merging(current: records, loaded: disk, limit: limit)
        if pendingSave { save() }
    }

    private func save() {
        pendingSave = true
        guard loaded, loadRequested else { return }
        pendingSave = false
        guard let data = DictationHistoryCodec.encode(records) else { return }
        let url = fileURL
        queue.async {
            Self.write(data, to: url)
        }
    }

    /// 读盘（后台）。整个文件坏了：改名留底（`history.json.bad`），当作没有历史。
    nonisolated private static func read(_ url: URL) -> [DictationRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let records = DictationHistoryCodec.decode(data) { return records }
        let bad = url.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
        return []
    }

    /// 写失败报给用户一次、记 fault 日志（#101）；内存里的历史不动，下次保存再试。
    nonisolated private static func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            StorageWriteFailure.report(L("storage.what.dictation"), reason: error.localizedDescription)
        }
    }
}
