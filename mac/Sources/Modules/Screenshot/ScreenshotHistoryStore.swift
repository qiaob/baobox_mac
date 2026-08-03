import AppKit

/// 截图历史：每次截图（复制/保存/贴图）都会存一份 PNG，供菜单快速找回。
/// 与"保存到磁盘"的文件相互独立；索引 JSON + 图片文件落在 Application Support/Baobox 下。
@MainActor
final class ScreenshotHistoryStore {
    static let shared = ScreenshotHistoryStore()

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let filename: String
        let createdAt: Date
    }

    /// 新→旧排序。
    private(set) var entries: [Entry] = []

    static var dir: URL { ClipboardStore.baseDir.appendingPathComponent("ScreenshotHistory", isDirectory: true) }
    static var indexFile: URL { ClipboardStore.baseDir.appendingPathComponent("screenshots.json") }

    /// 菜单缩略图缓存（按条目 id）。
    private var thumbnails: [UUID: NSImage] = [:]
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        load()
    }

    // MARK: - 变更

    func record(image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let entry = Entry(id: UUID(), filename: UUID().uuidString + ".png", createdAt: Date())
        do {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try png.write(to: Self.dir.appendingPathComponent(entry.filename))
        } catch {
            return // 写盘失败就不记录，截图主流程不受影响。
        }
        entries.insert(entry, at: 0)
        trimToLimit()
        scheduleSave()
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(entry.filename))
        thumbnails[entry.id] = nil
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    func clearAll() {
        for entry in entries {
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(entry.filename))
        }
        entries.removeAll()
        thumbnails.removeAll()
        scheduleSave()
    }

    /// 超出上限时删除最旧条目及其文件。设置页调小上限时也调用。
    func trimToLimit() {
        let limit = ScreenshotSettings.historyLimit
        while entries.count > limit {
            let removed = entries.removeLast()
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(removed.filename))
            thumbnails[removed.id] = nil
        }
        scheduleSave()
    }

    // MARK: - 读取

    func image(for entry: Entry) -> NSImage? {
        NSImage(contentsOf: Self.dir.appendingPathComponent(entry.filename))
    }

    func cgImage(for entry: Entry) -> CGImage? {
        guard let image = image(for: entry) else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// 菜单缩略图（等比缩到最长边 140pt，缓存复用）。
    func thumbnail(for entry: Entry) -> NSImage? {
        if let cached = thumbnails[entry.id] { return cached }
        guard let full = image(for: entry), full.size.width > 0, full.size.height > 0 else { return nil }
        let maxSide: CGFloat = 140
        let ratio = min(maxSide / full.size.width, maxSide / full.size.height, 1)
        let target = NSSize(width: max(1, full.size.width * ratio),
                            height: max(1, full.size.height * ratio))
        let thumb = NSImage(size: target, flipped: false) { rect in
            full.draw(in: rect)
            return true
        }
        thumbnails[entry.id] = thumb
        return thumb
    }

    // MARK: - 持久化（与其他 store 相同的 0.5s 防抖 + 退出 flush）

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
        try? FileManager.default.createDirectory(at: ClipboardStore.baseDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: Self.indexFile)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Entry].self, from: data) {
            // 索引里可能有文件已被手动删除的条目，过滤掉避免菜单出现空缩略图。
            entries = decoded.filter {
                FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent($0.filename).path)
            }
        }
    }
}
