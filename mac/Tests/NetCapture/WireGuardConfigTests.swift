import Foundation
import XCTest

/// WireGuard 的密钥文件与客户端配置（docs/packet-capture/CONTROL.md §2.4）。
final class WireGuardConfigTests: XCTestCase {

    private func hex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    /// RFC 7748 §6.1 的 X25519 样例：Alice 的私钥 → 公钥。
    func testPublicKeyFromRFC7748Vector() {
        let keys = WireGuardKeys(serverKey: hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"),
                                 clientKey: Data(repeating: 1, count: 32))
        XCTAssertEqual(keys.serverPublicKey,
                       hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a").base64EncodedString())
    }

    /// 和真引擎（mitmproxy 12.3.1，`--mode wireguard:<文件>@19653`）读同一份密钥文件打印出来的配置逐字一致。
    func testConfigMatchesWhatTheEnginePrinted() throws {
        let file = Data(#"{"server_key": "HNDO4mEg/tv94E+zn7WlhQWv703RAkOfVxjJ4SPNfPU=", "client_key": "rmEAxLdL81JBeun5mehNW8dJmxmT+NDKe5KJqIwJkcg="}"#.utf8)
        let keys = try XCTUnwrap(WireGuardKeys.decode(file))
        let printed = """
        [Interface]
        PrivateKey = rmEAxLdL81JBeun5mehNW8dJmxmT+NDKe5KJqIwJkcg=
        Address = 10.0.0.1/32
        DNS = 10.0.0.53

        [Peer]
        PublicKey = M8WPfspsC4x5e377o3gPft/d3zFx7A+H95MxGSd2u3M=
        AllowedIPs = 0.0.0.0/0
        Endpoint = 192.168.0.9:19653
        """
        let config = try XCTUnwrap(keys.clientConfig(endpoint: "192.168.0.9:19653"))
        XCTAssertEqual(config.components(separatedBy: "\n"), printed.components(separatedBy: "\n"))
    }

    func testDecodeRejectsBadFiles() {
        XCTAssertNil(WireGuardKeys.decode(Data("not json".utf8)))
        XCTAssertNil(WireGuardKeys.decode(Data(#"{"server_key":"AAAA","client_key":"AAAA"}"#.utf8)))
        XCTAssertNil(WireGuardKeys.decode(Data(#"{"server_key":"HNDO4mEg/tv94E+zn7WlhQWv703RAkOfVxjJ4SPNfPU="}"#.utf8)))
    }

    func testEncodeRoundTrip() {
        let keys = WireGuardKeys.generate()
        XCTAssertEqual(keys.serverKey.count, 32)
        XCTAssertNotEqual(keys.serverKey, keys.clientKey)
        XCTAssertEqual(WireGuardKeys.decode(keys.encoded()), keys)
    }

    /// 没有就生成（权限 600），有就照用；坏了重新生成；`replace` 换一份新的。
    func testKeyFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("wireguard.json")
        let first = try WireGuardKeyFile.loadOrCreate(at: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try WireGuardKeyFile.loadOrCreate(at: url), first)

        try Data("garbage".utf8).write(to: url)
        let rebuilt = try WireGuardKeyFile.loadOrCreate(at: url)
        XCTAssertNotEqual(rebuilt, first)
        let replaced = try WireGuardKeyFile.replace(at: url)
        XCTAssertNotEqual(replaced, rebuilt)
        XCTAssertEqual(try WireGuardKeyFile.loadOrCreate(at: url), replaced)
        // 没有留下临时文件。
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["wireguard.json"])
    }

    func testTunnelAddress() {
        XCTAssertTrue(WireGuardKeys.isTunnelAddress(WireGuardKeys.clientAddress))
        XCTAssertFalse(WireGuardKeys.isTunnelAddress("10.0.1.1"))
        XCTAssertFalse(WireGuardKeys.isTunnelAddress("192.168.0.9"))
    }
}
