import AppKit
import Foundation

/// Claude Code 助手 —— 环境与本地文件基础层。
///
/// 本文件是整个模块的「底座」：路径常量、`claude` 二进制探测、`~/.claude/settings.json`
/// 与 `~/.claude.json` 的安全读-改-写、MCP / 权限 / Co-Authored-By 的底层读写接口、
/// 以及在终端里续接会话的启动器。UI 层只调这里暴露的方法，绝不自己碰文件。
///
/// 并发说明：`ClaudeEnv` 与 `ClaudeJSONFile` 有意**不**标 `@MainActor`，因为它们的所有
/// 成员要么是纯路径计算、要么是可能读写数 MB 文件的重 IO —— 这些必须能在后台线程直接调用。
/// 若强行标 `@MainActor`（技术方案 3.1 的字面写法），反而会把大文件 IO 逼回主线程，违反
/// 「重 IO 一律后台」的硬约束。因此本文件里唯一需要主线程的 `TerminalLauncher`（触碰
/// NSWorkspace）单独标 `@MainActor`。这是对 TECH_DESIGN 3.1 的一处**刻意且必要**的偏离。
///
/// 本文件不含用户可见文案（脚本与命令字符串不经 L()）。
enum ClaudeEnv {

    // MARK: - 路径常量

    /// 真实家目录。GUI App 非沙箱，`homeDirectoryForCurrentUser` 取到的是真实 `~`。
    static var homeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.claude`
    static var claudeDir: URL {
        homeDir.appendingPathComponent(".claude", isDirectory: true)
    }

    /// `~/.claude/projects`
    static var projectsDir: URL {
        claudeDir.appendingPathComponent("projects", isDirectory: true)
    }

    /// `~/.claude/settings.json`（用户级配置）
    static var settingsFile: URL {
        claudeDir.appendingPathComponent("settings.json")
    }

    /// `~/.claude.json`（CLI 状态大文件，顶层 mcpServers 为用户级 MCP 配置）
    static var cliStateFile: URL {
        homeDir.appendingPathComponent(".claude.json")
    }

    /// `~/Library/Application Support/Baobox/ClaudeCode/`
    /// 与 `ClipboardStore.baseDir` 同一约定，追加本模块子目录。
    static var supportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDir.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Baobox/ClaudeCode", isDirectory: true)
    }

    /// 是否检测到 Claude Code（以 `~/.claude` 目录存在为准）。
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: claudeDir.path)
    }

    /// 确保支持目录存在，返回其 URL（幂等）。
    @discardableResult
    static func ensureSupportDir() -> URL {
        let dir = supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 二进制探测

    /// 二进制探测缓存（结果稳定，进程内缓存即可）。用锁保护，允许后台线程安全调用。
    private static let binaryLock = NSLock()
    private static var cachedBinary: String?

    /// 依次探测常见安装位置；都不在则回退字符串 `"claude"`（终端里 PATH 通常有）。
    /// 结果缓存。可在任意线程调用。
    static func findClaudeBinary() -> String? {
        binaryLock.lock()
        defer { binaryLock.unlock() }
        if let cached = cachedBinary {
            return cached
        }
        let fm = FileManager.default
        let candidates: [URL] = [
            homeDir.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            homeDir.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/usr/bin/claude")
        ]
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            cachedBinary = url.path
            return url.path
        }
        cachedBinary = "claude"
        return "claude"
    }

    /// 运行 `claude --version` 取版本串（如 `"1.0.0 (Claude Code)"`）。
    /// **必须在后台线程调用**（内部同步等待子进程）。失败返回 nil。
    static func cliVersion() -> String? {
        let binary = findClaudeBinary() ?? "claude"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 走登录 shell，保证 PATH 完整（binary 可能只是 "claude"）。
        process.arguments = ["-lc", "\(shellSingleQuote(binary)) --version"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // 先读干管道再等退出，避免管道写满导致子进程阻塞。
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - MCP 服务器（~/.claude.json 顶层 mcpServers）

    /// 读取用户级 MCP 服务器：`[(name, 配置字典)]`，按名称升序。
    /// 后台线程调用（可能读几 MB）。
    static func mcpServers() -> [(name: String, config: [String: Any])] {
        let state = ClaudeJSONFile.load(cliStateFile)
        guard let servers = state["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().compactMap { key in
            guard let config = servers[key] as? [String: Any] else { return nil }
            return (name: key, config: config)
        }
    }

    /// 新增或更新一个 MCP 服务器条目。后台线程调用。
    static func setMCPServer(name: String, config: [String: Any]) throws {
        try ClaudeJSONFile.mutate(cliStateFile) { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers[name] = config
            root["mcpServers"] = servers
        }
    }

    /// 删除一个 MCP 服务器条目。后台线程调用。
    static func removeMCPServer(name: String) throws {
        try ClaudeJSONFile.mutate(cliStateFile) { root in
            guard var servers = root["mcpServers"] as? [String: Any] else { return }
            servers.removeValue(forKey: name)
            root["mcpServers"] = servers
        }
    }

    // MARK: - 权限规则（settings.json permissions.allow / deny）

    enum PermissionKind: String {
        case allow
        case deny
    }

    /// 读取 allow / deny 字符串数组。后台线程调用。
    static func permissionRules(_ kind: PermissionKind) -> [String] {
        let settings = ClaudeSettingsFile.load()
        guard let permissions = settings["permissions"] as? [String: Any],
              let list = permissions[kind.rawValue] as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }

    /// 覆盖写入 allow / deny 数组（保留 permissions 下其他键）。后台线程调用。
    static func setPermissionRules(_ rules: [String], kind: PermissionKind) throws {
        try ClaudeSettingsFile.mutate { settings in
            var permissions = settings["permissions"] as? [String: Any] ?? [:]
            permissions[kind.rawValue] = rules
            settings["permissions"] = permissions
        }
    }

    /// 追加一条规则（已存在则忽略）。后台线程调用。
    static func addPermissionRule(_ rule: String, kind: PermissionKind) throws {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var rules = permissionRules(kind)
        guard !rules.contains(trimmed) else { return }
        rules.append(trimmed)
        try setPermissionRules(rules, kind: kind)
    }

    /// 移除一条规则。后台线程调用。
    static func removePermissionRule(_ rule: String, kind: PermissionKind) throws {
        var rules = permissionRules(kind)
        rules.removeAll { $0 == rule }
        try setPermissionRules(rules, kind: kind)
    }

    // MARK: - Co-Authored-By（settings.json includeCoAuthoredBy）

    /// 缺省视为 true（Claude Code 出厂即署名）。后台线程调用。
    static func includeCoAuthoredBy() -> Bool {
        let settings = ClaudeSettingsFile.load()
        return settings["includeCoAuthoredBy"] as? Bool ?? true
    }

    /// 写入 includeCoAuthoredBy。后台线程调用。
    static func setIncludeCoAuthoredBy(_ value: Bool) throws {
        try ClaudeSettingsFile.mutate { settings in
            settings["includeCoAuthoredBy"] = value
        }
    }

    // MARK: - 简单标量键（配置节可视化控件用；全部走 settings.json，后台调用）

    /// permissions.defaultMode（default / acceptEdits / plan / bypassPermissions）。未设为 nil。
    static func defaultMode() -> String? {
        let settings = ClaudeSettingsFile.load()
        return (settings["permissions"] as? [String: Any])?["defaultMode"] as? String
    }

    static func setDefaultMode(_ mode: String) throws {
        try ClaudeSettingsFile.mutate { settings in
            var permissions = settings["permissions"] as? [String: Any] ?? [:]
            permissions["defaultMode"] = mode
            settings["permissions"] = permissions
        }
    }

    static func removeDefaultMode() throws {
        try ClaudeSettingsFile.mutate { settings in
            guard var permissions = settings["permissions"] as? [String: Any] else { return }
            permissions.removeValue(forKey: "defaultMode")
            if permissions.isEmpty {
                settings.removeValue(forKey: "permissions")
            } else {
                settings["permissions"] = permissions
            }
        }
    }

    /// model（模型别名字符串，如 "opus"/"sonnet"/"haiku"）。未设为 nil（跟随默认）。
    static func model() -> String? {
        ClaudeSettingsFile.load()["model"] as? String
    }

    static func setModel(_ model: String) throws {
        try ClaudeSettingsFile.mutate { settings in
            settings["model"] = model
        }
    }

    static func removeModel() throws {
        try ClaudeSettingsFile.mutate { settings in
            settings.removeValue(forKey: "model")
        }
    }

    /// cleanupPeriodDays（会话保留天数）。未设为 nil。容错取整（可能存成 Double/NSNumber）。
    static func cleanupPeriodDays() -> Int? {
        let value = ClaudeSettingsFile.load()["cleanupPeriodDays"]
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    static func setCleanupPeriodDays(_ days: Int) throws {
        try ClaudeSettingsFile.mutate { settings in
            settings["cleanupPeriodDays"] = days
        }
    }

    static func removeCleanupPeriodDays() throws {
        try ClaudeSettingsFile.mutate { settings in
            settings.removeValue(forKey: "cleanupPeriodDays")
        }
    }

    // MARK: - env 字典单键（隐私开关映射；只动指定键，不碰用户自设的其他 env）

    /// 读取 env 下某键的字符串值；不存在为 nil。
    static func envValue(_ key: String) -> String? {
        let settings = ClaudeSettingsFile.load()
        guard let env = settings["env"] as? [String: Any] else { return nil }
        if let s = env[key] as? String { return s }
        // 容错：值可能被存成数字/布尔，统一转字符串展示。
        if let n = env[key] as? NSNumber { return n.stringValue }
        return nil
    }

    /// 设置 env 下某键为固定字符串 "1"（隐私开关的开启态）。保留其他 env 键。
    static func setEnvFlag(_ key: String) throws {
        try ClaudeSettingsFile.mutate { settings in
            var env = settings["env"] as? [String: Any] ?? [:]
            env[key] = "1"
            settings["env"] = env
        }
    }

    /// 移除 env 下某键；env 变空字典则删除 env 键。保留其他 env 键。
    static func removeEnvKey(_ key: String) throws {
        try ClaudeSettingsFile.mutate { settings in
            guard var env = settings["env"] as? [String: Any] else { return }
            env.removeValue(forKey: key)
            if env.isEmpty {
                settings.removeValue(forKey: "env")
            } else {
                settings["env"] = env
            }
        }
    }

    // MARK: - Shell 转义

    /// 用单引号安全包裹一个字符串，供 shell 命令拼接。内部单引号按 `'\''` 转义。
    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - JSON 文件读-改-写工具

/// 对任意用户 JSON 文件（settings.json / .claude.json）的安全读-改-写。
/// 只基于 `JSONSerialization`（`[String: Any]`），保留全部未知字段；写前把原文件复制为
/// `<name>.baobox.bak`（每次覆盖）。**读写可能是几 MB，一律在后台线程调用。**
enum ClaudeJSONFile {

    /// 读取为字典；文件不存在或非法 → 空字典（决不 crash）。
    static func load(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [:]
        }
        return dict
    }

    /// 覆盖写入。写前备份，序列化用稳定选项（利于 diff）。
    static func write(_ dict: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        // 备份：`settings.json` → `settings.json.baobox.bak`；`.claude.json` → `.claude.json.baobox.bak`。
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("baobox.bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        // 确保父目录存在。
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url)
    }

    /// 读 → 变换 → 写回。变换闭包是纯函数，只动自己的键。
    static func mutate(_ url: URL, _ transform: (inout [String: Any]) -> Void) throws {
        var dict = load(url)
        transform(&dict)
        try write(dict, to: url)
    }
}

/// `settings.json` 的便捷入口（TECH_DESIGN 3.1 命名的 `ClaudeSettingsFile`）。
enum ClaudeSettingsFile {
    static func load() -> [String: Any] {
        ClaudeJSONFile.load(ClaudeEnv.settingsFile)
    }

    static func mutate(_ transform: (inout [String: Any]) -> Void) throws {
        try ClaudeJSONFile.mutate(ClaudeEnv.settingsFile, transform)
    }
}

// MARK: - 终端启动器

/// 在系统默认终端里执行命令（续接会话等）。触碰 NSWorkspace，故标 `@MainActor`，
/// 由菜单点击等主线程场景调用。写入的是极小的 `.command` 脚本，主线程落盘可接受。
@MainActor
enum TerminalLauncher {

    /// 把命令包成一次性 `.command` 脚本并用默认终端打开。
    /// - Parameters:
    ///   - command: 要执行的命令行（不含 cd）。
    ///   - directory: 执行目录；nil 则不 cd。
    static func run(command: String, in directory: String?) {
        let launchDir = ClaudeEnv.ensureSupportDir().appendingPathComponent("launch", isDirectory: true)
        try? FileManager.default.createDirectory(at: launchDir, withIntermediateDirectories: true)
        cleanupOldLaunchers(in: launchDir)

        var script = "#!/bin/zsh\n"
        if let directory, !directory.isEmpty {
            script += "cd \(ClaudeEnv.shellSingleQuote(directory))\n"
        }
        script += command + "\n"

        let fileURL = launchDir.appendingPathComponent("\(UUID().uuidString).command")
        guard let data = script.data(using: .utf8) else { return }
        do {
            try data.write(to: fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        } catch {
            return
        }
        NSWorkspace.shared.open(fileURL)
    }

    /// 在指定项目目录续接会话：`<claude> --resume <id>`。
    static func resume(sessionID: String, in directory: String, binary: String? = nil) {
        let bin = binary ?? ClaudeEnv.findClaudeBinary() ?? "claude"
        let command = "\(ClaudeEnv.shellSingleQuote(bin)) --resume \(ClaudeEnv.shellSingleQuote(sessionID))"
        run(command: command, in: directory)
    }

    /// 目录里超过 20 个旧启动脚本时清理最旧的，避免堆积。
    private static func cleanupOldLaunchers(in dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), files.count > 20 else { return }
        let sorted = files.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l < r
        }
        for url in sorted.prefix(sorted.count - 20) {
            try? fm.removeItem(at: url)
        }
    }
}
