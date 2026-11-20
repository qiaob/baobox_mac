import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：发给引擎的指令与解密范围。
// 见 docs/packet-capture/TECH_DESIGN.md §4.2。

/// 解密范围：哪些域名的 HTTPS 要解开看。域名按后缀匹配（`x.com` 匹配 `api.x.com`），匹配在桥脚本里做。
struct DecryptScope: Equatable, Sendable {
    enum Mode: String, Sendable {
        /// 全部解密。
        case all
        /// 只解密列出的域名。
        case allow
        /// 列出的域名不解密，其余解密。
        case deny
    }

    var mode: Mode
    var domains: [String]

    static let all = DecryptScope(mode: .all, domains: [])

    /// 从设置里的三个值得到范围。`setting` 是 `all` 或 `allowlist`（v1 的键值，沿用）：
    /// - `allowlist`：只解密 `allowText` 里的域名。名单空着等于什么都不解密，照字面执行。
    /// - `all`：`denyText` 里有域名就排除它们，没有就全部解密。
    static func from(setting: String, allowText: String, denyText: String) -> DecryptScope {
        if setting == "allowlist" {
            return DecryptScope(mode: .allow, domains: parseDomains(allowText))
        }
        let deny = parseDomains(denyText)
        return deny.isEmpty ? .all : DecryptScope(mode: .deny, domains: deny)
    }

    /// 把用户填的文本拆成域名：换行、逗号、空格都算分隔；去掉 `*.` 前缀、协议头、路径与端口；小写；去重保序。
    static func parseDomains(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " || $0 == "\t" || $0 == "\r" }) {
            var domain = piece.lowercased()
            if let range = domain.range(of: "://") { domain = String(domain[range.upperBound...]) }
            if let slash = domain.firstIndex(of: "/") { domain = String(domain[..<slash]) }
            if let colon = domain.firstIndex(of: ":") { domain = String(domain[..<colon]) }
            while domain.hasPrefix("*") || domain.hasPrefix(".") { domain.removeFirst() }
            while domain.hasSuffix(".") { domain.removeLast() }
            guard !domain.isEmpty, !seen.contains(domain) else { continue }
            seen.insert(domain)
            result.append(domain)
        }
        return result
    }

    /// 启动引擎时作为选项传进去的 JSON（`{"mode":…,"domains":[…]}`）。
    var json: String {
        let object: [String: Any] = ["mode": mode.rawValue, "domains": domains]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

/// 写进引擎标准输入的一条指令（一行 JSON）。
enum CaptureCommand: Equatable, Sendable {
    case shutdown
    case scope(DecryptScope)
    case allowDevice(String)
    case denyDevice(String)

    /// 带换行符的一行，直接写进管道。
    var line: Data {
        let object: [String: Any]
        switch self {
        case .shutdown:
            object = ["cmd": "shutdown"]
        case .scope(let scope):
            object = ["cmd": "scope", "mode": scope.mode.rawValue, "domains": scope.domains]
        case .allowDevice(let client):
            object = ["cmd": "allow_device", "client": client]
        case .denyDevice(let client):
            object = ["cmd": "deny_device", "client": client]
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}

/// 给终端 / 脚本用的环境变量（docs/packet-capture/TECH_DESIGN.md §6）。curl、Python、Node 不认系统代理，要靠这些。
enum CaptureShellEnv {
    /// `export …` 的若干行。`bundlePath` = 系统根证书 + CA 的合并文件；`caPath` = 只有 CA 的那张（Node 是「追加」语义）。
    static func exportLines(port: UInt16, bundlePath: String, caPath: String) -> [String] {
        let proxy = "http://127.0.0.1:\(port)"
        let quotedBundle = quote(bundlePath)
        return [
            "export HTTP_PROXY=\(proxy) HTTPS_PROXY=\(proxy) http_proxy=\(proxy) https_proxy=\(proxy)",
            "export SSL_CERT_FILE=\(quotedBundle) REQUESTS_CA_BUNDLE=\(quotedBundle) CURL_CA_BUNDLE=\(quotedBundle)",
            "export NODE_EXTRA_CA_CERTS=\(quote(caPath))",
        ]
    }

    /// 单引号包裹，内部单引号写成 `'\''`。
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
