import XCTest

final class ProxyPACTests: XCTestCase {
    func testProxyFirstThenDirect() {
        let script = ProxyPAC.script(proxyHost: "192.168.0.9", proxyPort: 9090)
        XCTAssertTrue(script.contains("function FindProxyForURL(url, host)"))
        XCTAssertTrue(script.contains("return \"PROXY 192.168.0.9:9090; DIRECT\";"))
    }

    func testTheMacItselfIsReachedDirectly() {
        let script = ProxyPAC.script(proxyHost: "192.168.0.9", proxyPort: 9090)
        XCTAssertTrue(script.contains("var own = [\"192.168.0.9\"];"))
        XCTAssertTrue(script.contains("isPlainHostName(h)"))
        XCTAssertTrue(script.contains("shExpMatch(h, \"*.local\")"))
        // 直连那一支排在走代理之前
        let direct = script.range(of: "return \"DIRECT\";")
        let proxy = script.range(of: "return \"PROXY")
        XCTAssertNotNil(direct)
        XCTAssertNotNil(proxy)
        if let direct, let proxy { XCTAssertTrue(direct.lowerBound < proxy.lowerBound) }
    }

    func testProxyByLocalNameKeepsTheIPDirectToo() {
        let script = ProxyPAC.script(proxyHost: "My-Mac.local", proxyPort: 9090,
                                     ownHosts: ["192.168.0.9", "My-Mac.local", ""])
        XCTAssertTrue(script.contains("return \"PROXY My-Mac.local:9090; DIRECT\";"))
        // 比较时都转成小写；名字不重复，空的不要
        XCTAssertTrue(script.contains("var own = [\"my-mac.local\", \"192.168.0.9\"];"))
    }

    func testHostCannotBreakOutOfTheStringLiteral() {
        let script = ProxyPAC.script(proxyHost: "a\"; evil(); \"\\\n", proxyPort: 1)
        XCTAssertFalse(script.contains("\"; evil(); \""))
        XCTAssertTrue(script.contains("PROXY a; evil(); :1; DIRECT"))
    }

    func testSafeHostName() {
        XCTAssertTrue(ProxyPAC.isSafeHostName("qiaodeMacBook-Pro"))
        XCTAssertTrue(ProxyPAC.isSafeHostName("my-mac.local"))
        XCTAssertFalse(ProxyPAC.isSafeHostName(""))
        XCTAssertFalse(ProxyPAC.isSafeHostName("my mac"))
        XCTAssertFalse(ProxyPAC.isSafeHostName("mac\"x"))
        XCTAssertFalse(ProxyPAC.isSafeHostName("乔的电脑"))
    }
}
