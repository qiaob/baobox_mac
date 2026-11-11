import Foundation

/// Codex 助手 —— Codex 会话 rollout jsonl 的快扫与索引。
///
/// 数据源：`~/.codex/sessions/YYYY/MM/DD/rollout-<时间戳>-<uuid>.jsonl`（DESIGN 第 0 节）。
/// 首块含 SessionMeta（id / cwd），随后是逐行事件；标题取首条用户输入。所有解析都必须容错：
/// 任何字段缺失 / 类型不符只跳过或降级，**决不 crash**（无 force unwrap、无 try!）。
///
/// 刷新、复用、排序、删除、导出外壳与清理旧会话在与 Claude Code 助手共用的 `Core/CLISession/`（#109）：
/// 本文件只留 Codex 的「格式」`CodexSessionFormat`。与 Claude 不同（DESIGN 的「简化」）：只做内存缓存，
/// 不落磁盘缓存文件（`cacheFileURL` 为 nil）。rollout 的逐行解析辅助 `CodexJSONLParsing` 与导出 Markdown 的拼法是纯逻辑，
/// 在 `CodexSessionMarkdown.swift`（编进 `BaoboxTests`）。
///
/// 用户可见文案：降级标题 `aitools.session.untitled`；导出 Markdown 的小标题 `aitools.export.user` / `aitools.export.assistant`。

// MARK: - 数据模型

/// 一条 Codex 会话摘要（用于列表 / 菜单展示与续接）。
struct CodexSessionSummary: Identifiable, Equatable, CLISessionSummary {
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

/// Codex 会话索引：内存缓存 + 后台刷新，都在共用的 `CLISessionIndex`；Codex 没有独有的功能，这里只放 `shared`。
@MainActor
final class CodexSessionIndex: CLISessionIndex<CodexSessionFormat> {
    static let shared = CodexSessionIndex()

    private override init() {
        super.init()
    }
}

// MARK: - 缓存记录

/// 一条内存缓存记录（原 `CodexSessionIndex.CacheRecord`）。Codable 只为满足共用层的约束 —— Codex 不落盘。
struct CodexSessionRecord: CLISessionRecord {
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

// MARK: - 格式（后台扫描 / 解析，全部静态，可在后台线程调用）

/// Codex 会话日志的格式：`~/.codex/sessions/` 下递归的 rollout jsonl，只在内存里缓存。
enum CodexSessionFormat: CLISessionFormat {

    /// 不落磁盘缓存（DESIGN 简化）。
    static var cacheFileURL: URL? {
        nil
    }

    /// 清理旧会话的根目录。
    static var logRoot: URL {
        CodexEnv.sessionsDir
    }

    /// 递归枚举 `sessions/` 下全部 jsonl 普通文件。
    static func sessionFiles() -> [CLISessionFile] {
        CLISessionFiles.jsonlRecursively(under: CodexEnv.sessionsDir)
    }

    static func summary(of record: CodexSessionRecord, fileURL: URL) -> CodexSessionSummary {
        record.toSummary(fileURL: fileURL)
    }

    /// 快扫单个 rollout 文件：只读头 64KB，取 SessionMeta 的 id / cwd 与首条用户输入作标题；最后活动时间 = 文件修改时间。
    static func scan(_ file: CLISessionFile) -> CodexSessionRecord? {
        let url = file.url
        let mtime = file.modified
        let size = file.size
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
            guard let object = CLIJSONL.parseObject(Data(lineData)) else { continue }
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
        let projectName = resolvedPath.isEmpty ? "" : CLISessionPaths.projectName(fromPath: resolvedPath)
        let title = firstUserText.map { String($0.prefix(80)) } ?? L("aitools.session.untitled")
        // id 优先 SessionMeta，取不到再从文件名解析 uuid（rollout-<ts>-<uuid>.jsonl）。
        let id = metaID ?? uuidFromFileName(url) ?? url.deletingPathExtension().lastPathComponent

        return CodexSessionRecord(
            modified: mtime.timeIntervalSince1970,
            size: size,
            id: id,
            projectPath: resolvedPath,
            projectName: projectName,
            title: title,
            lastActivity: mtime.timeIntervalSince1970
        )
    }

    /// 从 `rollout-<时间戳>-<uuid>.jsonl` 文件名解析末段 uuid。
    static func uuidFromFileName(_ url: URL) -> String? {
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

    /// 把 rollout jsonl 里 user / assistant 的对话文本导出成 Markdown。这里只读文件、取文案，拼法在 `CodexSessionMarkdown`。
    /// 整份按字节读入（可能较大，故只在后台线程调用），逐行解析：一行里有坏字节只丢那一行（以前整份按 UTF-8 解，
    /// 一个坏字节就整份导出失败）。读不了文件返回 nil。
    static func markdown(fileURL: URL, title: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let headings = CLISessionMarkdown.Headings(
            user: L("aitools.export.user"),
            assistant: L("aitools.export.assistant")
        )
        return CodexSessionMarkdown.markdown(from: data, title: title, headings: headings)
    }
}
