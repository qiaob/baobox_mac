import CryptoKit
import Foundation

/// 局域网模式的请求签名（#98，docs/phone-transfer/TECH_DESIGN.md §3.4）。纯函数，服务端队列上调用。
///
/// 页面走 http，内容是明文；能做到的是**令牌不上网、请求伪造不了**：
/// - 二维码地址把令牌放在 `#` 后面，浏览器不发给服务端；
/// - 每个接口请求带 `c`（设备 id）、`ts` + `n`（毫秒时间戳 + 随机数，防重放）或 `exp`（下载链接的过期时刻），
///   最后一个参数是 `sig` = HMAC-SHA256(密钥, 方法 \n 路径 \n 去掉 sig 的原始查询串) 的十六进制；
/// - 批准前用令牌签名；批准后服务端给这台设备一把自己的密钥（用令牌派生的一次性掩码异或后再传），之后只认它。
enum LANAuth {
    /// `ts` 与本机时钟最多差多少（手机一般自动对时）。
    static let clockWindow: TimeInterval = 10 * 60
    /// 随机数记多久（> 2 × clockWindow，窗口内重放都能认出来）。
    static let nonceTTL: TimeInterval = 25 * 60
    /// 下载链接（`<img>` / `<a download>` 用，加不了随机数）最长有效期。
    static let maxLinkLifetime: TimeInterval = 24 * 60 * 60
    /// 已批准的设备多久没有请求就作废，要重新扫码、重新允许。
    static let idleExpiry: TimeInterval = 30 * 60

    /// 令牌（二维码里那串）当密钥：直接用它的 UTF-8 字节，手机那边同样拿字符串算。
    static func key(token: String) -> SymmetricKey {
        SymmetricKey(data: Data(token.utf8))
    }

    /// 原始查询串拆成「去掉 sig 的部分」和 sig。sig 必须是最后一个参数、64 位十六进制；不是就 nil。
    static func splitSignature(_ rawQuery: String) -> (unsigned: String, sig: String)? {
        guard let range = rawQuery.range(of: "&sig=", options: .backwards) else { return nil }
        let unsigned = String(rawQuery[..<range.lowerBound])
        let sig = String(rawQuery[range.upperBound...])
        guard sig.count == 64, sig.allSatisfy(\.isHexDigit), !unsigned.isEmpty else { return nil }
        return (unsigned, sig.lowercased())
    }

    static func canonical(method: String, path: String, unsignedQuery: String) -> Data {
        Data("\(method)\n\(path)\n\(unsignedQuery)".utf8)
    }

    static func signature(_ canonical: Data, key: SymmetricKey) -> String {
        hex(Data(HMAC<SHA256>.authenticationCode(for: canonical, using: key)))
    }

    /// 定长比较（`isValidAuthenticationCode` 内部是常量时间的）。
    static func verify(_ sig: String, canonical: Data, key: SymmetricKey) -> Bool {
        guard let mac = unhex(sig), mac.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: canonical, using: key)
    }

    /// 发给手机的设备密钥：dk ⊕ HMAC(登记时的令牌, "dk:" + 设备 id)。掩码只用这一次（设备 id 每台不同），
    /// 抓包的人没有令牌就解不出来。
    static func wrap(deviceKey: SymmetricKey, regKey: SymmetricKey, clientID: String) -> String {
        let mask = Data(HMAC<SHA256>.authenticationCode(for: Data("dk:\(clientID)".utf8), using: regKey))
        let raw = deviceKey.withUnsafeBytes { Data($0) }
        return hex(Data(zip(raw, mask).map { $0 ^ $1 }))
    }

    /// 审批框和手机上都显示的 4 位设备码，两边一致再点允许（防有人抢在你的手机前面登记）。
    static func deviceCode(regKey: SymmetricKey, clientID: String) -> String {
        let mac = Array(HMAC<SHA256>.authenticationCode(for: Data("fp:\(clientID)".utf8), using: regKey))
        let value = (Int(mac[0]) << 8 | Int(mac[1])) % 10_000
        return String(format: "%04d", value)
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func unhex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
