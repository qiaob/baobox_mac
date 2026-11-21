import CryptoKit
import Foundation

// 网络抓包的纯逻辑（Foundation + CryptoKit，进 BaoboxTests）：手机经 WireGuard 接进来要的密钥与客户端配置。
// 见 docs/packet-capture/CONTROL.md §2.4。
//
// 引擎（mitmproxy 的 `--mode wireguard:<密钥文件>@<端口>`）只做服务器，一份配置一个对端：
// 隧道里客户端地址固定 10.0.0.1，DNS 10.0.0.53（引擎自己应答）。

/// 引擎认的密钥文件：`{"server_key": <base64>, "client_key": <base64>}`，两把都是 Curve25519 私钥（32 字节）。
/// 没有就由 Baobox 生成：这样引擎没起过也能出二维码；引擎读到已有的就照用，不改写（2026-11-21 实测）。
struct WireGuardKeys: Equatable, Sendable {
    var serverKey: Data
    var clientKey: Data

    /// 隧道里客户端（手机）的地址、DNS。引擎写死的，配置文本和设备名都用它。
    static let clientAddress = "10.0.0.1"
    static let dnsAddress = "10.0.0.53"

    static func generate() -> WireGuardKeys {
        WireGuardKeys(serverKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                      clientKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
    }

    /// 解密钥文件。不是 JSON、缺键、不是 32 字节的 base64 都返回 nil。
    static func decode(_ data: Data) -> WireGuardKeys? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = (object["server_key"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let client = (object["client_key"] as? String).flatMap({ Data(base64Encoded: $0) }),
              server.count == 32, client.count == 32 else { return nil }
        return WireGuardKeys(serverKey: server, clientKey: client)
    }

    func encoded() -> Data {
        let object = ["server_key": serverKey.base64EncodedString(), "client_key": clientKey.base64EncodedString()]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// 服务器（引擎）的公钥，写进客户端配置的 `[Peer]`。
    var serverPublicKey: String? {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: serverKey) else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// 客户端配置：二维码的内容，也是「复制配置」的内容。`endpoint` = `<Mac 的局域网 IP>:<端口>`。
    func clientConfig(endpoint: String) -> String? {
        guard let serverPublicKey else { return nil }
        return """
        [Interface]
        PrivateKey = \(clientKey.base64EncodedString())
        Address = \(Self.clientAddress)/32
        DNS = \(Self.dnsAddress)

        [Peer]
        PublicKey = \(serverPublicKey)
        AllowedIPs = 0.0.0.0/0
        Endpoint = \(endpoint)
        """
    }

    /// 隧道里的地址（10.0.0.x）：经 WireGuard 进来的设备。
    static func isTunnelAddress(_ ip: String) -> Bool {
        ip.hasPrefix("10.0.0.")
    }
}

/// 密钥文件的读写。权限 600（里面是隧道的私钥）。
enum WireGuardKeyFile {
    /// 读已有的；没有或读不出来就生成一份写下去。写不下去抛错（调用方报 `StorageWriteFailure`）。
    static func loadOrCreate(at url: URL) throws -> WireGuardKeys {
        if let data = try? Data(contentsOf: url), let keys = WireGuardKeys.decode(data) { return keys }
        return try replace(at: url)
    }

    /// 换一份新的（设置页「重新生成 WireGuard 密钥」）。扫过旧二维码的隧道从此连不上。
    @discardableResult
    static func replace(at url: URL) throws -> WireGuardKeys {
        let keys = WireGuardKeys.generate()
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 先以 600 建一个临时文件再改名换上：私钥一刻也不以别的权限落在盘上，换的那一下是原子的。
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: keys.encoded(),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return keys
    }
}
