import Foundation
import XCTest

/// IP 检测的解析与地址分类（docs/netcheck/DESIGN.md）。回包样本与 baobox_shared 的 Rust 测试同一批。比对与表格在 NetCheckCompareTests。
final class NetCheckLogicTests: XCTestCase {

    /// 不带 key 的回包（ipapi.is 2026-11 实测，gcp-us 出口节点）
    private let anonGCP = #"{"ip":"34.3.107.77","is_bogon":false,"company":"Google LLC","asn":"AS15169 Google LLC","city":"The Dalles","region":"Oregon","country":"United States","lat":45.59456,"lon":-121.17868,"timezone":"America/Los_Angeles","docs":"https://ipapi.is/free-tier.html?ref=api"}"#
    /// 不带 key 的回包（ipapi.is 文档里的家宽例子）
    private let anonHome = #"{"ip":"82.66.115.249","is_bogon":false,"company":"Proxad / Free SAS","asn":"AS12322 Free SAS","city":"Goven","region":"Brittany","country":"France","timezone":"Europe/Paris"}"#
    /// 带 key 的回包（文档例子，删掉了用不到的字段）
    private let keyed = #"{"ip":"107.174.138.172","is_bogon":false,"is_datacenter":true,"is_tor":true,"is_proxy":false,"is_vpn":false,"company":{"name":"VPS ACE","type":"business"},"asn":{"asn":36352,"org":"HostPapa","type":"hosting"},"location":{"country":"United States","city":"Buffalo","timezone":"America/New_York"}}"#
    private let bashOK = #"[{"ip":"203.0.113.7","country_name":"Singapore","asn":"AS16509 Amazon.com, Inc.","org":"Amazon.com, Inc.","city_name":"Singapore","type":"ip"},{"ip":"172.253.2.1","country_name":"Singapore","asn":"AS15169 Google LLC","org":"Google LLC","city_name":"Singapore","type":"dns"},{"ip":"162.158.1.1","country_name":"Singapore","asn":"AS13335 Cloudflare, Inc.","org":"Cloudflare, Inc.","city_name":"Singapore","type":"dns"},{"ip":"DNS is not leaking.","type":"conclusion"}]"#
    private let bashNone = #"[{"ip":"203.0.113.9","country_name":"USA","asn":"AS396982 Google LLC","org":"Google LLC","type":"ip"},{"type":"error","text":"No DNS servers found. Try again..."}]"#

    private let hostMDNS = "candidate:1840965416 1 udp 2113937151 5f0b4c1e-9a2d-4d8e-b0c1-1a2b3c4d5e6f.local 54321 typ host generation 0"
    private let srflxHome = "a=candidate:842163050 1 udp 1677729535 82.66.115.249 61235 typ srflx raddr 192.168.0.23 rport 50000"

    private func info(_ text: String) -> NetCheckIPInfo {
        guard let parsed = NetCheckLogic.parseIPAPI(text) else {
            XCTFail("回包没解析出来")
            return NetCheckIPInfo(ip: "")
        }
        return parsed
    }

    private func dns(_ text: String) -> NetCheckDNSResult {
        NetCheckLogic.parseBashWS(text) ?? NetCheckDNSResult()
    }

    // MARK: 回包

    func testAnonymousIPAPIShape() {
        let parsed = info(anonGCP)
        XCTAssertEqual(parsed.asn, 15169)
        XCTAssertEqual(parsed.network, "Google LLC")
        XCTAssertEqual(parsed.timezone, "America/Los_Angeles")
        XCTAssertEqual(parsed.city, "The Dalles")
        XCTAssertEqual(parsed.country, "United States")
        XCTAssertNil(parsed.datacenter)
    }

    func testKeyedIPAPIShape() {
        let parsed = info(keyed)
        XCTAssertEqual(parsed.asn, 36352)
        XCTAssertEqual(parsed.network, "HostPapa")
        XCTAssertEqual(parsed.company, "VPS ACE")
        XCTAssertEqual(parsed.city, "Buffalo")
        XCTAssertEqual(parsed.datacenter, true)
        XCTAssertEqual(parsed.tor, true)
        XCTAssertEqual(parsed.vpn, false)
    }

    func testGarbageAndBogonsAreNotAnAnswer() {
        XCTAssertNil(NetCheckLogic.parseIPAPI("<html>rate limited</html>"))
        XCTAssertNil(NetCheckLogic.parseIPAPI(#"{"error":"x"}"#))
        XCTAssertNil(NetCheckLogic.parseIPAPI(#"{"ip":"10.0.0.1","is_bogon":true,"asn":null}"#))
    }

    func testFlagsFallBackToTheCloudTable() {
        // 没有机房判定（不带 key）：ASN 在云厂商表里就是机房
        XCTAssertEqual(info(anonGCP).flags, [.hosting])
        XCTAssertEqual(info(anonHome).flags, [])
        // 带 key：照服务的判定
        XCTAssertEqual(info(keyed).flags, [.hosting, .tor])
        var notDC = info(anonGCP)
        notDC.datacenter = false
        XCTAssertEqual(notDC.flags, [], "服务说不是机房就信它")
        var everything = NetCheckIPInfo(ip: "1.2.3.4")
        everything.datacenter = true
        everything.vpn = true
        everything.proxy = true
        everything.tor = true
        XCTAssertEqual(everything.flags, [.hosting, .vpn, .proxy, .tor])
    }

    func testBashWSRecordsAndErrors() {
        let ok = dns(bashOK)
        XCTAssertEqual(ok.resolvers.count, 2, "只收 dns 记录（ip / conclusion 不用）")
        XCTAssertEqual(ok.resolvers[0].asn, 15169)
        XCTAssertEqual(ok.resolvers[0].network, "Google LLC")
        XCTAssertEqual(ok.resolvers[0].country, "Singapore")
        XCTAssertNil(ok.error)
        let none = dns(bashNone)
        XCTAssertEqual(none.error, "No DNS servers found. Try again...")
        XCTAssertTrue(none.resolvers.isEmpty)
        XCTAssertNil(NetCheckLogic.parseBashWS(#"{"error":"x"}"#))
    }

    // MARK: ICE 与地址

    func testCandidates() {
        let c = NetCheckLogic.parseCandidate(srflxHome)
        XCTAssertEqual(c?.kind, .serverReflexive)
        XCTAssertEqual(c?.address, "82.66.115.249")
        XCTAssertEqual(c?.transport, "udp")
        XCTAssertEqual(NetCheckLogic.parseCandidate(hostMDNS)?.isMDNS, true)
        XCTAssertNil(NetCheckLogic.parseCandidate("candidate:1 1 udp 1 1.2.3.4 5 typ weird"))
        XCTAssertNil(NetCheckLogic.parseCandidate("not a candidate"))
        XCTAssertNil(NetCheckLogic.parseCandidate("candidate:1 1 udp"))
    }

    func testAddressClassification() {
        XCTAssertTrue(NetCheckLogic.isPublic("34.3.107.77"))
        XCTAssertTrue(NetCheckLogic.isPublic("2406:3003::1"))
        XCTAssertFalse(NetCheckLogic.isPublic("192.168.0.23"))
        XCTAssertFalse(NetCheckLogic.isPublic("100.101.102.103"), "Tailscale / 运营商级 NAT 不算公网")
        XCTAssertFalse(NetCheckLogic.isPublic("fd7a:115c:a1e0::1"))
        XCTAssertFalse(NetCheckLogic.isPublic("fe80::1"))
        XCTAssertFalse(NetCheckLogic.isPublic("abc.local"))
        XCTAssertFalse(NetCheckLogic.isPublic("256.1.1.1"))
        XCTAssertTrue(NetCheckLogic.sameAddress("2001:db8::1", "2001:0db8:0:0::1"))
        XCTAssertFalse(NetCheckLogic.sameAddress("1.2.3.4", "1.2.3.5"))
    }

    func testSameNetwork() {
        XCTAssertTrue(NetCheckLogic.sameNetwork(15169, 15169))
        XCTAssertTrue(NetCheckLogic.sameNetwork(15169, 396982), "Google 的两个 ASN 算同一家")
        XCTAssertTrue(NetCheckLogic.sameNetwork(16509, 14618), "AWS 的两个 ASN 算同一家")
        XCTAssertFalse(NetCheckLogic.sameNetwork(15169, 16509))
        XCTAssertFalse(NetCheckLogic.sameNetwork(4657, 9506))
    }

    // MARK: IPv6：没有 / 没测出来

    func testIPv6ImmediateFailureMeansNoIPv6() {
        // 没有 IPv6 的 Mac 上 URLSession 立刻报 -1009（2026-11-25 实测）；找不到、连不上同理
        XCTAssertTrue(NetCheckLogic.meansNoIPv6(URLError(.notConnectedToInternet)))
        XCTAssertTrue(NetCheckLogic.meansNoIPv6(URLError(.cannotFindHost)))
        XCTAssertTrue(NetCheckLogic.meansNoIPv6(URLError(.cannotConnectToHost)))
        XCTAssertTrue(NetCheckLogic.meansNoIPv6(URLError(.dnsLookupFailed)))
        // NSError 形式（URLSession 的回调给的）也认
        XCTAssertTrue(NetCheckLogic.meansNoIPv6(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)))
    }

    func testIPv6TimeoutsAndServiceErrorsAreNotMeasured() {
        XCTAssertFalse(NetCheckLogic.meansNoIPv6(URLError(.timedOut)))
        XCTAssertFalse(NetCheckLogic.meansNoIPv6(URLError(.secureConnectionFailed)))
        XCTAssertFalse(NetCheckLogic.meansNoIPv6(URLError(.badServerResponse)))
        XCTAssertFalse(NetCheckLogic.meansNoIPv6(URLError(.networkConnectionLost)))
        XCTAssertFalse(NetCheckLogic.meansNoIPv6(NetCheckFailure("HTTP 503")))
        XCTAssertFalse(NetCheckLogic.meansNoIPv6(NSError(domain: "other", code: -1009)))
    }

    // MARK: 并发、有总期限

    func testParallelWaitsForAllWhenTheyAreQuick() async {
        let started = Date()
        let done = await NetCheckParallel.run((0..<10).map { _ in { Thread.sleep(forTimeInterval: 0.05) } }, deadline: 5)
        XCTAssertEqual(done, 10)
        // 并发：十个 0.05 秒的活远不到 0.5 秒
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.45)
    }

    func testParallelStopsWaitingAtTheDeadline() async {
        let started = Date()
        let jobs: [@Sendable () -> Void] = [
            { Thread.sleep(forTimeInterval: 0.01) },
            { Thread.sleep(forTimeInterval: 0.01) },
            { Thread.sleep(forTimeInterval: 3) },
        ]
        let done = await NetCheckParallel.run(jobs, deadline: 0.3)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(done, 2, "到点只算已经回来的")
        XCTAssertGreaterThanOrEqual(elapsed, 0.29)
        XCTAssertLessThan(elapsed, 2, "没回来的不等")
    }

    func testParallelWithNothingToDo() async {
        let done = await NetCheckParallel.run([], deadline: 10)
        XCTAssertEqual(done, 0)
    }
}
