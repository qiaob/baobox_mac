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
        /// 什么都不解密（「解密 HTTPS」关着）。
        case none
    }

    var mode: Mode
    var domains: [String]

    static let all = DecryptScope(mode: .all, domains: [])
    /// 「解密 HTTPS」关着：所有 TLS 原样放行，列表里这种行的说明是「关了解密」。
    static let off = DecryptScope(mode: .none, domains: [])

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

/// 让引擎再发一次的请求（docs/packet-capture/TOOLS.md §3）。内容全在指令里，引擎重启过也能发。
struct ReplayRequest: Equatable, Sendable {
    /// 新那一行的 id。Swift 这边先生成、引擎照用，所以发之前就知道该选中哪一行。
    var id: UUID
    var method: String
    var url: String
    var headers: [HTTPHeader]
    /// 解压后的正文。长度、压缩、分块这几个头桥脚本会丢掉重算。
    var body: Data?
    /// 重发的是哪一条（列表里那条的 id）。只留在 Baobox 这边（MCP 摘要里的 `[replay of <id>]`），不发给引擎。
    var origin: UUID? = nil
}

/// 写进引擎标准输入的一条指令（一行 JSON）。
enum CaptureCommand: Equatable, Sendable {
    case shutdown
    case scope(DecryptScope)
    case allowDevice(String)
    case denyDevice(String)
    case replay(ReplayRequest)
    /// 全量的 Mock 规则（停用的也带上，引擎自己跳过）。
    case rules([MockRule])
    /// 记录 / 暂停（docs/packet-capture/CONTROL.md §5）。
    case record(Bool)
    /// 局域网设备能不能拿引擎当代理（「手动代理」开关，CONTROL.md §2.1）。
    case lanProxy(Bool)
    /// 记不记这台 Mac 发出的原始 TCP（「本机 → TCP」，CONTROL.md §4.1）。
    case macTCP(Bool)
    /// 手机配置页的端口，0 = 没开（「给其他设备装证书」）。桥据此把打开代理地址的浏览器转过去、接证书检测。
    case pagePort(UInt16)
    /// 列表清空了：被放行的域名下次再来时重新报一行「没解密」。`device` = 只清这台（设备键），nil = 全部
    /// （docs/packet-capture/TLS-FINGERPRINT.md §7.2）。
    case forgetReported(device: String?)
    /// 「重新尝试解密」：忘掉这台设备上这个域名的握手失败，下一条连接重新接管（TLS-FINGERPRINT.md §7.2）。
    case retryDecrypt(device: String, host: String)

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
        case .replay(let request):
            var replay: [String: Any] = [
                "cmd": "replay",
                // 小写：和引擎自己生成的 flow id 一个写法。
                "id": request.id.uuidString.lowercased(),
                "method": request.method,
                "url": request.url,
                "headers": request.headers.map { [$0.name, $0.value] },
            ]
            if let body = request.body, !body.isEmpty {
                replay["body"] = body.base64EncodedString()
            } else {
                replay["body"] = NSNull()
            }
            object = replay
        case .rules(let rules):
            object = ["cmd": "rules", "rules": rules.map(\.commandObject)]
        case .record(let on):
            object = ["cmd": "record", "on": on]
        case .lanProxy(let on):
            object = ["cmd": "lan_proxy", "on": on]
        case .macTCP(let on):
            object = ["cmd": "mac_tcp", "on": on]
        case .pagePort(let port):
            object = ["cmd": "page_port", "port": Int(port)]
        case .forgetReported(let device):
            object = device.map { ["cmd": "forget_reported", "device": $0] } ?? ["cmd": "forget_reported"]
        case .retryDecrypt(let device, let host):
            object = ["cmd": "retry_decrypt", "device": device, "host": host]
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
