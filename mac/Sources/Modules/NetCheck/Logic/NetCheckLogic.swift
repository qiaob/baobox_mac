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
    /// 回包给的两位国家代码（带 key 的 ipapi.is 才有）；没有是空串
    var countryCode: String = ""
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
    var country: String = ""
    /// bash.ws 给的两位国家代码（小写，如 `us`）；没有是空串
    var countryCode: String = ""
}

/// bash.ws 的 DNS 检测结果。
struct NetCheckDNSResult: Equatable {
    var resolvers: [NetCheckResolver] = []
    /// 服务端报的错（「No DNS servers found. Try again...」）
    var error: String?
    /// 系统解析器返回了 Fake-IP（198.18.0.0/15），且没有看到真实上游解析器
    var fakeIPDetected: Bool = false
}

/// 归属后面的灰色小标签：只是信息，不参加比较。
enum NetCheckExitFlag: Equatable {
    case hosting, vpn, proxy, tor
    /// 公共 DNS（`NetCheckLogic.publicDNS`）：它的国家不参加比较
    case publicDNS
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

    /// 全球任播的公共 DNS（解析器**出口**的 ASN → 名字）。它们的服务器在地址库里登记的是运营方的国家，不是服务器真实所在，
    /// 直连、没有任何代理时也会被标成别的国家，所以这些 DNS 服务器的国家不参加比较（docs/netcheck/COMPARE.md §2）。
    /// 认的是出口 ASN：bash.ws 报的是解析器向外查询的地址，不是 8.8.8.8 这种服务地址。2026-11-25 实测（对各家服务地址发
    /// `o-o.myaddr.l.google.com` TXT 拿出口地址，再查起源 ASN）：Google 15169、Cloudflare 13335、OpenDNS 36692，
    /// Quad9 出口在 PCH 的 AS42 / AS715（19281 是它的服务地址）。
    /// 不收 NextDNS、AdGuard、Control D：出口在通用机房（AS57695 / 23961、AS60068、AS212238），很多 VPN 也用，靠 ASN 认不出。
    /// 运营商自己的 DNS、云厂商的 DNS 也不收（「DNS 由国内运营商在答」正是要标出来的）。
    static func publicDNS(_ asn: Int) -> String? {
        switch asn {
        case 15169: return "Google Public DNS"
        case 13335: return "Cloudflare"
        case 36692: return "OpenDNS / Cisco"
        case 19281, 42, 715: return "Quad9"
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
        info.countryCode = string(place["country_code"])
        info.timezone = string(place["timezone"])
        return info
    }

    /// 解析 `https://bash.ws/dnsleak/test/<id>?json=2`：一个数组，每条带 `type`。只收 `dns`（服务器）与 `error`；
    /// `ip`（bash.ws 看到的客户端）和 `conclusion`（它自己的结论）不用。每条有 `country`（小写两位代码）与
    /// `country_name`（`USA` 这种写法，2026-11-25 实测）。
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
                                                         country: string(record["country_name"]),
                                                         countryCode: string(record["country"])))
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
        return NetCheckCandidate(kind: kind, address: address)
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

    /// 是否是代理常用的 Fake-IP 网段（RFC 2544 基准测试段 `198.18.0.0/15`，Clash / Surge / sing-box 默认用它）。
    /// 也认 IPv4-mapped IPv6（`::ffff:198.18.x.x`）。
    static func isFakeIP(_ text: String) -> Bool {
        if let b = ipv4Bytes(text) {
            return b[0] == 198 && (b[1] == 18 || b[1] == 19)
        }
        if let b = ipv6Bytes(text), let mapped = ipv4MappedBytes(b) {
            return mapped[0] == 198 && (mapped[1] == 18 || mapped[1] == 19)
        }
        return false
    }

    /// `::ffff:0:0/96`（IPv4 映射的 IPv6 地址）抽出后 4 字节。
    private static func ipv4MappedBytes(_ b: [UInt8]) -> [UInt8]? {
        guard b.count == 16,
              b[0..<10].allSatisfy({ $0 == 0 }),
              b[10] == 0xff, b[11] == 0xff else { return nil }
        return Array(b[12..<16])
    }

    private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        let isPrivate = b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
        let isLoopback = b[0] == 127
        let isLinkLocal = b[0] == 169 && b[1] == 254
        // 0.0.0.0/8：本网络 / 未指定
        let isThisNetwork = b[0] == 0
        let isDocumentation = (b[0] == 192 && b[1] == 0 && b[2] == 2)
            || (b[0] == 198 && b[1] == 51 && b[2] == 100)
            || (b[0] == 203 && b[1] == 0 && b[2] == 113)
        // 100.64.0.0/10：运营商级 NAT，Tailscale 的地址也在这里
        let isShared = b[0] == 100 && (64...127).contains(b[1])
        // 198.18.0.0/15：RFC 2544 基准测试段，代理 Fake-IP 默认用它
        let isBenchmark = b[0] == 198 && (b[1] == 18 || b[1] == 19)
        // 224.0.0.0/4 多播 + 240.0.0.0/4 保留与广播
        let isMulticastOrReserved = b[0] >= 224
        return !(isPrivate || isLoopback || isLinkLocal || isThisNetwork || isDocumentation
                 || isShared || isBenchmark || isMulticastOrReserved)
    }

    /// 是不是公网地址。认不出的（mDNS 名字、乱码）不算。
    static func isPublic(_ text: String) -> Bool {
        if let b = ipv4Bytes(text) {
            return isPublicIPv4(b)
        }
        if let b = ipv6Bytes(text) {
            if let mapped = ipv4MappedBytes(b) {
                return isPublicIPv4(mapped)
            }
            let isUnspecified = b.allSatisfy { $0 == 0 }
            let isLoopback = b.dropLast().allSatisfy { $0 == 0 } && b[15] == 1
            let isUniqueLocal = (b[0] & 0xfe) == 0xfc
            let isLinkLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0x80
            let isMulticast = b[0] == 0xff
            let isDocumentation = b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8
            return !(isUnspecified || isLoopback || isUniqueLocal || isLinkLocal || isMulticast || isDocumentation)
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
    /// （notConnectedToInternet，2026-11-25 实测），所以它也算「没有」。走系统代理时代理 CONNECT 失败
    /// （`kCFErrorDomainCFNetwork` 310，直接给或者包在 `NSUnderlyingErrorKey` 里）也算没有：开着 Clash / Surge 且关了
    /// IPv6 时会一直落在这里，对这些用户「这条路上没有 IPv6」就是实情。
    static func meansNoIPv6(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                break
            }
        }
        return isProxyConnectFailure(error as NSError)
    }

    /// `kCFErrorDomainCFNetwork` 310（kCFErrorHTTPSProxyConnectionFailure），本身或往下几层的 underlying error。
    private static func isProxyConnectFailure(_ error: NSError, depth: Int = 0) -> Bool {
        if error.domain == "kCFErrorDomainCFNetwork", error.code == 310 { return true }
        guard depth < 4, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isProxyConnectFailure(underlying, depth: depth + 1)
    }

    /// IPv6 那一行的结果：`probe` 是引擎的探测，`ipv4Measured` 是 IPv4 那一行测出来了没有。
    /// IPv4 自己都没测出来（整机断网、DNS 全坏）时，IPv6 的失败一律算「没测出来」，不写「没有」。
    static func resolveIPv6(_ probe: NetCheckIPv6Probe, ipv4Measured: Bool) -> Result<NetCheckIPInfo?, NetCheckFailure> {
        switch probe {
        case .found(let info): return .success(info)
        case .failed(let why): return .failure(why)
        case .absent(let why): return ipv4Measured ? .success(nil) : .failure(why)
        }
    }

}

// MARK: - IPv6 探测

/// 引擎对 IPv6 的探测结果，最终是「有 / 没有 / 没测出来」要看 IPv4 那一行（`NetCheckLogic.resolveIPv6`）。
enum NetCheckIPv6Probe {
    case found(NetCheckIPInfo)
    /// 连接立刻失败（`meansNoIPv6`）；带上万一要写成「没测出来」时的原因
    case absent(NetCheckFailure)
    case failed(NetCheckFailure)
}

// MARK: - 并发、有总期限

/// 一批会阻塞的活（系统解析器）在专用队列上并发跑（最多 8 个同时跑，不往全局队列上堆），整批最多等 `deadline` 秒：
/// 都做完或到点就返回，没做完的留在后台自己结束、不等。期限定时器在自己的串行队列上，全局线程池被占满时也排得上。
/// 上一批还有没返回的时候不再发新的（`.busy`）：DNS 卡住时连点两次「立即检测」，不至于把线程越堆越多。不在主线程等。
enum NetCheckParallel {
    enum Outcome: Equatable {
        /// 按时做完了几个
        case finished(Int)
        /// 上一批还有没返回的，这一批没发
        case busy
    }

    static let maxConcurrent = 8

    private static let workQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.baobox.netcheck.probes"
        queue.maxConcurrentOperationCount = maxConcurrent
        queue.qualityOfService = .utility
        return queue
    }()

    private static let timerQueue = DispatchQueue(label: "com.baobox.netcheck.probes.deadline")

    private static let lock = NSLock()
    private static var outstanding = 0

    /// 上一批还有没返回的活。
    static var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outstanding > 0
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?
        private var done = 0
        private let total: Int

        init(_ continuation: CheckedContinuation<Outcome, Never>, total: Int) {
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
            resume?.resume(returning: .finished(count))
        }

        func deadlinePassed() {
            lock.lock()
            let resume = continuation
            continuation = nil
            let count = done
            lock.unlock()
            resume?.resume(returning: .finished(count))
        }
    }

    /// 占位：上一批都返回了才占得到（不在 async 函数里直接拿锁）。
    private static func reserve(_ count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard outstanding == 0 else { return false }
        outstanding = count
        return true
    }

    private static func release() {
        lock.lock()
        outstanding -= 1
        lock.unlock()
    }

    static func run(_ jobs: [@Sendable () -> Void], deadline: TimeInterval) async -> Outcome {
        guard !jobs.isEmpty else { return .finished(0) }
        guard reserve(jobs.count) else { return .busy }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let state = State(continuation, total: jobs.count)
            for job in jobs {
                workQueue.addOperation {
                    job()
                    release()
                    state.finishedOne()
                }
            }
            timerQueue.asyncAfter(deadline: .now() + max(0, deadline)) {
                state.deadlinePassed()
            }
        }
    }
}
