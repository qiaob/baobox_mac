import Foundation
import XCTest

/// 引擎的监听组合与桥的开关（docs/packet-capture/CONTROL.md §2.1）。
final class EngineLaunchTests: XCTestCase {

    func testLocalOnly() {
        let listeners = EngineListeners(port: 9090, lan: false, wireguardPort: nil)
        XCTAssertEqual(listeners.modeArguments(keyFile: "/k.json"),
                       ["--mode", "regular@127.0.0.1:9090", "--mode", "socks5@127.0.0.1:9092"])
    }

    /// 手动代理或给其他设备装证书：HTTP 代理听局域网；SOCKS 永远只听本机；WireGuard 开着才加。
    func testLANAndWireGuard() {
        let listeners = EngineListeners(port: 19640, lan: true, wireguardPort: 19643)
        XCTAssertEqual(listeners.modeArguments(keyFile: "/a b/wireguard.json"),
                       ["--mode", "regular@0.0.0.0:19640", "--mode", "socks5@127.0.0.1:19642",
                        "--mode", "wireguard:/a b/wireguard.json@19643"])
    }

    func testListenersEquality() {
        let base = EngineListeners(port: 9090, lan: false, wireguardPort: nil)
        XCTAssertNotEqual(base, EngineListeners(port: 9090, lan: true, wireguardPort: nil))
        XCTAssertNotEqual(base, EngineListeners(port: 9090, lan: false, wireguardPort: 51820))
        XCTAssertEqual(base, EngineListeners(port: 9090, lan: false, wireguardPort: nil))
    }

    func testNeighbourNeverOverflows() {
        XCTAssertEqual(EngineListeners.neighbour(of: 9090, offset: 2), 9092)
        XCTAssertEqual(EngineListeners.neighbour(of: 65535, offset: 2), 65533)
        XCTAssertEqual(EngineListeners(port: 65534, lan: false, wireguardPort: nil).socksPort, 65532)
    }

    func testFlagOptions() {
        let flags = BridgeFlags(record: false, lanProxy: true, macTCP: false, pagePort: 9091)
        XCTAssertEqual(flags.optionArguments, [
            "--set", "baobox_record=false", "--set", "baobox_lan_proxy=true",
            "--set", "baobox_mac_tcp=false", "--set", "baobox_page_port=9091",
        ])
    }

    /// 只发变了的。
    func testFlagCommands() {
        let before = BridgeFlags(record: true, lanProxy: false, macTCP: false, pagePort: 0)
        XCTAssertEqual(before.commands(toReach: before), [])
        var after = before
        after.record = false
        after.pagePort = 9091
        XCTAssertEqual(before.commands(toReach: after), [.record(false), .pagePort(9091)])
        after = before
        after.lanProxy = true
        after.macTCP = true
        XCTAssertEqual(before.commands(toReach: after), [.lanProxy(true), .macTCP(true)])
    }
}
