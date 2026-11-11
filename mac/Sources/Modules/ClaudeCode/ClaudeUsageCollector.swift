import Foundation

/// Claude Code 用量条目的收集（#109）：列 `projects/<项目>/*.jsonl`，从近 N 小时改过的文件里取带 usage 的 assistant 行，
/// 按 message.id + requestId 去重，交给 5 小时 / 周窗口、今日累计与报表。
///
/// 按文件缓存解析结果（只在内存、进程内）：修改时间与大小都没变的文件直接用上一轮解析出的条目，只重新解析变了的。
/// hook 接通之后最快每分钟刷一次，全量解析近 180 小时的日志（实测 1.3 GB 约 11 秒 CPU）扛不住，增量之后只解析正在写的那几个文件。
/// 跨文件的去重不进缓存：缓存的是每个文件按行序排好的「候选条目 + 去重键」（同一个文件里的重复已经去掉，见 `candidates`），
/// 每一轮按原来的遍历顺序（项目目录 → 文件 → 行）在合并时重做，所以结果与每次全量解析逐条相同（顺序、去重、费用）。
/// 缓存只留修改时间在 `retentionHours` 以内、目录里还在的文件。
/// 修改时间与大小都没变、内容却变了的文件（或者只是变得读不了）会用旧结果 —— 与会话索引同一个前提。
///
/// 任意后台线程调用；刷新与报表可能同时在跑：缓存的读写在锁里，读文件、解析在锁外。
/// 只 import Foundation、不引用 App 与模块里的其他类型：进 BaoboxTests。
final class ClaudeUsageCollector: @unchecked Sendable {

    /// 一行用量：条目 + 去重键（message.id + "|" + requestId；只有 message.id 时就是它；都没有为 nil，不去重）。
    struct Candidate: Equatable, Sendable {
        let dedupKey: String?
        let entry: CLIUsageEntry
    }

    /// 一次收集的结果。`parsedFiles` / `reusedFiles`：这一轮重新解析了几个文件、直接用了缓存的有几个。
    struct Collection: Sendable {
        let entries: [CLIUsageEntry]
        let parsedFiles: Int
        let reusedFiles: Int
    }

    private struct CachedFile {
        let modified: Date
        let size: Int
        let candidates: [Candidate]
    }

    let projectsDir: URL
    /// 缓存只留修改时间在这么多小时以内的文件（= 菜单刷新的采集窗口）。报表看得更久，更早的文件照旧每次解析、不进缓存。
    let retentionHours: Int
    /// 项目目录名（`/` 换成了 `-`）→ 展示用路径：行里没有 cwd 时用。
    private let fallbackProjectPath: @Sendable (String) -> String
    private let lock = NSLock()
    /// 键 = 文件路径。只在锁里读写。
    private var cache: [String: CachedFile] = [:]

    init(projectsDir: URL, retentionHours: Int, fallbackProjectPath: @escaping @Sendable (String) -> String) {
        self.projectsDir = projectsDir
        self.retentionHours = retentionHours
        self.fallbackProjectPath = fallbackProjectPath
    }

    /// 缓存里现在有几个文件。
    var cachedFileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// 收集近 `hours` 小时内改过的文件的去重用量条目。
    /// 列目录、过滤、逐行解析与去重的规则照搬原来的全量解析（`FileManager` 的调用与选项相同，多取一个文件大小）。
    func collect(sinceHoursAgo hours: Int, now: Date = Date()) -> Collection {
        let cutoff = now.addingTimeInterval(-Double(hours) * 3_600)
        let retentionCutoff = now.addingTimeInterval(-Double(retentionHours) * 3_600)
        lock.lock()
        let previous = cache
        lock.unlock()

        var files: [[Candidate]] = []
        var updates: [String: CachedFile] = [:]
        /// 这一轮列到的、修改时间还在保留窗口里的文件：缓存只留这些（不在目录里的、过期了的在末尾删掉）。
        var keptPaths = Set<String>()
        var parsed = 0
        var reused = 0

        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let fallbackPath = fallbackProjectPath(projectDir.lastPathComponent)
            for file in entries where file.pathExtension == "jsonl" {
                let path = file.path
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate
                // 先于下面的窗口判断：报表窗口比保留窗口短时（7 天），落在两者之间的文件这一轮不解析，缓存照留。
                if let mtime, mtime >= retentionCutoff {
                    keptPaths.insert(path)
                }
                if let mtime, mtime < cutoff { continue }
                let size = values?.fileSize

                if let mtime, let size, let cached = previous[path], cached.modified == mtime, cached.size == size {
                    files.append(cached.candidates)
                    reused += 1
                    continue
                }
                // 读不了的文件这次跳过、不进缓存（下次再试），同原来。
                guard let candidates = Self.parse(file, mtime: mtime, fallbackProjectPath: fallbackPath) else { continue }
                files.append(candidates)
                parsed += 1
                // 取不到修改时间或大小的没法判断变没变，不缓存（同原来每次都解析）。
                if let mtime, let size, mtime >= retentionCutoff {
                    updates[path] = CachedFile(modified: mtime, size: size, candidates: candidates)
                }
            }
        }

        lock.lock()
        for (path, file) in updates {
            cache[path] = file
        }
        // 删掉已经不在目录里的、修改时间（按现在的）超出保留窗口的。
        cache = cache.filter { keptPaths.contains($0.key) }
        lock.unlock()

        return Collection(entries: Self.merge(files), parsedFiles: parsed, reusedFiles: reused)
    }

    /// 读一个文件、解析出全部候选条目；读不了返回 nil。每个文件读完就放掉临时对象，峰值不随文件数累加（#93）。
    static func parse(_ url: URL, mtime: Date?, fallbackProjectPath: String) -> [Candidate]? {
        autoreleasepool {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return candidates(in: data, mtime: mtime, fallbackProjectPath: fallbackProjectPath)
        }
    }

    /// 一个文件里带 usage 的 assistant 行，按行序；跨文件的去重留到合并时做。行里没有时间戳用文件的修改时间（再没有用现在）。
    ///
    /// 同一个文件里同一个去重键只留第一条（一条消息按内容块拆成几行，共用 message.id + requestId）：合并时它后面的同键条目
    /// 无论别的文件里有没有都一定被去掉 —— 前面那条要么被收下、要么因为键已经见过被跳过，键都已经在集合里 —— 提前丢掉不改变结果，缓存小一截。
    static func candidates(in data: Data, mtime: Date?, fallbackProjectPath: String) -> [Candidate] {
        var result: [Candidate] = []
        var keysInFile = Set<String>()
        // 同一个文件里模型名、项目路径几乎都一样：相同的字符串共用一份存储，缓存省内存（值不变）。
        var interned: [String: String] = [:]
        func intern(_ string: String) -> String {
            if let existing = interned[string] { return existing }
            interned[string] = string
            return string
        }

        for lineData in data.split(separator: 0x0A) {
            guard let object = CLIJSONL.parseObject(Data(lineData)),
                  (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            // 去重键：message.id + requestId；只有 message.id 用它；两者都缺则不去重直接计入。
            let messageID = message["id"] as? String
            let requestID = object["requestId"] as? String
            let dedupKey: String?
            if let messageID, let requestID {
                dedupKey = messageID + "|" + requestID
            } else {
                dedupKey = messageID
            }
            if let dedupKey, !keysInFile.insert(dedupKey).inserted { continue }

            let ts = object["timestamp"] as? String
            let date = ts.flatMap { CLIJSONL.parseDate($0) } ?? mtime ?? Date()
            let modelID = message["model"] as? String ?? ""
            let projectPath = (object["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackProjectPath

            result.append(Candidate(dedupKey: dedupKey, entry: CLIUsageEntry(
                timestamp: date,
                modelID: intern(modelID),
                projectPath: intern(projectPath),
                input: CLIUsageEntry.tokenCount(usage["input_tokens"]),
                output: CLIUsageEntry.tokenCount(usage["output_tokens"]),
                cacheWrite: CLIUsageEntry.tokenCount(usage["cache_creation_input_tokens"]),
                cacheRead: CLIUsageEntry.tokenCount(usage["cache_read_input_tokens"])
            )))
        }
        return result
    }

    /// 按文件的遍历顺序合并、去重：同一个去重键只留第一次出现的那条（与原来边读边去重的结果相同）。
    static func merge(_ files: [[Candidate]]) -> [CLIUsageEntry] {
        var entries: [CLIUsageEntry] = []
        entries.reserveCapacity(files.reduce(0) { $0 + $1.count })
        var seenKeys = Set<String>()
        for candidates in files {
            for candidate in candidates {
                if let key = candidate.dedupKey, !seenKeys.insert(key).inserted { continue }
                entries.append(candidate.entry)
            }
        }
        return entries
    }
}
