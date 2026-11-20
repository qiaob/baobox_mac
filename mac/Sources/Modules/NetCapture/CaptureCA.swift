import CryptoKit
import Foundation
import Security

/// 抓包用的根证书（CA）：在哪、装没装、怎么装进 Mac。
///
/// CA 由引擎（mitmproxy）自己生成，放在 `NetCaptureEnv.engineConfDir`：`mitmproxy-ca-cert.pem` 是公开证书，
/// `mitmproxy-ca.pem` 带私钥（引擎写成 600）。叶子证书也由引擎签，Baobox 不碰。
/// 见 docs/packet-capture/TECH_DESIGN.md §5。
///
/// 并发：不标 `@MainActor`。这里的方法要么是路径计算，要么会起子进程同步等（`security`、`osascript`、引擎），
/// **一律在后台线程调用**。
final class CaptureCA: @unchecked Sendable {
    static let shared = CaptureCA()
    private init() {}

    // MARK: - 路径

    /// 公开证书（PEM）。给设备下载、给 Mac 安装的都是这张。
    var certURL: URL { NetCaptureEnv.engineConfDir.appendingPathComponent("mitmproxy-ca-cert.pem") }

    /// 系统根证书 + CA 的合并文件，给终端里的工具用（`SSL_CERT_FILE` 等）。
    var bundleURL: URL { NetCaptureEnv.supportDir.appendingPathComponent("ca-bundle.pem") }

    var isGenerated: Bool { FileManager.default.fileExists(atPath: certURL.path) }

    func certPEM() -> Data? { try? Data(contentsOf: certURL) }

    /// 证书的 DER 字节（描述文件里要这个）。
    func certDER() -> Data? {
        guard let pem = certPEM(), let text = String(data: pem, encoding: .utf8) else { return nil }
        let base64 = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: base64)
    }

    // MARK: - 生成

    /// 确保 CA 已生成。没有就让引擎空跑一次：桥脚本的 `baobox_oneshot` 选项让它就绪后立刻退出，约 1 秒。
    @discardableResult
    func ensureGenerated() -> Bool {
        if isGenerated { return true }
        guard NetCaptureEnv.engineUnavailable == nil, let script = NetCaptureEnv.bridgeScriptURL else { return false }
        let confDir = NetCaptureEnv.engineConfDir
        try? FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        // -n：不起代理监听，只初始化（生成证书）。
        NetCaptureEnv.run(NetCaptureEnv.engineURL.path, [
            "-n", "-q",
            "--set", "confdir=\(confDir.path)",
            "-s", script.path,
            "--set", "baobox_oneshot=true",
        ], stdin: Data())
        return isGenerated
    }

    // MARK: - Mac 上的信任

    /// CA 是否已被这台 Mac 信任：对它自己做一次信任评估，在受信任根里就通过。
    func isTrusted() -> Bool {
        guard let der = certDER(), let cert = SecCertificateCreateWithData(nil, der as CFData) else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return false }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// 装证书的结果。`cancelled` = 用户在系统的验证框里点了取消，不算出错。
    struct TrustResult {
        var ok: Bool
        var cancelled = false
        var message = ""
    }

    /// 当前用户的登录钥匙串。
    private var loginKeychain: String {
        NetCaptureEnv.homeDir.appendingPathComponent("Library/Keychains/login.keychain-db").path
    }

    private static let systemKeychain = "/Library/Keychains/System.keychain"

    /// 把 CA 加进登录钥匙串并设为这个用户信任的根证书。
    ///
    /// **以当前用户身份跑，不提权**：改信任设置时系统自己会弹验证框（密码 / Touch ID）。
    /// v1 的做法是 `osascript … with administrator privileges` 以 root 跑 `add-trusted-cert -d`（管理员域），
    /// 2026-11-21 在 macOS 27 上实测：证书进了系统钥匙串，但信任设置没写进去（root 的 shell 不在用户的图形会话里，
    /// 系统要的那次「用户交互」做不了），而且命令不报错地做了一半。用户域的信任对这个用户的所有 App 都生效，够用。
    func installTrust() -> TrustResult {
        guard ensureGenerated() else { return TrustResult(ok: false, message: "CA not generated") }
        let result = NetCaptureEnv.run("/usr/bin/security", [
            "add-trusted-cert", "-r", "trustRoot", "-k", loginKeychain, certURL.path,
        ])
        return Self.trustResult(result)
    }

    /// 取消信任，并把证书从钥匙串里删掉。
    func removeTrust() -> TrustResult {
        guard isGenerated else { return TrustResult(ok: true) }
        // 先撤信任设置（系统弹验证框）；证书本身还留在钥匙串里，再按指纹删掉。
        let removed = NetCaptureEnv.run("/usr/bin/security", ["remove-trusted-cert", certURL.path])
        let outcome = Self.trustResult(removed)
        guard outcome.ok, let sha1 = sha1Fingerprint() else { return outcome }
        NetCaptureEnv.run("/usr/bin/security", ["delete-certificate", "-Z", sha1, loginKeychain])
        // 早先那次没装成的安装可能在系统钥匙串里也留了一份（没有信任设置，不起作用）；有就顺手删掉，这一步要管理员密码。
        let stray = NetCaptureEnv.run("/usr/bin/security", ["find-certificate", "-a", "-Z", Self.systemKeychain])
        if stray.stdoutString.contains(sha1) {
            _ = runAsAdmin("security delete-certificate -Z \(sha1) \(Self.systemKeychain)")
        }
        return outcome
    }

    private static func trustResult(_ result: NetCaptureEnv.ProcessResult) -> TrustResult {
        if result.ok { return TrustResult(ok: true) }
        let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        let cancelled = lower.contains("cancel") || lower.contains("-60006") || lower.contains("-128")
        return TrustResult(ok: false, cancelled: cancelled, message: message)
    }

    private func runAsAdmin(_ shell: String) -> NetCaptureEnv.ProcessResult {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return NetCaptureEnv.run("/usr/bin/osascript",
                                 ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }

    private func sha1Fingerprint() -> String? {
        guard let der = certDER() else { return nil }
        return Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - 给终端用的合并证书

    /// 写出「系统根证书 + CA」的合并文件并返回路径。只给 CA 一张的话，没被解密（放行）的域名在终端里会校验失败。
    func writeBundle() -> URL? {
        guard ensureGenerated(), let ca = certPEM() else { return nil }
        let roots = NetCaptureEnv.run("/usr/bin/security", [
            "find-certificate", "-a", "-p", "/System/Library/Keychains/SystemRootCertificates.keychain",
        ])
        guard roots.ok, !roots.stdout.isEmpty else { return nil }
        var bundle = roots.stdout
        if bundle.last != 0x0A { bundle.append(0x0A) }
        bundle.append(ca)
        NetCaptureEnv.ensureSupportDir()
        do {
            try bundle.write(to: bundleURL, options: .atomic)
        } catch {
            StorageWriteFailure.report("netcapture.ca-bundle", reason: error.localizedDescription)
            return nil
        }
        return bundleURL
    }

    // MARK: - iOS 模拟器

    /// 给所有已启动的 iOS 模拟器装上根证书。没装 Xcode、没有已启动的模拟器都会失败，原因在 message 里。
    func installIntoBootedSimulators() -> (ok: Bool, message: String) {
        guard ensureGenerated() else { return (false, "CA not generated") }
        let result = NetCaptureEnv.run("/usr/bin/xcrun",
                                       ["simctl", "keychain", "booted", "add-root-cert", certURL.path])
        return (result.ok, result.ok ? "" : result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - v1 留下的旧证书

    /// v1（自研内核）的 CA 叫这个名字，装在登录钥匙串或系统钥匙串里。
    private static let legacyCAName = "Baobox Proxy CA"

    /// 这台 Mac 上是否还留着 v1 的 CA 目录（里面有旧 CA 的私钥）。
    var hasLegacyCA: Bool {
        FileManager.default.fileExists(atPath: NetCaptureEnv.legacyCADir.path)
    }

    /// 清掉 v1 的东西：撤掉对旧 CA 的信任、把它从钥匙串删掉，再删磁盘上的两个旧目录（里面有旧 CA 的私钥）。
    /// 只在用户点了按钮时做。旧 CA 在登录钥匙串里；系统钥匙串里也有的话才需要管理员密码。
    func removeLegacyCA() -> TrustResult {
        let pem = NetCaptureEnv.legacyCADir.appendingPathComponent("baobox-ca.pem").path
        if FileManager.default.fileExists(atPath: pem) {
            // 没有信任设置时这一步会失败，无所谓；用户点了取消就整个停下。
            let removed = Self.trustResult(NetCaptureEnv.run("/usr/bin/security", ["remove-trusted-cert", pem]))
            if removed.cancelled { return removed }
        }
        NetCaptureEnv.run("/usr/bin/security", ["delete-certificate", "-c", Self.legacyCAName, loginKeychain])
        let inSystem = NetCaptureEnv.run("/usr/bin/security",
                                         ["find-certificate", "-c", Self.legacyCAName, Self.systemKeychain])
        if inSystem.ok {
            let admin = runAsAdmin("security delete-certificate -c \(NetCaptureEnv.shellSingleQuote(Self.legacyCAName)) "
                + Self.systemKeychain)
            guard admin.ok else { return Self.trustResult(admin) }
        }
        try? FileManager.default.removeItem(at: NetCaptureEnv.legacyCADir)
        try? FileManager.default.removeItem(at: NetCaptureEnv.legacyLeafDir)
        return TrustResult(ok: true)
    }
}
