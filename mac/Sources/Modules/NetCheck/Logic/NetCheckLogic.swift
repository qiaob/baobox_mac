import Foundation

// IP 检测的纯逻辑：解析检测服务的回包、ICE 候选、地址分类、「同一家云厂商」的判断。比对与表格在 NetCheckCompare.swift。
// 只依赖 Foundation，进 BaoboxTests。见 docs/netcheck/COMPARE.md（呈现）、docs/netcheck/DESIGN.md（请求）。

// MARK: - IP 归属

/// 一个 IP 的归属与位置。
struct NetCheckIPInfo: Equatable {
    var ip: String
    /// 自治系统号（`AS15169` 里的 15169）
    var asn: Int?
    /// 网络运营方（ASN 的 org）
    var network: String = ""
    /// 地址登记的公司
    var company: String = ""
    var city: String = ""
    var country: String = ""
    /// IANA 时区名
    var timezone: String = ""
    /// 以下四个判定带 key 的回包才有；没有就是 nil
    var datacenter: Bool?
    var vpn: Bool?
    var proxy: Bool?
    var tor: Bool?

    /// 归属后面的灰色小标签。机房：服务给了「不是机房」就信它；给了「是」或没给判定但 ASN 在内置的云厂商表里，就是机房。
    var flags: [NetCheckExitFlag] {
        var flags: [NetCheckExitFlag] = []
        if datacenter == true || (datacenter == nil && asn.flatMap(NetCheckLogic.knownHosting) != nil) {
            flags.append(.hosting)
        }
        if vpn == true { flags.append(.vpn) }
        if proxy == true { flags.append(.proxy) }
        if tor == true { flags.append(.tor) }
        return flags
    }
}

/// 一台 DNS 服务器。
struct NetCheckResolver: Equatable {
    var ip: String
    var asn: Int?
    var network: String = ""
    var city: String = ""
    var country: String = ""
}

/// bash.ws 的 DNS 检测结果。
struct NetCheckDNSResult: Equatable {
    var resolvers: [NetCheckResolver] = []
    /// 服务端报的错（「No DNS servers found. Try again...」）
    var error: String?
}

/// 归属后面的灰色小标签：只是信息，不参加比较。
enum NetCheckExitFlag: Equatable {
    case hosting, vpn, proxy, tor
}

/// 表里的五行，顺序即展示顺序。
enum NetCheckItem: String, CaseIterable, Equatable {
    case ipv4, ipv6, dns, webrtc, timezone
}

/// 一次检测拿到的全部原料。哪一项没拿到就是 `.failure`。
struct NetCheckObservations {
    var ipv4: Result<NetCheckIPInfo, NetCheckFailure>
    /// `.success(nil)` = 没有 IPv6 出口
    var ipv6: Result<NetCheckIPInfo?, NetCheckFailure>
    var dns: Result<NetCheckDNSResult, NetCheckFailure>
    var systemTimezone: String?
    /// ICE 候选原文。nil = 没测
    var webrtc: Result<[String], NetCheckFailure>?
    /// WebRTC 拿到的、和 IPv4 / IPv6 那一行都不同的地址另查的归属（地址 → 归属；查不到的不在里面）
    var webrtcLookups: [String: NetCheckIPInfo] = [:]
}

/// 一项没测出来的原因（已经是给人看的文字）。
struct NetCheckFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - ICE 候选

enum NetCheckCandidateKind: Equatable {
    case host, serverReflexive, peerReflexive, relay
}

struct NetCheckCandidate: Equatable {
    let kind: NetCheckCandidateKind
    /// IP，或浏览器混淆过的 `xxxx.local`
    let address: String
    let transport: String

    var isMDNS: Bool { address.lowercased().hasSuffix(".local") }
}

// MARK: - 解析

enum NetCheckLogic {

    /// 主要云厂商 / 机房的 ASN（与 Rust 版 `known_hosting` 同一张表）。宁缺毋滥。
    static func knownHosting(_ asn: Int) -> String? {
        switch asn {
        case 16509, 14618: return "Amazon AWS"
        case 15169, 396982: return "Google Cloud"
        case 8075: return "Microsoft Azure"
        case 31898: return "Oracle Cloud"
        case 14061: return "DigitalOcean"
        case 20473: return "Vultr"
        case 63949: return "Akamai / Linode"
        case 24940: return "Hetzner"
        case 16276: return "OVHcloud"
        case 45102: return "Alibaba Cloud"
        case 132203: return "Tencent Cloud"
        case 9009: return "M247"
        case 60068: return "CDN77 / Datacamp"
        default: return nil
        }
    }

    // MARK: JSON 小工具

    private static func object(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    /// 只认真正的布尔（JSONSerialization 把 true/false 解成 NSNumber，数字 0/1 也是 NSNumber，要区分）。
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    /// 从 `AS15169 Google LLC` 里拆出号码和名字。
    static func splitASN(_ text: String) -> (Int?, String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("AS") || text.hasPrefix("as") else { return (nil, text) }
        let rest = text.dropFirst(2)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let name = rest.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        return (Int(digits), name)
    }

    // MARK: 回包

    /// 解析 ipapi.is。认不带 key（字段在顶层、`asn` 是字符串）与带 key（`asn` / `company` / `location` 是对象）两种。
    /// 不是 JSON、没有 `ip`、保留地址（`is_bogon`）都返回 nil。
    static func parseIPAPI(_ text: String) -> NetCheckIPInfo? {
        guard let root = object(text) as? [String: Any],
              let ip = root["ip"] as? String, !ip.isEmpty else { return nil }
        if bool(root["is_bogon"]) == true { return nil }
        var info = NetCheckIPInfo(ip: ip)
        info.datacenter = bool(root["is_datacenter"])
        info.vpn = bool(root["is_vpn"])
        info.proxy = bool(root["is_proxy"])
        info.tor = bool(root["is_tor"])

        if let text = root["asn"] as? String {
            (info.asn, info.network) = splitASN(text)
        } else if let asn = root["asn"] as? [String: Any] {
            info.asn = int(asn["asn"])
            info.network = string(asn["org"])
        }
        if let text = root["company"] as? String {
            info.company = text
        } else if let company = root["company"] as? [String: Any] {
            info.company = string(company["name"])
        }
        let place = root["location"] as? [String: Any] ?? root
        info.city = string(place["city"])
        info.country = string(place["country"])
        info.timezone = string(place["timezone"])
        return info
    }

    /// 解析 `https://bash.ws/dnsleak/test/<id>?json=2`：一个数组，每条带 `type`。只收 `dns`（服务器）与 `error`；
    /// `ip`（bash.ws 看到的客户端）和 `conclusion`（它自己的结论）不用。
    static func parseBashWS(_ text: String) -> NetCheckDNSResult? {
        guard let records = object(text) as? [Any] else { return nil }
        var result = NetCheckDNSResult()
        for case let record as [String: Any] in records {
            switch string(record["type"]) {
            case "dns":
                let (asn, fromASN) = splitASN(string(record["asn"]))
                let org = string(record["org"])
                result.resolvers.append(NetCheckResolver(ip: string(record["ip"]), asn: asn,
                                                         network: org.isEmpty ? fromASN : org,
                                                         city: string(record["city_name"]),
                                                         country: string(record["country_name"])))
            case "error":
                let words = string(record["text"])
                result.error = words.isEmpty ? "bash.ws error" : words
            default:
                continue
            }
        }
        return result
    }

    /// 解析一条 ICE 候选：`candidate:842163049 1 udp 1677729535 203.0.113.7 54321 typ srflx …`。
    /// 前面带不带 `a=` 都认；字段不够、没有 `typ`、类型认不出返回 nil。
    static func parseCandidate(_ line: String) -> NetCheckCandidate? {
        var line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("a=") { line.removeFirst(2) }
        guard line.hasPrefix("candidate:") else { return nil }
        let fields = line.dropFirst("candidate:".count).split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 8, fields[6] == "typ" else { return nil }
        let kind: NetCheckCandidateKind
        switch fields[7] {
        case "host": kind = .host
        case "srflx": kind = .serverReflexive
        case "prflx": kind = .peerReflexive
        case "relay": kind = .relay
        default: return nil
        }
        var address = String(fields[4])
        address = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return NetCheckCandidate(kind: kind, address: address, transport: fields[2].lowercased())
    }

    // MARK: 地址

    /// IPv4 的四个字节。
    static func ipv4Bytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt8(part) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    /// IPv6 的十六个字节（用系统的 inet_pton，各种写法都认）。
    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        guard text.contains(":") else { return nil }
        var address = in6_addr()
        let ok = text.withCString { inet_pton(AF_INET6, $0, &address) } == 1
        guard ok else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// 是不是公网地址。认不出的（mDNS 名字、乱码）不算。
    static func isPublic(_ text: String) -> Bool {
        if let b = ipv4Bytes(text) {
            let isPrivate = b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            let isLoopback = b[0] == 127
            let isLinkLocal = b[0] == 169 && b[1] == 254
            let isUnspecified = b == [0, 0, 0, 0]
            let isDocumentation = (b[0] == 192 && b[1] == 0 && b[2] == 2)
                || (b[0] == 198 && b[1] == 51 && b[2] == 100)
                || (b[0] == 203 && b[1] == 0 && b[2] == 113)
            // 100.64.0.0/10：运营商级 NAT，Tailscale 的地址也在这里
            let isShared = b[0] == 100 && (64...127).contains(b[1])
            return !(isPrivate || isLoopback || isLinkLocal || isUnspecified || isDocumentation || isShared)
        }
        if let b = ipv6Bytes(text) {
            let isUnspecified = b.allSatisfy { $0 == 0 }
            let isLoopback = b.dropLast().allSatisfy { $0 == 0 } && b[15] == 1
            let isUniqueLocal = (b[0] & 0xfe) == 0xfc
            let isLinkLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0x80
            return !(isUnspecified || isLoopback || isUniqueLocal || isLinkLocal)
        }
        return false
    }

    /// 两个地址是不是同一个（IPv6 的不同写法算同一个）。
    static func sameAddress(_ a: String, _ b: String) -> Bool {
        if let x = ipv4Bytes(a), let y = ipv4Bytes(b) { return x == y }
        if let x = ipv6Bytes(a), let y = ipv6Bytes(b) { return x == y }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// IPv6 探测失败时是「没有 IPv6」还是「没测出来」：连接立刻失败（没有 IPv6 路由、找不到 / 连不上这个只有 AAAA 记录的服务）
    /// 算没有；超时、TLS 出错、服务回错这些算没测出来。没有 IPv6 的 Mac 上 URLSession 0.02 秒就报 -1009
    /// （notConnectedToInternet，2026-11-25 实测），所以它也算「没有」。
    static func meansNoIPv6(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// 两个 ASN 是不是同一家：号码相同，或者在云厂商表里是同一家
    /// （Google 的 15169 / 396982、AWS 的 16509 / 14618 常常一个出 IPv4、一个出 IPv6）。
    static func sameNetwork(_ a: Int, _ b: Int) -> Bool {
        if a == b { return true }
        guard let x = knownHosting(a), let y = knownHosting(b) else { return false }
        return x == y
    }
}

// MARK: - 并发、有总期限

/// 一批会阻塞的活（系统解析器）并发跑，整批最多等 `deadline` 秒：都做完或到点就返回，没做完的留在后台自己结束、不等。
/// 不在主线程等。返回按时做完了几个。
enum NetCheckParallel {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Int, Never>?
        private var done = 0
        private let total: Int

        init(_ continuation: CheckedContinuation<Int, Never>, total: Int) {
            self.continuation = continuation
            self.total = total
        }

        func finishedOne() {
            lock.lock()
            done += 1
            let resume = done >= total ? continuation : nil
            if resume != nil { continuation = nil }
            let count = done
            lock.unlock()
            resume?.resume(returning: count)
        }

        func deadlinePassed() {
            lock.lock()
            let resume = continuation
            continuation = nil
            let count = done
            lock.unlock()
            resume?.resume(returning: count)
        }
    }

    static func run(_ jobs: [@Sendable () -> Void], deadline: TimeInterval) async -> Int {
        guard !jobs.isEmpty else { return 0 }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let state = State(continuation, total: jobs.count)
            for job in jobs {
                DispatchQueue.global(qos: .utility).async {
                    job()
                    state.finishedOne()
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, deadline)) {
                state.deadlinePassed()
            }
        }
    }
}
