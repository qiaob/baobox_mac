import Foundation

// 快速入口使用记录的落盘（docs/launcher/TECH_DESIGN.md §5.3）：`~/Library/Application Support/Baobox/Launcher/usage.json`。
// 记录模型和规则在 `Logic/LauncherUsageStore.swift` 的 `LauncherUsageRecords`（纯值）；这里只管读写：
// 启动时后台读（读完裁剪一次），改动后防抖 2 秒在后台写，退出时同步写掉。文件不存在 / 坏了都当空记录。

@MainActor
final class LauncherUsageStore {
    /// 改动后等多久写盘（连着执行几次只写一次）。
    static let saveDelay: TimeInterval = 2

    /// 内存里的记录：排序直接读它，零磁盘 IO。
    private(set) var records = LauncherUsageRecords()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.baobox.app.launcher.usage", qos: .utility)
    private var loadRequested = false
    /// 读盘完成之前不写：免得用还没读进来的空记录盖掉磁盘上的。
    private var loaded = false
    /// 读盘完成前的改动，读完按顺序补上。
    private var pendingChanges: [(inout LauncherUsageRecords) -> Void] = []
    /// 有没写盘的改动。
    private var dirty = false
    private var saveWork: DispatchWorkItem?

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Baobox/Launcher", isDirectory: true)
    }

    init(directory: URL = LauncherUsageStore.defaultDirectory) {
        fileURL = directory.appendingPathComponent("usage.json")
    }

    /// 启动时调一次：后台读盘，读完回主线程换上。
    func load() {
        guard !loadRequested else { return }
        loadRequested = true
        let url = fileURL
        queue.async {
            let disk = Self.read(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishLoading(disk) }
            }
        }
    }

    /// 执行了一行：次数 +1，并记「这个输入选了它」（`input` 是拆掉前缀后的查询词，空的不记）。
    func recordUse(key: String, input: String, now: Date) {
        change { records in
            records.recordUse(of: key, at: now)
            records.recordChoice(key, forInput: input, at: now)
        }
    }

    /// App 退出：取消防抖，同步写掉没落盘的改动（等前面还在写的那次写完再写）。
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        guard loaded, dirty else { return }
        dirty = false
        guard let data = Self.encode(records) else { return }
        let url = fileURL
        queue.sync { Self.write(data, to: url) }
    }

    // MARK: - 内部

    private func change(_ apply: @escaping (inout LauncherUsageRecords) -> Void) {
        apply(&records)
        if !loaded { pendingChanges.append(apply) }
        dirty = true
        scheduleSave()
    }

    private func finishLoading(_ disk: LauncherUsageRecords) {
        var merged = disk
        for apply in pendingChanges { apply(&merged) }
        pendingChanges = []
        records = merged
        loaded = true
        if dirty { scheduleSave() }
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    private func saveNow() {
        saveWork = nil
        guard loaded, dirty else { return }
        dirty = false
        let snapshot = records
        let url = fileURL
        queue.async {
            guard let data = Self.encode(snapshot) else { return }
            Self.write(data, to: url)
        }
    }

    /// 编码：键排序（文件稳定、好比对）。编码失败按写盘失败报。
    nonisolated private static func encode(_ records: LauncherUsageRecords) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(records)
        } catch {
            StorageWriteFailure.report(L("storage.what.launcherUsage"), reason: error.localizedDescription)
            return nil
        }
    }

    /// 读盘（后台）：文件不存在 → 空记录；不是合法 JSON → 改名留底（`usage.json.bad`）、当空记录。
    /// 字段缺失、类型不对由 `LauncherUsageRecords` 的解码容错处理（只跳过那一处）。读完裁剪一次。
    nonisolated private static func read(_ url: URL) -> LauncherUsageRecords {
        guard let data = try? Data(contentsOf: url) else { return LauncherUsageRecords() }
        guard var records = try? JSONDecoder().decode(LauncherUsageRecords.self, from: data) else {
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            return LauncherUsageRecords()
        }
        records.prune()
        return records
    }

    /// 原子写；失败报给用户一次、记 fault 日志（约定 8）。内存里的记录不动，下次改动再写。
    nonisolated private static func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            StorageWriteFailure.report(L("storage.what.launcherUsage"), reason: error.localizedDescription)
        }
    }
}
