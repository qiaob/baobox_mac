import Foundation

/// 剪贴板历史存储：内存 + 磁盘持久化（JSON + 图片文件）。
@MainActor
final class ClipboardStore: ObservableObject {
    /// 新→旧排序，置顶项排最前。
    @Published private(set) var items: [ClipboardItem] = []

    static let baseDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Baobox", isDirectory: true)
    }()
    static var imagesDir: URL { baseDir.appendingPathComponent("ClipboardImages", isDirectory: true) }
    static var storeFile: URL { baseDir.appendingPathComponent("clipboard.json") }

    static let maxItemsKey = "clipboard.maxItems"

    private var saveWorkItem: DispatchWorkItem?

    init() {
        load()
    }

    var maxItems: Int {
        let value = UserDefaults.standard.integer(forKey: Self.maxItemsKey)
        return value == 0 ? 200 : value
    }

    // MARK: - 变更

    func add(_ item: ClipboardItem) {
        // 与最近一条内容相同 → 仅刷新时间戳。
        if let latest = items.max(by: { $0.createdAt < $1.createdAt }),
           latest.contentSignature == item.contentSignature {
            if let index = items.firstIndex(where: { $0.id == latest.id }) {
                items[index].createdAt = Date()
                // 若新条目携带图片文件而旧条目已有，删除新写入的重复图片。
                if item.type == .image, let newName = item.imageFilename,
                   newName != items[index].imageFilename {
                    deleteImageFile(named: newName)
                }
                sortItems()
                scheduleSave()
            }
            return
        }

        items.append(item)
        sortItems()
        enforceLimit()
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        sortItems()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: index)
        deleteImageFile(for: removed)
        scheduleSave()
    }

    func clearAll() {
        for item in items { deleteImageFile(for: item) }
        items.removeAll()
        scheduleSave()
    }

    // MARK: - 内部

    private func sortItems() {
        items.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return a.createdAt > b.createdAt
        }
    }

    /// 超出上限时从未置顶的尾部（最旧）淘汰，并删除关联图片。
    private func enforceLimit() {
        let limit = maxItems
        guard items.count > limit else { return }
        var overflow = items.count - limit
        var i = items.count - 1
        while overflow > 0 && i >= 0 {
            if !items[i].isPinned {
                let removed = items.remove(at: i)
                deleteImageFile(for: removed)
                overflow -= 1
            }
            i -= 1
        }
    }

    private func deleteImageFile(for item: ClipboardItem) {
        guard item.type == .image, let name = item.imageFilename else { return }
        deleteImageFile(named: name)
    }

    private func deleteImageFile(named name: String) {
        let url = Self.imagesDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 持久化

    /// 立即落盘并取消待执行的防抖任务。
    /// 保存是 0.5s 防抖的，App 退出时若不强制 flush，退出前最后 0.5s 内的
    /// 复制 / 置顶 / 删除会永久丢失。
    func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveNow()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveNow()
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        try? FileManager.default.createDirectory(at: Self.baseDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) {
            try? data.write(to: Self.storeFile)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ClipboardItem].self, from: data) {
            items = decoded
            sortItems()
        }
    }
}
