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
    /// 历史文件。内容是密文还是明文取决于「加密存储」开关，读取侧两种都认，
    /// 所以文件名保持中性（不叫 .json / .enc）。见 `ClipboardCrypto`。
    static var storeFile: URL { baseDir.appendingPathComponent("clipboard.dat") }
    /// 更早版本用过的文件名，启动时按序尝试读入并迁移到 `storeFile` 后删除。
    static var legacyStoreFiles: [URL] {
        [baseDir.appendingPathComponent("clipboard.enc"),
         baseDir.appendingPathComponent("clipboard.json")]
    }

    static let maxItemsKey = "clipboard.maxItems"
    static let retentionDaysKey = "clipboard.retentionDays"
    static let ignoredBundleIDsKey = "clipboard.ignoredBundleIDs"
    static let recordConcealedKey = "clipboard.recordConcealed"

    private var saveWorkItem: DispatchWorkItem?

    init() {
        load()
        pruneExpired()
    }

    var maxItems: Int {
        let value = UserDefaults.standard.integer(forKey: Self.maxItemsKey)
        return value == 0 ? 200 : value
    }

    /// 历史保留天数，0 = 永久。
    var retentionDays: Int {
        UserDefaults.standard.integer(forKey: Self.retentionDaysKey)
    }

    /// 忽略名单（bundle id）：命中的来源 App 不记录历史。
    static var ignoredBundleIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: ignoredBundleIDsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: ignoredBundleIDsKey) }
    }

    /// 是否记录被来源标记为敏感（ConcealedType）的内容 —— 1Password / Bitwarden 等
    /// 密码管理器复制的密码走的就是这个标记。出厂关闭；`bool(forKey:)` 未设置时返回
    /// false，正好等于「默认不记录」，无需注册默认值。
    static var recordConcealed: Bool {
        get { UserDefaults.standard.bool(forKey: recordConcealedKey) }
        set { UserDefaults.standard.set(newValue, forKey: recordConcealedKey) }
    }

    // MARK: - 变更

    func add(_ item: ClipboardItem) {
        pruneExpired()
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

    // MARK: - 文本片段（= 手工创建的收藏条目）

    /// 所有片段：收藏 + 带标题或关键字。顺手复制来的收藏不算。
    var snippets: [ClipboardItem] { items.filter { $0.isSnippet } }

    /// 新建一条片段。不走 `add(_:)` —— 那条路径带「与最近一条同内容就合并」的去重逻辑，
    /// 对手工创建的片段是错的（用户可能就是要存一条和刚复制的东西一样的片段）。
    @discardableResult
    func addSnippet(title: String, content: String, keyword: String? = nil) -> UUID {
        let item = ClipboardItem(id: UUID(), type: .text, text: content, imageFilename: nil,
                                 sourceAppName: nil, sourceBundleID: nil, createdAt: Date(),
                                 isPinned: true, isConcealed: false,
                                 title: title, keyword: normalizedKeyword(keyword))
        items.append(item)
        sortItems()
        scheduleSave()
        return item.id
    }

    func setSnippetTitle(_ id: UUID, _ title: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].title = trimmed.isEmpty ? nil : trimmed
        scheduleSave()
    }

    /// 设关键字。空串 = 取消触发；同一关键字只允许一条，后设的顶掉先设的。
    func setSnippetKeyword(_ id: UUID, _ keyword: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let normalized = normalizedKeyword(keyword)
        if let normalized {
            for other in items.indices where items[other].id != id && items[other].keyword == normalized {
                items[other].keyword = nil
            }
        }
        items[index].keyword = normalized
        scheduleSave()
    }

    func setSnippetContent(_ id: UUID, _ content: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text = content
        scheduleSave()
    }

    /// 按关键字找片段（关键字展开用）。
    func snippet(forKeyword keyword: String) -> ClipboardItem? {
        items.first { $0.isPinned && $0.keyword == keyword }
    }

    private func normalizedKeyword(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

    /// 清空历史，收藏条目**保留** —— 「收藏 = 永远不删」对显式清空同样成立；
    /// 真想连收藏一起清，先逐条取消收藏。弹窗文案（clearConfirm.message）与此一致。
    func clearAll() {
        let removed = items.filter { !$0.isPinned }
        guard !removed.isEmpty else { return }
        for item in removed { deleteImageFile(for: item) }
        items.removeAll { !$0.isPinned }
        scheduleSave()
    }

    /// 关掉「记录敏感内容」开关时调用：把已经入库的敏感条目一并清掉（含置顶的）。
    /// 只停止新增而把旧的留在磁盘上，等于开关关了密码还在，不符合用户预期。
    func removeConcealed() {
        let concealed = items.filter(\.isConcealed)
        guard !concealed.isEmpty else { return }
        for item in concealed { deleteImageFile(for: item) }
        items.removeAll { $0.isConcealed }
        scheduleSave()
    }

    /// 清理超过保留期的未置顶条目（0 = 永久保留）。启动、新增、打开面板时各触发一次，
    /// 无需常驻定时器。
    func pruneExpired() {
        let days = retentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let expired = items.filter { !$0.isPinned && $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        for item in expired { deleteImageFile(for: item) }
        let expiredIDs = Set(expired.map(\.id))
        items.removeAll { expiredIDs.contains($0.id) }
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

    /// 「加密存储」开关切换后调用：历史文件立刻按新格式重写，图片文件后台批量转换。
    func applyStorageEncryptionChange() {
        flushPendingSave()
        ClipboardCrypto.syncStoredImages(in: Self.imagesDir)
    }

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
        guard let data = try? encoder.encode(items) else { return }
        ClipboardCrypto.write(data, to: Self.storeFile)
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = ClipboardCrypto.read(from: Self.storeFile),
           let decoded = try? decoder.decode([ClipboardItem].self, from: data) {
            items = decoded
            sortItems()
            return
        }

        // 走到这里说明 storeFile 不存在，或存在但解不开/解不出（钥匙串里的密钥被删、
        // 换了机器…）。后者不能就这么放着 —— 下一次 saveNow() 会直接覆盖它。先挪成
        // .bak 留个念想，符合「改用户文件前先备份」的约定。
        if FileManager.default.fileExists(atPath: Self.storeFile.path) {
            let backup = Self.baseDir.appendingPathComponent("clipboard.dat.baobox.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: Self.storeFile, to: backup)
        }

        // 迁移老文件名：读出来后按当前开关重写到 storeFile，再删掉原件。
        // 解码失败时保留原文件不删 —— 宁可留个读不出的文件，也不擅自销毁用户数据。
        for legacyURL in Self.legacyStoreFiles {
            guard let legacy = ClipboardCrypto.read(from: legacyURL),
                  let decoded = try? decoder.decode([ClipboardItem].self, from: legacy) else { continue }
            items = decoded
            sortItems()
            saveNow()
            try? FileManager.default.removeItem(at: legacyURL)
            return
        }
    }
}
