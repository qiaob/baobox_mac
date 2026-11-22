import Foundation
import XCTest

/// 引擎的监听组合与桥的开关（docs/packet-capture/CONTROL.md §2.1、WIREGUARD-DEVICES.md §4）。
final class EngineLaunchTests: XCTestCase {

    func testLocalOnly() {
        let listeners = EngineListeners(port: 9090, lan: false)
        XCTAssertEqual(listeners.modeArguments,
                       ["--mode", "regular@127.0.0.1:9090", "--mode", "socks5@127.0.0.1:9092"])
    }

    /// 手动代理或给其他设备装证书：HTTP 代理听局域网；SOCKS 永远只听本机；WireGuard 每台设备一个监听，按设备表的顺序。
    func testLANAndSeveralWireGuardDevices() {
        let listeners = EngineListeners(port: 19640, lan: true, wireguard: [
            WireGuardListener(keyFile: "/a b/wireguard/1111.json", port: 19643),
            WireGuardListener(keyFile: "/a b/wireguard/2222.json", port: 19644),
        ])
        XCTAssertEqual(listeners.modeArguments,
                       ["--mode", "regular@0.0.0.0:19640", "--mode", "socks5@127.0.0.1:19642",
                        "--mode", "wireguard:/a b/wireguard/1111.json@19643",
                        "--mode", "wireguard:/a b/wireguard/2222.json@19644"])
    }

    /// 加一台、删一台、换了顺序都算监听组合变了（要重启引擎）。
    func testListenersEquality() {
        let one = WireGuardListener(keyFile: "/k/1.json", port: 51820)
        let two = WireGuardListener(keyFile: "/k/2.json", port: 51821)
        let base = EngineListeners(port: 9090, lan: false)
        XCTAssertNotEqual(base, EngineListeners(port: 9090, lan: true))
        XCTAssertNotEqual(base, EngineListeners(port: 9090, lan: false, wireguard: [one]))
        XCTAssertNotEqual(EngineListeners(port: 9090, lan: false, wireguard: [one]),
                          EngineListeners(port: 9090, lan: false, wireguard: [one, two]))
        XCTAssertNotEqual(EngineListeners(port: 9090, lan: false, wireguard: [one, two]),
                          EngineListeners(port: 9090, lan: false, wireguard: [two, one]))
        XCTAssertEqual(base, EngineListeners(port: 9090, lan: false, wireguard: []))
    }

    func testNeighbourNeverOverflows() {
        XCTAssertEqual(EngineListeners.neighbour(of: 9090, offset: 2), 9092)
        XCTAssertEqual(EngineListeners.neighbour(of: 65535, offset: 2), 65533)
        XCTAssertEqual(EngineListeners(port: 65534, lan: false).socksPort, 65532)
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
