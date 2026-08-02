import Foundation

/// 唯一会动 `/etc/hosts` 的地方。所有提权动作收敛在这里，将来换特权助手只改这一个文件。
enum HostsWriter {

    /// 把 Baobox 块写进系统 hosts（块为空 = 摘掉接管），随后刷新 DNS 缓存。
    ///
    /// **必须在后台线程调用**（内部同步等待授权与子进程）。
    static func write(block: String) -> HostsApplyOutcome {
        let current = HostsFile.readSystem()
        let composed = HostsFile.compose(userContent: HostsFile.stripBlock(current), block: block)

        // 内容没变就别弹授权框 —— 频繁无谓地要密码是这个功能最容易被讨厌的地方。
        guard composed != current else { return .ok }

        HostsEnv.ensureSupportDir()
        let staging = HostsEnv.stagingFile
        do {
            try composed.write(to: staging, atomically: true, encoding: .utf8)
        } catch {
            return .failed(error.localizedDescription)
        }

        let hosts = HostsEnv.shellQuote(HostsEnv.systemHostsPath)
        let backup = HostsEnv.shellQuote(HostsEnv.backupPath)
        let pending = HostsEnv.shellQuote(staging.path)
        // 备份只在不存在时做一次：否则第二次应用会把备份覆盖成「已被我们改过」的版本，
        // 真正的原始 hosts 就永久丢了。
        let command = [
            "[ -f \(backup) ] || /bin/cp \(hosts) \(backup)",
            "/bin/cp \(pending) \(hosts)",
            "/usr/sbin/chown root:wheel \(hosts)",
            "/bin/chmod 644 \(hosts)",
            "/usr/bin/dscacheutil -flushcache",
            // mDNSResponder 没在跑时 killall 返回非零，会让整条命令被判失败。
            "/usr/bin/killall -HUP mDNSResponder || true"
        ].joined(separator: " && ")

        switch HostsEnv.runPrivileged(command) {
        case .success:
            try? FileManager.default.removeItem(at: staging)
            return .ok
        case .failure(.cancelled):
            return .cancelled
        case .failure(let error):
            return .failed(error.localizedDescription)
        }
    }
}
