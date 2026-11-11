import Foundation

/// Claude Code 助手 —— 会话 JSONL 的解析、索引、审计与磁盘维护。
///
/// 数据源见 TECH_DESIGN 2.2。所有解析都必须容错：任何字段缺失 / 类型不符都只跳过或降级，
/// **决不 crash**（无 force unwrap、无 try!）。重 IO 一律后台，完成后回主线程发布 `@Published`。
///
/// 刷新、复用、排序、删除、导出外壳、磁盘缓存与清理旧会话在与 Codex 助手共用的 `Core/CLISession/`（#109）：
/// 本文件只留 Claude Code 的「格式」`ClaudeSessionFormat`（会话文件在哪、怎么快扫、怎么导出、缓存放哪）
/// 与独有的审计、`~/.claude` 磁盘分布。
///
/// 用户可见文案：本文件仅一处降级标题用 L()：
///   - `claudecode.session.untitled` —— 无标题会话占位。
///     en: "(untitled session)" / zh-Hans: "(无标题会话)"

// MARK: - 逐行 JSON 解析工具（本模块共享）

/// 会话 / 事件 JSONL 里 Claude Code 独有的解析辅助。逐行解析与时间戳用共用的 `CLIJSONL`。
enum ClaudeJSONLParsing {

    /// 从 message.content 提取首个可读文本。
    /// content 可能是纯字符串，或 `[{type:text,text:...}, {type:tool_use,...}]` 数组。
    nonisolated static func extractText(fromContent content: Any) -> String? {
        if let text = content as? String {
            return text
        }
        if let blocks = content as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "text" {
                if let text = block["text"] as? String { return text }
            }
        }
        return nil
    }
}

// MARK: - 数据模型

/// 一条会话摘要（用于列表 / 菜单展示与续接）。
struct ClaudeSessionSummary: Identifiable, Equatable, CLISessionSummary {
    /// 文件名里的 uuid。
    let id: String
    let fileURL: URL
    /// 项目路径（cwd）。
    let projectPath: String
    /// 项目展示名（cwd 末段）。
    var projectName: String
    let title: String
    let lastActivity: Date
    let fileSize: Int64
    /// 末次 assistant 消息的 model id;快扫窗口内没有 assistant 行则为 nil。
    var model: String?
    /// 末次请求的上下文规模(input + cache_read + cache_creation tokens);同上可为 nil。
    var contextTokens: Int?
}

/// 审计：某文件被改动的次数与末次时间。
struct ClaudeAuditEntry: Identifiable {
    let id: String            // 文件路径即唯一键
    let filePath: String
    var count: Int
    var lastEdited: Date
}

/// 审计：按项目分组的改动。
struct ClaudeAuditProject: Identifiable {
    let id: String            // 项目路径即唯一键
    let projectPath: String
    let projectName: String
    var entries: [ClaudeAuditEntry]
    var totalCount: Int
}

/// `~/.claude` 磁盘占用分布。
struct ClaudeDiskStats {
    var projectsBytes: Int64 = 0
    var todosBytes: Int64 = 0
    var shellSnapshotsBytes: Int64 = 0
    var otherBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var sessionFileCount: Int = 0
}

// MARK: - 索引单例

/// 会话索引：内存缓存 + 磁盘 index-cache-v2.json，快扫（头 64KB + 尾 8KB）+ 增量复用，都在共用的 `CLISessionIndex`。
/// 这里只加 Claude 独有的审计与磁盘分布。
@MainActor
final class ClaudeSessionIndex: CLISessionIndex<ClaudeSessionFormat> {
    static let shared = ClaudeSessionIndex()

    /// 参与审计的编辑类工具。后台 nonisolated 静态方法要读它，故显式 nonisolated（不可变 Sendable）。
    nonisolated static let editToolNames: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private override init() {
        super.init()
    }

    // MARK: - 审计

    /// 某日的改动审计（按项目分组）。全量后台流式处理，完成回主线程。
    func auditEntries(on day: Date, completion: @escaping ([ClaudeAuditProject]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let projects = Self.computeAudit(on: day)
            DispatchQueue.main.async {
                completion(projects)
            }
        }
    }

    // MARK: - 磁盘统计

    /// 统计 `~/.claude` 占用分布。后台计算，完成回主线程。
    func diskStats(completion: @escaping (ClaudeDiskStats) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let stats = Self.computeDiskStats()
            DispatchQueue.main.async {
                completion(stats)
            }
        }
    }
}

// MARK: - 缓存记录

/// index-cache-v2.json 的一条记录（原 `ClaudeSessionIndex.CacheRecord`）。可 Codable 持久化，字段名就是缓存文件里的键，别改。
struct ClaudeSessionRecord: CLISessionRecord {
    let modified: Double       // mtime.timeIntervalSince1970
    let size: Int64
    let id: String
    let projectPath: String
    let projectName: String
    let title: String
    let lastActivity: Double   // timeIntervalSince1970
    var model: String?
    var contextTokens: Int?

    func toSummary(fileURL: URL) -> ClaudeSessionSummary {
        ClaudeSessionSummary(
            id: id,
            fileURL: fileURL,
            projectPath: projectPath,
            projectName: projectName,
            title: title,
            lastActivity: Date(timeIntervalSince1970: lastActivity),
            fileSize: size,
            model: model,
            contextTokens: contextTokens
        )
    }
}

// MARK: - 格式（后台扫描 / 解析，全部静态，可在后台线程调用）

/// Claude Code 会话日志的格式：`~/.claude/projects/<项目>/<会话>.jsonl`，缓存落盘到 index-cache-v2.json。
enum ClaudeSessionFormat: CLISessionFormat {

    /// v2:新增 model / contextTokens 字段,换文件名让旧缓存整体失效重扫一次。
    static var cacheFileURL: URL? {
        ClaudeEnv.supportDir.appendingPathComponent("index-cache-v2.json")
    }

    /// 清理旧会话的根目录。
    static var logRoot: URL {
        ClaudeEnv.projectsDir
    }

    /// projects 下一层项目目录里的全部 jsonl。
    static func sessionFiles() -> [CLISessionFile] {
        CLISessionFiles.jsonlInSubdirectories(of: ClaudeEnv.projectsDir)
    }

    static func summary(of record: ClaudeSessionRecord, fileURL: URL) -> ClaudeSessionSummary {
        record.toSummary(fileURL: fileURL)
    }

    /// 快扫单个文件：读头 64KB + 尾 8KB。头取 summary/首条 user/cwd，尾取末次时间戳与末次 cwd。
    /// 头尾都没有 cwd 时从所在项目目录名（munged）反推展示路径。
    static func scan(_ file: CLISessionFile) -> ClaudeSessionRecord? {
        let url = file.url
        let mtime = file.modified
        let size = file.size
        let mungedDir = url.deletingLastPathComponent().lastPathComponent
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let headData: Data
        let tailData: Data
        do {
            headData = (try handle.read(upToCount: 64 * 1024)) ?? Data()
            let end = try handle.seekToEnd()
            if end > 8 * 1024 {
                try handle.seek(toOffset: end - 8 * 1024)
            } else {
                try handle.seek(toOffset: 0)
            }
            tailData = (try handle.read(upToCount: 8 * 1024)) ?? Data()
        } catch {
            return nil
        }

        // —— 头块：标题与 cwd；model 先取头块首个 assistant 作兜底 ——
        var summaryTitle: String?
        var firstUserText: String?
        var cwd: String?
        var model: String?
        for lineData in headData.split(separator: 0x0A) {
            guard let object = CLIJSONL.parseObject(Data(lineData)) else { continue }
            let type = object["type"] as? String
            if summaryTitle == nil, type == "summary", let s = object["summary"] as? String {
                summaryTitle = s
            }
            if let dirValue = object["cwd"] as? String, !dirValue.isEmpty {
                cwd = dirValue   // 保留头块中最后一次
            }
            if model == nil, type == "assistant", let m = assistantModel(object) {
                model = m
            }
            if firstUserText == nil, type == "user",
               let message = object["message"] as? [String: Any],
               let content = message["content"],
               let text = ClaudeJSONLParsing.extractText(fromContent: content) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 跳过系统注入（如 <command-name>…）。
                if !trimmed.isEmpty, !trimmed.hasPrefix("<") {
                    firstUserText = trimmed
                }
            }
        }

        // —— 尾块：末次时间戳 / cwd / model / 上下文规模(末次 assistant usage) ——
        var lastActivity: Date?
        var contextTokens: Int?
        for lineData in tailData.split(separator: 0x0A) {
            guard let object = CLIJSONL.parseObject(Data(lineData)) else { continue }
            if let dirValue = object["cwd"] as? String, !dirValue.isEmpty {
                cwd = dirValue
            }
            if let ts = object["timestamp"] as? String, let date = CLIJSONL.parseDate(ts) {
                lastActivity = date
            }
            if (object["type"] as? String) == "assistant" {
                if let m = assistantModel(object) { model = m }   // 末次覆盖
                if let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    let input = (usage["input_tokens"] as? Int) ?? 0
                    let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    let total = input + cacheRead + cacheWrite
                    if total > 0 { contextTokens = total }
                }
            }
        }

        let resolvedPath = cwd ?? ClaudeSessionIndex.demungeDirName(mungedDir)
        let projectName = CLISessionPaths.projectName(fromPath: resolvedPath)
        let title = summaryTitle
            ?? firstUserText.map { String($0.prefix(60)) }
            ?? L("claudecode.session.untitled")
        let activity = lastActivity ?? mtime
        let id = url.deletingPathExtension().lastPathComponent

        return ClaudeSessionRecord(
            modified: mtime.timeIntervalSince1970,
            size: size,
            id: id,
            projectPath: resolvedPath,
            projectName: projectName,
            title: title,
            lastActivity: activity.timeIntervalSince1970,
            model: model,
            contextTokens: contextTokens
        )
    }

    /// 从 assistant 行取 message.model,过滤 `<synthetic>` 等占位值。
    private static func assistantModel(_ object: [String: Any]) -> String? {
        guard let m = (object["message"] as? [String: Any])?["model"] as? String,
              !m.isEmpty, !m.hasPrefix("<") else { return nil }
        return m
    }

    /// 逐行解析成 Markdown（## User / ## Assistant）。
    static func markdown(fileURL: URL, title: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        var lines: [String] = ["# \(title)", ""]
        for lineData in data.split(separator: 0x0A) {
            guard let object = CLIJSONL.parseObject(Data(lineData)),
                  let type = object["type"] as? String,
                  type == "user" || type == "assistant",
                  let message = object["message"] as? [String: Any] else { continue }

            let text: String?
            if type == "user" {
                text = message["content"].flatMap { ClaudeJSONLParsing.extractText(fromContent: $0) }
            } else {
                // assistant.content 是数组，拼接全部 text 块。
                if let blocks = message["content"] as? [[String: Any]] {
                    let joined = blocks.compactMap { block -> String? in
                        (block["type"] as? String) == "text" ? block["text"] as? String : nil
                    }.joined(separator: "\n\n")
                    text = joined.isEmpty ? nil : joined
                } else {
                    text = message["content"].flatMap { ClaudeJSONLParsing.extractText(fromContent: $0) }
                }
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lines.append(type == "user" ? "## User" : "## Assistant")
            lines.append("")
            lines.append(text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 审计 / 磁盘统计（全部 nonisolated static，可在后台线程调用）

extension ClaudeSessionIndex {

    /// 某日改动审计。全量逐文件逐行流式处理。
    nonisolated static func computeAudit(on day: Date) -> [ClaudeAuditProject] {
        let fm = FileManager.default
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        // 项目路径 → (项目名, 文件路径 → 审计条目)
        var grouped: [String: (name: String, entries: [String: ClaudeAuditEntry])] = [:]

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudeEnv.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                // 文件 mtime 早于当日起点则整文件跳过（改动不可能落在当日）。
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mtime, mtime < dayStart { continue }

                autoreleasepool {  // 每个文件读完就放掉临时对象，峰值不随文件数累加（#93）
                    guard let data = try? Data(contentsOf: file) else { return }
                    let mungedName = projectDir.lastPathComponent

                    for lineData in data.split(separator: 0x0A) {
                        guard let object = CLIJSONL.parseObject(Data(lineData)),
                              (object["type"] as? String) == "assistant",
                              let ts = object["timestamp"] as? String,
                              let date = CLIJSONL.parseDate(ts),
                              date >= dayStart, date < dayEnd,
                              let message = object["message"] as? [String: Any],
                              let content = message["content"] as? [[String: Any]] else { continue }

                        let projectPath = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                            ?? demungeDirName(mungedName)

                        for block in content where (block["type"] as? String) == "tool_use" {
                            guard let name = block["name"] as? String, editToolNames.contains(name),
                                  let input = block["input"] as? [String: Any] else { continue }
                            let filePath = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
                            guard let filePath, !filePath.isEmpty else { continue }

                            var bucket = grouped[projectPath] ?? (name: projectName(fromPath: projectPath), entries: [:])
                            if var entry = bucket.entries[filePath] {
                                entry.count += 1
                                if date > entry.lastEdited { entry.lastEdited = date }
                                bucket.entries[filePath] = entry
                            } else {
                                bucket.entries[filePath] = ClaudeAuditEntry(id: filePath, filePath: filePath, count: 1, lastEdited: date)
                            }
                            grouped[projectPath] = bucket
                        }
                    }
                }
            }
        }

        // 组装并排序：项目按总次数降序，条目按末次时间降序。
        var projects: [ClaudeAuditProject] = grouped.map { path, bucket in
            let entries = bucket.entries.values.sorted { $0.lastEdited > $1.lastEdited }
            let total = entries.reduce(0) { $0 + $1.count }
            return ClaudeAuditProject(id: path, projectPath: path, projectName: bucket.name, entries: entries, totalCount: total)
        }
        projects.sort { $0.totalCount > $1.totalCount }
        return projects
    }

    /// 磁盘占用分布。
    nonisolated static func computeDiskStats() -> ClaudeDiskStats {
        var stats = ClaudeDiskStats()
        let claudeDir = ClaudeEnv.claudeDir
        let total = directorySize(claudeDir)
        stats.totalBytes = total

        let (projectsBytes, sessionCount) = projectsSizeAndCount()
        stats.projectsBytes = projectsBytes
        stats.sessionFileCount = sessionCount
        stats.todosBytes = directorySize(claudeDir.appendingPathComponent("todos", isDirectory: true))
        stats.shellSnapshotsBytes = directorySize(claudeDir.appendingPathComponent("shell-snapshots", isDirectory: true))
        stats.otherBytes = max(0, total - stats.projectsBytes - stats.todosBytes - stats.shellSnapshotsBytes)
        return stats
    }

    // MARK: - 私有辅助

    /// munged 目录名反推展示路径（仅展示用，lossy）。munge 把 `/` 与 `.` 都换成了 `-`。
    nonisolated static func demungeDirName(_ dir: String) -> String {
        dir.replacingOccurrences(of: "-", with: "/")
    }

    /// 目录递归总字节数（enumerator 遍历，容错）。
    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: []
              ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// projects 目录字节数与 jsonl 文件计数。
    nonisolated static func projectsSizeAndCount() -> (Int64, Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: ClaudeEnv.projectsDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
        ) else { return (0, 0) }
        var total: Int64 = 0
        var count = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
            if child.pathExtension == "jsonl" { count += 1 }
        }
        return (total, count)
    }
}
