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

    /// 推送 CA 证书到设备下载目录并尝试拉起安装界面。后台线程调用。
    /// 返回是否推送成功；安装界面因 ROM 而异，仅尽力拉起。
    @discardableResult
    static func pushAndInstallCert(serial: String) -> Bool {
        guard let adb = adbPath() else { return false }
        let caPath = MITMCertAuthority.shared.caCertURL.path
        guard FileManager.default.fileExists(atPath: caPath) else { return false }
        let remote = "/sdcard/Download/baobox-ca.crt"
        let push = NetCaptureEnv.run(adb, ["-s", serial, "push", caPath, remote])
        guard push.ok else { return false }
        // 尝试打开证书文件的安装 intent（不同 ROM 行为不一，失败退回打开安全设置）。
        let view = NetCaptureEnv.run(adb, ["-s", serial, "shell", "am", "start",
                                           "-a", "android.intent.action.VIEW",
                                           "-d", "file://\(remote)",
                                           "-t", "application/x-x509-ca-cert"])
        if !view.ok {
            NetCaptureEnv.run(adb, ["-s", serial, "shell", "am", "start",
                                    "-a", "android.settings.SECURITY_SETTINGS"])
        }
        return true
    }
}
