import Foundation

// 本机网络环境摘要的纯逻辑：解析系统代理字典、系统 DNS 字典、筛选活跃隧道与主局域网网卡。
// 只依赖 Foundation，进 BaoboxTests。纯本地只读，不发任何网络请求。

/// 本机主局域网网卡与 IPv4。
struct NetCheckLAN: Equatable, Sendable {
    let interface: String
    let ip: String
}

/// 系统代理设置（HTTP / HTTPS / SOCKS / PAC）。
struct NetCheckLocalProxy: Equatable, Sendable {
    var http: String?
    var https: String?
    var socks: String?
    var pac: String?

    var isEmpty: Bool {
        http == nil && https == nil && socks == nil && pac == nil
    }

    /// 供展示的紧凑条目：HTTP 与 HTTPS 指向同一地址时合并为 `HTTP(S) …`。
    var entries: [String] {
        var result: [String] = []
        if let http, let https, http == https {
            result.append("HTTP(S) \(http)")
        } else {
            if let http { result.append("HTTP \(http)") }
            if let https { result.append("HTTPS \(https)") }
        }
        if let socks { result.append("SOCKS \(socks)") }
        if let pac {
            if let host = URL(string: pac)?.host, !host.isEmpty {
                result.append("PAC (\(host))")
            } else {
                result.append("PAC")
            }
        }
        return result
    }
}

/// 一条活跃的 VPN / TUN 隧道接口（排除系统自带只有 link-local 地址的空 utun）。
struct NetCheckTunnel: Equatable, Sendable {
    let interface: String
    /// 非链路本地地址，IPv4 排在前面。
    let addresses: [String]

    var isFakeIP: Bool {
        addresses.contains(where: NetCheckLogic.isFakeIP)
    }

    /// 例如 `utun4 (198.18.0.1)`。
    var label: String {
        guard let first = addresses.first else { return interface }
        return "\(interface) (\(first))"
    }
}

/// 一次采集到的本机网络环境快照。
struct NetCheckEnvironment: Equatable, Sendable {
    var lan: NetCheckLAN?
    var proxy: NetCheckLocalProxy = NetCheckLocalProxy()
    var tunnels: [NetCheckTunnel] = []
    var dnsServers: [String] = []
}

enum NetCheckEnvironmentLogic {

    /// 从 `getifaddrs` 抽出来的一条接口地址（剥离 C 结构体，便于纯逻辑测试）。
    struct RawInterfaceAddress: Equatable, Sendable {
        let name: String
        let address: String
        let isIPv4: Bool
        let isUp: Bool
        let isRunning: Bool
        let isLoopback: Bool
    }

    /// 解析 `SCDynamicStoreCopyProxies` 返回的字典。字段缺失或类型不符时安全跳过。
    static func parseProxies(_ dict: [String: Any]) -> NetCheckLocalProxy {
        var proxy = NetCheckLocalProxy()
        if enabled(dict["HTTPEnable"]) {
            proxy.http = endpoint(host: dict["HTTPProxy"], port: dict["HTTPPort"])
        }
        if enabled(dict["HTTPSEnable"]) {
            proxy.https = endpoint(host: dict["HTTPSProxy"], port: dict["HTTPSPort"])
        }
        if enabled(dict["SOCKSEnable"]) {
            proxy.socks = endpoint(host: dict["SOCKSProxy"], port: dict["SOCKSPort"])
        }
        if enabled(dict["ProxyAutoConfigEnable"]),
           let raw = dict["ProxyAutoConfigURLString"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { proxy.pac = trimmed }
        }
        return proxy
    }

    /// 解析 `State:/Network/Global/DNS`（或服务级 DNS）字典里的 `ServerAddresses`。
    static func parseDNSServers(_ dict: [String: Any]) -> [String] {
        guard let raw = dict["ServerAddresses"] as? [Any] else { return [] }
        var seen: Set<String> = []
        var result: [String] = []
        for entry in raw {
            guard let text = entry as? String else { continue }
            let ip = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty, seen.insert(ip).inserted else { continue }
            result.append(ip)
        }
        return result
    }

    /// 隧道接口名（VPN / Clash TUN / Tailscale / WireGuard 等）。
    static func isTunnelInterface(_ name: String) -> Bool {
        for prefix in ["utun", "ipsec", "ppp", "tun", "tap"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            return !rest.isEmpty && rest.allSatisfy { $0.isASCII && $0.isNumber }
        }
        return false
    }

    /// 链路本地 / 回环 / 未指定地址：系统自带的空闲 `utun0–utun3` 通常只有 `fe80::` 链路本地地址，不算活跃 VPN 隧道。
    static func isLinkLocalOrLoopback(_ address: String) -> Bool {
        if let b = NetCheckLogic.ipv4Bytes(address) {
            return b[0] == 127 || b[0] == 0 || (b[0] == 169 && b[1] == 254)
        }
        if let b = NetCheckLogic.ipv6Bytes(address) {
            let isUnspecified = b.allSatisfy { $0 == 0 }
            let isLoopback = b.dropLast().allSatisfy { $0 == 0 } && b[15] == 1
            let isLinkLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0x80
            return isUnspecified || isLoopback || isLinkLocal
        }
        return true
    }

    /// 筛选活跃隧道接口：必须 UP & RUNNING、非回环、并且带有至少一个非链路本地地址。
    static func filterTunnels(_ raw: [RawInterfaceAddress]) -> [NetCheckTunnel] {
        var byName: [String: (v4: [String], v6: [String])] = [:]
        for item in raw {
            guard item.isUp, item.isRunning, !item.isLoopback, isTunnelInterface(item.name) else { continue }
            let ip = stripScopeID(item.address)
            guard !ip.isEmpty, !isLinkLocalOrLoopback(ip) else { continue }
            var bucket = byName[item.name] ?? ([], [])
            if item.isIPv4 {
                if !bucket.v4.contains(ip) { bucket.v4.append(ip) }
            } else {
                if !bucket.v6.contains(ip) { bucket.v6.append(ip) }
            }
            byName[item.name] = bucket
        }
        return byName.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            guard let bucket = byName[name] else { return nil }
            let addresses = bucket.v4 + bucket.v6
            guard !addresses.isEmpty else { return nil }
            return NetCheckTunnel(interface: name, addresses: addresses)
        }
    }

    /// 选出主局域网接口和 IPv4：优先匹配默认路由出口 IP（`outboundIP`），否则排除虚拟网卡后取名称最靠前的（如 `en0`）。
    static func pickPrimaryLAN(_ raw: [RawInterfaceAddress], outboundIP: String?) -> NetCheckLAN? {
        let excludedPrefixes = ["utun", "bridge", "awdl", "llw", "ap", "vmnet", "vmenet",
                                "gif", "stf", "tap", "tun", "ppp", "anpi", "ipsec", "nan"]
        var candidates: [NetCheckLAN] = []
        var seen: Set<String> = []
        for item in raw {
            guard item.isIPv4, item.isUp, item.isRunning, !item.isLoopback else { continue }
            guard !excludedPrefixes.contains(where: { item.name.hasPrefix($0) }) else { continue }
            let ip = item.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty, !isLinkLocalOrLoopback(ip) else { continue }
            let key = "\(item.name)|\(ip)"
            guard seen.insert(key).inserted else { continue }
            candidates.append(NetCheckLAN(interface: item.name, ip: ip))
        }
        candidates.sort { $0.interface.localizedStandardCompare($1.interface) == .orderedAscending }
        if let outboundIP, let matched = candidates.first(where: { $0.ip == outboundIP }) {
            return matched
        }
        return candidates.first
    }

    /// 去掉 `getnameinfo` 给 IPv6 链路地址附带的 `%utun0` 作用域后缀。
    static func stripScopeID(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percent = trimmed.firstIndex(of: "%") else { return trimmed }
        return String(trimmed[..<percent])
    }

    // MARK: 辅助

    private static func enabled(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return number.intValue != 0
    }

    private static func endpoint(host: Any?, port: Any?) -> String? {
        guard let rawHost = host as? String else { return nil }
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let number = port as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue > 0 {
            return "\(formattedHost):\(number.intValue)"
        }
        return formattedHost
    }
}
