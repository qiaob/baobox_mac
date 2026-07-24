import Foundation

/// 局域网接口枚举与 magic 域名常量。
enum NetworkInterfaces {

    /// magic 域名：被代理设备访问 `http://baobox.proxy/` 可下载 CA 证书（由 ProxyConnection 本地应答）。
    static let magicHost = "baobox.proxy"

    /// 一个可用局域网接口。
    struct Interface: Identifiable {
        var id: String { name + ip }
        let name: String   // 如 "en0"
        let ip: String     // 如 "192.168.1.23"
    }

    /// 枚举 `AF_INET`、非回环、up & running 的接口，返回 [(iface, ip)]。
    /// 过滤掉链路本地 169.254.x（自动私有地址，通常不可用）。
    static func lanIPv4() -> [Interface] {
        var result: [Interface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_RUNNING) == IFF_RUNNING,
                  (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            // 排除虚拟 / 非局域网接口：VPN(utun/ppp/tun/tap)、网桥(bridge，Docker/虚拟机/热点共享)、
            // AirDrop(awdl/llw)、个人热点(ap)、虚拟机(vmnet) 等——它们的 IP 手机连不上，不能用作代理地址。
            // 这些接口名（如 bridge100）字母序会排在 en0 前面，若不排除，取「排序后第一个」会选错网卡。
            let virtualPrefixes = ["utun", "bridge", "awdl", "llw", "ap", "vmnet", "gif", "stf", "tap", "tun", "ppp"]
            if virtualPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let saLen = socklen_t(addr.pointee.sa_len)
            guard getnameinfo(addr, saLen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let ip = String(cString: host)
            guard !ip.isEmpty, !ip.hasPrefix("169.254.") else { continue }
            result.append(Interface(name: name, ip: ip))
        }
        // en0 / en1 之类物理网卡排前面（简单按名称排序即可让 en0 靠前）。
        return result.sorted { $0.name < $1.name }
    }

    /// 主局域网 IP（供菜单 / 二维码展示）。多网卡时优先取「默认路由的出口 IP」——即真正上网那块网卡；
    /// 失败或出口非标准私有局域网段（如 VPN CGNAT 100.x）时，回退到排除虚拟接口后的第一个物理网卡。
    static func primaryIP() -> String {
        if let out = outboundIP(), isPrivateLAN(out) { return out }
        return lanIPv4().first?.ip ?? "127.0.0.1"
    }

    /// 是否 RFC1918 私有局域网地址（手机同 Wi-Fi 能直连的段）。
    private static func isPrivateLAN(_ ip: String) -> Bool {
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return true }
        if ip.hasPrefix("172.") {
            let parts = ip.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]) { return (16...31).contains(second) }
        }
        return false
    }

    /// 默认路由的本地出口 IP：向公网地址「连接」一个 UDP socket（不实际发包，仅让内核按路由表选出口），
    /// 再 `getsockname` 读回本地地址。多网卡 / 多接口时这才是真正对外那块网卡的 IP。失败返回 nil。
    private static func outboundIP() -> String? {
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

    /// 证书下载 URL（保留，供直链 / 展示）——扫码下载 CA 文件。
    static var certDownloadURL: String { "http://\(magicHost)/cert" }

    /// 配置页 URL（供二维码 / 展示）——手机**未设代理**时也能同 Wi-Fi 直连打开（装证书 / 配代理，§16.2）。
    /// 用本机局域网 IP:端口直连；不能用 magic 域名 `baobox.proxy`（那要先设代理才能解析，首次配置时打不开）。
    static var landingPageURL: String { "http://\(primaryIP()):\(NetCaptureEnv.port)/" }
}
