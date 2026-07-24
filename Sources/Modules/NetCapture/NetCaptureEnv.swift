import Foundation

/// 网络抓包 —— 环境与共享基础层。
///
/// 本文件是模块的「底座」：支持目录、UserDefaults 键与默认值、共享的同步子进程执行器、
/// shell 转义。所有网络/证书子系统只调这里暴露的方法，绝不各自散落硬编码。
///
/// 并发说明：`NetCaptureEnv` 有意**不**标 `@MainActor` —— 它的成员要么是纯路径计算、
/// 要么是可能阻塞的子进程 IO（openssl / networksetup / adb），这些必须能在后台线程直接调用。
/// 本文件不含用户可见文案（脚本与命令字符串不经 L()）。
enum NetCaptureEnv {

    // MARK: - 路径常量

    /// 真实家目录。GUI App 非沙箱，取到的是真实 `~`。
    static var homeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/Library/Application Support/Baobox/NetCapture/`
    /// 与 `ClaudeEnv.supportDir` / `CodexEnv.supportDir` 同一约定，独立子目录避免串扰。
    static var supportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDir.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Baobox/NetCapture", isDirectory: true)
    }

    /// CA 目录：`supportDir/ca/`。
    static var caDir: URL { supportDir.appendingPathComponent("ca", isDirectory: true) }

    /// 叶子证书缓存目录：`supportDir/leaf/`。
    static var leafDir: URL { supportDir.appendingPathComponent("leaf", isDirectory: true) }

    /// 确保支持目录存在，返回其 URL（幂等）。
    @discardableResult
    static func ensureSupportDir() -> URL {
        let dir = supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - UserDefaults 键与默认值

    enum Keys {
        static let port = "netcapture.port"
        static let autoSystemProxy = "netcapture.autoSystemProxy"
        static let serviceName = "netcapture.serviceName"
        static let maxFlows = "netcapture.maxFlows"
        static let bodyCap = "netcapture.bodyCap"
        static let decryptScope = "netcapture.decryptScope"       // "all" | "allowlist"
        static let allowDomains = "netcapture.allowDomains"        // 换行分隔
        static let denyDomains = "netcapture.denyDomains"          // 换行分隔
        static let mcpPort = "netcapture.mcpPort"
        static let mcpRedactAuth = "netcapture.mcpRedactAuth"
        static let clearOnStop = "netcapture.clearOnStop"
        /// 设备别名字典（ip → 用户自定义别名），供多设备 Tab 展示（§17）。
        static let deviceAliases = "netcapture.deviceAliases"
        /// 崩溃兜底：开启系统代理前保存的原状态（JSON 编码），停止或下次启动还原。
        static let savedProxyState = "netcapture.savedProxyState"
    }

    /// 未知来源设备的占位标识（clientIP 为 nil 时归入此桶）。
    static let unknownDeviceKey = "?"

    /// 一次性注册出厂默认值（在 `activate()` 调）。`register(defaults:)` 不覆盖用户已设值。
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.port: 9090,
            Keys.autoSystemProxy: true,
            Keys.serviceName: "",
            Keys.maxFlows: 1000,
            Keys.bodyCap: 5 * 1024 * 1024,
            Keys.decryptScope: "all",
            Keys.allowDomains: "",
            Keys.denyDomains: "",
            Keys.mcpPort: 9191,
            Keys.mcpRedactAuth: true,
            Keys.clearOnStop: true,
        ])
    }

    // MARK: - 读取便捷

    static var port: UInt16 {
        let raw = UserDefaults.standard.integer(forKey: Keys.port)
        let clamped = (1024...65535).contains(raw) ? raw : 9090
        return UInt16(clamped)
    }

    static var mcpPort: UInt16 {
        let raw = UserDefaults.standard.integer(forKey: Keys.mcpPort)
        let clamped = (1024...65535).contains(raw) ? raw : 9191
        return UInt16(clamped)
    }

    static var maxFlows: Int {
        let raw = UserDefaults.standard.integer(forKey: Keys.maxFlows)
        return (200...5000).contains(raw) ? raw : 1000
    }

    static var bodyCap: Int {
        let raw = UserDefaults.standard.integer(forKey: Keys.bodyCap)
        return raw > 0 ? raw : 5 * 1024 * 1024
    }

    static var autoSystemProxy: Bool {
        UserDefaults.standard.object(forKey: Keys.autoSystemProxy) as? Bool ?? true
    }

    static var clearOnStop: Bool {
        UserDefaults.standard.object(forKey: Keys.clearOnStop) as? Bool ?? true
    }

    static var mcpRedactAuth: Bool {
        UserDefaults.standard.object(forKey: Keys.mcpRedactAuth) as? Bool ?? true
    }

    // MARK: - 设备别名（§17，ip → 别名，UserDefaults 持久化）

    /// 读取某设备别名（去空白后非空才返回）。
    static func deviceAlias(for ip: String) -> String? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Keys.deviceAliases) as? [String: String] else {
            return nil
        }
        let alias = dict[ip]?.trimmingCharacters(in: .whitespaces)
        return (alias?.isEmpty == false) ? alias : nil
    }

    /// 设置/清除某设备别名；传 nil 或空串即清除该键。
    static func setDeviceAlias(_ alias: String?, for ip: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: Keys.deviceAliases) as? [String: String]) ?? [:]
        let trimmed = (alias ?? "").trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { dict.removeValue(forKey: ip) } else { dict[ip] = trimmed }
        UserDefaults.standard.set(dict, forKey: Keys.deviceAliases)
    }

    // MARK: - 解密范围判定

    /// 依据「解密范围」设置判断某 host 是否应尝试 MITM 解密。
    /// - 全部模式（默认）：deny 列表命中则透传，其余解密。
    /// - 白名单模式：仅 allow 列表命中才解密，其余透传。
    /// 任何情况下判定为「不解密」都走盲隧道透传，绝不中断连接。
    static func shouldDecrypt(host: String) -> Bool {
        let scope = UserDefaults.standard.string(forKey: Keys.decryptScope) ?? "all"
        let deny = domainList(Keys.denyDomains)
        if scope == "allowlist" {
            let allow = domainList(Keys.allowDomains)
            return allow.contains { hostMatches(host, pattern: $0) }
        }
        // 全部模式：deny 命中则不解密。
        return !deny.contains { hostMatches(host, pattern: $0) }
    }

    private static func domainList(_ key: String) -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 域名匹配：支持 `*.example.com` 前缀通配与精确匹配（大小写不敏感）。
    private static func hostMatches(_ host: String, pattern: String) -> Bool {
        let h = host.lowercased()
        let p = pattern.lowercased()
        if p.hasPrefix("*.") {
            let suffix = String(p.dropFirst(1)) // ".example.com"
            return h.hasSuffix(suffix) || h == String(suffix.dropFirst())
        }
        return h == p
    }

    // MARK: - 子进程执行（同步，后台线程调用）

    struct ProcessResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
        var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
        var ok: Bool { status == 0 }
    }

    /// 同步执行一个可执行文件并收集 stdout/stderr。**必须在后台线程调用**（内部同步等待）。
    /// 先并发读干两个管道再 waitUntilExit，避免管道写满导致子进程阻塞。
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], stdin: Data? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        var inPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        }
        do {
            try process.run()
        } catch {
            return ProcessResult(status: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
        }
        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        // 顺序读干两个管道再等退出（同 ClaudeEnv 惯例）。本模块调用的子进程（openssl /
        // networksetup / adb / osascript）输出量都很小，不会因单管道写满而死锁。
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: outData, stderr: errData)
    }

    /// 探测 openssl 可执行路径（macOS 自带 `/usr/bin/openssl`，即 LibreSSL）。
    static func opensslPath() -> String {
        let fm = FileManager.default
        for path in ["/usr/bin/openssl", "/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"]
            where fm.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/openssl"
    }

    // MARK: - Shell 转义

    /// 用单引号安全包裹一个字符串，供 shell 命令拼接。内部单引号按 `'\''` 转义。
    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
