import XCTest

final class PhonePairingTests: XCTestCase {
    func testTokenShape() {
        let token = PhonePairing.makeToken()
        XCTAssertEqual(token.count, 6)
        XCTAssertTrue(token.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) })
        XCTAssertNotEqual(PhonePairing.makeToken() + PhonePairing.makeToken(), token + token)
    }

    func testTokenMatchesOnlyTheExactValue() {
        XCTAssertTrue(PhonePairing.tokenMatches(requestTarget: "/?k=abc234", token: "abc234"))
        XCTAssertTrue(PhonePairing.tokenMatches(requestTarget: "/?x=1&k=abc234&y=2", token: "abc234"))
        XCTAssertFalse(PhonePairing.tokenMatches(requestTarget: "/?k=abc23", token: "abc234"))
        XCTAssertFalse(PhonePairing.tokenMatches(requestTarget: "/?k=abc2345", token: "abc234"))
        XCTAssertFalse(PhonePairing.tokenMatches(requestTarget: "/?kk=abc234", token: "abc234"))
        XCTAssertFalse(PhonePairing.tokenMatches(requestTarget: "/", token: "abc234"))
        XCTAssertFalse(PhonePairing.tokenMatches(requestTarget: "/abc234", token: "abc234"))
    }

    func testQueryValue() {
        XCTAssertEqual(PhonePairing.queryValue("h", in: "/proxy?h=local"), "local")
        XCTAssertEqual(PhonePairing.queryValue("h", in: "/proxy.pac?k=abc&h=local"), "local")
        XCTAssertEqual(PhonePairing.queryValue("k", in: "/?k="), "")
        XCTAssertNil(PhonePairing.queryValue("h", in: "/proxy"))
        XCTAssertNil(PhonePairing.queryValue("h", in: "/proxy?hh=local"))
        XCTAssertNil(PhonePairing.queryValue("h", in: "/h=local"))
    }

    func testEmptyTokenNeverMatches() {
        XCTAssertFalse(PhonePairing.tokenMatches(requestTarget: "/?k=", token: ""))
        XCTAssertFalse(PhonePairing.tokenMatches(requestTarget: "/", token: ""))
    }

    func testDeviceToAdmit() {
        let local: Set<String> = ["192.168.0.9"]
        // 手机直接连配置页
        XCTAssertEqual(PhonePairing.deviceToAdmit(remote: "192.168.0.5", forwardedClient: nil, localAddresses: local), "192.168.0.5")
        // 手机已设代理，请求经引擎转过来：认桥写的来源
        XCTAssertEqual(PhonePairing.deviceToAdmit(remote: "192.168.0.9", forwardedClient: "192.168.0.5", localAddresses: local), "192.168.0.5")
        XCTAssertEqual(PhonePairing.deviceToAdmit(remote: "127.0.0.1", forwardedClient: "192.168.0.5", localAddresses: local), "192.168.0.5")
        // 别的设备自己写这个头：不认，放行的是它自己
        XCTAssertEqual(PhonePairing.deviceToAdmit(remote: "192.168.0.7", forwardedClient: "192.168.0.5", localAddresses: local), "192.168.0.7")
        // Mac 自己开的页面：没有可放行的
        XCTAssertNil(PhonePairing.deviceToAdmit(remote: "127.0.0.1", forwardedClient: nil, localAddresses: local))
        XCTAssertNil(PhonePairing.deviceToAdmit(remote: "127.0.0.1", forwardedClient: "127.0.0.1", localAddresses: local))
        // 模拟器经 NAT 出来，看上去就是 Mac 自己的局域网地址，又没有桥写的头：照对端放行
        XCTAssertEqual(PhonePairing.deviceToAdmit(remote: "192.168.0.9", forwardedClient: nil, localAddresses: local), "192.168.0.9")
    }

    func testDeviceAddress() {
        XCTAssertEqual(PhonePairing.deviceAddress("192.168.0.5"), "192.168.0.5")
        XCTAssertEqual(PhonePairing.deviceAddress("::ffff:192.168.0.5"), "192.168.0.5")
        XCTAssertEqual(PhonePairing.deviceAddress("fe80::1%en0"), "fe80::1")
        XCTAssertTrue(PhonePairing.isLoopback("127.0.0.1"))
        XCTAssertTrue(PhonePairing.isLoopback("::1"))
        XCTAssertFalse(PhonePairing.isLoopback("192.168.0.5"))
    }
}
