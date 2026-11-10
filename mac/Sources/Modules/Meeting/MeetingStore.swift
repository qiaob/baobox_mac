import AppKit
import Foundation
import os

private let storeLog = Logger(subsystem: "com.baobox.app", category: "meeting.store")

/// 会议库（docs/meeting/TECH_DESIGN.md §4）：`~/Library/Application Support/Baobox/Meetings/`。
///
/// `records` 是 index.json 的内存副本、主线程模型：菜单、会议库窗口只读它（零磁盘 IO）。读写盘都在后台串行队列：
/// 改一条 = 先改内存，再排队写它的 meta.json 与整份 index.json（原子写）。meta.json 是真相源，index.json 缺失或损坏时
/// 扫目录重建；启动时还会与磁盘对账（目录被删了、写到一半退出留下的）。
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    /// ~/Library/Application Support/Baobox/Meetings/
    nonisolated let rootURL: URL

    /// 全部会议，新的在前。
    @Published private(set) var records: [MeetingRecord] = []
    /// 启动时的读索引 / 重建 / 迁移做完了。
    @Published private(set) var isLoaded = false

    private let io = DispatchQueue(label: "com.baobox.app.meeting.store", qos: .utility)
    /// 正在写的（会议记录中、自由听译记录中、纪要整理中）：启动时修「记录中」、保留时长清理都跳过它们。
    private var activeIDs: Set<String> = []
    /// 这次运行里分出去的目录（同一分钟开两次时不撞名；磁盘上还没建出来也算占用）。
    private var reservedDirs: Set<String> = []
    private var loadStarted = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        rootURL = base.appendingPathComponent("Baobox/Meetings", isDirectory: true)
    }

    // MARK: - 读

    func record(_ id: String) -> MeetingRecord? {
        records.first { $0.id == id }
    }

    func directoryURL(for record: MeetingRecord) -> URL {
        rootURL.appendingPathComponent(record.dir, isDirectory: true)
    }

    /// 纪要 + 速记 + 转录所在的 Markdown：迁移进来的旧记录是原文件，其余是目录里的 meeting.md。
    func markdownURL(for record: MeetingRecord) -> URL {
        if let legacy = record.meta.legacyPath {
            return URL(fileURLWithPath: legacy)
        }
        return directoryURL(for: record).appendingPathComponent(MeetingLibraryLayout.markdownFileName)
    }

    /// 所有会议里没完成的行动项数（菜单「行动项」标题用，只读内存）。
    var openActionItemCount: Int {
        records.reduce(0) { $0 + $1.meta.openActionItemCount }
    }

    /// 后台读一场会议的 Markdown（会议库详情、全文搜索用）；读不到为 nil。
    func loadMarkdown(_ id: String, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        guard let record = record(id) else {
            completion(nil)
            return
        }
        let url = markdownURL(for: record)
        io.async {
            let text = FileManager.default.contents(atPath: url.path).flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(text) }
            }
        }
    }

    /// 后台读几场会议的 Markdown（会议库全文搜索、周报）；读不到的不在结果里。
    func loadMarkdowns(_ ids: [String], completion: @escaping @MainActor @Sendable ([String: String]) -> Void) {
        let targets = ids.compactMap { id in record(id).map { (id, markdownURL(for: $0)) } }
        guard !targets.isEmpty else {
            completion([:])
            return
        }
        io.async {
            var texts: [String: String] = [:]
            for (id, url) in targets {
                if let data = FileManager.default.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) {
                    texts[id] = text
                }
            }
            let result = texts
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    /// 周报的位置：`weekly/<yyyy-Www>.md`。
    func weeklyURL(_ key: String) -> URL {
        rootURL.appendingPathComponent(MeetingLibraryLayout.weeklyFolderName, isDirectory: true)
            .appendingPathComponent(key + ".md")
    }

    // MARK: - 启动

    /// App 启动时调一次（MeetingTool.activate）：后台读 index.json（缺失 / 损坏就扫目录重建，否则与磁盘对账），
    /// 首次启动把旧实时翻译记录按引用迁进来；回主线程后修上次没收尾的状态、按保留时长清理。
    func load() {
        guard !loadStarted else { return }
        loadStarted = true
        let root = rootURL
        let migrating = !MeetingSettings.migratedLegacy
        let legacyFolders = migrating ? Self.legacyFoldersToMigrate() : []
        let legacyTitle = L("meeting.legacy.title")
        io.async {
            let indexURL = root.appendingPathComponent(MeetingLibraryLayout.indexFileName)
            let indexData = FileManager.default.contents(atPath: indexURL.path)
            var loaded: [MeetingRecord]
            var dirty: Bool
            if let indexData, let decoded = MeetingLibraryScanner.decodeIndex(indexData) {
                (loaded, dirty) = MeetingLibraryScanner.reconcile(decoded, root: root)
            } else {
                loaded = MeetingLibraryScanner.rebuild(root: root)
                // 索引坏了要换掉；本来就没有、库也是空的就先不建目录。
                dirty = indexData != nil || !loaded.isEmpty
                if indexData != nil {
                    storeLog.error("index.json unreadable, rebuilt from \(loaded.count) meeting folders")
                }
            }
            let imported = Self.importLegacy(folders: legacyFolders, root: root, existing: loaded, title: legacyTitle)
            if !imported.isEmpty {
                storeLog.notice("imported \(imported.count) legacy live translate transcripts")
            }
            let all = loaded + imported
            let changed = dirty || !imported.isEmpty
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MeetingStore.shared.finishLoad(all, dirty: changed, migrated: migrating)
                }
            }
        }
    }

    private func finishLoad(_ loaded: [MeetingRecord], dirty: Bool, migrated: Bool) {
        // 读盘期间新建的（启动后马上就开了会）以内存里的为准，再合上读到的。
        let memoryIDs = Set(records.map(\.id))
        var merged = records + loaded.filter { !memoryIDs.contains($0.id) }
        // 上次没收尾的（App 被杀、崩溃、纪要整理到一半退出）不会再变了：标成仅转录。
        var repaired: [MeetingRecord] = []
        for index in merged.indices where !activeIDs.contains(merged[index].id) {
            switch merged[index].meta.status {
            case .recording, .summarizing:
                merged[index].meta.status = .transcribed
                repaired.append(merged[index])
            case .transcribed, .summarized, .failed:
                break
            }
        }
        records = MeetingLibraryScanner.sorted(merged)
        isLoaded = true
        if migrated {
            MeetingSettings.migratedLegacy = true
        }
        for record in repaired {
            writeMeta(record)
        }
        if dirty || !repaired.isEmpty {
            writeIndex()
        }
        applyRetention()
    }

    /// 旧版实时翻译「保存记录」开关与保存位置的设置键（字面量不能改）。会议这边只在迁移时读：看用户用没用过、旧记录在哪。
    private static let legacyRecordEnabledKey = "livetranslate.record.enabled"
    private static let legacyRecordFolderKey = "livetranslate.record.folder"

    /// 要迁移的旧记录文件夹：用户开过「保存记录」或改过保存位置才看 —— 没用过就不去碰「文稿」（首次启动就弹授权框）。
    /// 没改过位置时，默认文件夹的名字随界面语言，两种都看一眼。
    private static func legacyFoldersToMigrate() -> [URL] {
        let defaults = UserDefaults.standard
        let custom = defaults.string(forKey: legacyRecordFolderKey) ?? ""
        guard defaults.object(forKey: legacyRecordEnabledKey) != nil || !custom.isEmpty else { return [] }
        if !custom.isEmpty {
            return [URL(fileURLWithPath: custom, isDirectory: true)]
        }
        // 旧版的默认位置：~/Documents/Baobox 实时翻译记录（名字随界面语言）。
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        let current = documents.appendingPathComponent(L("livetranslate.record.defaultFolderName"), isDirectory: true)
        let parent = current.deletingLastPathComponent()
        var folders = [current]
        for name in ["Baobox 实时翻译记录", "Baobox Live Translate"] {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            if !folders.contains(url) { folders.append(url) }
        }
        return folders
    }

    /// 后台：旧记录 → 会议库条目（type free、legacyPath 指向原文件、文件原地不动），已经引用过的跳过。
    nonisolated private static func importLegacy(folders: [URL], root: URL, existing: [MeetingRecord],
                                                 title: String) -> [MeetingRecord] {
        guard !folders.isEmpty else { return [] }
        let fileManager = FileManager.default
        let referenced = Set(existing.compactMap(\.meta.legacyPath))
        var taken = Set(existing.map(\.dir))
        var seen = Set<String>()
        var imported: [MeetingRecord] = []
        for folder in folders {
            for item in MeetingLegacyImporter.scan(folder: folder, fileManager: fileManager)
            where !referenced.contains(item.path) && seen.insert(item.path).inserted {
                let year = MeetingLibraryLayout.yearFolder(for: item.start)
                let base = MeetingLibraryLayout.folderName(start: item.start, title: title)
                let name = MeetingLibraryLayout.unique(base) { candidate in
                    let dir = year + "/" + candidate
                    return taken.contains(dir) || fileManager.fileExists(atPath: root.appendingPathComponent(dir).path)
                }
                let dir = year + "/" + name
                taken.insert(dir)
                let meta = MeetingMeta(type: .free, title: title, start: item.start, end: item.end,
                                       status: item.summarized ? .summarized : .transcribed,
                                       template: MeetingMinutesTemplate.content.storageValue, legacyPath: item.path)
                guard let data = meta.encoded() else { continue }
                write(data, to: root.appendingPathComponent(dir, isDirectory: true)
                    .appendingPathComponent(MeetingLibraryLayout.metaFileName))
                imported.append(MeetingRecord(dir: dir, meta: meta))
            }
        }
        return imported
    }

    /// 保留时长：超过的移到废纸篓（只在启动时做；改了设置下次启动生效，免得在设置里一选就删掉一批）。
    private func applyRetention() {
        let days = MeetingSettings.retentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let expired = records.filter { record in
            record.meta.start < cutoff && !activeIDs.contains(record.id)
                && record.meta.status != .recording && record.meta.status != .summarizing
        }
        guard !expired.isEmpty else { return }
        storeLog.notice("retention \(days) days: moving \(expired.count) meetings to the Trash")
        for record in expired {
            delete(record.id)
        }
    }

    // MARK: - 写

    /// 新开一场会议：分目录、写 meta.json（状态「记录中」）、进索引。
    func createMeeting(type: MeetingType, title: String, start: Date, event: MeetingEventInfo?,
                       template: String) -> MeetingRecord {
        let dir = reserveDirectory(start: start, title: title)
        let calendar = event.map(MeetingCalendarRef.init(event:))
        let meta = MeetingMeta(type: type, title: title, start: start, attendees: event?.attendees ?? [],
                               calendar: calendar?.isEmpty == true ? nil : calendar, status: .recording,
                               template: template)
        let record = MeetingRecord(dir: dir, meta: meta)
        activeIDs.insert(meta.id)
        insert(record)
        return record
    }

    /// 改一条的元信息（内存 + 排队写 meta.json 与索引）；`sync` = App 正在退出，写完再返回。
    func update(_ id: String, sync: Bool = false, _ change: (inout MeetingMeta) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        change(&record.meta)
        guard record != records[index] else {
            if sync { flush() }
            return
        }
        records[index] = record
        records = MeetingLibraryScanner.sorted(records)
        writeMeta(record, sync: sync)
        writeIndex(sync: sync)
    }

    /// 行动项勾选完成 / 取消（写回 meta.json）。
    func setActionItem(_ itemID: String, done: Bool, inMeeting id: String) {
        update(id) { meta in
            guard let index = meta.actionItems.firstIndex(where: { $0.id == itemID }) else { return }
            meta.actionItems[index].done = done
        }
    }

    /// 这一场写完了（转录收尾、纪要也处理完）：之后启动修复、保留时长清理照常管它。
    func finishWriting(_ id: String) {
        activeIDs.remove(id)
    }

    /// 删除：会议目录（迁移进来的旧记录连原文件）移到废纸篓，出索引。
    func delete(_ id: String, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard let record = record(id) else {
            completion?(false)
            return
        }
        var targets = [directoryURL(for: record)]
        if let legacy = record.meta.legacyPath {
            targets.append(URL(fileURLWithPath: legacy))
        }
        records.removeAll { $0.id == id }
        activeIDs.remove(id)
        writeIndex()
        io.async {
            var succeeded = true
            for url in targets where FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    succeeded = false
                    storeLog.error("trash failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let result = succeeded
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion?(result) }
            }
        }
    }

    /// 作废一场什么也没记下的会议（没开起来、开了又马上结束）：目录里只有 meta.json，直接删掉，不进废纸篓。
    func discard(_ id: String) {
        guard let record = record(id) else { return }
        let folder = directoryURL(for: record)
        records.removeAll { $0.id == id }
        activeIDs.remove(id)
        writeIndex()
        io.async {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: folder.appendingPathComponent(MeetingLibraryLayout.metaFileName))
            // 只删空目录（以防万一里面有了别的东西）。
            if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fileManager.removeItem(at: folder)
            }
        }
    }

    /// 整份重写一场会议的 Markdown（重新生成纪要：纪要一节换掉，别的原样）；写完回主线程报结果。
    func writeMarkdown(_ id: String, text: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let record = record(id) else {
            completion(false)
            return
        }
        let url = markdownURL(for: record)
        let data = Data(text.utf8)
        io.async {
            let succeeded = Self.write(data, to: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(succeeded) }
            }
        }
    }

    /// 写周报（同一周再生成就覆盖）；写好回主线程给文件位置，失败为 nil。
    func writeWeekly(_ key: String, text: String, completion: @escaping @MainActor @Sendable (URL?) -> Void) {
        let url = weeklyURL(key)
        let data = Data(text.utf8)
        io.async {
            let succeeded = Self.write(data, to: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(succeeded ? url : nil) }
            }
        }
    }

    /// 等排着的写盘做完（App 退出前）。
    func flush() {
        io.sync {}
    }

    // MARK: - Finder

    /// 在 Finder 中打开会议库目录（还没有就先建）。
    func openInFinder() {
        let url = rootURL
        io.async {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 在 Finder 中选中这场会议的 Markdown（还没有就选中目录）。
    func reveal(_ id: String) {
        guard let record = record(id) else { return }
        let markdown = markdownURL(for: record)
        let folder = directoryURL(for: record)
        io.async {
            let target = FileManager.default.fileExists(atPath: markdown.path) ? markdown : folder
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
        }
    }

    /// 打开这场会议的 Markdown（第一段的临时入口；第二段换成会议库窗口的详情）。
    func open(_ id: String) {
        guard let record = record(id) else { return }
        let url = markdownURL(for: record)
        io.async {
            let exists = FileManager.default.fileExists(atPath: url.path)
            DispatchQueue.main.async {
                if exists {
                    NSWorkspace.shared.open(url)
                } else {
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
            }
        }
    }

    // MARK: - 内部

    private func insert(_ record: MeetingRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
        records = MeetingLibraryScanner.sorted(records)
        writeMeta(record)
        writeIndex()
    }

    /// 分一个目录：「yyyy/yyyy-MM-dd HH-mm 标题」，撞名加「 (2)」。
    private func reserveDirectory(start: Date, title: String) -> String {
        let year = MeetingLibraryLayout.yearFolder(for: start)
        let base = MeetingLibraryLayout.folderName(start: start, title: title)
        let known = Set(records.map(\.dir)).union(reservedDirs)
        let root = rootURL
        let name = MeetingLibraryLayout.unique(base) { candidate in
            let dir = year + "/" + candidate
            return known.contains(dir) || FileManager.default.fileExists(atPath: root.appendingPathComponent(dir).path)
        }
        let dir = year + "/" + name
        reservedDirs.insert(dir)
        return dir
    }

    private func writeMeta(_ record: MeetingRecord, sync: Bool = false) {
        guard let data = record.meta.encoded() else { return }
        let url = directoryURL(for: record).appendingPathComponent(MeetingLibraryLayout.metaFileName)
        perform(sync: sync) { Self.write(data, to: url) }
    }

    private func writeIndex(sync: Bool = false) {
        guard let data = MeetingLibraryScanner.encodeIndex(records) else { return }
        let url = rootURL.appendingPathComponent(MeetingLibraryLayout.indexFileName)
        perform(sync: sync) { Self.write(data, to: url) }
    }

    private func perform(sync: Bool, _ work: @escaping @Sendable () -> Void) {
        if sync {
            io.sync(execute: work)
        } else {
            io.async(execute: work)
        }
    }

    @discardableResult
    nonisolated private static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            storeLog.error("write \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 纪要的结果 → 会议库里的状态。
    nonisolated static func status(after outcome: MeetingMinutesOutcome) -> MeetingStatus {
        switch outcome {
        case .generating: return .summarizing
        case .done: return .summarized
        case .failed: return .failed
        case .off, .noModel, .tooShort, .interrupted: return .transcribed
        }
    }
}

// MARK: - 自由听译的新记录写进会议库（docs/meeting/TECH_DESIGN.md §2.3、ENGINE.md §4.5.3）

extension MeetingStore: FreeListeningLibrary {
    var folderURL: URL { rootURL }

    /// 每份自由听译记录一条：目录「yyyy-MM-dd HH-mm 自由听译」，记下第一句时才进索引（一句没有就不留痕迹）。
    /// 自由听译的版式（`.content` 模板、不标说话人），纪要整理好发「实时翻译纪要已整理好」。
    func beginFreeListeningRecord(start: Date, run: MeetingEngineRun, summarizes: Bool) -> FreeListeningRecord {
        let title = L("meeting.type.free")
        let dir = reserveDirectory(start: start, title: title)
        let id = UUID().uuidString
        var destination = MeetingTranscript.Destination(
            fileURL: rootURL.appendingPathComponent(dir, isDirectory: true)
                .appendingPathComponent(MeetingLibraryLayout.markdownFileName),
            displayName: (dir as NSString).lastPathComponent)
        destination.summarizes = summarizes
        destination.onEvent = { event in
            MeetingStore.shared.freeListening(event, id: id, dir: dir, start: start, title: title)
        }
        return MeetingTranscript(start: start, config: run, destination: destination)
    }

    private func freeListening(_ event: MeetingTranscriptEvent, id: String, dir: String, start: Date,
                               title: String) {
        switch event {
        case .created:
            activeIDs.insert(id)
            insert(MeetingRecord(dir: dir, meta: MeetingMeta(
                id: id, type: .free, title: title, start: start, status: .recording,
                template: MeetingMinutesTemplate.content.storageValue)))
        case .finished(let end, let minutes, let terminating):
            update(id, sync: terminating) { meta in
                meta.end = end
                meta.status = Self.status(after: minutes)
            }
            if minutes != .generating {
                finishWriting(id)
            }
        case .minutes(let outcome):
            update(id, sync: outcome == .interrupted) { meta in
                meta.status = Self.status(after: outcome)
            }
            finishWriting(id)
        }
    }
}
