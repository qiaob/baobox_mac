import Foundation

// IP 检测的表：把每条路查到的 IP、国家、归属列出来，四样（国家、归属、地址、时区）各自比，对不上就是「不一致」，
// 并按多数把对不上的格子标红（并列最多时全红）。没有哪一行是「正确值」。只依赖 Foundation，进 BaoboxTests。
// 文案在 NetCheckText（这里给结构化的值）。见 docs/netcheck/COMPARE.md §2。

// MARK: - 表的结构

/// 比的四样，顺序即「对不上的：…」里的次序。
enum NetCheckAspect: CaseIterable, Equatable {
    case country, owner, address, timezone
}

/// 一格里的值（文案层据此出字）。
enum NetCheckValue: Equatable {
    /// 原样显示：地址、「运营方 · AS123」
    case text(String)
    /// 国家（认得出代码就有代码，文案层用 App 语言的地区名；认不出只有原文）和城市
    case place(code: String?, country: String, city: String)
    /// 「没有」（没有 IPv6）
    case noIPv6
    /// 「没查到」
    case notFound
    /// 「网页没拿到公网地址」
    case noPublicAddress
    /// 「N 台」（DNS 的一组）
    case servers(Int)
    /// 「系统 X」；nil = 系统时区没读到
    case systemZone(String?)
    /// 「IP 所在 X」；nil = 没查到
    case ipZone(String?)
    case empty
}

struct NetCheckCell: Equatable {
    var value: NetCheckValue
    /// 对不上，标红
    var mismatch = false
    /// 不参加比较（公共 DNS 的国家）：灰色显示，不会红
    var muted = false

    init(_ value: NetCheckValue, mismatch: Bool = false, muted: Bool = false) {
        self.value = value
        self.mismatch = mismatch
        self.muted = muted
    }
}

/// 一行里的一条：IP / 国家 / 归属三格（DNS、WebRTC 一行可能有好几条）。
struct NetCheckLine: Equatable {
    var address: NetCheckCell
    var country: NetCheckCell
    var owner: NetCheckCell
    /// 归属后面的灰色小标签
    var flags: [NetCheckExitFlag] = []

    var hasMismatch: Bool { address.mismatch || country.mismatch || owner.mismatch }
}

/// 一行没测出来的原因。
enum NetCheckRowFailure: Equatable {
    /// 带原因（已经是给人看的文字）
    case failed(String)
    /// bash.ws 自己报的错
    case dnsServiceError(String)
    /// bash.ws 一台 DNS 服务器都没看到
    case dnsNoResolvers
}

struct NetCheckRow: Equatable {
    let item: NetCheckItem
    var lines: [NetCheckLine] = []
    /// 没测出来时有值（`lines` 为空）
    var failure: NetCheckRowFailure?
    /// DNS 那一行：一共几台服务器
    var serverCount: Int?

    var hasMismatch: Bool { lines.contains(where: \.hasMismatch) }
}

enum NetCheckConclusion: Equatable {
    case consistent
    /// 对不上的那几样，按 `NetCheckAspect.allCases` 的次序
    case inconsistent([NetCheckAspect])
    /// 四样都因为缺值没东西可比
    case cannotCompare
}

struct NetCheckTable: Equatable {
    var rows: [NetCheckRow]
    var conclusion: NetCheckConclusion
}

// MARK: - 比对

enum NetCheckCompare {
    /// WebRTC 拿到的地址和 IPv4 / IPv6 那一行都不同时另查归属，最多查这么多个。
    static let maxLookups = 3

    /// 网页拿到的公网地址（去重、按出现的顺序）：跳过 relay、mDNS 名字、内网地址。
    static func publicAddresses(_ lines: [String]) -> [String] {
        var addresses: [String] = []
        for candidate in lines.compactMap(NetCheckLogic.parseCandidate) {
            guard candidate.kind != .relay, !candidate.isMDNS, NetCheckLogic.isPublic(candidate.address) else { continue }
            if !addresses.contains(where: { NetCheckLogic.sameAddress($0, candidate.address) }) {
                addresses.append(candidate.address)
            }
        }
        return addresses
    }

    /// 要另查归属的地址：公网的、和 IPv4 / IPv6 那一行的地址都不同的，最多 3 个。
    static func addressesToLookUp(_ webrtc: Result<[String], NetCheckFailure>?,
                                  ipv4: Result<NetCheckIPInfo, NetCheckFailure>,
                                  ipv6: Result<NetCheckIPInfo?, NetCheckFailure>) -> [String] {
        guard case .success(let lines)? = webrtc else { return [] }
        let known = knownInfos(ipv4: ipv4, ipv6: ipv6)
        let stray = publicAddresses(lines).filter { address in
            !known.contains { NetCheckLogic.sameAddress($0.ip, address) }
        }
        return Array(stray.prefix(maxLookups))
    }

    private static func knownInfos(ipv4: Result<NetCheckIPInfo, NetCheckFailure>,
                                   ipv6: Result<NetCheckIPInfo?, NetCheckFailure>) -> [NetCheckIPInfo] {
        var infos: [NetCheckIPInfo] = []
        if case .success(let v4) = ipv4 { infos.append(v4) }
        if case .success(let v6?) = ipv6 { infos.append(v6) }
        return infos
    }

    // MARK: 格子里的字

    /// 国家和城市；国家认得出就带上两位代码。两样都没有时「没查到」。
    static func place(city: String, country: String, code: String = "") -> NetCheckValue {
        let city = city.trimmingCharacters(in: .whitespaces)
        let country = country.trimmingCharacters(in: .whitespaces)
        let code = NetCheckCountry.code(code, name: country)
        guard code != nil || !country.isEmpty || !city.isEmpty else { return .notFound }
        return .place(code: code, country: country, city: city)
    }

    /// 「运营方 · AS45102」。ASN 当字符串拼，不带千位分隔符（真机上出现过 `AS45,102`）。两样都没有时「没查到」。
    static func owner(name: String, asn: Int?) -> NetCheckValue {
        var parts: [String] = []
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { parts.append(name) }
        if let asn { parts.append("AS" + String(asn)) }
        return parts.isEmpty ? .notFound : .text(parts.joined(separator: " · "))
    }

    private static func ownerName(_ info: NetCheckIPInfo) -> String {
        info.network.isEmpty ? info.company : info.network
    }

    // MARK: 比的键

    /// 国家按 ISO 两位代码比，认不出代码的按名字比（`NetCheckCountry.key`）。
    private static func countryKey(_ country: String, code: String) -> String? {
        NetCheckCountry.key(code: code, name: country)
    }

    /// 同一个 ASN，或同一家云厂商的不同 ASN，键相同。
    private static func ownerKey(_ asn: Int?) -> String? {
        guard let asn else { return nil }
        return NetCheckLogic.knownHosting(asn) ?? "AS" + String(asn)
    }

    /// 地址按族分组（0 = IPv4，1 = IPv6），键是字节（不同写法的 IPv6 算同一个）。认不出的地址不参加。
    private static func addressKey(_ address: String) -> (group: Int, key: String)? {
        if let bytes = NetCheckLogic.ipv4Bytes(address) { return (0, bytes.map(String.init).joined(separator: ".")) }
        if let bytes = NetCheckLogic.ipv6Bytes(address) { return (1, bytes.map(String.init).joined(separator: ":")) }
        return nil
    }

    private static func zoneKey(_ zone: String?) -> String? {
        let key = (zone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    // MARK: 建表

    private enum Column { case address, country, owner }

    /// 参加比较的一个值：在哪一样的哪一组、键、它在表里的哪一格。
    private struct Vote {
        let aspect: NetCheckAspect
        let group: Int
        let key: String
        let row: Int
        let line: Int
        let column: Column
    }

    static func table(_ o: NetCheckObservations) -> NetCheckTable {
        var rows: [NetCheckRow] = []
        var votes: [Vote] = []

        func vote(_ aspect: NetCheckAspect, group: Int = 0, _ key: String?, line: Int, _ column: Column) {
            guard let key else { return }
            votes.append(Vote(aspect: aspect, group: group, key: key, row: rows.count, line: line, column: column))
        }

        /// IPv4 / IPv6 那一行、WebRTC 另查到的那一条：地址、国家、归属三格都参加比较。
        /// `samePlaceAsRow`：WebRTC 的地址就是 IPv4 / IPv6 那一行的（国家、归属借用那一行的）——同一个地址是同一个观测，
        /// 不再为国家、归属多算一票，只有地址参加比较。
        func infoLine(_ info: NetCheckIPInfo, line: Int, samePlaceAsRow: Bool = false) -> NetCheckLine {
            if let address = addressKey(info.ip) { vote(.address, group: address.group, address.key, line: line, .address) }
            if !samePlaceAsRow {
                vote(.country, countryKey(info.country, code: info.countryCode), line: line, .country)
                vote(.owner, ownerKey(info.asn), line: line, .owner)
            }
            return NetCheckLine(address: NetCheckCell(.text(info.ip)),
                                country: NetCheckCell(place(city: info.city, country: info.country, code: info.countryCode)),
                                owner: NetCheckCell(owner(name: ownerName(info), asn: info.asn)),
                                flags: info.flags)
        }

        // IPv4
        switch o.ipv4 {
        case .failure(let why):
            rows.append(NetCheckRow(item: .ipv4, failure: .failed(why.message)))
        case .success(let info):
            let line = infoLine(info, line: 0)
            rows.append(NetCheckRow(item: .ipv4, lines: [line]))
        }

        // IPv6
        switch o.ipv6 {
        case .failure(let why):
            rows.append(NetCheckRow(item: .ipv6, failure: .failed(why.message)))
        case .success(nil):
            rows.append(NetCheckRow(item: .ipv6, lines: [NetCheckLine(address: NetCheckCell(.noIPv6),
                                                                       country: NetCheckCell(.empty),
                                                                       owner: NetCheckCell(.empty))]))
        case .success(let info?):
            let line = infoLine(info, line: 0)
            rows.append(NetCheckRow(item: .ipv6, lines: [line]))
        }

        // DNS：按「国家 + 归属」分组，每组一条，一组算一个值；归属只列出来，不参加比较；公共 DNS 的国家也不参加
        let dns = dnsRow(o.dns, vote: { key, line in vote(.country, key, line: line, .country) })
        rows.append(dns)

        // WebRTC：每个公网地址一条
        if let webrtc = o.webrtc {
            switch webrtc {
            case .failure(let why):
                rows.append(NetCheckRow(item: .webrtc, failure: .failed(why.message)))
            case .success(let candidates):
                let addresses = publicAddresses(candidates)
                if addresses.isEmpty {
                    rows.append(NetCheckRow(item: .webrtc, lines: [NetCheckLine(address: NetCheckCell(.noPublicAddress),
                                                                                 country: NetCheckCell(.empty),
                                                                                 owner: NetCheckCell(.empty))]))
                } else {
                    let known = knownInfos(ipv4: o.ipv4, ipv6: o.ipv6)
                    var lines: [NetCheckLine] = []
                    for address in addresses {
                        let index = lines.count
                        // 和 IPv4 / IPv6 那一行相同：国家、归属用那一行的（不另算一票）；不同：用另查的
                        let borrowed = known.first { NetCheckLogic.sameAddress($0.ip, address) }
                        let source = borrowed ?? o.webrtcLookups.first { NetCheckLogic.sameAddress($0.key, address) }?.value
                        if var info = source {
                            info.ip = address
                            lines.append(infoLine(info, line: index, samePlaceAsRow: borrowed != nil))
                        } else {
                            // 没查到：地址照样参加地址的比较，国家和归属不参加
                            if let key = addressKey(address) { vote(.address, group: key.group, key.key, line: index, .address) }
                            lines.append(NetCheckLine(address: NetCheckCell(.text(address)),
                                                      country: NetCheckCell(.notFound), owner: NetCheckCell(.notFound)))
                        }
                    }
                    rows.append(NetCheckRow(item: .webrtc, lines: lines))
                }
            }
        }

        // 时区：系统的、IP 所在的（取 IPv4 的，没有就取 IPv6 的）
        var ipZone: String?
        if case .success(let v4) = o.ipv4 { ipZone = zoneKey(v4.timezone) }
        if ipZone == nil, case .success(let v6?) = o.ipv6 { ipZone = zoneKey(v6.timezone) }
        let systemZone = zoneKey(o.systemTimezone)
        vote(.timezone, systemZone, line: 0, .address)
        vote(.timezone, ipZone, line: 0, .country)
        rows.append(NetCheckRow(item: .timezone, lines: [NetCheckLine(address: NetCheckCell(.systemZone(systemZone)),
                                                                       country: NetCheckCell(.ipZone(ipZone)),
                                                                       owner: NetCheckCell(.empty))]))

        // 比：每一样、每一组各自看
        var comparable: Set<NetCheckAspect> = []
        var mismatched: Set<NetCheckAspect> = []
        for aspect in NetCheckAspect.allCases {
            let ofAspect = votes.filter { $0.aspect == aspect }
            for group in Set(ofAspect.map(\.group)) {
                let members = ofAspect.filter { $0.group == group }
                guard members.count >= 2 else { continue }
                comparable.insert(aspect)
                let marked = minority(members.map(\.key))
                guard !marked.isEmpty else { continue }
                mismatched.insert(aspect)
                for member in members where marked.contains(member.key) {
                    switch member.column {
                    case .address: rows[member.row].lines[member.line].address.mismatch = true
                    case .country: rows[member.row].lines[member.line].country.mismatch = true
                    case .owner: rows[member.row].lines[member.line].owner.mismatch = true
                    }
                }
            }
        }

        let conclusion: NetCheckConclusion
        if !mismatched.isEmpty {
            conclusion = .inconsistent(NetCheckAspect.allCases.filter { mismatched.contains($0) })
        } else if comparable.isEmpty {
            conclusion = .cannotCompare
        } else {
            conclusion = .consistent
        }
        return NetCheckTable(rows: rows, conclusion: conclusion)
    }

    /// 按多数要标红的键：都一样时没有；出现最多的只有一个时，除它以外的都标；并列最多时全标。
    static func minority(_ keys: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for key in keys { counts[key, default: 0] += 1 }
        guard counts.count >= 2, let top = counts.values.max() else { return [] }
        let leaders = counts.filter { $0.value == top }.map(\.key)
        if leaders.count > 1 { return Set(counts.keys) }
        return Set(counts.keys).subtracting(leaders)
    }

    /// DNS 那一行：按「国家 + 归属」分组（按第一次出现的顺序），每组一条：台数、国家、归属。
    /// 公共 DNS（`NetCheckLogic.publicDNS`）的组：国家照样列出来但不参加比较（灰色），归属后面加「公共 DNS」小标签。
    private static func dnsRow(_ dns: Result<NetCheckDNSResult, NetCheckFailure>,
                               vote: (String?, Int) -> Void) -> NetCheckRow {
        let result: NetCheckDNSResult
        switch dns {
        case .failure(let why): return NetCheckRow(item: .dns, failure: .failed(why.message))
        case .success(let value): result = value
        }
        if let error = result.error { return NetCheckRow(item: .dns, failure: .dnsServiceError(error)) }
        if result.resolvers.isEmpty { return NetCheckRow(item: .dns, failure: .dnsNoResolvers) }

        struct Group {
            let key: String
            let first: NetCheckResolver
            var count: Int
        }
        var groups: [Group] = []
        for resolver in result.resolvers {
            let ownerPart = resolver.asn.map { "AS" + String($0) } ?? resolver.network.lowercased()
            let key = (countryKey(resolver.country, code: resolver.countryCode) ?? "") + "|" + ownerPart
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].count += 1
            } else {
                groups.append(Group(key: key, first: resolver, count: 1))
            }
        }
        var lines: [NetCheckLine] = []
        for (index, group) in groups.enumerated() {
            let resolver = group.first
            let isPublic = resolver.asn.flatMap(NetCheckLogic.publicDNS) != nil
            if !isPublic { vote(countryKey(resolver.country, code: resolver.countryCode), index) }
            lines.append(NetCheckLine(address: NetCheckCell(.servers(group.count)),
                                      country: NetCheckCell(place(city: "", country: resolver.country,
                                                                  code: resolver.countryCode), muted: isPublic),
                                      owner: NetCheckCell(owner(name: resolver.network, asn: resolver.asn)),
                                      flags: isPublic ? [.publicDNS] : []))
        }
        return NetCheckRow(item: .dns, lines: lines, serverCount: result.resolvers.count)
    }

    // MARK: 纯文本报告

    /// 报告里的词（文案层用 `L()` 填）。
    struct ReportWords {
        var rowTitle: (NetCheckRow) -> String
        var value: (NetCheckValue) -> String
        var failure: (NetCheckRowFailure) -> String
        var flag: (NetCheckExitFlag) -> String
        /// 标红的格子后面加的，如「（不一致）」
        var mismatch: String
        /// 「项目：…」里的冒号
        var colon: String
    }

    /// 表的每一条一行：「项目：IP · 国家 · 归属」，标红的格子后面加 `mismatch`；空格子跳过；小标签放在归属（和它的标记）后面的方括号里。
    static func reportLines(_ table: NetCheckTable, words: ReportWords) -> [String] {
        var lines: [String] = []
        for row in table.rows {
            let title = words.rowTitle(row)
            if let failure = row.failure {
                lines.append(title + words.colon + words.failure(failure))
                continue
            }
            for line in row.lines {
                var cells: [String] = []
                for (index, cell) in [line.address, line.country, line.owner].enumerated() {
                    var text = words.value(cell.value)
                    if cell.mismatch, !text.isEmpty { text += words.mismatch }
                    if index == 2, !line.flags.isEmpty {
                        let tags = "[" + line.flags.map(words.flag).joined(separator: ", ") + "]"
                        text = text.isEmpty ? tags : text + " " + tags
                    }
                    guard !text.isEmpty else { continue }
                    cells.append(text)
                }
                lines.append(title + words.colon + cells.joined(separator: " · "))
            }
        }
        return lines
    }
}
