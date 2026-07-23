import Foundation

/// Codex 助手 —— Codex 会话 rollout jsonl 的快扫与索引。
///
/// 数据源：`~/.codex/sessions/YYYY/MM/DD/rollout-<时间戳>-<uuid>.jsonl`（DESIGN 第 0 节）。
/// 首块含 SessionMeta（id / cwd），随后是逐行事件；标题取首条用户输入。所有解析都必须容错：
/// 任何字段缺失 / 类型不符只跳过或降级，**决不 crash**（无 force unwrap、无 try!）。
///
/// 模式照 `ClaudeSessionIndex`，但**简化**：只做内存缓存 + 后台刷新，不落磁盘缓存文件。
///
/// 用户可见文案：仅一处降级标题 `aitools.session.untitled`。

// MARK: - 解析辅助

enum CodexJSONLParsing {

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated static func parseDate(_ string: String) -> Date? {
        if let date = iso8601Fractional.date(from: string) { return date }
        return iso8601Plain.date(from: string)
    }

    nonisolated static func parseObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 从内容值提取首个可读文本。内容可能是纯字符串，或
    /// `[{type:text|input_text, text:...}]` 数组（Codex 与 Claude 的 content 略有差异）。
    nonisolated static func extractText(from content: Any?) -> String? {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                let type = block["type"] as? String
                if type == nil || type == "text" || type == "input_text" || type == "output_text" {
                    if let text = block["text"] as? String, !text.isEmpty { return text }
                }
            }
        }
        return nil
    }

    /// 从一个 rollout 行对象里尽力取出 (id, cwd)。兼容顶层与 `payload` 嵌套两种写法。
    nonisolated static func extractMeta(from object: [String: Any]) -> (id: String?, cwd: String?) {
        var id = object["id"] as? String
        var cwd = object["cwd"] as? String
        if let payload = object["payload"] as? [String: Any] {
            id = id ?? (payload["id"] as? String)
            cwd = cwd ?? (payload["cwd"] as? String)
        }
        return (id, cwd)
    }

    /// 从一个 rollout 行对象里尽力取出用户输入文本；非用户消息返回 nil。
    nonisolated static func extractUserText(from object: [String: Any]) -> String? {
        if let payload = object["payload"] as? [String: Any] {
            // 形态 A：event_msg / user_message，message 为字符串。
            if (payload["type"] as? String) == "user_message", let m = payload["message"] as? String {
                return m
            }
            // 形态 B：response_item，role == user，content 为块数组。
            if (payload["role"] as? String) == "user",
               let text = extractText(from: payload["content"]) {
                return text
            }
        }
        // 形态 C：顶层直接带 role / content。
        if (object["role"] as? String) == "user",
           let text = extractText(from: object["content"]) {
            return text
        }
        return nil
    }
}

// MARK: - 数据模型

/// 一条 Codex 会话摘要（用于列表 / 菜单展示与续接）。
struct CodexSessionSummary: Identifiable, Equatable {
    /// 会话 id（SessionMeta 优先，文件名 uuid 兜底）。
    let id: String
    let fileURL: URL
    /// 项目路径（cwd）；未知时为空串。
    let projectPath: String
    /// 项目展示名（cwd 末段）。
    let projectName: String
    let title: String
    let lastActivity: Date
    let fileSize: Int64
}

// MARK: - 索引单例

@MainActor
final class CodexSessionIndex: ObservableObject {
    static let shared = CodexSessionIndex()

    /// 新→旧排序。
    @Published private(set) var sessions: [CodexSessionSummary] = []
    @Published private(set) var isRefreshing = false

    /// 内存快扫缓存（键 = 文件路径）；仅主线程读写，无磁盘持久化（DESIGN 简化）。
    private var cache: [String: CacheRecord] = [:]
    private var refreshing = false

    private init() {}

    // MARK: 刷新

    /// 后台快扫全部 rollout jsonl → 回主线程发布。去抖，进行中不重入。
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        isRefreshing = true
        let previousCache = cache
        DispatchQueue.global(qos: .utility).async {
            let (summaries, newCache) = Self.scanAll(previousCache: previousCache)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sessions = summaries
                    self.cache = newCache
                    self.refreshing = false
                    self.isRefreshing = false
                }
            }
        }
    }

    /// 最近 N 条（已按新→旧排序）。主线程同步读内存。
    func recentSessions(limit: Int) -> [CodexSessionSummary] {
        Array(sessions.prefix(max(0, limit)))
    }

    /// 删除单个会话文件。回调是否成功，成功则从内存索引移除。
    func deleteSession(_ summary: CodexSessionSummary, completion: @escaping (Bool) -> Void) {
        let url = summary.fileURL
        DispatchQueue.global(qos: .utility).async {
            let ok = (try? FileManager.default.removeItem(at: url)) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok {
                        self.sessions.removeAll { $0.id == summary.id }
                        self.cache.removeValue(forKey: url.path)
                    }
                }
                completion(ok)
            }
        }
    }
}

// MARK: - 缓存记录

extension CodexSessionIndex {
    struct CacheRecord {
        let modified: Double
        let size: Int64
        let id: String
        let projectPath: String
        let projectName: String
        let title: String
        let lastActivity: Double

        func toSummary(fileURL: URL) -> CodexSessionSummary {
            CodexSessionSummary(
                id: id,
                fileURL: fileURL,
                projectPath: projectPath,
                projectName: projectName,
                title: title,
                lastActivity: Date(timeIntervalSince1970: lastActivity),
                fileSize: size
            )
        }
    }
}

// MARK: - 后台扫描（nonisolated static，可在后台线程调用）

extension CodexSessionIndex {

    /// 递归枚举 `sessions/` 下全部 jsonl；mtime+size 未变的复用缓存，否则快扫。mtime 降序。
    nonisolated static func scanAll(previousCache: [String: CacheRecord]) -> ([CodexSessionSummary], [String: CacheRecord]) {
        let fm = FileManager.default
        var summaries: [CodexSessionSummary] = []
        var newCache: [String: CacheRecord] = [:]

        guard let enumerator = fm.enumerator(
            at: CodexEnv.sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [:])
        }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let size = Int64(values?.fileSize ?? 0)
            let path = url.path

            if let record = previousCache[path],
               abs(record.modified - mtime.timeIntervalSince1970) < 0.001,
               record.size == size {
                newCache[path] = record
                summaries.append(record.toSummary(fileURL: url))
                continue
            }

            if let scanned = scanFile(url, mtime: mtime, size: size) {
                newCache[path] = scanned.record
                summaries.append(scanned.summary)
            }
        }

        summaries.sort { $0.lastActivity > $1.lastActivity }
        return (summaries, newCache)
    }

    /// 快扫单个 rollout 文件：只读头 64KB，取 SessionMeta 的 id / cwd 与首条用户输入作标题。
    nonisolated static func scanFile(_ url: URL, mtime: Date, size: Int64) -> (summary: CodexSessionSummary, record: CacheRecord)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let headData: Data
        do {
            headData = (try handle.read(upToCount: 64 * 1024)) ?? Data()
        } catch {
            return nil
        }

        var metaID: String?
        var cwd: String?
        var firstUserText: String?
        for lineData in headData.split(separator: 0x0A) {
            guard let object = CodexJSONLParsing.parseObject(Data(lineData)) else { continue }
            let meta = CodexJSONLParsing.extractMeta(from: object)
            if metaID == nil, let mid = meta.id, !mid.isEmpty { metaID = mid }
            if let mcwd = meta.cwd, !mcwd.isEmpty { cwd = mcwd }
            if firstUserText == nil, let text = CodexJSONLParsing.extractUserText(from: object) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 跳过系统注入（如 <environment_context> 等以 < 起头的块）。
                if !trimmed.isEmpty, !trimmed.hasPrefix("<") {
                    firstUserText = trimmed
                }
            }
        }

        let resolvedPath = cwd ?? ""
        let projectName = resolvedPath.isEmpty ? "" : self.projectName(fromPath: resolvedPath)
        let title = firstUserText.map { String($0.prefix(80)) } ?? L("aitools.session.untitled")
        // id 优先 SessionMeta，取不到再从文件名解析 uuid（rollout-<ts>-<uuid>.jsonl）。
        let id = metaID ?? uuidFromFileName(url) ?? url.deletingPathExtension().lastPathComponent

        let record = CacheRecord(
            modified: mtime.timeIntervalSince1970,
            size: size,
            id: id,
            projectPath: resolvedPath,
            projectName: projectName,
            title: title,
            lastActivity: mtime.timeIntervalSince1970
        )
        return (record.toSummary(fileURL: url), record)
    }

    /// 从 `rollout-<时间戳>-<uuid>.jsonl` 文件名解析末段 uuid。
    nonisolated static func uuidFromFileName(_ url: URL) -> String? {
        let base = url.deletingPathExtension().lastPathComponent
        // 标准 uuid 含 5 段 8-4-4-4-12，用 `-` 分隔；取末 5 段拼回。
        let parts = base.components(separatedBy: "-")
        guard parts.count >= 5 else { return nil }
        let candidate = parts.suffix(5).joined(separator: "-")
        // 粗校验：长度 36 且仅十六进制与短横。
        guard candidate.count == 36 else { return nil }
        let allowed = Set("0123456789abcdefABCDEF-")
        guard candidate.allSatisfy({ allowed.contains($0) }) else { return nil }
        return candidate
    }

    /// 从路径取展示名（末段）。
    nonisolated static func projectName(fromPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
