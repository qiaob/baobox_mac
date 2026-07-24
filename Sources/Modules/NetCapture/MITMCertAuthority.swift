import Foundation
import Network
import Security

/// 本地根证书（CA）签发与信任管理。
///
/// - 首次需要时用系统自带 `/usr/bin/openssl`（LibreSSL）一次性生成根 CA，存 `supportDir/ca/`，
///   私钥 `chmod 600`。
/// - 按 host 懒加载签发叶子证书，缓存到内存（`[host: sec_identity_t]`）+ 磁盘（`leaf/<host>.p12`）。
/// - `.p12` → `SecPKCS12Import` → `SecIdentity` → `sec_identity_create` → `sec_identity_t` 供 `NWProtocolTLS`。
/// - Mac 信任安装/移除走 `security add/remove-trusted-cert` + osascript 管理员授权。
///
/// 并发：本类**不**标 `@MainActor`。identity 查询要在 Network 连接队列上同步调用（CONNECT 已知 host，
/// 命中缓存 0 开销，未命中同步阻塞签发一次——openssl 冷启 ~30–80ms，可接受）。内部用锁保护缓存。
/// 签发失败 → 返回 nil，上层对该 host 走盲隧道透传。
final class MITMCertAuthority: @unchecked Sendable {
    static let shared = MITMCertAuthority()

    /// p12 导出/导入口令（仅用于本机进程内把私钥搬进 keychain-less 的 SecIdentity，非安全边界）。
    private static let p12Passphrase = "baobox"

    private let lock = NSLock()
    private var identityCache: [String: sec_identity_t] = [:]
    /// CA 是否已就绪（内存标记，避免每次查磁盘）。
    private var caReady = false

    private init() {}

    // MARK: - 路径

    var caKeyURL: URL { NetCaptureEnv.caDir.appendingPathComponent("baobox-ca.key") }
    var caCertURL: URL { NetCaptureEnv.caDir.appendingPathComponent("baobox-ca.pem") }
    private var caSerialURL: URL { NetCaptureEnv.caDir.appendingPathComponent("baobox-ca.srl") }
    private var leafKeyURL: URL { NetCaptureEnv.caDir.appendingPathComponent("leaf.key") }

    /// CA 是否已在磁盘生成。
    var isCAGenerated: Bool {
        FileManager.default.fileExists(atPath: caKeyURL.path)
            && FileManager.default.fileExists(atPath: caCertURL.path)
    }

    /// CA 根证书 PEM 数据（供设备下载）。未生成返回 nil。
    func caCertPEM() -> Data? {
        try? Data(contentsOf: caCertURL)
    }

    // MARK: - CA 生成（幂等，后台线程调用）

    /// 确保 CA 存在；不存在则用 openssl 生成。返回是否就绪。**后台线程调用**。
    @discardableResult
    func ensureCA() -> Bool {
        lock.lock()
        if caReady { lock.unlock(); return true }
        lock.unlock()

        if isCAGenerated {
            lock.lock(); caReady = true; lock.unlock()
            return true
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: NetCaptureEnv.caDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: NetCaptureEnv.leafDir, withIntermediateDirectories: true)
        let openssl = NetCaptureEnv.opensslPath()

        // 1) 生成 CA 私钥。
        let genKey = NetCaptureEnv.run(openssl, ["genrsa", "-out", caKeyURL.path, "2048"])
        guard genKey.ok else { return false }
        // 私钥权限 600。
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKeyURL.path)

        // 2) 生成自签根证书（10 年，标记为 CA）。
        let genCert = NetCaptureEnv.run(openssl, [
            "req", "-x509", "-new", "-nodes", "-key", caKeyURL.path, "-sha256", "-days", "3650",
            "-subj", "/CN=Baobox Proxy CA/O=Baobox",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-out", caCertURL.path,
        ])
        guard genCert.ok else { return false }

        // 3) 共享叶子私钥（所有 host 复用一把，省签发时间）。
        let genLeafKey = NetCaptureEnv.run(openssl, ["genrsa", "-out", leafKeyURL.path, "2048"])
        guard genLeafKey.ok else { return false }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: leafKeyURL.path)

        lock.lock(); caReady = true; lock.unlock()
        return true
    }

    // MARK: - 叶子证书按 host 签发 + SecIdentity

    /// 取某 host 的 TLS 服务端 identity（懒加载签发 + 缓存）。失败返回 nil（上层透传该 host）。
    /// **可在 Network 连接队列同步调用**：命中缓存立即返回；未命中同步签发一次。
    func identity(forHost host: String) -> sec_identity_t? {
        let key = host.lowercased()
        lock.lock()
        if let cached = identityCache[key] { lock.unlock(); return cached }
        lock.unlock()

        guard ensureCA() else { return nil }

        // 磁盘缓存命中？
        let p12URL = NetCaptureEnv.leafDir.appendingPathComponent("\(sanitized(key)).p12")
        if let data = try? Data(contentsOf: p12URL), let identity = importIdentity(from: data) {
            lock.lock(); identityCache[key] = identity; lock.unlock()
            return identity
        }

        // 现签。
        guard let data = signLeaf(host: key), let identity = importIdentity(from: data) else { return nil }
        try? data.write(to: p12URL)
        lock.lock(); identityCache[key] = identity; lock.unlock()
        return identity
    }

    /// 用 openssl 为 host 签发叶子证书并导出 p12。返回 p12 数据。后台/连接队列调用。
    private func signLeaf(host: String) -> Data? {
        let openssl = NetCaptureEnv.opensslPath()
        let tmp = FileManager.default.temporaryDirectory
        let stem = UUID().uuidString
        let csrURL = tmp.appendingPathComponent("\(stem).csr")
        let extURL = tmp.appendingPathComponent("\(stem).ext")
        let crtURL = tmp.appendingPathComponent("\(stem).crt")
        let p12URL = tmp.appendingPathComponent("\(stem).p12")
        defer {
            for url in [csrURL, extURL, crtURL, p12URL] { try? FileManager.default.removeItem(at: url) }
        }

        // CSR（CN 取 host）。
        let csr = NetCaptureEnv.run(openssl, [
            "req", "-new", "-key", leafKeyURL.path, "-subj", "/CN=\(host)", "-out", csrURL.path,
        ])
        guard csr.ok else { return nil }

        // SAN 扩展文件（现代客户端只认 SAN）。用文件而非 shell process substitution，避免 shell 依赖。
        let extText = """
        subjectAltName=DNS:\(host)
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        """
        guard (try? extText.write(to: extURL, atomically: true, encoding: .utf8)) != nil else { return nil }

        // 用 CA 签发叶子（≤825 天）。
        let sign = NetCaptureEnv.run(openssl, [
            "x509", "-req", "-in", csrURL.path,
            "-CA", caCertURL.path, "-CAkey", caKeyURL.path, "-CAcreateserial", "-CAserial", caSerialURL.path,
            "-sha256", "-days", "825", "-extfile", extURL.path, "-out", crtURL.path,
        ])
        guard sign.ok else { return nil }

        // 导出 p12（含叶子 + CA 链）。注意：LibreSSL 默认用 SecPKCS12Import 兼容的传统加密，
        // 不能加 OpenSSL 3 的 `-legacy` 标志（LibreSSL 无此选项，会报错）。
        let export = NetCaptureEnv.run(openssl, [
            "pkcs12", "-export", "-inkey", leafKeyURL.path, "-in", crtURL.path, "-certfile", caCertURL.path,
            "-passout", "pass:\(Self.p12Passphrase)", "-out", p12URL.path,
        ])
        guard export.ok else { return nil }
        return try? Data(contentsOf: p12URL)
    }

    /// `.p12` → `SecPKCS12Import` → `SecIdentity` → `sec_identity_t`。失败返回 nil。
    ///
    /// TODO(有 Mac 者验证)：macOS 上 `SecPKCS12Import` 的行为与 iOS 略有差异——某些系统版本需要在
    /// options 里带 `kSecImportExportKeychain`（否则可能导入到 login 钥匙串或报 `errSecInternalComponent`）。
    /// 另需确认系统 LibreSSL `openssl pkcs12 -export` 产出的 PBE 算法可被 `SecPKCS12Import` 解析
    /// （LibreSSL 默认为传统 3DES/RC2，通常兼容）。若遇导入失败，此处该 host 会退化为盲隧道透传（不影响上网）。
    private func importIdentity(from p12: Data) -> sec_identity_t? {
        let options: [String: Any] = [kSecImportExportPassphrase as String: Self.p12Passphrase]
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityAny = first[kSecImportItemIdentity as String] else { return nil }
        // 运行时类型校验后再桥接为 SecIdentity：避免 CLAUDE.md 约定禁止的无保护 force-cast 崩溃；
        // 类型不符（理论上不会发生）则返回 nil，调用方据此对该 host 走透传兜底。
        guard CFGetTypeID(identityAny as CFTypeRef) == SecIdentityGetTypeID() else { return nil }
        let secIdentity = identityAny as! SecIdentity
        return sec_identity_create(secIdentity)
    }

    private func sanitized(_ host: String) -> String {
        host.replacingOccurrences(of: "*", with: "_wild_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// 清空内存 identity 缓存（停止抓包时调，释放内存；磁盘 p12 保留复用）。
    func flushMemoryCache() {
        lock.lock(); identityCache.removeAll(keepingCapacity: false); lock.unlock()
    }

    // MARK: - Mac 信任状态 / 安装 / 移除

    /// 查询 CA 是否已在系统被信任。
    ///
    /// 简化实现：对 CA 证书本身做 `SecTrustEvaluateWithError` —— 已加入受信任根则通过。
    /// 未生成 CA 直接返回 false。**后台线程调用**（可能触发信任评估 IO）。
    func isTrusted() -> Bool {
        guard let pem = caCertPEM(), let cert = certificate(fromPEM: pem) else { return false }
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        guard SecTrustCreateWithCertificates(cert, policy, &trust) == errSecSuccess, let trust else {
            return false
        }
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    /// 从 PEM 数据构造 SecCertificate（剥离 PEM 头尾取 DER）。
    private func certificate(fromPEM pem: Data) -> SecCertificate? {
        guard let text = String(data: pem, encoding: .utf8) else { return nil }
        let base64 = text
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    /// 一键安装并信任到系统钥匙串（需管理员授权，走系统授权弹窗）。
    /// 返回是否成功。**后台线程调用**（osascript 同步阻塞等待授权）。
    func installTrust() -> (ok: Bool, message: String) {
        guard ensureCA() else { return (false, "CA not generated") }
        let caPath = caCertURL.path
        // security add-trusted-cert 写系统钥匙串需管理员；用 osascript 触发系统授权框。
        let shell = "security add-trusted-cert -d -r trustRoot "
            + "-k /Library/Keychains/System.keychain \(NetCaptureEnv.shellSingleQuote(caPath))"
        let script = "do shell script \"\(escapeForAppleScript(shell))\" with administrator privileges"
        let result = NetCaptureEnv.run("/usr/bin/osascript", ["-e", script])
        return (result.ok, result.ok ? "" : result.stderrString)
    }

    /// 移除系统信任。返回是否成功。**后台线程调用**。
    func removeTrust() -> (ok: Bool, message: String) {
        let caPath = caCertURL.path
        // remove-trusted-cert -d 从管理员域移除；同样需管理员。
        let shell = "security remove-trusted-cert -d \(NetCaptureEnv.shellSingleQuote(caPath))"
        let script = "do shell script \"\(escapeForAppleScript(shell))\" with administrator privileges"
        let result = NetCaptureEnv.run("/usr/bin/osascript", ["-e", script])
        return (result.ok, result.ok ? "" : result.stderrString)
    }

    /// 转义供 AppleScript 字符串字面量使用（反斜杠与双引号）。
    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
