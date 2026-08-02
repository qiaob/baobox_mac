import Foundation

/// hosts 管理 —— 环境与共享基础层：支持目录、路径常量、shell/AppleScript 转义、提权执行器。
///
/// 并发说明：有意**不**标 `@MainActor` —— 提权执行会同步等待子进程（用户还要输密码，
/// 可能好几秒），必须能在后台线程直接调用。
enum HostsEnv {

    // MARK: - 路径

    static var homeDir: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/Library/Application Support/Baobox/Hosts/`（与其它模块同一约定，独立子目录避免串扰）。
    static var supportDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDir.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Baobox/Hosts", isDirectory: true)
    }

    static var schemesFile: URL { supportDir.appendingPathComponent("schemes.json") }

    /// 提权写入前的暂存文件：先以当前用户身份写好完整内容，再由特权命令整体拷过去。
    static var stagingFile: URL { supportDir.appendingPathComponent("pending-hosts") }

    static let systemHostsPath = "/etc/hosts"
    /// 首次接管前的原始 hosts 备份。**只在不存在时创建**，否则第二次应用就会把
    /// 备份覆盖成「已被我们改过」的版本，真正的原始内容就永久丢了。
    static let backupPath = "/etc/hosts.baobox.bak"

    @discardableResult
    static func ensureSupportDir() -> URL {
        let dir = supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 转义

    /// 包成 shell 单引号字面量（支持目录路径里有空格，必须引）。
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 转义成 AppleScript 双引号字符串字面量的内容。
    static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - 提权执行

    enum PrivilegedError: LocalizedError {
        /// 用户在系统授权框上点了取消 / 输错密码放弃。
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return L("hosts.error.cancelled")
            case .failed(let message): return message
            }
        }
    }

    /// 以管理员身份执行一条 shell 命令。
    ///
    /// 走 `osascript` 的 `do shell script … with administrator privileges`：不需要额外的
    /// 特权助手 target 与签名配置，代价是每次弹一次系统授权框。所有提权动作都收敛到这一个
    /// 函数，将来换成 `SMAppService` 特权助手时上层不用动。
    ///
    /// **必须在后台线程调用**（同步等待子进程 + 用户输密码）。
    static func runPrivileged(_ shell: String) -> Result<Void, PrivilegedError> {
        let script = "do shell script \"\(appleScriptQuote(shell))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        // 先读干管道再等退出，避免管道写满导致子进程阻塞。
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus != 0 else { return .success(()) }

        let message = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 用户取消授权：AppleScript 报 -128（User canceled）。这不是错误，安静降级。
        if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
            return .failure(.cancelled)
        }
        return .failure(.failed(message.isEmpty ? L("hosts.error.unknown") : message))
    }
}
