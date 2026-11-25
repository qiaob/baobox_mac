import Foundation

// 网络泄露检测的纯逻辑：解析检测服务的回包、判定五项、收成两个问题的总结。
// 只依赖 Foundation，进 BaoboxTests。规格与 baobox_shared 的 baobox-core/src/netcheck.rs 相同，
// 改判定时两边一起改；这里产出结构化的原因（NetCheckReason），文案在 NetCheckText。
// 见 docs/netcheck/DESIGN.md。

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

    /// 「城市, 国家」，两样都没有时 nil。
    var place: String? {
        let parts = [city, country].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// 给人看的一行：`34.3.107.77 · Google LLC · AS15169 · The Dalles, United States`。
    var describe: String {
        var parts = [ip]
        let owner = network.isEmpty ? company : network
        if !owner.isEmpty { parts.append(owner) }
        if let asn { parts.append("AS\(asn)") }
        if let place { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    /// 是不是机房 IP。返回 `.some(名字)`：名字为 nil 表示服务判定是机房但不知道是谁家。
    /// 服务给了「不是机房」就信它；没给判定就查内置的云厂商表。
    var hosting: String?? {
        if datacenter == false { return nil }
        if let asn, let name = NetCheckLogic.knownHosting(asn) { return .some(name) }
        if datacenter == true {
            let owner = network.isEmpty ? company : network
            return .some(owner.isEmpty ? nil : owner)
        }
        return nil
    }
}

/// 一台 DNS 服务器（或 bash.ws 看到的客户端）。
struct NetCheckResolver: Equatable {
    var ip: String
    var asn: Int?
    var network: String = ""
    var city: String = ""
    var country: String = ""

    var describe: String {
        var parts = [ip]
        if !network.isEmpty { parts.append(network) }
        if let asn { parts.append("AS\(asn)") }
        if !country.isEmpty { parts.append(country) }
        return parts.joined(separator: " · ")
    }
}

/// bash.ws 的 DNS 泄露检测结果。
struct NetCheckDNSResult: Equatable {
    var clients: [NetCheckResolver] = []
    var resolvers: [NetCheckResolver] = []
    /// bash.ws 自己的结论文字
    var conclusion: String?
    /// 服务端报的错（「No DNS servers found. Try again...」）
    var error: String?
}

/// 用户声明的「真实网络」：不开 VPN 时出口所在的 ASN。
struct NetCheckRealNetworks: Equatable {
    private(set) var asns: [Int] = []

    /// 逗号 / 空白分隔，`AS4657` 与 `4657` 都认，认不出的跳过。
    init(parsing text: String) {
        let separators = CharacterSet(charactersIn: ",，").union(.whitespacesAndNewlines)
        asns = text.components(separatedBy: separators).compactMap { part in
            var digits = part.trimmingCharacters(in: .whitespaces)
            if digits.hasPrefix("AS") || digits.hasPrefix("as") { digits.removeFirst(2) }
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII) else { return nil }
            return Int(digits)
        }
    }

    init() {}

    var isEmpty: Bool { asns.isEmpty }

    func contains(_ asn: Int?) -> Bool {
        guard let asn else { return false }
        return asns.contains(asn)
    }
}

// MARK: - 结论

enum NetCheckVerdict: Equatable {
    case ok
    /// 不算泄露，但值得知道
    case notice
    case leak
    /// 测不出
    case unknown
}

/// 五项检测，顺序即展示顺序。
enum NetCheckItem: String, CaseIterable, Equatable {
    case exit, ipv6, dns, webrtc, timezone
}

/// 出口那一项的标记。
enum NetCheckExitFlag: Equatable {
    /// 机房 IP；名字 nil = 不知道是谁家
    case hosting(String?)
    case vpn, proxy, tor
}

/// 每一项结论的原因（展示层据此出文案）。
enum NetCheckReason: Equatable {
    /// 没测出来，带原因
    case failed(String)

    case exitIsReal(String)
    case exitFlagged(String, [NetCheckExitFlag])
    case exitClean(String)

    case noIPv6
    case ipv6IsReal(String)
    case ipv6Differs(String)
    case ipv6Matches(String)

    case dnsServiceError(String)
    case dnsNoResolvers
    case dnsLeak([String])
    /// 没声明真实网络：判不出
    case dnsUndeclared(count: Int, owners: [String])
    case dnsClean(count: Int, owners: [String])

    case webrtcCannotCompare([String])
    case webrtcLeak([String])
    case webrtcLocal([String])
    case webrtcNothing
    case webrtcMatches

    case timezoneUnavailable
    case exitTimezoneUnknown
    case timezoneMatch(String)
    case timezoneMismatch(system: String, exit: String)
}

struct NetCheckFinding: Equatable {
    let item: NetCheckItem
    let verdict: NetCheckVerdict
    let reason: NetCheckReason
}

/// 总结的两个问题。
enum NetCheckGoal: Equatable {
    /// 运营商能看到你的流量吗
    case carrier
    /// App 能看出你的真实位置吗
    case location
}

/// 「看得出在用代理」的几条线索。
enum NetCheckProxyHint: Equatable {
    case hostingExit, timezoneMismatch, dnsCarrier
}

enum NetCheckSummaryReason: Equatable {
    /// 隧道没生效
    case tunnelOff
    /// 这几项没走隧道
    case partialLeak([NetCheckItem])
    /// 这几项没测出来
    case undetermined([NetCheckItem])
    /// 都进了隧道
    case carrierClean
    /// 这几项暴露了真实 IP
    case ipLeak([NetCheckItem])
    /// 看不出位置；`place` = App 看到的位置，`hints` 非空时是提示
    case locationHidden(place: String?, hints: [NetCheckProxyHint])
}

struct NetCheckSummary: Equatable {
    let goal: NetCheckGoal
    let verdict: NetCheckVerdict
    let reason: NetCheckSummaryReason
}

/// 一次检测拿到的全部原料。哪一项没拿到就是 `.failure`。
struct NetCheckObservations {
    var ipv4: Result<NetCheckIPInfo, NetCheckFailure>
    /// `.success(nil)` = 没有 IPv6 出口
    var ipv6: Result<NetCheckIPInfo?, NetCheckFailure>
    var dns: Result<NetCheckDNSResult, NetCheckFailure>
    var systemTimezone: String?
    /// ICE 候选原文。nil = 没测（WebView 起不来之外的原因，比如被跳过）
    var webrtc: Result<[String], NetCheckFailure>?
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

// MARK: - 解析与判定

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

    /// 解析 `https://bash.ws/dnsleak/test/<id>?json=2`：一个数组，每条带 `type`（ip / dns / conclusion / error）。
    static func parseBashWS(_ text: String) -> NetCheckDNSResult? {
        guard let records = object(text) as? [Any] else { return nil }
        var result = NetCheckDNSResult()
        for case let record as [String: Any] in records {
            switch string(record["type"]) {
            case let kind where kind == "ip" || kind == "dns":
                let (asn, fromASN) = splitASN(string(record["asn"]))
                let org = string(record["org"])
                let entry = NetCheckResolver(ip: string(record["ip"]), asn: asn,
                                             network: org.isEmpty ? fromASN : org,
                                             city: string(record["city_name"]),
                                             country: string(record["country_name"]))
                if kind == "ip" { result.clients.append(entry) } else { result.resolvers.append(entry) }
            case "conclusion":
                let words = string(record["ip"]).isEmpty ? string(record["text"]) : string(record["ip"])
                if !words.isEmpty { result.conclusion = words }
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

    // MARK: 五项判定

    static func judgeExit(_ ipv4: Result<NetCheckIPInfo, NetCheckFailure>,
                          real: NetCheckRealNetworks) -> NetCheckFinding {
        let info: NetCheckIPInfo
        switch ipv4 {
        case .failure(let why): return NetCheckFinding(item: .exit, verdict: .unknown, reason: .failed(why.message))
        case .success(let value): info = value
        }
        if real.contains(info.asn) {
            return NetCheckFinding(item: .exit, verdict: .leak, reason: .exitIsReal(info.describe))
        }
        var flags: [NetCheckExitFlag] = []
        if let name = info.hosting { flags.append(.hosting(name)) }
        if info.vpn == true { flags.append(.vpn) }
        if info.proxy == true { flags.append(.proxy) }
        if info.tor == true { flags.append(.tor) }
        if flags.isEmpty {
            return NetCheckFinding(item: .exit, verdict: .ok, reason: .exitClean(info.describe))
        }
        return NetCheckFinding(item: .exit, verdict: .notice, reason: .exitFlagged(info.describe, flags))
    }

    static func judgeIPv6(_ ipv6: Result<NetCheckIPInfo?, NetCheckFailure>,
                          ipv4: Result<NetCheckIPInfo, NetCheckFailure>,
                          real: NetCheckRealNetworks) -> NetCheckFinding {
        let info: NetCheckIPInfo
        switch ipv6 {
        case .failure(let why): return NetCheckFinding(item: .ipv6, verdict: .unknown, reason: .failed(why.message))
        case .success(nil): return NetCheckFinding(item: .ipv6, verdict: .ok, reason: .noIPv6)
        case .success(let value?): info = value
        }
        if real.contains(info.asn) {
            return NetCheckFinding(item: .ipv6, verdict: .leak, reason: .ipv6IsReal(info.describe))
        }
        if case .success(let v4) = ipv4, let a = info.asn, let b = v4.asn, a != b {
            return NetCheckFinding(item: .ipv6, verdict: .leak, reason: .ipv6Differs(info.describe))
        }
        return NetCheckFinding(item: .ipv6, verdict: .ok, reason: .ipv6Matches(info.describe))
    }

    static func judgeDNS(_ dns: Result<NetCheckDNSResult, NetCheckFailure>,
                         real: NetCheckRealNetworks) -> NetCheckFinding {
        let result: NetCheckDNSResult
        switch dns {
        case .failure(let why): return NetCheckFinding(item: .dns, verdict: .unknown, reason: .failed(why.message))
        case .success(let value): result = value
        }
        if let error = result.error {
            return NetCheckFinding(item: .dns, verdict: .unknown, reason: .dnsServiceError(error))
        }
        if result.resolvers.isEmpty {
            return NetCheckFinding(item: .dns, verdict: .unknown, reason: .dnsNoResolvers)
        }
        let leaked = result.resolvers.filter { real.contains($0.asn) }.map(\.describe)
        if !leaked.isEmpty {
            return NetCheckFinding(item: .dns, verdict: .leak, reason: .dnsLeak(leaked))
        }
        // 按运营方归并：一屏几十台 Google 服务器没有意义
        var owners: [String] = []
        for resolver in result.resolvers {
            let name = resolver.network.isEmpty ? resolver.ip : resolver.network
            if !owners.contains(name) { owners.append(name) }
        }
        let count = result.resolvers.count
        if real.isEmpty {
            return NetCheckFinding(item: .dns, verdict: .unknown, reason: .dnsUndeclared(count: count, owners: owners))
        }
        return NetCheckFinding(item: .dns, verdict: .ok, reason: .dnsClean(count: count, owners: owners))
    }

    /// 网页经 STUN 拿到的公网地址应当就是出口 IP（或出口的 IPv6）。不是 = UDP 绕过了隧道。
    static func judgeWebRTC(_ webrtc: Result<[String], NetCheckFailure>,
                            ipv4: Result<NetCheckIPInfo, NetCheckFailure>,
                            ipv6: Result<NetCheckIPInfo?, NetCheckFailure>) -> NetCheckFinding {
        let lines: [String]
        switch webrtc {
        case .failure(let why): return NetCheckFinding(item: .webrtc, verdict: .unknown, reason: .failed(why.message))
        case .success(let value): lines = value
        }
        var exits: [String] = []
        if case .success(let v4) = ipv4 { exits.append(v4.ip) }
        if case .success(let v6?) = ipv6 { exits.append(v6.ip) }

        var publicAddresses: [String] = []
        var localAddresses: [String] = []
        for candidate in lines.compactMap(parseCandidate) {
            if candidate.kind == .relay || candidate.isMDNS { continue }
            let address = candidate.address
            if isPublic(address) {
                if !publicAddresses.contains(where: { sameAddress($0, address) }) { publicAddresses.append(address) }
            } else if !localAddresses.contains(where: { sameAddress($0, address) }) {
                localAddresses.append(address)
            }
        }

        if exits.isEmpty && !publicAddresses.isEmpty {
            return NetCheckFinding(item: .webrtc, verdict: .unknown, reason: .webrtcCannotCompare(publicAddresses))
        }
        let stray = publicAddresses.filter { address in !exits.contains { sameAddress($0, address) } }
        if !stray.isEmpty {
            return NetCheckFinding(item: .webrtc, verdict: .leak, reason: .webrtcLeak(stray))
        }
        if !localAddresses.isEmpty {
            return NetCheckFinding(item: .webrtc, verdict: .notice, reason: .webrtcLocal(localAddresses))
        }
        return NetCheckFinding(item: .webrtc, verdict: .ok,
                               reason: publicAddresses.isEmpty ? .webrtcNothing : .webrtcMatches)
    }

    static func judgeTimezone(_ system: String?, ipv4: Result<NetCheckIPInfo, NetCheckFailure>) -> NetCheckFinding {
        guard let system, !system.isEmpty else {
            return NetCheckFinding(item: .timezone, verdict: .unknown, reason: .timezoneUnavailable)
        }
        guard case .success(let info) = ipv4, !info.timezone.isEmpty else {
            return NetCheckFinding(item: .timezone, verdict: .unknown, reason: .exitTimezoneUnknown)
        }
        if system == info.timezone {
            return NetCheckFinding(item: .timezone, verdict: .ok, reason: .timezoneMatch(system))
        }
        return NetCheckFinding(item: .timezone, verdict: .notice,
                               reason: .timezoneMismatch(system: system, exit: info.timezone))
    }

    /// 各项结论，顺序固定：出口、IPv6、DNS、WebRTC（测了才有）、时区。
    static func evaluate(_ o: NetCheckObservations, real: NetCheckRealNetworks) -> [NetCheckFinding] {
        var findings = [
            judgeExit(o.ipv4, real: real),
            judgeIPv6(o.ipv6, ipv4: o.ipv4, real: real),
            judgeDNS(o.dns, real: real),
        ]
        if let webrtc = o.webrtc {
            findings.append(judgeWebRTC(webrtc, ipv4: o.ipv4, ipv6: o.ipv6))
        }
        findings.append(judgeTimezone(o.systemTimezone, ipv4: o.ipv4))
        return findings
    }

    /// 整体结论：有泄露就是泄露；否则有测不出的就是测不出；否则有提示就是提示。
    static func overall(_ verdicts: [NetCheckVerdict]) -> NetCheckVerdict {
        if verdicts.contains(.leak) { return .leak }
        if verdicts.contains(.unknown) { return .unknown }
        if verdicts.contains(.notice) { return .notice }
        return .ok
    }

    // MARK: 总结

    /// 把各项结论收成两个问题的回答（与 Rust 版 `summarize` 同一套规则）。
    static func summarize(_ o: NetCheckObservations, findings: [NetCheckFinding]) -> [NetCheckSummary] {
        func verdict(_ item: NetCheckItem) -> NetCheckVerdict? {
            findings.first { $0.item == item }?.verdict
        }
        func items(_ list: [NetCheckItem], _ v: NetCheckVerdict) -> [NetCheckItem] {
            list.filter { verdict($0) == v }
        }

        let tunnelItems: [NetCheckItem] = [.exit, .ipv6, .dns, .webrtc]
        let carrier: NetCheckSummary
        if verdict(.exit) == .leak {
            carrier = NetCheckSummary(goal: .carrier, verdict: .leak, reason: .tunnelOff)
        } else if !items(tunnelItems, .leak).isEmpty {
            carrier = NetCheckSummary(goal: .carrier, verdict: .leak, reason: .partialLeak(items(tunnelItems, .leak)))
        } else if !items(tunnelItems, .unknown).isEmpty {
            carrier = NetCheckSummary(goal: .carrier, verdict: .unknown,
                                      reason: .undetermined(items(tunnelItems, .unknown)))
        } else {
            carrier = NetCheckSummary(goal: .carrier, verdict: .ok, reason: .carrierClean)
        }

        let ipItems: [NetCheckItem] = [.exit, .ipv6, .webrtc]
        var hints: [NetCheckProxyHint] = []
        if verdict(.exit) == .notice { hints.append(.hostingExit) }
        if verdict(.timezone) == .notice { hints.append(.timezoneMismatch) }
        if verdict(.dns) == .leak { hints.append(.dnsCarrier) }
        let place: String?
        if case .success(let info) = o.ipv4 { place = info.place } else { place = nil }
        let location: NetCheckSummary
        if !items(ipItems, .leak).isEmpty {
            location = NetCheckSummary(goal: .location, verdict: .leak, reason: .ipLeak(items(ipItems, .leak)))
        } else if !items(ipItems, .unknown).isEmpty {
            location = NetCheckSummary(goal: .location, verdict: .unknown,
                                       reason: .undetermined(items(ipItems, .unknown)))
        } else {
            location = NetCheckSummary(goal: .location, verdict: hints.isEmpty ? .ok : .notice,
                                       reason: .locationHidden(place: place, hints: hints))
        }
        return [carrier, location]
    }
}
