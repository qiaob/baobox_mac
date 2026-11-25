import Foundation
import Security

/// 网络检测的设置。ipapi.is 的 key 在钥匙串，其余在 UserDefaults。见 docs/netcheck/DESIGN.md §4.3、SPEED.md §2.3。
enum NetCheckSettings {
    static let dnsProbesKey = "netcheck.dnsProbes"
    static let stunServerKey = "netcheck.stunServer"

    static let defaultDNSProbes = 10
    static let dnsProbesRange = 1...50
    /// DNS 探测（并发解析）整段最多等这么久，到点用已经回来的继续。
    static let dnsProbeDeadline: TimeInterval = 10
    static let defaultSTUNServer = "stun:stun.l.google.com:19302"

    /// 检测服务的地址（与 baobox_shared 的默认值相同；Mac 版不开放修改）。
    static let ipEndpoint = "https://api.ipapi.is/"
    static let ipv6Endpoint = "https://api6.ipify.org"
    static let dnsEndpoint = "https://bash.ws"
    static let dnsHost = "bash.ws"

    static var dnsProbes: Int {
        let value = UserDefaults.standard.object(forKey: dnsProbesKey) as? Int ?? defaultDNSProbes
        return min(max(value, dnsProbesRange.lowerBound), dnsProbesRange.upperBound)
    }

    static var stunServer: String {
        let value = (UserDefaults.standard.string(forKey: stunServerKey) ?? "").trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? defaultSTUNServer : value
    }

    // MARK: 菜单栏实时网速（docs/netcheck/SPEED.md §2.3）

    static let liveSpeedEnabledKey = "netcheck.liveSpeed.enabled"
    static let liveSpeedModeKey = "netcheck.liveSpeed.mode"

    /// 默认关：菜单栏的位置紧张，更新后不该给所有人多出一个状态项。
    static var liveSpeedEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: liveSpeedEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: liveSpeedEnabledKey) }
    }

    static var liveSpeedMode: NetSpeedDisplayMode {
        get { NetSpeedDisplayMode(rawValue: UserDefaults.standard.string(forKey: liveSpeedModeKey) ?? "") ?? .down }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: liveSpeedModeKey) }
    }
}

/// ipapi.is 的 key：存钥匙串（照 `AIKeychain` 的做法），不进 UserDefaults、不写日志。
enum NetCheckKeychain {
    private static let service = "com.baobox.app"
    private static let account = "netcheck.ipapi.apiKey"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// 空串 = 删除。返回是否成功。
    @discardableResult
    static func save(_ key: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return true }
        var attributes = baseQuery
        attributes[kSecAttrLabel as String] = "Baobox ipapi.is API Key"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
