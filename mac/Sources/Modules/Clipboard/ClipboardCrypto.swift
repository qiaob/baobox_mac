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
/// 兼容策略：读取时先按密文解，解不开就当作明文原样返回；写入时开关关着、或 Keychain
/// 不可用，都降级写明文。**宁可明文也不能丢数据** —— 加密是否生效在设置页有状态提示。
enum ClipboardCrypto {
    private static let keychainService = "com.baobox.app"
    private static let keychainAccount = "clipboard.historyKey"
    private static let keyByteCount = 32

    /// 进程内缓存，避免每次写盘都查一遍 Keychain。可能被后台转换线程访问，用锁保护。
    private static var cachedKey: SymmetricKey?
    private static let lock = NSLock()

    /// 磁盘文件的格式转换队列。串行：连点开关时后入队的那次决定最终状态，
    /// 不会有两个方向的任务交叉写同一批文件。
    private static let conversionQueue = DispatchQueue(label: "com.baobox.clipboard.crypto", qos: .utility)

    static let enabledKey = "clipboard.encryptStorage"

    /// 用户是否开启落盘加密。出厂开启 —— 未设置过时 `object(forKey:)` 为 nil，取默认 true。
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Keychain 是否可用。开关开着却返回 false = 降级成了明文，设置页要提示。
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

    /// 按当前开关写盘：开着且拿得到密钥就写密文，否则写明文。返回是否写成功。
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let payload = isEnabled ? (seal(data) ?? data) : data
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

    // MARK: - 格式转换

    /// 把 `dir` 里的图片文件就地转成当前开关要求的格式（开 → 补加密，关 → 解回明文）。
    /// 后台串行执行：文件名是内容哈希不变、读取侧明文/密文都吃，所以中途中断也不影响
    /// 使用，下次启动或下次切开关时接着来。
    static func syncStoredImages(in dir: URL) {
        conversionQueue.async {
            // 在任务真正开始时才读开关：连点两下时只有最后一次的方向算数。
            let shouldEncrypt = isEnabled
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                guard let raw = try? Data(contentsOf: url) else { continue }
                let decrypted = open(raw)  // nil = 这个文件本来就是明文
                if shouldEncrypt {
                    if decrypted != nil { continue }              // 已经是密文
                    guard let sealed = seal(raw) else { return }  // 拿不到密钥，后面也不用试
                    try? sealed.write(to: url, options: .atomic)
                } else {
                    guard let plain = decrypted else { continue } // 已经是明文
                    try? plain.write(to: url, options: .atomic)
                }
            }
        }
    }
}
