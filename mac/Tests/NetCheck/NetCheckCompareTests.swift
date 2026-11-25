import Foundation
import XCTest

/// IP 检测的表：四样（国家、归属、地址、时区）各自比，按多数标红（docs/netcheck/COMPARE.md §2、§8）。
final class NetCheckCompareTests: XCTestCase {

    // MARK: - 样本（文档地址段 192.0.2 / 198.51.100 / 203.0.113 不算公网，WebRTC 要用真的公网地址）

    private let alibaba = "Alibaba (US) Technology Co., Ltd."

    private func info(_ ip: String, country: String = "Singapore", city: String = "Singapore", asn: Int? = 45102,
                      network: String = "Alibaba (US) Technology Co., Ltd.", timezone: String = "Asia/Singapore") -> NetCheckIPInfo {
        NetCheckIPInfo(ip: ip, asn: asn, network: network, city: city, country: country, timezone: timezone)
    }

    private func resolver(_ ip: String, country: String = "Singapore", asn: Int? = 15169,
                          network: String = "Google LLC") -> NetCheckResolver {
        NetCheckResolver(ip: ip, asn: asn, network: network, city: "", country: country)
    }

    private func srflx(_ address: String) -> String {
        "candidate:842163049 1 udp 1677729535 \(address) 61234 typ srflx raddr 0.0.0.0 rport 0"
    }

    private let v4 = "8.219.158.59"
    private let v4Other = "34.3.107.77"
    private let v6 = "2406:da18::7"

    /// 一次「各项一致」的检测：IPv4 在新加坡的阿里云，没有 IPv6，两组 DNS 都在新加坡，网页拿到的就是 IPv4，时区一致。
    private func clean() -> NetCheckObservations {
        NetCheckObservations(ipv4: .success(info(v4)), ipv6: .success(nil),
                             dns: .success(NetCheckDNSResult(resolvers: [
                                resolver("172.253.2.1"),
                                resolver("162.158.1.1", asn: 13335, network: "Cloudflare, Inc."),
                             ])),
                             systemTimezone: "Asia/Singapore",
                             webrtc: .success([srflx(v4)]))
    }

    private func row(_ table: NetCheckTable, _ item: NetCheckItem) -> NetCheckRow? {
        table.rows.first { $0.item == item }
    }

    private func dnsOf(_ countries: [String]) -> Result<NetCheckDNSResult, NetCheckFailure> {
        // 每台一个不同的 ASN，好让它们各成一组
        .success(NetCheckDNSResult(resolvers: countries.enumerated().map { index, country in
            resolver("192.0.2.\(index + 1)", country: country, asn: 64500 + index, network: "DNS \(index)")
        }))
    }

    // MARK: - 一致

    func testConsistent() {
        let table = NetCheckCompare.table(clean())
        XCTAssertEqual(table.conclusion, .consistent)
        XCTAssertEqual(table.rows.map(\.item), [.ipv4, .ipv6, .dns, .webrtc, .timezone])
        XCTAssertFalse(table.rows.contains(where: \.hasMismatch))
        let ipv4 = row(table, .ipv4)?.lines.first
        XCTAssertEqual(ipv4?.address.value, .text(v4))
        XCTAssertEqual(ipv4?.country.value, .text("Singapore · Singapore"))
        XCTAssertEqual(ipv4?.owner.value, .text("\(alibaba) · AS45102"))
        XCTAssertEqual(row(table, .ipv6)?.lines.first?.address.value, .noIPv6)
        // 网页拿到的就是 IPv4：国家、归属直接用那一行的
        let webrtc = row(table, .webrtc)?.lines.first
        XCTAssertEqual(webrtc?.country.value, .text("Singapore · Singapore"))
        XCTAssertEqual(webrtc?.owner.value, .text("\(alibaba) · AS45102"))
        let zone = row(table, .timezone)?.lines.first
        XCTAssertEqual(zone?.address.value, .systemZone("Asia/Singapore"))
        XCTAssertEqual(zone?.country.value, .ipZone("Asia/Singapore"))
    }

    // MARK: - 国家

    func testCountryThreeAgainstOne() {
        var o = clean()
        o.dns = dnsOf(["Singapore", "Singapore", "United States"])
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(table.conclusion, .inconsistent([.country]))
        let dns = row(table, .dns)
        XCTAssertEqual(dns?.lines.map(\.country.mismatch), [false, false, true], "只有少数那一组红")
        XCTAssertEqual(row(table, .ipv4)?.lines.first?.country.mismatch, false)
        XCTAssertFalse(row(table, .ipv4)?.hasMismatch ?? true)
        XCTAssertTrue(dns?.hasMismatch ?? false)
    }

    func testCountryOneAgainstOne() {
        // 只有 IPv4 和 DNS 两个国家、各不相同：两格都红
        var o = clean()
        o.webrtc = nil
        o.dns = dnsOf(["United States"])
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(table.conclusion, .inconsistent([.country]))
        XCTAssertEqual(row(table, .ipv4)?.lines.first?.country.mismatch, true)
        XCTAssertEqual(row(table, .dns)?.lines.first?.country.mismatch, true)
    }

    func testCountryTwoAgainstTwo() {
        // IPv4、IPv6 在新加坡，两组 DNS 在美国：2 比 2，四个都红
        var o = clean()
        o.webrtc = nil
        o.ipv6 = .success(info(v6))
        o.dns = dnsOf(["United States", "United States"])
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(row(table, .ipv4)?.lines.first?.country.mismatch, true)
        XCTAssertEqual(row(table, .ipv6)?.lines.first?.country.mismatch, true)
        XCTAssertEqual(row(table, .dns)?.lines.map(\.country.mismatch), [true, true])
    }

    func testDNSGroupCountsAsOneValue() {
        // 五台都在美国、同一家：一组只算一个值，2 比 1，只有那一组红
        var o = clean()
        o.webrtc = nil
        o.ipv6 = .success(info(v6))
        o.dns = .success(NetCheckDNSResult(resolvers: (1...5).map { resolver("192.0.2.\($0)", country: "United States") }))
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(row(table, .dns)?.lines.count, 1)
        XCTAssertEqual(row(table, .dns)?.lines.first?.country.mismatch, true)
        XCTAssertEqual(row(table, .ipv4)?.lines.first?.country.mismatch, false)
        XCTAssertEqual(row(table, .ipv6)?.lines.first?.country.mismatch, false)
    }

    func testCountryMissingOrDifferentlyWritten() {
        // 回包里没有国家：少一个值，不算不一致
        var o = clean()
        o.ipv4 = .success(info(v4, country: "", city: ""))
        o.dns = dnsOf(["United States"])
        o.webrtc = nil
        var table = NetCheckCompare.table(o)
        XCTAssertFalse(table.rows.contains(where: \.hasMismatch))
        XCTAssertEqual(row(table, .ipv4)?.lines.first?.country.value, .notFound)
        // 大小写、首尾空白不算不同
        o.ipv4 = .success(info(v4, country: " singapore "))
        o.dns = dnsOf(["Singapore"])
        table = NetCheckCompare.table(o)
        XCTAssertEqual(table.conclusion, .consistent)
    }

    // MARK: - 归属

    func testOwnerDiffers() {
        // IPv6 走的是另一家（本地运营商），国家一样：只有 IPv6 的归属那一格红（IPv4 和 WebRTC 借用的那一条是同一家，2 比 1）
        var o = clean()
        o.ipv6 = .success(info(v6, asn: 4657, network: "StarHub Ltd"))
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(table.conclusion, .inconsistent([.owner]))
        let ipv6 = row(table, .ipv6)?.lines.first
        XCTAssertEqual(ipv6?.owner.mismatch, true)
        XCTAssertEqual(ipv6?.country.mismatch, false)
        XCTAssertEqual(ipv6?.address.mismatch, false, "地址两族分开比：IPv6 只有一个值")
    }

    func testOwnerMajorityAcrossRows() {
        // IPv4、IPv6 同一家，WebRTC 另查到的是另一家：2 比 1，只有 WebRTC 那一格红
        var o = clean()
        o.ipv6 = .success(info(v6))
        o.webrtc = .success([srflx(v4Other)])
        o.webrtcLookups = [v4Other: info(v4Other, asn: 4657, network: "StarHub Ltd")]
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(row(table, .webrtc)?.lines.first?.owner.mismatch, true)
        XCTAssertEqual(row(table, .ipv4)?.lines.first?.owner.mismatch, false)
        XCTAssertEqual(row(table, .ipv6)?.lines.first?.owner.mismatch, false)
    }

    func testOwnerSameCloudUnderAnotherASN() {
        var o = clean()
        o.ipv4 = .success(info(v4, asn: 15169, network: "Google LLC"))
        o.ipv6 = .success(info(v6, asn: 396982, network: "Google LLC"))
        XCTAssertEqual(NetCheckCompare.table(o).conclusion, .consistent)
    }

    func testOwnerMissingAndDNSOwnersNotCompared() {
        // IPv6 没有 ASN：不参加；DNS 是 Google / Cloudflare 而 IPv4 是阿里云：DNS 的归属不参加比较
        var o = clean()
        o.ipv6 = .success(info(v6, asn: nil, network: "Somebody"))
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(table.conclusion, .consistent)
        XCTAssertEqual(row(table, .ipv6)?.lines.first?.owner.value, .text("Somebody"))
    }

    // MARK: - 地址

    func testWebRTCGotAnotherAddress() {
        // 网页拿到另一个 IPv4（另查到同一国家、同一家）：两个地址都红，国家归属不红
        var o = clean()
        o.webrtc = .success([srflx(v4Other)])
        o.webrtcLookups = [v4Other: info(v4Other)]
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(table.conclusion, .inconsistent([.address]))
        XCTAssertEqual(row(table, .ipv4)?.lines.first?.address.mismatch, true)
        let webrtc = row(table, .webrtc)?.lines.first
        XCTAssertEqual(webrtc?.address.mismatch, true)
        XCTAssertEqual(webrtc?.country.mismatch, false)
        XCTAssertEqual(webrtc?.owner.mismatch, false)
    }

    func testAddressFamiliesAreComparedSeparately() {
        // IPv4 行和 WebRTC 的 IPv4 一样，IPv6 行和 WebRTC 的 IPv6 一样（写法不同）：一致
        var o = clean()
        o.ipv6 = .success(info(v6))
        o.webrtc = .success([srflx(v4), srflx("2406:da18:0:0:0:0:0:7")])
        XCTAssertEqual(NetCheckCompare.table(o).conclusion, .consistent)
        // 网页拿到 IPv6，而 IPv6 那一行是「没有」：IPv6 只有一个值，地址不算不一致（国家、归属照常比）
        o.ipv6 = .success(nil)
        o.webrtcLookups = ["2406:da18:0:0:0:0:0:7": info(v6)]
        XCTAssertEqual(NetCheckCompare.table(o).conclusion, .consistent)
    }

    func testAddressNotLookedUpStillCompared() {
        // 另查没查到：国家、归属写「没查到」、不参加比较；地址照样比
        var o = clean()
        o.webrtc = .success([srflx(v4Other)])
        let table = NetCheckCompare.table(o)
        let webrtc = row(table, .webrtc)?.lines.first
        XCTAssertEqual(webrtc?.country.value, .notFound)
        XCTAssertEqual(webrtc?.owner.value, .notFound)
        XCTAssertEqual(webrtc?.address.mismatch, true)
        XCTAssertEqual(table.conclusion, .inconsistent([.address]))
    }

    // MARK: - 时区

    func testTimezone() {
        var o = clean()
        o.systemTimezone = "Asia/Shanghai"
        var table = NetCheckCompare.table(o)
        XCTAssertEqual(table.conclusion, .inconsistent([.timezone]))
        let zone = row(table, .timezone)?.lines.first
        XCTAssertEqual(zone?.address.mismatch, true)
        XCTAssertEqual(zone?.country.mismatch, true, "1 比 1：两边都红")
        // 系统时区读不到：只剩一个值，算一致
        o.systemTimezone = nil
        table = NetCheckCompare.table(o)
        XCTAssertEqual(table.conclusion, .consistent)
        XCTAssertEqual(row(table, .timezone)?.lines.first?.address.value, .systemZone(nil))
    }

    func testTimezoneFallsBackToIPv6() {
        var o = clean()
        o.ipv4 = .success(info(v4, timezone: ""))
        o.ipv6 = .success(info(v6, timezone: "Asia/Tokyo"))
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(row(table, .timezone)?.lines.first?.country.value, .ipZone("Asia/Tokyo"))
        XCTAssertEqual(table.conclusion, .inconsistent([.timezone]))
    }

    // MARK: - 缺值

    func testFewerThanTwoValuesIsConsistentButNothingAtAllIsCannotCompare() {
        // 只有 IPv4 测出来、系统时区也没读到：每一样都不足两个值 → 无法比较
        var o = NetCheckObservations(ipv4: .success(info(v4)), ipv6: .failure(NetCheckFailure("x")),
                                     dns: .failure(NetCheckFailure("y")), systemTimezone: nil, webrtc: nil)
        XCTAssertEqual(NetCheckCompare.table(o).conclusion, .cannotCompare)
        // 多一个系统时区：时区能比了，且一样 → 一致
        o.systemTimezone = "Asia/Singapore"
        XCTAssertEqual(NetCheckCompare.table(o).conclusion, .consistent)
    }

    func testEverythingFailed() {
        let o = NetCheckObservations(ipv4: .failure(NetCheckFailure("down")), ipv6: .failure(NetCheckFailure("x")),
                                     dns: .failure(NetCheckFailure("y")), systemTimezone: nil,
                                     webrtc: .failure(NetCheckFailure("z")))
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(table.conclusion, .cannotCompare)
        XCTAssertEqual(row(table, .ipv4)?.failure, .failed("down"))
        XCTAssertEqual(row(table, .webrtc)?.failure, .failed("z"))
        XCTAssertTrue(row(table, .ipv4)?.lines.isEmpty ?? false)
        XCTAssertEqual(row(table, .timezone)?.lines.first?.country.value, .ipZone(nil))
    }

    func testIPv4FailedButTheRestCompare() {
        var o = clean()
        o.ipv4 = .failure(NetCheckFailure("down"))
        o.ipv6 = .success(info(v6))
        o.webrtc = nil
        o.dns = dnsOf(["United States"])
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(table.conclusion, .inconsistent([.country]))
        XCTAssertEqual(row(table, .ipv6)?.lines.first?.country.mismatch, true)
        XCTAssertEqual(row(table, .timezone)?.lines.first?.country.value, .ipZone("Asia/Singapore"), "时区取 IPv6 的")
    }

    // MARK: - 多数

    func testMinority() {
        XCTAssertEqual(NetCheckCompare.minority([]), [])
        XCTAssertEqual(NetCheckCompare.minority(["a"]), [])
        XCTAssertEqual(NetCheckCompare.minority(["a", "a"]), [])
        XCTAssertEqual(NetCheckCompare.minority(["a", "a", "a", "b"]), ["b"])
        XCTAssertEqual(NetCheckCompare.minority(["a", "b"]), ["a", "b"])
        XCTAssertEqual(NetCheckCompare.minority(["a", "a", "b", "b"]), ["a", "b"])
        XCTAssertEqual(NetCheckCompare.minority(["a", "a", "b", "b", "c"]), ["a", "b", "c"], "并列最多时全红")
        XCTAssertEqual(NetCheckCompare.minority(["a", "a", "b", "c"]), ["b", "c"])
    }

    func testMismatchListOrder() {
        // 先在时区、再在国家出问题：清单按「国家、归属、地址、时区」的次序
        var o = clean()
        o.systemTimezone = "Europe/Paris"
        o.webrtc = nil
        o.dns = dnsOf(["France"])
        XCTAssertEqual(NetCheckCompare.table(o).conclusion, .inconsistent([.country, .timezone]))
    }

    // MARK: - DNS 分组

    func testDNSGroupingAndCounts() {
        var o = clean()
        o.dns = .success(NetCheckDNSResult(resolvers: [
            resolver("172.253.2.1"), resolver("172.253.2.2"), resolver("172.253.2.3"),
            resolver("162.158.1.1", asn: 13335, network: "Cloudflare, Inc."),
            resolver("162.158.1.2", asn: 13335, network: "Cloudflare, Inc."),
            resolver("8.8.4.4", country: "United States"),
        ]))
        let dns = row(NetCheckCompare.table(o), .dns)
        XCTAssertEqual(dns?.serverCount, 6)
        XCTAssertEqual(dns?.lines.map(\.address.value), [.servers(3), .servers(2), .servers(1)])
        XCTAssertEqual(dns?.lines.map(\.country.value), [.text("Singapore"), .text("Singapore"), .text("United States")])
        XCTAssertEqual(dns?.lines.map(\.owner.value), [.text("Google LLC · AS15169"), .text("Cloudflare, Inc. · AS13335"),
                                                     .text("Google LLC · AS15169")])
    }

    func testDNSFailures() {
        var o = clean()
        o.dns = .success(NetCheckDNSResult(resolvers: [], error: "No DNS servers found. Try again..."))
        XCTAssertEqual(row(NetCheckCompare.table(o), .dns)?.failure, .dnsServiceError("No DNS servers found. Try again..."))
        o.dns = .success(NetCheckDNSResult())
        XCTAssertEqual(row(NetCheckCompare.table(o), .dns)?.failure, .dnsNoResolvers)
        o.dns = .failure(NetCheckFailure("timeout"))
        XCTAssertEqual(row(NetCheckCompare.table(o), .dns)?.failure, .failed("timeout"))
    }

    // MARK: - WebRTC

    func testWebRTCKeepsOnlyPublicAddresses() {
        let lines = [
            "candidate:1 1 udp 2113937151 5f0b4c1e-9a2d-4d8e-b0c1-1a2b3c4d5e6f.local 54321 typ host generation 0",
            "candidate:3 1 udp 2122260223 192.168.0.23 50000 typ host generation 0",
            "candidate:4 1 udp 2122260223 100.101.102.103 50000 typ host generation 0",
            "candidate:5 1 udp 1 34.3.107.99 3478 typ relay raddr 0.0.0.0 rport 0",
            srflx(v4Other), srflx(v4), srflx(v6), srflx(v4Other),
        ]
        XCTAssertEqual(NetCheckCompare.publicAddresses(lines), [v4Other, v4, v6], "内网、mDNS、relay 不算；去重")
        // 和 IPv4 / IPv6 那一行相同的不另查
        XCTAssertEqual(NetCheckCompare.addressesToLookUp(.success(lines), ipv4: .success(info(v4)),
                                                         ipv6: .success(info(v6))), [v4Other])
        // IPv6 那一行没有：网页拿到的 IPv6 要查
        XCTAssertEqual(NetCheckCompare.addressesToLookUp(.success(lines), ipv4: .success(info(v4)), ipv6: .success(nil)),
                       [v4Other, v6])
        // 最多查 3 个
        let many = (1...5).map { srflx("34.3.107.\($0)") }
        XCTAssertEqual(NetCheckCompare.addressesToLookUp(.success(many), ipv4: .success(info(v4)), ipv6: .success(nil)).count, 3)
        XCTAssertEqual(NetCheckCompare.addressesToLookUp(.failure(NetCheckFailure("x")), ipv4: .success(info(v4)),
                                                         ipv6: .success(nil)), [])
        XCTAssertEqual(NetCheckCompare.addressesToLookUp(nil, ipv4: .success(info(v4)), ipv6: .success(nil)), [])
    }

    func testWebRTCRowShapes() {
        var o = clean()
        o.webrtc = .success(["candidate:3 1 udp 2122260223 192.168.0.23 50000 typ host generation 0"])
        XCTAssertEqual(row(NetCheckCompare.table(o), .webrtc)?.lines.first?.address.value, .noPublicAddress)
        o.webrtc = .failure(NetCheckFailure("timeout"))
        XCTAssertEqual(row(NetCheckCompare.table(o), .webrtc)?.failure, .failed("timeout"))
        o.webrtc = nil
        XCTAssertNil(row(NetCheckCompare.table(o), .webrtc), "没测 WebRTC 就没有这一行")
    }

    // MARK: - 写法

    func testOwnerTextHasNoGroupingSeparator() {
        XCTAssertEqual(NetCheckCompare.owner(name: alibaba, asn: 45102), .text("\(alibaba) · AS45102"))
        XCTAssertEqual(NetCheckCompare.owner(name: "", asn: 4657), .text("AS4657"))
        XCTAssertEqual(NetCheckCompare.owner(name: " ", asn: nil), .notFound)
        XCTAssertEqual(NetCheckCompare.owner(name: "Big", asn: 1_234_567), .text("Big · AS1234567"))
        XCTAssertEqual(NetCheckCompare.place(city: "Singapore", country: "Singapore"), .text("Singapore · Singapore"))
        XCTAssertEqual(NetCheckCompare.place(city: "", country: "France"), .text("France"))
        XCTAssertEqual(NetCheckCompare.place(city: "", country: ""), .notFound)
    }

    func testFlagsCarryIntoTheLine() {
        var o = clean()
        var exit = info(v4)
        exit.datacenter = true
        exit.vpn = true
        o.ipv4 = .success(exit)
        let table = NetCheckCompare.table(o)
        XCTAssertEqual(row(table, .ipv4)?.lines.first?.flags, [.hosting, .vpn])
        XCTAssertEqual(row(table, .webrtc)?.lines.first?.flags, [.hosting, .vpn], "借用的那一条也带上")
        XCTAssertEqual(table.conclusion, .consistent, "小标签不影响结论")
    }

    // MARK: - 报告

    private var words: NetCheckCompare.ReportWords {
        NetCheckCompare.ReportWords(
            rowTitle: { $0.serverCount.map { "DNS(\($0))" } ?? $0.item.rawValue },
            value: { value in
                switch value {
                case .text(let text): return text
                case .noIPv6: return "none"
                case .notFound: return "?"
                case .noPublicAddress: return "no public"
                case .servers(let count): return "\(count)x"
                case .systemZone(let zone): return "sys " + (zone ?? "?")
                case .ipZone(let zone): return "ip " + (zone ?? "?")
                case .empty: return ""
                }
            },
            failure: { failure in
                if case .failed(let why) = failure { return "failed: " + why }
                return "failed"
            },
            flag: { $0 == .hosting ? "DC" : "flag" },
            mismatch: "(≠)", colon: ": ")
    }

    func testReportMarksMismatchedCells() {
        var o = clean()
        o.dns = dnsOf(["Singapore", "Singapore", "United States"])
        var exit = info(v4)
        exit.datacenter = true
        o.ipv4 = .success(exit)
        o.ipv6 = .failure(NetCheckFailure("down"))
        let lines = NetCheckCompare.reportLines(NetCheckCompare.table(o), words: words)
        XCTAssertEqual(lines, [
            "ipv4: 8.219.158.59 · Singapore · Singapore · \(alibaba) · AS45102 [DC]",
            "ipv6: failed: down",
            "DNS(3): 1x · Singapore · DNS 0 · AS64500",
            "DNS(3): 1x · Singapore · DNS 1 · AS64501",
            "DNS(3): 1x · United States(≠) · DNS 2 · AS64502",
            "webrtc: 8.219.158.59 · Singapore · Singapore · \(alibaba) · AS45102 [DC]",
            "timezone: sys Asia/Singapore · ip Asia/Singapore",
        ])
    }

    func testReportMarkGoesBeforeTheTags() {
        // 归属对不上又带小标签：标记跟着归属，小标签在最后
        var o = clean()
        var exit = info(v4)
        exit.datacenter = true
        o.ipv4 = .success(exit)
        o.webrtc = nil
        o.ipv6 = .success(info(v6, asn: 4657, network: "StarHub Ltd"))
        let lines = NetCheckCompare.reportLines(NetCheckCompare.table(o), words: words)
        XCTAssertEqual(lines.first, "ipv4: 8.219.158.59 · Singapore · Singapore · \(alibaba) · AS45102(≠) [DC]")
        XCTAssertEqual(lines[1], "ipv6: 2406:da18::7 · Singapore · Singapore · StarHub Ltd · AS4657(≠)")
    }
}
