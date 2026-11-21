import XCTest

final class ProxyPACTests: XCTestCase {
    func testProxyFirstThenDirect() {
        let script = ProxyPAC.script(proxyHost: "192.168.0.9", proxyPort: 9090)
        XCTAssertTrue(script.contains("function FindProxyForURL(url, host)"))
        XCTAssertTrue(script.contains("return \"PROXY 192.168.0.9:9090; DIRECT\";"))
    }

    func testTheMacItselfIsReachedDirectly() {
        let script = ProxyPAC.script(proxyHost: "192.168.0.9", proxyPort: 9090)
        XCTAssertTrue(script.contains("host === \"192.168.0.9\""))
        XCTAssertTrue(script.contains("isPlainHostName(host)"))
        // 直连那一支排在走代理之前
        let direct = script.range(of: "return \"DIRECT\";")
        let proxy = script.range(of: "return \"PROXY")
        XCTAssertNotNil(direct)
        XCTAssertNotNil(proxy)
        if let direct, let proxy { XCTAssertTrue(direct.lowerBound < proxy.lowerBound) }
    }

    func testHostCannotBreakOutOfTheStringLiteral() {
        let script = ProxyPAC.script(proxyHost: "a\"; evil(); \"\\\n", proxyPort: 1)
        XCTAssertFalse(script.contains("\"; evil(); \""))
        XCTAssertTrue(script.contains("PROXY a; evil(); :1; DIRECT"))
    }
}
