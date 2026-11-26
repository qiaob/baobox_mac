import Foundation
import SystemConfiguration

/// 读取本机网络环境快照：主局域网网卡、系统代理、活跃 VPN/TUN 隧道、系统 DNS 服务器。
/// 纯本地只读（不发任何网络请求），在后台队列调用，避免阻塞主线程。
enum NetCheckEnvironmentReader {

    /// 读取完整的本机网络环境快照。
    static func read() -> NetCheckEnvironment {
        let raw = interfaceAddresses()
        let lan = NetCheckEnvironmentLogic.pickPrimaryLAN(raw, outboundIP: outboundIPv4())
        let tunnels = NetCheckEnvironmentLogic.filterTunnels(raw)
        let proxy = readProxies()
        let dns = readDNSServers()
        return NetCheckEnvironment(lan: lan, proxy: proxy, tunnels: tunnels, dnsServers: dns)
    }

    /// 仅读取主局域网网卡与 IPv4（供菜单栏网速小菜单轻量复用）。
    static func primaryLAN() -> NetCheckLAN? {
        NetCheckEnvironmentLogic.pickPrimaryLAN(interfaceAddresses(), outboundIP: outboundIPv4())
    }

    // MARK: SystemConfiguration

    private static func readProxies() -> NetCheckLocalProxy {
        guard let dict = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return NetCheckLocalProxy()
        }
        return NetCheckEnvironmentLogic.parseProxies(dict)
    }

    private static func readDNSServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "com.baobox.netcheck" as CFString, nil, nil) else {
            return []
        }
        if let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
            let servers = NetCheckEnvironmentLogic.parseDNSServers(global)
            if !servers.isEmpty { return servers }
        }
        // 兜底：部分网络配置下 Global/DNS 为空，查主服务的 DNS
        if let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let service = ipv4["PrimaryService"] as? String, !service.isEmpty,
           let svcDNS = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/DNS" as CFString) as? [String: Any] {
            return NetCheckEnvironmentLogic.parseDNSServers(svcDNS)
        }
        return []
    }

    // MARK: getifaddrs & 路由表

    private static func interfaceAddresses() -> [NetCheckEnvironmentLogic.RawInterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var result: [NetCheckEnvironmentLogic.RawInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            guard let addr = ptr.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let saLen = socklen_t(addr.pointee.sa_len)
            guard getnameinfo(addr, saLen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let ip = String(cString: host)
            guard !ip.isEmpty else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            result.append(NetCheckEnvironmentLogic.RawInterfaceAddress(
                name: String(cString: ptr.pointee.ifa_name),
                address: ip,
                isIPv4: family == AF_INET,
                isUp: (flags & IFF_UP) == IFF_UP,
                isRunning: (flags & IFF_RUNNING) == IFF_RUNNING,
                isLoopback: (flags & IFF_LOOPBACK) != 0
            ))
        }
        return result
    }

    /// 默认路由的本地出口 IPv4：向公网地址「连接」UDP socket（不实际发包，仅让内核查路由表选出口），再 getsockname。
    private static func outboundIPv4() -> String? {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(53).bigEndian
        inet_pton(AF_INET, "8.8.8.8", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(sock, sa, &len)
            }
        }
        guard got == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }
}
