import Foundation

/// Cursor / Codex 助手 —— Cursor 环境：项目 Rules 管理与全局 MCP 读写。
///
/// - 项目列表：用户经 NSOpenPanel 添加文件夹，路径数组存 UserDefaults，读取时过滤已不存在的。
/// - 每项目 `.cursor/rules/*.mdc` 枚举与旧式 `.cursorrules` 检测。
/// - 内置 3 个 `.mdc` 模板（通用 / 前端 / Python，含 YAML frontmatter），一键写入
///   `<项目>/.cursor/rules/`（目录不存在则创建，同名文件不覆盖并报错）。
/// - 全局 `~/.cursor/mcp.json` 的 `mcpServers` 读 / 增 / 删（JSONSerialization + 备份，结构同 Claude）。
///
/// 并发说明：低层 `CursorEnv` 静态方法皆为可后台调用的文件 IO；`CursorProjectIndex`（缓存 +
/// 后台刷新）标 `@MainActor`，供菜单与设置页读内存快照（菜单零磁盘 IO）。

// MARK: - 低层环境

enum CursorEnv {

    /// 项目路径列表的持久化键（UserDefaults）。
    static let projectsDefaultsKey = "aitools.cursorProjects"

    static var homeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.cursor`
    static var cursorDir: URL {
        homeDir.appendingPathComponent(".cursor", isDirectory: true)
    }

    /// `~/.cursor/mcp.json`（全局 MCP 配置）
    static var mcpFile: URL {
        cursorDir.appendingPathComponent("mcp.json")
    }

    /// 是否检测到 Cursor（以 `~/.cursor` 目录存在为准）。
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: cursorDir.path)
    }

    // MARK: 项目列表（UserDefaults）

    /// 读取项目路径（过滤已不存在的目录，保序去重）。可在任意线程调用。
    static func projectPaths() -> [String] {
        let raw = UserDefaults.standard.stringArray(forKey: projectsDefaultsKey) ?? []
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [String] = []
        for path in raw {
            guard !path.isEmpty, !seen.contains(path) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            seen.insert(path)
            result.append(path)
        }
        // 顺手清理失效条目，保持存储干净。
        if result != raw {
            UserDefaults.standard.set(result, forKey: projectsDefaultsKey)
        }
        return result
    }

    /// 追加一个项目路径（已存在则忽略）。
    static func addProject(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var paths = UserDefaults.standard.stringArray(forKey: projectsDefaultsKey) ?? []
        guard !paths.contains(trimmed) else { return }
        paths.append(trimmed)
        UserDefaults.standard.set(paths, forKey: projectsDefaultsKey)
    }

    /// 移除一个项目路径。
    static func removeProject(_ path: String) {
        var paths = UserDefaults.standard.stringArray(forKey: projectsDefaultsKey) ?? []
        paths.removeAll { $0 == path }
        UserDefaults.standard.set(paths, forKey: projectsDefaultsKey)
    }

    // MARK: Rules 枚举

    /// 某项目 `.cursor/rules/*.mdc` 文件（按名称升序）。后台线程调用。
    static func ruleFiles(inProject projectPath: String) -> [URL] {
        let rulesDir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".cursor/rules", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: rulesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { $0.pathExtension == "mdc" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 某项目是否存在旧式 `.cursorrules` 文件。后台线程调用。
    static func hasLegacyCursorrules(inProject projectPath: String) -> Bool {
        let url = URL(fileURLWithPath: projectPath).appendingPathComponent(".cursorrules")
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: 模板写入

    /// 写入错误：目标已存在（不覆盖）或落盘失败。
    enum TemplateError: Error {
        case alreadyExists
        case writeFailed
    }

    /// 把模板写入 `<项目>/.cursor/rules/<fileName>`。目录不存在则创建；同名文件不覆盖并报错。
    /// 后台线程调用。
    static func writeTemplate(_ template: CursorRuleTemplate, toProject projectPath: String) throws {
        let rulesDir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".cursor/rules", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        let target = rulesDir.appendingPathComponent(template.fileName)
        if fm.fileExists(atPath: target.path) {
            throw TemplateError.alreadyExists
        }
        guard let data = template.content.data(using: .utf8) else {
            throw TemplateError.writeFailed
        }
        do {
            try data.write(to: target)
        } catch {
            throw TemplateError.writeFailed
        }
    }

    // MARK: 全局 MCP（~/.cursor/mcp.json，结构同 Claude mcpServers）

    /// 读取全局 MCP 服务器：`[(name, 配置字典)]`，按名称升序。后台线程调用。
    static func mcpServers() -> [(name: String, config: [String: Any])] {
        let root = CursorJSONFile.load(mcpFile)
        guard let servers = root["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().compactMap { key in
            guard let config = servers[key] as? [String: Any] else { return nil }
            return (name: key, config: config)
        }
    }

    /// 新增或更新一个 MCP 服务器条目。后台线程调用。
    static func setMCPServer(name: String, config: [String: Any]) throws {
        try CursorJSONFile.mutate(mcpFile) { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers[name] = config
            root["mcpServers"] = servers
        }
    }

    /// 删除一个 MCP 服务器条目。后台线程调用。
    static func removeMCPServer(name: String) throws {
        try CursorJSONFile.mutate(mcpFile) { root in
            guard var servers = root["mcpServers"] as? [String: Any] else { return }
            servers.removeValue(forKey: name)
            root["mcpServers"] = servers
        }
    }
}

// MARK: - JSON 文件读-改-写工具（mcp.json）

/// 对 `~/.cursor/mcp.json` 的安全读-改-写：基于 `JSONSerialization`，保留未知字段，写前备份。
enum CursorJSONFile {

    static func load(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [:]
        }
        return dict
    }

    static func write(_ dict: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("baobox.bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url)
    }

    static func mutate(_ url: URL, _ transform: (inout [String: Any]) -> Void) throws {
        var dict = load(url)
        transform(&dict)
        try write(dict, to: url)
    }
}

// MARK: - 内置 Rules 模板

/// 一个 `.cursor/rules/*.mdc` 模板（YAML frontmatter + 正文）。
struct CursorRuleTemplate: Identifiable {
    let id: String
    let fileName: String
    /// 展示名的本地化 key。
    let titleKey: String
    let content: String

    /// 本地化展示名（用固定字面量 key 取词，供 AppKit 菜单等纯 Swift 场景用）。
    var localizedTitle: String {
        switch id {
        case "frontend": return L("aitools.cursor.template.frontend")
        case "python": return L("aitools.cursor.template.python")
        default: return L("aitools.cursor.template.general")
        }
    }

    /// 通用 / 前端 / Python 三套。
    static let all: [CursorRuleTemplate] = [general, frontend, python]

    static let general = CursorRuleTemplate(
        id: "general",
        fileName: "baobox-general.mdc",
        titleKey: "aitools.cursor.template.general",
        content: """
        ---
        description: General project conventions
        globs:
        alwaysApply: true
        ---

        # Project conventions

        - Match the existing code style; do not reformat unrelated lines.
        - Keep changes small and focused; explain non-obvious decisions in comments.
        - Prefer clear names over abbreviations.
        - Add or update tests when you change behavior.
        - Never commit secrets; read configuration from environment variables.
        """
    )

    static let frontend = CursorRuleTemplate(
        id: "frontend",
        fileName: "baobox-frontend.mdc",
        titleKey: "aitools.cursor.template.frontend",
        content: """
        ---
        description: Frontend (TypeScript / React) conventions
        globs: *.ts,*.tsx,*.js,*.jsx,*.css
        alwaysApply: false
        ---

        # Frontend conventions

        - Use TypeScript with strict typing; avoid `any`.
        - Prefer functional components and hooks; keep components small.
        - Co-locate styles with components; use semantic, accessible markup.
        - Handle loading and error states explicitly.
        - Keep side effects inside effects/handlers, not render bodies.
        """
    )

    static let python = CursorRuleTemplate(
        id: "python",
        fileName: "baobox-python.mdc",
        titleKey: "aitools.cursor.template.python",
        content: """
        ---
        description: Python conventions
        globs: *.py
        alwaysApply: false
        ---

        # Python conventions

        - Follow PEP 8; use type hints on public functions.
        - Prefer standard library and explicit imports.
        - Use f-strings for formatting; avoid mutable default arguments.
        - Raise specific exceptions; never swallow errors silently.
        - Add docstrings to modules and public functions.
        """
    )
}

// MARK: - 项目 Rules 索引（缓存 + 后台刷新，供菜单零 IO 读取）

/// 一项目的 Rules 状态快照。
struct CursorProject: Identifiable, Equatable {
    /// 项目路径即唯一键。
    let id: String
    let path: String
    let name: String
    let ruleFileNames: [String]      // .cursor/rules/*.mdc 文件名
    let hasLegacyCursorrules: Bool

    var ruleFileURLs: [URL] {
        let dir = URL(fileURLWithPath: path).appendingPathComponent(".cursor/rules", isDirectory: true)
        return ruleFileNames.map { dir.appendingPathComponent($0) }
    }
}

@MainActor
final class CursorProjectIndex: ObservableObject {
    static let shared = CursorProjectIndex()

    @Published private(set) var projects: [CursorProject] = []
    @Published private(set) var isRefreshing = false

    private var refreshing = false

    private init() {}

    /// 后台枚举各项目 Rules → 回主线程发布。去抖，进行中不重入。
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async {
            let projects = Self.scanAll()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.projects = projects
                    self.refreshing = false
                    self.isRefreshing = false
                }
            }
        }
    }

    /// 添加项目并刷新。
    func addProject(_ path: String) {
        CursorEnv.addProject(path)
        refresh()
    }

    /// 移除项目并刷新。
    func removeProject(_ path: String) {
        CursorEnv.removeProject(path)
        refresh()
    }

    /// 写模板到项目并刷新；回调成功与否（错误留给调用方转文案）。
    func writeTemplate(_ template: CursorRuleTemplate, toProject path: String,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error>
            do {
                try CursorEnv.writeTemplate(template, toProject: path)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refresh()
                    completion(result)
                }
            }
        }
    }

    /// 后台扫描全部项目。
    nonisolated static func scanAll() -> [CursorProject] {
        CursorEnv.projectPaths().map { path in
            let files = CursorEnv.ruleFiles(inProject: path).map { $0.lastPathComponent }
            let legacy = CursorEnv.hasLegacyCursorrules(inProject: path)
            let name = URL(fileURLWithPath: path).lastPathComponent
            return CursorProject(
                id: path,
                path: path,
                name: name.isEmpty ? path : name,
                ruleFileNames: files,
                hasLegacyCursorrules: legacy
            )
        }
    }
}
