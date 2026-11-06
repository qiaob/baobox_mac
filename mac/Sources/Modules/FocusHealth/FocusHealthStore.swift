import Foundation

/// `~/Library/Application Support/Baobox/FocusHealth/` 下的 items.json（提醒项）与 state.json（运行状态）。
/// 写盘走后台串行队列；睡眠前与退出时同步写（技术设计 §8）。
final class FocusHealthStore {
    private let queue = DispatchQueue(label: "com.baobox.app.focushealth.store", qos: .utility)
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("Baobox/FocusHealth", isDirectory: true)
    }

    private var itemsURL: URL { directory.appendingPathComponent("items.json") }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    /// 读盘（启动时一次，两个小 JSON）。没有文件 = 第一次用：给预置四项。
    func load() -> (items: [ReminderItem], state: FocusHealthState) {
        var items = ReminderPreset.defaults()
        if let data = try? Data(contentsOf: itemsURL) {
            if let decoded = try? JSONDecoder().decode([ReminderItem].self, from: data) {
                items = decoded
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

    private func write<T: Encodable>(_ value: T, to url: URL, sync: Bool) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        let directory = self.directory
        let work = {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if sync {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }
}
