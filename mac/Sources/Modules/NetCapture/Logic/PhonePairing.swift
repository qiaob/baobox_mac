import Foundation

/// 扫码即放行：二维码里的配置页地址带一个口令（`?k=…`）。口令只显示在这台 Mac 的屏幕上，
/// 带着它来开配置页的设备，就当作用户本人拿着的那台，直接放行，不用再回 Mac 上点「允许」。
/// 手输地址没带口令的，照旧走「允许」。
enum PhonePairing {
    /// 去掉了容易看错的 0 o 1 l i。
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    /// 新口令，6 位。每次启动 App 换一个。
    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    /// 请求行里的目标（如 `/?k=abc234`）带的口令对不对。口令为空一律不对。
    static func tokenMatches(requestTarget: String, token: String) -> Bool {
        guard !token.isEmpty, let mark = requestTarget.firstIndex(of: "?") else { return false }
        let query = requestTarget[requestTarget.index(after: mark)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0] == "k", parts[1] == token { return true }
        }
        return false
    }

    /// 连接对端的地址整理成引擎那边用的写法：去掉网卡后缀（`%en0`）和 IPv4 映射前缀（`::ffff:`）。
    static func deviceAddress(_ raw: String) -> String {
        var text = raw
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        if text.lowercased().hasPrefix("::ffff:") { text = String(text.dropFirst(7)) }
        return text
    }

    /// 该放行哪台设备。
    /// - `remote`：连到配置页的对端地址。
    /// - `forwardedClient`：请求是经引擎转过来的（手机已经设了代理）时，桥在 `X-Baobox-Client` 里写的真正来源。
    ///   只有对端是这台 Mac 自己（回环，或 `localAddresses` 里的地址）时才认这个头 —— 别的设备写这个头没用。
    /// 没有可放行的（比如 Mac 自己开的页面）返回 nil。
    static func deviceToAdmit(remote: String, forwardedClient: String?, localAddresses: Set<String>) -> String? {
        let remote = deviceAddress(remote)
        let fromThisMac = isLoopback(remote) || localAddresses.contains(remote)
        if fromThisMac, let forwarded = forwardedClient.map(deviceAddress), !forwarded.isEmpty {
            return isLoopback(forwarded) ? nil : forwarded
        }
        if remote.isEmpty || isLoopback(remote) { return nil }
        return remote
    }

    static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1" || address == "localhost"
    }
}
