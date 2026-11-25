import Foundation
import XCTest

/// 网络泄露检测的纯逻辑（docs/netcheck/DESIGN.md）。回包样本与 baobox_shared 的 Rust 测试同一批。
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
    private let hostLAN = "candidate:3 1 udp 2122260223 192.168.0.23 50000 typ host generation 0"
    private let srflxExit = "candidate:842163049 1 udp 1677729535 34.3.107.77 61234 typ srflx raddr 0.0.0.0 rport 0"
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

    private func observations(_ exit: NetCheckIPInfo, webrtc: [String]? = nil,
                              timezone: String = "Asia/Singapore") -> NetCheckObservations {
        NetCheckObservations(ipv4: .success(exit), ipv6: .success(nil), dns: .success(dns(bashOK)),
                             systemTimezone: timezone, webrtc: webrtc.map { .success($0) })
    }

    private func finding(_ findings: [NetCheckFinding], _ item: NetCheckItem) -> NetCheckFinding? {
        findings.first { $0.item == item }
    }

    // MARK: 回包

    func testAnonymousIPAPIShape() {
        let parsed = info(anonGCP)
        XCTAssertEqual(parsed.asn, 15169)
        XCTAssertEqual(parsed.network, "Google LLC")
        XCTAssertEqual(parsed.timezone, "America/Los_Angeles")
        XCTAssertEqual(parsed.place, "The Dalles, United States")
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

    func testHostingFallsBackToTheCloudTable() {
        XCTAssertEqual(info(anonGCP).hosting, .some("Google Cloud"))
        XCTAssertNil(info(anonHome).hosting)
        XCTAssertEqual(info(keyed).hosting, .some("HostPapa"))
        var notDC = info(anonGCP)
        notDC.datacenter = false
        XCTAssertNil(notDC.hosting)
    }

    func testBashWSRecordsAndErrors() {
        let ok = dns(bashOK)
        XCTAssertEqual(ok.clients.count, 1)
        XCTAssertEqual(ok.resolvers.count, 2)
        XCTAssertEqual(ok.resolvers[0].asn, 15169)
        XCTAssertEqual(ok.conclusion, "DNS is not leaking.")
        let none = dns(bashNone)
        XCTAssertEqual(none.error, "No DNS servers found. Try again...")
        XCTAssertEqual(NetCheckLogic.judgeDNS(.success(none), real: NetCheckRealNetworks(parsing: "4657")).verdict,
                       .unknown)
        XCTAssertNil(NetCheckLogic.parseBashWS(#"{"error":"x"}"#))
    }

    func testRealNetworksParsing() {
        let real = NetCheckRealNetworks(parsing: "AS4657, 9506，as12322  foo")
        XCTAssertTrue(real.contains(4657))
        XCTAssertTrue(real.contains(9506))
        XCTAssertTrue(real.contains(12322))
        XCTAssertFalse(real.contains(15169))
        XCTAssertFalse(real.contains(nil))
        XCTAssertTrue(NetCheckRealNetworks(parsing: "  ").isEmpty)
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

    // MARK: 判定

    func testExitOnTheRealNetworkIsALeak() {
        let findings = NetCheckLogic.evaluate(observations(info(anonHome)), real: NetCheckRealNetworks(parsing: "AS12322"))
        XCTAssertEqual(findings[0].verdict, .leak)
        XCTAssertEqual(NetCheckLogic.overall(findings.map(\.verdict)), .leak)
    }

    func testCloudExitIsANotice() {
        let findings = NetCheckLogic.evaluate(observations(info(anonGCP)), real: NetCheckRealNetworks(parsing: "4657"))
        XCTAssertEqual(findings[0].verdict, .notice)
        XCTAssertEqual(findings[0].reason, .exitFlagged(info(anonGCP).describe, [.hosting("Google Cloud")]))
    }

    func testResolverOnTheRealNetworkIsADNSLeak() {
        var o = observations(info(anonGCP))
        var result = dns(bashOK)
        result.resolvers.append(NetCheckResolver(ip: "203.116.1.78", asn: 4657, network: "StarHub"))
        o.dns = .success(result)
        let findings = NetCheckLogic.evaluate(o, real: NetCheckRealNetworks(parsing: "4657"))
        XCTAssertEqual(finding(findings, .dns)?.verdict, .leak)
    }

    func testDNSOwnersAreGrouped() {
        let found = finding(NetCheckLogic.evaluate(observations(info(anonGCP)), real: NetCheckRealNetworks(parsing: "4657")), .dns)
        XCTAssertEqual(found?.reason, .dnsClean(count: 2, owners: ["Google LLC", "Cloudflare, Inc."]))
        let undeclared = finding(NetCheckLogic.evaluate(observations(info(anonGCP)), real: NetCheckRealNetworks()), .dns)
        XCTAssertEqual(undeclared?.verdict, .unknown)
    }

    func testIPv6FromAnotherNetworkIsALeak() {
        var o = observations(info(anonGCP))
        o.ipv6 = .success(NetCheckIPInfo(ip: "2406:3003::1", asn: 4657, network: "StarHub"))
        XCTAssertEqual(finding(NetCheckLogic.evaluate(o, real: NetCheckRealNetworks()), .ipv6)?.verdict, .leak)
        XCTAssertEqual(finding(NetCheckLogic.evaluate(observations(info(anonGCP)), real: NetCheckRealNetworks()), .ipv6)?.reason,
                       .noIPv6)
    }

    func testTimezone() {
        let mismatch = finding(NetCheckLogic.evaluate(observations(info(anonGCP)), real: NetCheckRealNetworks()), .timezone)
        XCTAssertEqual(mismatch?.reason, .timezoneMismatch(system: "Asia/Singapore", exit: "America/Los_Angeles"))
        let match = finding(NetCheckLogic.evaluate(observations(info(anonGCP), timezone: "America/Los_Angeles"),
                                                   real: NetCheckRealNetworks()), .timezone)
        XCTAssertEqual(match?.verdict, .ok)
    }

    func testFailuresAreUnknown() {
        let o = NetCheckObservations(ipv4: .failure(NetCheckFailure("down")), ipv6: .failure(NetCheckFailure("x")),
                                     dns: .failure(NetCheckFailure("y")), systemTimezone: nil,
                                     webrtc: .failure(NetCheckFailure("z")))
        let findings = NetCheckLogic.evaluate(o, real: NetCheckRealNetworks())
        XCTAssertTrue(findings.allSatisfy { $0.verdict == .unknown })
        XCTAssertEqual(findings[0].reason, .failed("down"))
    }

    func testWebRTC() {
        let real = NetCheckRealNetworks(parsing: "4657")
        func webrtc(_ lines: [String]) -> NetCheckFinding? {
            finding(NetCheckLogic.evaluate(observations(info(anonGCP), webrtc: lines), real: real), .webrtc)
        }
        XCTAssertEqual(webrtc([hostMDNS, srflxHome])?.reason, .webrtcLeak(["82.66.115.249"]))
        XCTAssertEqual(webrtc([hostMDNS, srflxExit])?.reason, .webrtcMatches)
        XCTAssertEqual(webrtc([hostLAN, srflxExit])?.reason, .webrtcLocal(["192.168.0.23"]))
        XCTAssertEqual(webrtc([])?.reason, .webrtcNothing)
        XCTAssertNil(finding(NetCheckLogic.evaluate(observations(info(anonGCP)), real: real), .webrtc),
                     "没测 WebRTC 就没有这一项")
        let order = NetCheckLogic.evaluate(observations(info(anonGCP), webrtc: [srflxExit]), real: real).map(\.item)
        XCTAssertEqual(order, [.exit, .ipv6, .dns, .webrtc, .timezone])
    }

    func testOverallPriority() {
        XCTAssertEqual(NetCheckLogic.overall([.ok, .notice]), .notice)
        XCTAssertEqual(NetCheckLogic.overall([.notice, .unknown]), .unknown)
        XCTAssertEqual(NetCheckLogic.overall([.unknown, .leak]), .leak)
        XCTAssertEqual(NetCheckLogic.overall([.ok]), .ok)
    }

    // MARK: 总结

    private func summary(_ o: NetCheckObservations, _ real: String) -> [NetCheckSummary] {
        let findings = NetCheckLogic.evaluate(o, real: NetCheckRealNetworks(parsing: real))
        return NetCheckLogic.summarize(o, findings: findings)
    }

    func testCleanTunnel() {
        let s = summary(observations(info(anonGCP), webrtc: [hostMDNS, srflxExit], timezone: "America/Los_Angeles"), "4657")
        XCTAssertEqual(s[0], NetCheckSummary(goal: .carrier, verdict: .ok, reason: .carrierClean))
        XCTAssertEqual(s[1], NetCheckSummary(goal: .location, verdict: .notice,
                                             reason: .locationHidden(place: "The Dalles, United States", hints: [.hostingExit])))
    }

    func testWebRTCLeakAnswersYesToBoth() {
        let s = summary(observations(info(anonGCP), webrtc: [srflxHome]), "4657")
        XCTAssertEqual(s[0].reason, .partialLeak([.webrtc]))
        XCTAssertEqual(s[1].reason, .ipLeak([.webrtc]))
    }

    func testDNSLeakShowsTheCarrierNotTheLocation() {
        var o = observations(info(anonGCP), webrtc: [srflxExit], timezone: "America/Los_Angeles")
        var result = dns(bashOK)
        result.resolvers[0].asn = 4657
        o.dns = .success(result)
        let s = summary(o, "4657")
        XCTAssertEqual(s[0].verdict, .leak)
        XCTAssertEqual(s[1].verdict, .notice)
        XCTAssertEqual(s[1].reason, .locationHidden(place: "The Dalles, United States", hints: [.hostingExit, .dnsCarrier]))
    }

    func testTunnelOff() {
        let s = summary(observations(info(anonHome)), "12322")
        XCTAssertEqual(s[0].reason, .tunnelOff)
        XCTAssertEqual(s[1].reason, .ipLeak([.exit]))
    }

    func testUndeclaredRealNetworksLeaveTheCarrierOpen() {
        let s = summary(observations(info(anonGCP), webrtc: [srflxExit]), "")
        XCTAssertEqual(s[0].reason, .undetermined([.dns]))
    }
}
