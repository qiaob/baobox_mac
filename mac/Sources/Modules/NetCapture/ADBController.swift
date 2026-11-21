import Foundation

/// Android adb 一键设置：探测 adb、枚举设备、设/清代理、推证书并拉起安装。
///
/// 本类不标 `@MainActor`：adb 子进程同步阻塞，须后台调用。UI 在后台队列调用后回主线程更新。
enum ADBController {

    /// 已连设备。
    struct Device: Identifiable {
        var id: String { serial }
        let serial: String
        let model: String   // 尽力从 `-l` 解析，取不到为空
    }

    private static let lock = NSLock()
    private static var cachedPath: String?

    /// 探测 adb 路径：常见 SDK 位置 + Homebrew + PATH。缓存。返回 nil 表示未安装。
    static func adbPath() -> String? {
        lock.lock()
        if let cached = cachedPath { lock.unlock(); return cached.isEmpty ? nil : cached }
        lock.unlock()

        let fm = FileManager.default
        let home = NetCaptureEnv.homeDir
        let candidates = [
            home.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path,
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            lock.lock(); cachedPath = path; lock.unlock()
            return path
        }
        // 退回 PATH 查找（登录 shell）。
        let which = NetCaptureEnv.run("/bin/zsh", ["-lc", "command -v adb"])
        if which.ok {
            let path = which.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                lock.lock(); cachedPath = path; lock.unlock()
                return path
            }
        }
        lock.lock(); cachedPath = ""; lock.unlock()
        return nil
    }

    /// 枚举已连设备（`adb devices -l`）。后台线程调用。
    static func devices() -> [Device] {
        guard let adb = adbPath() else { return [] }
        let result = NetCaptureEnv.run(adb, ["devices", "-l"])
        guard result.ok else { return [] }
        var devices: [Device] = []
        for line in result.stdoutString.components(separatedBy: "\n").dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("device") else { continue }
            let fields = trimmed.split(separator: " ")
            guard let serial = fields.first, fields.count >= 2, fields[1] == "device" else { continue }
            let model = fields.first { $0.hasPrefix("model:") }.map { String($0.dropFirst("model:".count)) } ?? ""
            devices.append(Device(serial: String(serial), model: model))
        }
        return devices
    }

    /// 一键设代理：`settings put global http_proxy <ip>:<port>`。后台线程调用。
    @discardableResult
    static func setProxy(serial: String, ip: String, port: UInt16) -> Bool {
        guard let adb = adbPath() else { return false }
        let result = NetCaptureEnv.run(adb, ["-s", serial, "shell", "settings", "put", "global",
                                             "http_proxy", "\(ip):\(port)"])
        return result.ok
    }

    /// 清除代理：`settings put global http_proxy :0`。后台线程调用。
    @discardableResult
    static func clearProxy(serial: String) -> Bool {
        guard let adb = adbPath() else { return false }
        let result = NetCaptureEnv.run(adb, ["-s", serial, "shell", "settings", "put", "global",
                                             "http_proxy", ":0"])
        return result.ok
    }

    /// 把 CA 证书推到设备的下载目录，再把人带到系统设置里离「安装证书」最近的一页。后台线程调用。
    /// 返回是否推送成功。
    ///
    /// Android 11 起 CA 证书**只能在系统设置里装**，别的入口系统都会拒绝。2026-11-21 在 Android 15 模拟器上实测：
    /// - 用 VIEW 打开 `file://` 的证书文件（v1 的做法）：提示「无法读取证书文件」。
    /// - 从系统的证书安装器里选这个文件：提示「CA 证书必须在设置里安装」。
    /// - 设置 → 更多安全和隐私 → 加密与凭据 → 安装证书 → CA 证书 → 仍然安装 → 选文件：装上了，不需要先设锁屏密码。
    /// 所以这里不再试图拉起安装器，只打开「更多安全和隐私」那一页（AOSP 的 action；厂商系统上可能没有，退回安全设置首页），
    /// 剩下三步由界面上的文字告诉用户。
    @discardableResult
    static func pushAndInstallCert(serial: String) -> Bool {
        guard let adb = adbPath() else { return false }
        guard CaptureCA.shared.ensureGenerated() else { return false }
        let caPath = CaptureCA.shared.certURL.path
        let push = NetCaptureEnv.run(adb, ["-s", serial, "push", caPath, certRemotePath])
        guard push.ok else { return false }
        if !startActivity(adb: adb, serial: serial, action: "com.android.settings.security.SECURITY_ADVANCED_SETTINGS") {
            startActivity(adb: adb, serial: serial, action: "android.settings.SECURITY_SETTINGS")
        }
        return true
    }

    /// 证书在设备上的位置（「下载」目录）。
    static let certRemotePath = "/sdcard/Download/baobox-ca.crt"

    /// `am start -a <action>`。解析不了时 `am` 的退出码仍是 0，只在输出里写 Error，所以两样都看。
    @discardableResult
    private static func startActivity(adb: String, serial: String, action: String) -> Bool {
        let result = NetCaptureEnv.run(adb, ["-s", serial, "shell", "am", "start", "-a", action])
        return result.ok && !result.stdoutString.contains("Error") && !result.stderrString.contains("Error")
    }
}
