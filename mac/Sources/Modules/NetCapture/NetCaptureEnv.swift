import Foundation

/// 网络抓包 —— 环境与共享基础层。
///
/// 本文件是模块的「底座」：支持目录、UserDefaults 键与默认值、共享的同步子进程执行器、
/// shell 转义。所有网络/证书子系统只调这里暴露的方法，绝不各自散落硬编码。
///
/// 并发说明：`NetCaptureEnv` 有意**不**标 `@MainActor` —— 它的成员要么是纯路径计算、
/// 要么是可能阻塞的子进程 IO（networksetup / adb / security），这些必须能在后台线程直接调用。
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

    /// 引擎（mitmproxy）的配置目录：CA 证书与私钥由它生成在这里。`supportDir/mitmproxy/`。
    static var engineConfDir: URL { supportDir.appendingPathComponent("mitmproxy", isDirectory: true) }

    /// v1 自研内核留下的两个目录（旧 CA 与叶子证书缓存）。只在清理旧证书时用，见 `CaptureCA.removeLegacyCA()`。
    static var legacyCADir: URL { supportDir.appendingPathComponent("ca", isDirectory: true) }
    static var legacyLeafDir: URL { supportDir.appendingPathComponent("leaf", isDirectory: true) }

    // MARK: - 引擎

    /// 包内的 mitmdump：`Baobox.app/Contents/Helpers/mitmproxy.app/Contents/MacOS/mitmdump`
    /// （构建时由 project.yml 的「Embed mitmproxy」阶段拷进来，docs/packet-capture/TECH_DESIGN.md §2）。
    static var engineURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/mitmproxy.app/Contents/MacOS/mitmdump")
    }

    /// 桥脚本：`Baobox.app/Contents/Resources/NetCapture/baobox_bridge.py`。
    static var bridgeScriptURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("NetCapture/baobox_bridge.py")
    }

    /// 引擎为什么用不了；nil = 能用。包里只带 Apple 芯片版，开发构建没跑 `make vendor` 时包里没有引擎。
    enum EngineUnavailable {
        case needsAppleSilicon
        case notBundled
    }

    static var engineUnavailable: EngineUnavailable? {
        guard isAppleSilicon else { return .needsAppleSilicon }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: engineURL.path),
              let script = bridgeScriptURL, fm.fileExists(atPath: script.path) else { return .notBundled }
        return nil
    }

    /// 这台机器是不是 Apple 芯片（Baobox 自己跑在 Rosetta 下也算，引擎是另起的原生进程）。
    private static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

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
        static let serviceName = "netcapture.serviceName"
        static let maxFlows = "netcapture.maxFlows"
        static let bodyCap = "netcapture.bodyCap"
        static let decryptScope = "netcapture.decryptScope"       // "all" | "allowlist"
        /// 用户手填的 Wi-Fi 名称。新版 macOS 不给定位权限就读不到当前 Wi-Fi 名，而 iPhone 的代理描述文件要按名称匹配网络。
        static let wifiName = "netcapture.wifiName"
        /// 「这台 Mac」上次是不是开着（下次点开始时照旧）。
        static let lastMacCapture = "netcapture.lastMacCapture"
        static let allowDomains = "netcapture.allowDomains"        // 换行分隔
        static let denyDomains = "netcapture.denyDomains"          // 换行分隔
        static let mcpPort = "netcapture.mcpPort"
        static let mcpRedactAuth = "netcapture.mcpRedactAuth"
        static let clearOnStop = "netcapture.clearOnStop"
        /// 允许手机和平板连进来（引擎听局域网 + 开配置页）。第一次打开手机配置时置真，之后每次开始抓包都照这个来；设置页能关。
        static let phoneEnabled = "netcapture.phoneEnabled"
        /// 设备别名字典（ip → 用户自定义别名），供多设备 Tab 展示（§17）。
        static let deviceAliases = "netcapture.deviceAliases"
        /// 崩溃兜底：开启系统代理前保存的原状态（JSON 编码），停止或下次启动还原。
        static let savedProxyState = "netcapture.savedProxyState"
        /// 列表里隐藏的域名（精确域名，`[String]`）。噪音域名每次都是那些，所以存着（docs/packet-capture/TOOLS.md §1）。
        static let hiddenHosts = "netcapture.hiddenHosts"
        /// 列表里藏起「未解密」的行（Bool，默认 false）。
        static let hideUndecrypted = "netcapture.hideUndecrypted"
        /// 左栏「过滤域名」输入框的文字（String）。
        static let hostFilterText = "netcapture.hostFilterText"
        /// 请求列表「过滤 URL」输入框的文字（String）。
        static let urlFilterText = "netcapture.urlFilterText"
    }

    /// 未知来源设备的占位标识（clientIP 为 nil 时归入此桶）。
    static let unknownDeviceKey = "?"

    /// 一次性注册出厂默认值（在 `activate()` 调）。`register(defaults:)` 不覆盖用户已设值。
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.port: 9090,
            Keys.serviceName: "",
            Keys.maxFlows: 1000,
            Keys.bodyCap: 5 * 1024 * 1024,
            Keys.decryptScope: "all",
            Keys.allowDomains: "",
            Keys.denyDomains: "",
            Keys.mcpPort: 9191,
            Keys.mcpRedactAuth: true,
            Keys.clearOnStop: false,
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

    static var phoneEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.phoneEnabled)
    }

    static var clearOnStop: Bool {
        UserDefaults.standard.object(forKey: Keys.clearOnStop) as? Bool ?? false
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

    // MARK: - 解密范围

    /// 设置里当前的解密范围（匹配在桥脚本里做，见 `DecryptScope`）。
    static var decryptScope: DecryptScope {
        let defaults = UserDefaults.standard
        return DecryptScope.from(setting: defaults.string(forKey: Keys.decryptScope) ?? "all",
                                 allowText: defaults.string(forKey: Keys.allowDomains) ?? "",
                                 denyText: defaults.string(forKey: Keys.denyDomains) ?? "")
    }

    /// 手机配置页的端口：代理端口的下一个（docs/packet-capture/TECH_DESIGN.md §7）。
    static var configPagePort: UInt16 { neighbour(of: port, offset: 1) }

    /// SOCKS5 监听的端口：代理端口 + 2。只听本机，给苹果平台的 WebSocket 用（它不走 HTTP 代理，只走系统的 SOCKS 代理）。
    static var socksPort: UInt16 { neighbour(of: port, offset: 2) }

    /// 代理端口旁边的端口；紧贴上限时往下取，保证不溢出、也不和代理端口重合。
    static func neighbour(of port: UInt16, offset: UInt16) -> UInt16 {
        port <= UInt16.max - offset ? port + offset : port - offset
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
        // 顺序读干两个管道再等退出（同 ClaudeEnv 惯例）。本模块调用的子进程（networksetup /
        // adb / osascript / security）输出量都很小，不会因单管道写满而死锁。
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: outData, stderr: errData)
    }

    // MARK: - Shell 转义

    /// 用单引号安全包裹一个字符串，供 shell 命令拼接。内部单引号按 `'\''` 转义。
    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
