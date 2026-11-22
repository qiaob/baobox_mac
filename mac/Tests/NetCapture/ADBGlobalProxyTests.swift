import XCTest

/// Android 隐藏全局代理的读法（docs/packet-capture/CONTROL.md §12）。
final class ADBGlobalProxyTests: XCTestCase {
    func testUnsetValues() {
        XCTAssertNil(ADBGlobalProxy.parse("null"))
        XCTAssertNil(ADBGlobalProxy.parse("null\n"))
        XCTAssertNil(ADBGlobalProxy.parse(""))
        XCTAssertNil(ADBGlobalProxy.parse(":0"))
        XCTAssertNil(ADBGlobalProxy.parse("192.168.0.9:0"))
    }

    func testSetValues() {
        XCTAssertEqual(ADBGlobalProxy.parse("192.168.0.9:9090\n"), "192.168.0.9:9090")
        XCTAssertEqual(ADBGlobalProxy.parse("  127.0.0.1:19780 "), "127.0.0.1:19780")
        XCTAssertEqual(ADBGlobalProxy.parse("10.0.2.2:9090"), "10.0.2.2:9090")
    }
}
