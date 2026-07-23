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

    /// 首个可用局域网 IP（供菜单展示）；无则返回 127.0.0.1。
    static func primaryIP() -> String {
        lanIPv4().first?.ip ?? "127.0.0.1"
    }

    /// 证书下载 URL（供二维码 / 展示）。
    static var certDownloadURL: String { "http://\(magicHost)/cert" }
}
