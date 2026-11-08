import Foundation
import Network

/// 局域网模式可以监听的网卡：本机所有 up 的 IPv4 网卡（含 VPN、互联网共享的网桥 —— 由用户自己选）。
/// 见 docs/phone-transfer/TECH_DESIGN.md §3.1。
struct PhoneTransferInterface: Identifiable, Equatable {
    enum Kind: Equatable {
        case wifi, wired, other
    }

    var id: String { name }
    /// BSD 名，如 `en0`。
    let name: String
    let ip: String
    var kind: Kind = .other

    /// 菜单里显示的名字：认得出类型的用「Wi-Fi」「有线网络」，否则用 BSD 名。
    var label: String {
        switch kind {
        case .wifi: return L("phonetransfer.lan.iface.wifi \(name) \(ip)")
        case .wired: return L("phonetransfer.lan.iface.wired \(name) \(ip)")
        case .other: return "\(name) · \(ip)"
        }
    }
}

enum PhoneTransferNetwork {
    /// 枚举 up & running、非回环、非 169.254 的 IPv4 网卡，每块取第一个地址。
    /// `kinds` 来自 `NWPathMonitor`（BSD 名 → 类型），没有的按 `.other`。
    static func interfaces(kinds: [String: PhoneTransferInterface.Kind]) -> [PhoneTransferInterface] {
        var result: [PhoneTransferInterface] = []
        var seen = Set<String>()
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_RUNNING) == IFF_RUNNING,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard !seen.contains(name) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty, !ip.hasPrefix("169.254.") else { continue }
            seen.insert(name)
            result.append(PhoneTransferInterface(name: name, ip: ip, kind: kinds[name] ?? .other))
        }
        // Wi-Fi、有线排前面，其余按名字。
        func rank(_ kind: PhoneTransferInterface.Kind) -> Int {
            switch kind {
            case .wifi: return 0
            case .wired: return 1
            case .other: return 2
            }
        }
        return result.sorted { rank($0.kind) != rank($1.kind) ? rank($0.kind) < rank($1.kind) : $0.name < $1.name }
    }

    /// `NWPath` 里的网卡类型表。
    static func kinds(of path: NWPath) -> [String: PhoneTransferInterface.Kind] {
        var map: [String: PhoneTransferInterface.Kind] = [:]
        for iface in path.availableInterfaces {
            switch iface.type {
            case .wifi: map[iface.name] = .wifi
            case .wiredEthernet: map[iface.name] = .wired
            default: map[iface.name] = .other
            }
        }
        return map
    }
}
