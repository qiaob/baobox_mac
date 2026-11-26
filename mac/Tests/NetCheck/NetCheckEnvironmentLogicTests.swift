import Foundation
import XCTest

/// 本机网络环境摘要的纯逻辑：系统代理、系统 DNS、活跃隧道过滤、主局域网网卡选择。
final class NetCheckEnvironmentLogicTests: XCTestCase {

    // MARK: - 系统代理

    func testParseEmptyProxies() {
        let empty = NetCheckEnvironmentLogic.parseProxies([:])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.entries, [])

        let disabled = NetCheckEnvironmentLogic.parseProxies([
            "HTTPEnable": 0,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": 7890,
            "SOCKSEnable": false,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": 7891,
        ])
        XCTAssertTrue(disabled.isEmpty)
    }

    func testParseMergesIdenticalHTTPAndHTTPSProxy() {
        let proxy = NetCheckEnvironmentLogic.parseProxies([
            "HTTPEnable": 1,
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": 7890,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": 7890,
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": 7891,
        ])
        XCTAssertFalse(proxy.isEmpty)
        XCTAssertEqual(proxy.http, "127.0.0.1:7890")
        XCTAssertEqual(proxy.https, "127.0.0.1:7890")
        XCTAssertEqual(proxy.socks, "127.0.0.1:7891")
        XCTAssertEqual(proxy.entries, ["HTTP(S) 127.0.0.1:7890", "SOCKS 127.0.0.1:7891"])
    }

    func testParseDistinctProxiesIPv6AndPAC() {
        let proxy = NetCheckEnvironmentLogic.parseProxies([
            "HTTPEnable": 1,
            "HTTPProxy": "::1",
            "HTTPPort": 8080,
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": 8443,
            "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString": "http://127.0.0.1:7890/proxy.pac",
        ])
        XCTAssertEqual(proxy.entries, ["HTTP [::1]:8080", "HTTPS 127.0.0.1:8443", "PAC (127.0.0.1)"])
    }

    func testParseProxyHandlesMalformedTypes() {
        let proxy = NetCheckEnvironmentLogic.parseProxies([
            "HTTPEnable": "yes",
            "HTTPProxy": 123,
            "HTTPSEnable": 1,
            "HTTPSProxy": "  ",
            "HTTPSPort": true,
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": true,
        ])
        XCTAssertNil(proxy.http)
        XCTAssertNil(proxy.https)
        XCTAssertEqual(proxy.socks, "127.0.0.1")
    }

    // MARK: - 系统 DNS

    func testParseDNSServers() {
        let servers = NetCheckEnvironmentLogic.parseDNSServers([
            "ServerAddresses": [" 198.18.0.2 ", "8.8.8.8", "198.18.0.2", "", 42, "2001:4860:4860::8888"],
        ])
        XCTAssertEqual(servers, ["198.18.0.2", "8.8.8.8", "2001:4860:4860::8888"])
        XCTAssertEqual(NetCheckEnvironmentLogic.parseDNSServers([:]), [])
    }

    // MARK: - 隧道筛选

    private func raw(_ name: String, _ address: String, isIPv4: Bool = true,
                     isUp: Bool = true, isRunning: Bool = true, isLoopback: Bool = false) -> NetCheckEnvironmentLogic.RawInterfaceAddress {
        NetCheckEnvironmentLogic.RawInterfaceAddress(name: name, address: address, isIPv4: isIPv4,
                                                     isUp: isUp, isRunning: isRunning, isLoopback: isLoopback)
    }

    func testFilterTunnelsSkipsIdleSystemUtunsAndKeepsActiveVPN() {
        let items = [
            // 系统自带只有链路本地 IPv6（带 %scope 后缀）的空闲 utun：必须过滤
            raw("utun0", "fe80::1234%utun0", isIPv4: false),
            raw("utun1", "fe80::5678%utun1", isIPv4: false),
            // 停用的 utun：过滤
            raw("utun2", "10.0.0.2", isUp: false),
            // 普通物理网卡：不算隧道
            raw("en0", "192.168.1.23"),
            // Clash / Surge Fake-IP TUN
            raw("utun10", "fd00::1", isIPv4: false),
            raw("utun10", "198.18.0.1", isIPv4: true),
            // Tailscale 隧道
            raw("utun4", "100.101.102.103", isIPv4: true),
            raw("utun4", "fd7a:115c:a1e0::1", isIPv4: false),
        ]
        let tunnels = NetCheckEnvironmentLogic.filterTunnels(items)
        XCTAssertEqual(tunnels.map(\.interface), ["utun4", "utun10"], "按自然序排，utun4 在 utun10 前面")
        XCTAssertEqual(tunnels[0].addresses, ["100.101.102.103", "fd7a:115c:a1e0::1"])
        XCTAssertEqual(tunnels[0].label, "utun4 (100.101.102.103)")
        XCTAssertFalse(tunnels[0].isFakeIP)
        XCTAssertEqual(tunnels[1].addresses, ["198.18.0.1", "fd00::1"], "IPv4 排在 IPv6 前面")
        XCTAssertEqual(tunnels[1].label, "utun10 (198.18.0.1)")
        XCTAssertTrue(tunnels[1].isFakeIP)
    }

    // MARK: - 主局域网网卡

    func testPickPrimaryLAN() {
        let items = [
            raw("bridge100", "192.168.64.1"),
            raw("utun4", "198.18.0.1"),
            raw("en0", "169.254.10.20"),
            raw("en0", "192.168.1.23"),
            raw("en5", "10.0.0.8"),
        ]
        // 默认路由走 en5（有线网卡）：优先选它
        XCTAssertEqual(NetCheckEnvironmentLogic.pickPrimaryLAN(items, outboundIP: "10.0.0.8"),
                       NetCheckLAN(interface: "en5", ip: "10.0.0.8"))
        // 默认路由走 VPN（198.18.0.1 不在局域网候选里）：退回排最前的物理网卡 en0，且跳过 169.254.x.x
        XCTAssertEqual(NetCheckEnvironmentLogic.pickPrimaryLAN(items, outboundIP: "198.18.0.1"),
                       NetCheckLAN(interface: "en0", ip: "192.168.1.23"))
        XCTAssertNil(NetCheckEnvironmentLogic.pickPrimaryLAN([raw("utun4", "198.18.0.1")], outboundIP: nil))
    }
}
