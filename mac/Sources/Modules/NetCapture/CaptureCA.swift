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

    /// 安装进系统钥匙串并设为受信任根。要管理员授权，系统会弹密码框；用户取消就返回失败。
    func installTrust() -> (ok: Bool, message: String) {
        guard ensureGenerated() else { return (false, "CA not generated") }
        let shell = "security add-trusted-cert -d -r trustRoot "
            + "-k /Library/Keychains/System.keychain \(NetCaptureEnv.shellSingleQuote(certURL.path))"
        let result = runAsAdmin(shell)
        return (result.ok, result.ok ? "" : result.stderrString)
    }

    /// 取消信任并从系统钥匙串删掉。
    func removeTrust() -> (ok: Bool, message: String) {
        guard isGenerated else { return (true, "") }
        let cert = NetCaptureEnv.shellSingleQuote(certURL.path)
        // remove-trusted-cert 只撤信任设置，证书本身还留在钥匙串里；再按 SHA-1 删掉，不留垃圾。
        var shell = "security remove-trusted-cert -d \(cert)"
        if let sha1 = sha1Fingerprint() {
            shell += "; security delete-certificate -Z \(sha1) /Library/Keychains/System.keychain"
        }
        let result = runAsAdmin(shell)
        return (result.ok, result.ok ? "" : result.stderrString)
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

    /// 清掉 v1 的东西：把旧 CA 从钥匙串删掉（连同对它的信任），再删磁盘上的两个旧目录。只在用户点了按钮时做。
    func removeLegacyCA() -> (ok: Bool, message: String) {
        let pem = NetCaptureEnv.legacyCADir.appendingPathComponent("baobox-ca.pem").path
        var steps: [String] = []
        if FileManager.default.fileExists(atPath: pem) {
            steps.append("security remove-trusted-cert -d \(NetCaptureEnv.shellSingleQuote(pem)) || true")
        }
        steps.append("security delete-certificate -c \(NetCaptureEnv.shellSingleQuote(Self.legacyCAName)) "
            + "/Library/Keychains/System.keychain || true")
        let admin = runAsAdmin(steps.joined(separator: "; "))
        guard admin.ok else { return (false, admin.stderrString) }
        // 登录钥匙串里那份不需要管理员。
        NetCaptureEnv.run("/usr/bin/security", ["delete-certificate", "-c", Self.legacyCAName])
        try? FileManager.default.removeItem(at: NetCaptureEnv.legacyCADir)
        try? FileManager.default.removeItem(at: NetCaptureEnv.legacyLeafDir)
        return (true, "")
    }
}
