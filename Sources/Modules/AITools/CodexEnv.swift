import Foundation

/// Codex 助手 —— Codex 环境与本地文件基础层。
///
/// 本文件是 Codex 侧的「底座」：`~/.codex` 路径常量、`codex` 二进制探测，以及
/// `~/.codex/config.toml` 的**行级**读-改-写。UI 层只调这里暴露的 typed 方法，绝不自己碰文件。
///
/// 并发说明：`CodexEnv` 与 `CodexTOML` 有意**不**标 `@MainActor`，成员要么是纯路径计算、
/// 要么是可能读写文件的 IO —— 这些必须能在后台线程直接调用（同 `ClaudeEnv` 的取舍）。
///
/// TOML 编辑取舍（DESIGN 第 2 节）：零依赖、必须保注释，故不写通用 TOML 解析器，只做
/// 「顶层标量键行编辑」——逐行扫描匹配 `^\s*key\s*=` 的首行整行替换；不存在则插到第一个
/// `[section]` 之前（无 section 则文件末尾）；写前备份 `.baobox.bak`。值只支持基础标量 /
/// 单行字符串数组——超出即返回「不可编辑」状态，由 UI 置灰控件、决不冒险改写。
enum CodexEnv {

    // MARK: - 路径常量

    /// 真实家目录。GUI App 非沙箱，取到的是真实 `~`。
    static var homeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/.codex`
    static var codexDir: URL {
        homeDir.appendingPathComponent(".codex", isDirectory: true)
    }

    /// `~/.codex/sessions`
    static var sessionsDir: URL {
        codexDir.appendingPathComponent("sessions", isDirectory: true)
    }

    /// `~/.codex/config.toml`
    static var configFile: URL {
        codexDir.appendingPathComponent("config.toml")
    }

    /// `~/Library/Application Support/Baobox/AITools/`
    /// 与 `ClaudeEnv.supportDir` 同一约定，独立子目录避免两模块串扰。
    static var supportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDir.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Baobox/AITools", isDirectory: true)
    }

    /// 是否检测到 Codex（以 `~/.codex` 目录存在为准）。
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: codexDir.path)
    }

    /// 确保支持目录存在，返回其 URL（幂等）。
    @discardableResult
    static func ensureSupportDir() -> URL {
        let dir = supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 二进制探测

    private static let binaryLock = NSLock()
    private static var cachedBinary: String?

    /// 依次探测常见安装位置；都不在则回退字符串 `"codex"`（终端里 PATH 通常有）。
    /// 结果缓存。可在任意线程调用。
    static func findCodexBinary() -> String {
        binaryLock.lock()
        defer { binaryLock.unlock() }
        if let cached = cachedBinary {
            return cached
        }
        let fm = FileManager.default
        let candidates: [URL] = [
            homeDir.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            cachedBinary = url.path
            return url.path
        }
        cachedBinary = "codex"
        return "codex"
    }

    // MARK: - config.toml：typed 标量键

    /// 顶层标量键（字符串值）读取结果。
    enum ScalarValue: Equatable {
        case absent            // 键不存在
        case value(String)     // 解析出的字符串值（已去引号）
        case uneditable        // 键存在，但值不是可安全编辑的单行字符串
    }

    /// 顶层数组键（字符串数组）读取结果。
    enum ArrayValue: Equatable {
        case absent
        case array([String])
        case uneditable
    }

    /// `approval_policy`（untrusted / on-request / never）。后台线程调用。
    static func approvalPolicy() -> ScalarValue { CodexTOML.readScalar(configFile, key: "approval_policy") }
    static func setApprovalPolicy(_ value: String) throws { try CodexTOML.setScalar(configFile, key: "approval_policy", value: value) }
    static func removeApprovalPolicy() throws { try CodexTOML.removeKey(configFile, key: "approval_policy") }

    /// `sandbox_mode`（read-only / workspace-write / danger-full-access）。后台线程调用。
    static func sandboxMode() -> ScalarValue { CodexTOML.readScalar(configFile, key: "sandbox_mode") }
    static func setSandboxMode(_ value: String) throws { try CodexTOML.setScalar(configFile, key: "sandbox_mode", value: value) }
    static func removeSandboxMode() throws { try CodexTOML.removeKey(configFile, key: "sandbox_mode") }

    /// `model`（默认模型名）。后台线程调用。
    static func model() -> ScalarValue { CodexTOML.readScalar(configFile, key: "model") }
    static func setModel(_ value: String) throws { try CodexTOML.setScalar(configFile, key: "model", value: value) }
    static func removeModel() throws { try CodexTOML.removeKey(configFile, key: "model") }

    /// `notify`（回合结束调用的程序数组，仅用户级生效）。后台线程调用。
    static func notify() -> ArrayValue { CodexTOML.readArray(configFile, key: "notify") }
    static func setNotify(_ programs: [String]) throws { try CodexTOML.setArray(configFile, key: "notify", values: programs) }
    static func removeNotify() throws { try CodexTOML.removeKey(configFile, key: "notify") }

    // MARK: - CLI 版本

    /// 运行 `codex --version` 取版本串。**必须在后台线程调用**（内部同步等待子进程）。失败返回 nil。
    static func cliVersion() -> String? {
        let binary = findCodexBinary()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 走登录 shell，保证 PATH 完整（binary 可能只是 "codex"）。
        process.arguments = ["-lc", "\(shellQuote(binary)) --version"]
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

    // MARK: - 磁盘统计 / 清理（~/.codex/sessions）

    /// 统计 `~/.codex/sessions` 占用字节数与 rollout 文件数。后台线程调用。
    static func sessionsDiskStats() -> (bytes: Int64, fileCount: Int) {
        let fm = FileManager.default
        var bytes: Int64 = 0
        var count = 0
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            bytes += Int64(values?.fileSize ?? 0)
            count += 1
        }
        return (bytes, count)
    }

    /// 删除早于 N 天（按 mtime）的 rollout jsonl。返回 (删除文件数, 释放字节数)。后台线程调用。
    static func cleanupSessions(olderThanDays days: Int) -> (Int, Int64) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var count = 0
        var bytes: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate ?? Date()
            guard mtime < cutoff else { continue }
            let size = Int64(values?.fileSize ?? 0)
            if (try? fm.removeItem(at: url)) != nil {
                count += 1
                bytes += size
            }
        }
        return (count, bytes)
    }

    // MARK: - MCP 服务器（config.toml [mcp_servers.*]，只读列出）

    /// 一个 `[mcp_servers.<name>]` 段的只读摘要。
    struct MCPServerInfo: Identifiable {
        let id: String       // 服务器名
        let name: String
        let command: String  // command 值（取不到为空）
        let args: [String]   // args 数组（取不到为空）
    }

    /// 只读扫描 config.toml 里的 `[mcp_servers.<name>]` 段（正则扫段头 + 段内 command / args）。
    /// 不做写入（块级增删见 DESIGN §5.1 P1）。后台线程调用。
    static func mcpServers() -> [MCPServerInfo] {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
        var result: [MCPServerInfo] = []

        var currentName: String?
        var currentCommand = ""
        var currentArgs: [String] = []

        func flush() {
            if let name = currentName {
                result.append(MCPServerInfo(id: name, name: name, command: currentCommand, args: currentArgs))
            }
            currentName = nil
            currentCommand = ""
            currentArgs = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                flush()
                // 段头形如 [mcp_servers.<name>] 或 [mcp_servers."<name>"]。
                if let name = mcpServerName(fromHeader: trimmed) {
                    currentName = name
                }
                continue
            }
            guard currentName != nil else { continue }
            if let rhs = rhsAfterKey(trimmed, key: "command"), let value = CodexTOML.parseString(rhs) {
                currentCommand = value
            } else if let rhs = rhsAfterKey(trimmed, key: "args"), let arr = CodexTOML.parseStringArray(rhs) {
                currentArgs = arr
            }
        }
        flush()
        return result.sorted { $0.name < $1.name }
    }

    /// 从段头 `[mcp_servers.<name>]` 解析服务器名；非该前缀返回 nil。
    private static func mcpServerName(fromHeader header: String) -> String? {
        guard header.hasPrefix("["), header.hasSuffix("]") else { return nil }
        let inner = String(header.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        let prefix = "mcp_servers."
        guard inner.hasPrefix(prefix) else { return nil }
        var name = String(inner.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        // 去掉可能的引号包裹。
        if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        return name.isEmpty ? nil : name
    }

    /// 若某行形如 `key = ...` 则返回等号右侧原文，否则 nil。
    private static func rhsAfterKey(_ line: String, key: String) -> String? {
        var s = Substring(line)
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        guard s.hasPrefix(key) else { return nil }
        s = s.dropFirst(key.count)
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        guard s.first == "=" else { return nil }
        return String(s.dropFirst())
    }
}

// MARK: - TOML 行级编辑器

/// `config.toml` 的行级编辑：只动顶层标量 / 单行字符串数组键，保全注释与其余内容。
enum CodexTOML {

    /// 值不可安全编辑（多行数组 / 内联表等）时抛出，调用方据此不落盘。
    enum EditError: Error {
        case uneditable
    }

    // MARK: 读取

    /// 读取顶层字符串键。
    static func readScalar(_ url: URL, key: String) -> CodexEnv.ScalarValue {
        let lines = fileLines(url)
        guard let rhs = topLevelRHS(lines, key: key) else { return .absent }
        if let parsed = parseString(rhs) { return .value(parsed) }
        return .uneditable
    }

    /// 读取顶层字符串数组键。
    static func readArray(_ url: URL, key: String) -> CodexEnv.ArrayValue {
        let lines = fileLines(url)
        guard let rhs = topLevelRHS(lines, key: key) else { return .absent }
        if let parsed = parseStringArray(rhs) { return .array(parsed) }
        return .uneditable
    }

    // MARK: 写入 / 移除

    static func setScalar(_ url: URL, key: String, value: String) throws {
        try replaceOrInsert(url, key: key, rawValue: encodeString(value))
    }

    static func setArray(_ url: URL, key: String, values: [String]) throws {
        try replaceOrInsert(url, key: key, rawValue: encodeStringArray(values))
    }

    /// 移除顶层键（整行删除）。若现值不可安全编辑则抛错，避免删半截多行结构。
    static func removeKey(_ url: URL, key: String) throws {
        var lines = fileLines(url)
        let sectionIdx = firstSectionIndex(lines)
        var targetIndex: Int?
        for i in 0..<sectionIdx where lineAssignsKey(lines[i], key: key) {
            targetIndex = i
            break
        }
        guard let index = targetIndex else { return }   // 本就不存在，视为成功
        // 现值必须是可安全解析的单行值，否则拒绝（防止破坏多行结构）。
        let rhs = rhsOf(lines[index]) ?? ""
        guard parseString(rhs) != nil || parseStringArray(rhs) != nil else { throw EditError.uneditable }
        backup(url)
        lines.remove(at: index)
        try writeLines(lines, to: url)
    }

    // MARK: 核心：整行替换或插入

    private static func replaceOrInsert(_ url: URL, key: String, rawValue: String) throws {
        var lines = fileLines(url)
        let sectionIdx = firstSectionIndex(lines)
        let newLine = "\(key) = \(rawValue)"

        // 已存在顶层键：整行替换（但现值须可安全解析，否则拒绝，防止值本是多行结构）。
        for i in 0..<sectionIdx where lineAssignsKey(lines[i], key: key) {
            let rhs = rhsOf(lines[i]) ?? ""
            guard parseString(rhs) != nil || parseStringArray(rhs) != nil else { throw EditError.uneditable }
            backup(url)
            lines[i] = newLine
            try writeLines(lines, to: url)
            return
        }

        // 不存在：插到第一个 [section] 之前；无 section 则文件末尾（保留末尾空行）。
        backup(url)
        if sectionIdx < lines.count {
            lines.insert(newLine, at: sectionIdx)
        } else if lines.last == "" {
            lines.insert(newLine, at: lines.count - 1)
        } else {
            lines.append(newLine)
        }
        try writeLines(lines, to: url)
    }

    // MARK: 行工具

    /// 读文件为行数组；不存在 / 非法 UTF-8 → 空文件（`[""]` 语义留给调用方）。
    /// 用 `components(separatedBy:)` 保留末尾空行，rejoin 后字节结构不变（保全注释）。
    private static func fileLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n")
    }

    private static func writeLines(_ lines: [String], to url: URL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n")
        guard let data = text.data(using: .utf8) else { throw EditError.uneditable }
        try data.write(to: url)
    }

    /// 写前备份 `config.toml.baobox.bak`（每次覆盖）。
    private static func backup(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let bak = url.appendingPathExtension("baobox.bak")
        try? fm.removeItem(at: bak)
        try? fm.copyItem(at: url, to: bak)
    }

    /// 第一个 `[section]` 头所在行；无则返回行数（顶层区域 = 全文）。
    /// 值行形如 `notify = [...]` 起首是键名，不会被误判为 section（section 行 trim 后以 `[` 起）。
    private static func firstSectionIndex(_ lines: [String]) -> Int {
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { return i }
        }
        return lines.count
    }

    /// 顶层区域内某键的 RHS（等号右侧原文）；找不到返回 nil。
    private static func topLevelRHS(_ lines: [String], key: String) -> String? {
        let sectionIdx = firstSectionIndex(lines)
        for i in 0..<sectionIdx where lineAssignsKey(lines[i], key: key) {
            return rhsOf(lines[i])
        }
        return nil
    }

    /// 判断某行是否形如 `^\s*key\s*=`。
    private static func lineAssignsKey(_ line: String, key: String) -> Bool {
        var s = Substring(line)
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        guard s.hasPrefix(key) else { return false }
        s = s.dropFirst(key.count)
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        return s.first == "="
    }

    /// 取等号右侧原文（首个 `=` 之后）。
    private static func rhsOf(_ line: String) -> String? {
        guard let range = line.range(of: "=") else { return nil }
        return String(line[range.upperBound...])
    }

    // MARK: 值解析（仅支持单行基础标量 / 单行字符串数组）

    /// 解析单行字符串值；非单行简单字符串（或带非注释尾巴）返回 nil。
    static func parseString(_ rhsRaw: String) -> String? {
        var s = Substring(rhsRaw)
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        guard let first = s.first, first == "\"" || first == "'" else { return nil }
        guard let (value, rest) = scanQuoted(s) else { return nil }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if tail.isEmpty || tail.hasPrefix("#") { return value }
        return nil
    }

    /// 解析单行字符串数组；跨行 / 含非字符串元素返回 nil。
    static func parseStringArray(_ rhsRaw: String) -> [String]? {
        var s = Substring(rhsRaw)
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        guard s.first == "[" else { return nil }
        s = s.dropFirst()
        var elements: [String] = []
        while true {
            while let f = s.first, f == " " || f == "\t" || f == "," { s = s.dropFirst() }
            guard let f = s.first else { return nil }   // 未见闭合 `]`（可能跨行）→ 不可编辑
            if f == "]" {
                let tail = s.dropFirst().trimmingCharacters(in: .whitespaces)
                if tail.isEmpty || tail.hasPrefix("#") { return elements }
                return nil
            }
            guard f == "\"" || f == "'" else { return nil }   // 非字符串元素 → 不可编辑
            guard let (value, rest) = scanQuoted(s) else { return nil }
            elements.append(value)
            s = rest
        }
    }

    /// 从 `"..."` / `'...'` 起始处扫出一个字符串值与其后剩余子串。
    private static func scanQuoted(_ input: Substring) -> (value: String, rest: Substring)? {
        guard let quote = input.first, quote == "\"" || quote == "'" else { return nil }
        let allowEscapes = (quote == "\"")
        var idx = input.index(after: input.startIndex)
        var result = ""
        while idx < input.endIndex {
            let c = input[idx]
            if allowEscapes, c == "\\" {
                let next = input.index(after: idx)
                guard next < input.endIndex else { return nil }
                switch input[next] {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(input[next])
                }
                idx = input.index(after: next)
            } else if c == quote {
                return (result, input[input.index(after: idx)...])
            } else {
                result.append(c)
                idx = input.index(after: idx)
            }
        }
        return nil
    }

    // MARK: 值编码（写回统一用基础字符串）

    static func encodeString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func encodeStringArray(_ values: [String]) -> String {
        "[" + values.map { encodeString($0) }.joined(separator: ", ") + "]"
    }
}
