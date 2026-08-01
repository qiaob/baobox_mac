import Foundation
import CryptoKit
import Security

/// 剪贴板落盘加密。
///
/// - 密钥：256-bit 随机对称密钥，存 Keychain（generic password），
///   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` —— 只在解锁后可读、不同步 iCloud、
///   不随备份迁到别的机器。App 用固定 DEVELOPMENT_TEAM 签名，重新编译签名身份不变，
///   Keychain ACL 因此稳定，不会每次构建都弹授权框。
/// - 数据：AES-GCM 整份封装，落盘的是 `combined`（nonce + 密文 + 认证标签）。
///
/// 兼容策略：读取时先按密文解，解不开就当作老版本留下的明文原样返回；写入时 Keychain
/// 不可用则降级写明文。**宁可明文也不能丢数据** —— 加密是否生效在设置页有状态提示。
enum ClipboardCrypto {
    private static let keychainService = "com.baobox.app"
    private static let keychainAccount = "clipboard.historyKey"
    private static let keyByteCount = 32

    /// 进程内缓存，避免每次写盘都查一遍 Keychain。可能被后台迁移线程访问，用锁保护。
    private static var cachedKey: SymmetricKey?
    private static let lock = NSLock()

    /// 加密当前是否可用（能拿到/建出 Keychain 密钥）。设置页据此显示存储状态。
    static var isAvailable: Bool { key() != nil }

    // MARK: - 密钥

    static func key() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let resolved = loadKey() ?? createKey()
        cachedKey = resolved
        return resolved
    }

    private static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess,
              let data = out as? Data,
              data.count == keyByteCount else { return nil }
        return SymmetricKey(data: data)
    }

    private static func createKey() -> SymmetricKey? {
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let data = Data(bytes)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrLabel as String: "Baobox Clipboard History Key",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return SymmetricKey(data: data) }
        // 并发/残留导致的重复项：回头读现存那把，别覆盖 —— 覆盖等于把已有历史锁死。
        if status == errSecDuplicateItem { return loadKey() }
        return nil
    }

    // MARK: - 加解密

    static func seal(_ plaintext: Data) -> Data? {
        guard let key = key(),
              let box = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        return box.combined
    }

    static func open(_ ciphertext: Data) -> Data? {
        guard let key = key(),
              let box = try? AES.GCM.SealedBox(combined: ciphertext),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }

    // MARK: - 文件读写

    /// 加密写盘；拿不到密钥时降级写明文。返回是否写成功。
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let payload = seal(data) ?? data
        do {
            try payload.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 读盘并解密；解不开就按明文返回（老版本遗留文件）。
    /// AES-GCM 带认证标签，明文被误判成密文的概率可以忽略。
    static func read(from url: URL) -> Data? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return open(raw) ?? raw
    }

    // MARK: - 迁移

    /// 把 `dir` 里遗留的明文 PNG 就地重新加密。后台一次性执行：
    /// 文件名是内容哈希、读取侧明文/密文都吃，所以中途失败也不影响使用，下次启动继续。
    static func migrateLegacyImages(in dir: URL) {
        DispatchQueue.global(qos: .utility).async {
            guard key() != nil else { return }
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                guard let raw = try? Data(contentsOf: url) else { continue }
                if open(raw) != nil { continue }  // 已是密文
                guard let sealed = seal(raw) else { return }  // 密钥没了，后面也不用试
                try? sealed.write(to: url, options: .atomic)
            }
        }
    }
}
