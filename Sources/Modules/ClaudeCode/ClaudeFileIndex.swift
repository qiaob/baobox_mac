import AppKit
import os
import UniformTypeIdentifiers

/// Claude Code 助手 —— 最近文件索引：从会话 JSONL 提取 Write/Edit 等工具写过的文件。
///
/// 设计见 docs/claude-code-assistant/RECENT_FILES.md。要点：
/// - 每 jsonl 一条缓存记录（mtime+size 未变整条复用；size 变大按字节偏移只解析追加部分；
///   变小或重写则全量重解析），持久化到 supportDir/file-index-cache-v1.json。
/// - 解析只到最后一个完整行（`\n`）为止，CLI 正在写的半行留给下次，不丢不重。
/// - 发布时按规范化路径合并全部会话，默认排除 `~/.claude/**` 与 `/.git/`，
///   按末次写入降序取前 500，且只保留磁盘上仍存在的文件。
/// - 解析全程容错：任何字段缺失 / IO 失败只跳过或降级，决不 crash。

// MARK: - 文件分类

/// 文件类别：面板筛选 chips 与「打开方式」映射共用。
/// 发布时按扩展名即时计算，不入缓存（调整映射无需升缓存版本）。
enum ClaudeFileCategory: String, CaseIterable, Identifiable, Codable {
    case doc
    case web
    case code
    case config
    case other

    var id: String { rawValue }

    /// 「打开方式」偏好的 UserDefaults 键（值 = bundleIdentifier，空/未设 = 系统默认）。
    var openAppDefaultsKey: String { "claudecode.openApp." + rawValue }

    /// 类别展示名（chips / 设置行共用）。
    var title: String {
        switch self {
        case .doc: return L("claudecode.files.category.doc")
        case .web: return L("claudecode.files.category.web")
        case .code: return L("claudecode.files.category.code")
        case .config: return L("claudecode.files.category.config")
        case .other: return L("claudecode.files.category.other")
        }
    }

    private static let docExtensions: Set<String> = [
        "md", "markdown", "mdx", "txt", "rst", "adoc", "rtf",
    ]
    /// 浏览器当页面打开的；css/vue/tsx 属创作产物 → code。
    private static let webExtensions: Set<String> = [
        "html", "htm", "xhtml",
    ]
    private static let configExtensions: Set<String> = [
        "yaml", "yml", "json", "toml", "ini", "conf", "cfg", "plist",
        "properties", "env", "xml", "xcstrings", "lock",
    ]
    private static let codeExtensions: Set<String> = [
        "swift", "py", "java", "ts", "tsx", "js", "jsx", "vue", "css", "scss",
        "sh", "zsh", "bash", "sql", "go", "rs", "rb", "php", "c", "h", "cpp",
        "hpp", "cc", "m", "mm", "kt", "kts", "scala", "cs", "dart", "lua", "pl", "r",
    ]

    static func category(forPath path: String) -> ClaudeFileCategory {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        if docExtensions.contains(ext) { return .doc }
        if webExtensions.contains(ext) { return .web }
        if configExtensions.contains(ext) { return .config }
        if codeExtensions.contains(ext) { return .code }
        return .other
    }
}

// MARK: - 数据模型

/// 一条最近文件（面板文件模式的行）。
struct ClaudeRecentFile: Identifiable, Equatable {
    /// 路径即唯一键。
    var id: String { filePath }
    /// 规范化绝对路径（standardizedFileURL，不解析符号链接）。
    let filePath: String
    /// 末次写入行的 cwd。
    let projectPath: String
    let projectName: String
    /// 末次写入所在会话（归因，v1 不展示）。
    let sessionId: String
    let lastWritten: Date
    /// 四种编辑工具（Write/Edit/MultiEdit/NotebookEdit）合并计数。
    let writeCount: Int
    let category: ClaudeFileCategory

    var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

// MARK: - 打开偏好

/// 「打开方式」与「包含内部文件」的 UserDefaults 访问。仅主线程读写。
enum ClaudeFileOpenSettings {
    static let includeInternalKey = "claudecode.files.includeInternal"

    static var includeInternal: Bool {
        get { UserDefaults.standard.bool(forKey: includeInternalKey) }
        set { UserDefaults.standard.set(newValue, forKey: includeInternalKey) }
    }

    /// 类别映射的 App；未设或已清空返回 nil（= 系统默认）。
    static func appBundleID(for category: ClaudeFileCategory) -> String? {
        guard let value = UserDefaults.standard.string(forKey: category.openAppDefaultsKey),
              !value.isEmpty else { return nil }
        return value
    }

    static func setAppBundleID(_ bundleID: String?, for category: ClaudeFileCategory) {
        if let bundleID, !bundleID.isEmpty {
            UserDefaults.standard.set(bundleID, forKey: category.openAppDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: category.openAppDefaultsKey)
        }
    }
}

// MARK: - 打开器

/// 打开 / 访达显示 / 复制路径。触碰 NSWorkspace，主线程调用。
@MainActor
enum ClaudeFileOpener {

    /// 打开失败时的诊断（`log stream --predicate 'subsystem == "com.baobox.app"'`）。
    private static let log = Logger(subsystem: "com.baobox.app", category: "recentfiles")

    /// 按类别偏好应用打开；未配置或 App 已卸载回退系统默认。永不报错。
    ///
    /// 关键点：本 App 是后台 LSUIElement，面板又是非激活面板，此时目标 App 默认可能拿不到
    /// 激活权——文件其实打开了、窗口却留在后台，看起来像「没反应」。故显式用带
    /// `activates = true` 的 OpenConfiguration，并在完成回调里记录失败原因。
    static func open(_ file: ClaudeRecentFile) {
        let url = URL(fileURLWithPath: file.filePath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        if let bundleID = ClaudeFileOpenSettings.appBundleID(for: file.category),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                guard let error else { return }
                log.error("open with app failed: \(error.localizedDescription, privacy: .public)")
                // 指定 App 打不开（版本不兼容 / 已损坏等）时兜底系统默认，不让用户白按一次。
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
                }
            }
        } else {
            NSWorkspace.shared.open(url, configuration: config) { _, error in
                if let error {
                    log.error("open failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    static func reveal(_ file: ClaudeRecentFile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.filePath)])
    }

    static func copyPath(_ file: ClaudeRecentFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.filePath, forType: .string)
    }
}

// MARK: - 图标缓存

/// 按扩展名取 UTType 图标（无磁盘 stat）。实际不同扩展名十几个，静态字典即可。
@MainActor
enum ClaudeFileIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forFileName fileName: String) -> NSImage {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let type: UTType = ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[ext] = image
        return image
    }
}

// MARK: - 索引单例

/// 最近文件索引：内存缓存 + 磁盘 file-index-cache-v1.json，增量扫描（偏移续读）。
@MainActor
final class ClaudeFileIndex: ObservableObject {
    static let shared = ClaudeFileIndex()

    /// 新→旧排序，已过滤（内部路径 / .git / 已删除），最多 500 条。
    @Published private(set) var files: [ClaudeRecentFile] = []
    /// 是否正在刷新（供 UI 显示首建加载态）。
    @Published private(set) var isRefreshing = false

    /// 键 = jsonl 文件路径。仅主线程读写。
    private var cache: [String: FileCacheRecord] = [:]
    private var refreshing = false
    private var saveWorkItem: DispatchWorkItem?

    /// 发布列表上限。
    nonisolated static let maxPublished = 500

    private var cacheFileURL: URL {
        ClaudeEnv.supportDir.appendingPathComponent("file-index-cache-v1.json")
    }

    private init() {
        loadCache()
    }

    // MARK: - 刷新

    /// 后台增量扫描全部 jsonl → 合并过滤 → 回主线程发布。去抖，进行中不重入。
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        isRefreshing = true
        let previousCache = cache                                  // 主线程快照，传入后台
        let includeInternal = ClaudeFileOpenSettings.includeInternal  // 主线程读 UserDefaults
        DispatchQueue.global(qos: .utility).async {
            let newCache = Self.scanAll(previousCache: previousCache)
            let published = Self.publishList(from: newCache, includeInternal: includeInternal)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.files = published
                    self.cache = newCache
                    self.refreshing = false
                    self.isRefreshing = false
                    self.scheduleCacheSave()
                }
            }
        }
    }

    /// App 退出前立即落盘缓存。
    func flushCache() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveCacheNow()
    }

    // MARK: - 缓存持久化（同 ClaudeSessionIndex 的 1s 防抖模式）

    private func scheduleCacheSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveCacheNow()
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func saveCacheNow() {
        let snapshot = cache
        let url = cacheFileURL
        DispatchQueue.global(qos: .utility).async {
            ClaudeEnv.ensureSupportDir()
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url)
            }
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let decoded = try? JSONDecoder().decode([String: FileCacheRecord].self, from: data) else {
            return
        }
        cache = decoded
    }
}

// MARK: - 缓存记录

extension ClaudeFileIndex {
    /// file-index-cache-v1.json 的一条记录（对应一个会话 jsonl）。
    struct FileCacheRecord: Codable {
        var modified: Double        // mtime.timeIntervalSince1970（容差 0.001 比较）
        var size: Int64
        /// 已消费到「最后一个完整行」之后的字节位置；追加时从这里续读。
        var parsedOffset: Int64
        var sessionId: String
        /// 键 = 规范化文件路径。
        var entries: [String: EntryRecord]

        struct EntryRecord: Codable {
            var count: Int
            var last: Double        // 末次写入 timeIntervalSince1970
            var projectPath: String
        }
    }
}

// MARK: - 后台扫描 / 解析（全部 nonisolated static，可在后台线程调用）

extension ClaudeFileIndex {

    /// 遍历 projects 下全部 jsonl：未变复用 / 追加续读 / 其余全量重解析。
    nonisolated static func scanAll(previousCache: [String: FileCacheRecord]) -> [String: FileCacheRecord] {
        let fm = FileManager.default
        var newCache: [String: FileCacheRecord] = [:]

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudeEnv.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let mungedDir = projectDir.lastPathComponent
            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                let size = Int64(values?.fileSize ?? 0)
                let path = file.path

                // ① mtime+size 都没变：整条复用，零 IO。
                if let record = previousCache[path],
                   abs(record.modified - mtime.timeIntervalSince1970) < 0.001,
                   record.size == size {
                    newCache[path] = record
                    continue
                }

                // ② 只追加（size 变大）：从上次偏移续读。失败则退回全量。
                if let previous = previousCache[path],
                   size > previous.size,
                   previous.parsedOffset >= 0, previous.parsedOffset <= previous.size,
                   let updated = parseRecord(file, mtime: mtime, size: size,
                                             startOffset: previous.parsedOffset,
                                             baseEntries: previous.entries,
                                             mungedDir: mungedDir) {
                    newCache[path] = updated
                    continue
                }

                // ③ 全量解析（新文件 / 变小 / 重写 / 续读失败）。
                if let record = parseRecord(file, mtime: mtime, size: size,
                                            startOffset: 0, baseEntries: [:],
                                            mungedDir: mungedDir) {
                    newCache[path] = record
                }
            }
        }
        return newCache
    }

    /// 从 startOffset 读到文件尾，解析完整行并合并进 baseEntries。
    /// 只消费到最后一个 `\n`；没有完整行则偏移原地不动（半行留给下次）。
    nonisolated static func parseRecord(
        _ url: URL, mtime: Date, size: Int64, startOffset: Int64,
        baseEntries: [String: FileCacheRecord.EntryRecord], mungedDir: String
    ) -> FileCacheRecord? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let data: Data
        do {
            if startOffset > 0 {
                try handle.seek(toOffset: UInt64(startOffset))
            }
            data = (try handle.readToEnd()) ?? Data()
        } catch {
            return nil
        }

        let sessionId = url.deletingPathExtension().lastPathComponent

        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            // 一整个完整行都没有：记录 mtime/size 防反复重读，偏移不动。
            return FileCacheRecord(modified: mtime.timeIntervalSince1970, size: size,
                                   parsedOffset: startOffset, sessionId: sessionId,
                                   entries: baseEntries)
        }
        let consumedCount = data.distance(from: data.startIndex, to: lastNewline) + 1
        let complete = data.prefix(consumedCount)

        var entries = baseEntries
        var lastCwd: String?
        for lineData in complete.split(separator: 0x0A) {
            guard let object = ClaudeJSONLParsing.parseObject(Data(lineData)) else { continue }
            let lineCwd = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let lineCwd { lastCwd = lineCwd }

            guard (object["type"] as? String) == "assistant",
                  let ts = object["timestamp"] as? String,
                  let date = ClaudeJSONLParsing.parseDate(ts),
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }

            let cwd = lineCwd ?? lastCwd
            let projectPath = cwd ?? ClaudeSessionIndex.demungeDirName(mungedDir)

            for block in content where (block["type"] as? String) == "tool_use" {
                guard let name = block["name"] as? String,
                      ClaudeSessionIndex.editToolNames.contains(name),
                      let input = block["input"] as? [String: Any] else { continue }
                let rawPath = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
                guard let rawPath, !rawPath.isEmpty,
                      let canonical = canonicalPath(rawPath, cwd: cwd) else { continue }

                let stamp = date.timeIntervalSince1970
                if var entry = entries[canonical] {
                    entry.count += 1
                    if stamp > entry.last {
                        entry.last = stamp
                        entry.projectPath = projectPath
                    }
                    entries[canonical] = entry
                } else {
                    entries[canonical] = .init(count: 1, last: stamp, projectPath: projectPath)
                }
            }
        }

        return FileCacheRecord(modified: mtime.timeIntervalSince1970, size: size,
                               parsedOffset: startOffset + Int64(consumedCount),
                               sessionId: sessionId, entries: entries)
    }

    /// 规范化为绝对路径：`~` 展开；相对路径按行内 cwd 解析，无 cwd 则放弃（不猜）。
    /// 只做字符串层规范化（不解析符号链接，避免逐路径 lstat）。
    nonisolated static func canonicalPath(_ raw: String, cwd: String?) -> String? {
        let expanded: String
        if raw.hasPrefix("/") {
            expanded = raw
        } else if raw.hasPrefix("~") {
            expanded = (raw as NSString).expandingTildeInPath
        } else if let cwd, !cwd.isEmpty {
            expanded = cwd + "/" + raw
        } else {
            return nil
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// 全部记录按路径合并 → 过滤（内部路径 / .git）→ 新→旧收集存在的文件，至多 maxPublished 条。
    nonisolated static func publishList(from cache: [String: FileCacheRecord],
                                        includeInternal: Bool) -> [ClaudeRecentFile] {
        struct Merged {
            var count: Int
            var last: Double
            var projectPath: String
            var sessionId: String
        }
        var merged: [String: Merged] = [:]
        for record in cache.values {
            for (path, entry) in record.entries {
                if var existing = merged[path] {
                    existing.count += entry.count
                    if entry.last > existing.last {
                        existing.last = entry.last
                        existing.projectPath = entry.projectPath
                        existing.sessionId = record.sessionId
                    }
                    merged[path] = existing
                } else {
                    merged[path] = Merged(count: entry.count, last: entry.last,
                                          projectPath: entry.projectPath,
                                          sessionId: record.sessionId)
                }
            }
        }

        let claudePrefix = ClaudeEnv.claudeDir.path + "/"
        let fm = FileManager.default
        let sorted = merged.sorted { $0.value.last > $1.value.last }

        var result: [ClaudeRecentFile] = []
        result.reserveCapacity(min(sorted.count, maxPublished))
        for (path, info) in sorted {
            if !includeInternal, path.hasPrefix(claudePrefix) { continue }
            if path.contains("/.git/") { continue }
            // 已删除 / 移走的不展示（缓存保留记录，文件恢复后自动回来）。
            guard fm.fileExists(atPath: path) else { continue }
            result.append(ClaudeRecentFile(
                filePath: path,
                projectPath: info.projectPath,
                projectName: ClaudeSessionIndex.projectName(fromPath: info.projectPath),
                sessionId: info.sessionId,
                lastWritten: Date(timeIntervalSince1970: info.last),
                writeCount: info.count,
                category: ClaudeFileCategory.category(forPath: path)
            ))
            if result.count >= maxPublished { break }
        }
        return result
    }
}
