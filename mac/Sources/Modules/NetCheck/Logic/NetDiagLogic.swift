import Foundation

// 单目标全链路诊断（DNS → TCP → TLS → HTTP）与常用服务一键连通性的纯逻辑。
// 只依赖 Foundation，进 BaoboxTests。纯只读探测，不修改任何系统代理或路由配置。

// MARK: - 单目标诊断模型

/// 解析后的诊断目标。
struct NetDiagTarget: Equatable, Sendable {
    let rawInput: String
    /// `"https"` / `"http"`
    let scheme: String
    let host: String
    let port: UInt16
    /// 路径（含查询串），默认 `"/"`。
    let path: String
    /// 目标本身是否是 IP 字面量（IP 字面量跳过 DNS）。
    let isIPLiteral: Bool

    var usesTLS: Bool { scheme == "https" }

    var urlString: String {
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let isDefaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        let authority = isDefaultPort ? hostPart : "\(hostPart):\(port)"
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return "\(scheme)://\(authority)\(normalizedPath)"
    }

    var hostPortLabel: String {
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(hostPart):\(port)"
    }
}

enum NetDiagStepState: Equatable, Sendable {
    case ok
    case warning
    case failed
    case skipped
}

struct NetDiagDNSResult: Equatable, Sendable {
    let state: NetDiagStepState
    let addresses: [String]
    let duration: TimeInterval?
    /// 是否命中代理 Fake-IP 网段（198.18.0.0/15）
    let fakeIP: Bool
    let error: String?
}

struct NetDiagTCPResult: Equatable, Sendable {
    let state: NetDiagStepState
    let duration: TimeInterval?
    let error: String?
}

struct NetDiagTLSResult: Equatable, Sendable {
    let state: NetDiagStepState
    let duration: TimeInterval?
    /// 如 `TLS 1.3` / `TLS 1.2`
    let protocolVersion: String?
    /// 证书主体名（CN / Subject Summary）
    let subject: String?
    /// 证书颁发者（Issuer）
    let issuer: String?
    /// 证书过期时间
    let expiresAt: Date?
    /// 系统是否信任该证书链
    let trusted: Bool?
    let error: String?
}

struct NetDiagHTTPResult: Equatable, Sendable {
    let state: NetDiagStepState
    let statusCode: Int?
    let ttfb: TimeInterval?
    /// 协商的传输协议，如 `h2`、`http/1.1`、`h3`
    let networkProtocol: String?
    /// `URLSessionTaskTransactionMetrics.isProxyConnection`
    let viaProxy: Bool?
    /// 实际连上的远端 IP
    let remoteAddress: String?
    /// 3xx 重定向目标（若存在）
    let redirectLocation: String?
    /// 403 地区限制 / Cloudflare 验证等额外说明
    let note: String?
    let error: String?
}

struct NetDiagReport: Equatable, Sendable {
    let at: Date
    let target: NetDiagTarget
    let dns: NetDiagDNSResult
    let tcp: NetDiagTCPResult
    let tls: NetDiagTLSResult
    let http: NetDiagHTTPResult
}

// MARK: - 常用服务一键连通性模型

enum NetServiceGroup: String, CaseIterable, Equatable, Sendable {
    case china
    case global
    case ai
}

struct NetServiceTarget: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let group: NetServiceGroup
    let url: String
    /// `GET`（如 generate_204 或需读 403 正文的 API）或 `HEAD`。
    let method: String
    /// 鉴权类 API（如 OpenAI / Anthropic）：401 / 405 代表网络与地区均通过，算可达。
    let acceptsAuthErrors: Bool
}

enum NetServiceOutcome: Equatable, Sendable {
    /// 可达（带 HTTP 状态码）
    case reachable(status: Int)
    /// 链路通但被地区限制 / Cloudflare 盾拦截
    case restricted(status: Int)
    /// 不可达（按错误归类）
    case unreachable(NetDiagErrorKind, detail: String)
}

enum NetDiagErrorKind: Equatable, Sendable {
    case timeout
    case dnsFailed
    case tlsError
    case connectionFailed
    case other
}

struct NetServiceResult: Equatable, Identifiable, Sendable {
    let target: NetServiceTarget
    let outcome: NetServiceOutcome
    let duration: TimeInterval?
    let viaProxy: Bool?

    var id: String { target.id }
}

// MARK: - 纯逻辑解析与判定

enum NetDiagLogic {

    /// 内置常用服务只读探测清单（每条仅几百字节到数 KB）。
    static let builtInServices: [NetServiceTarget] = [
        // 国内
        NetServiceTarget(id: "huawei", name: "Huawei 204", group: .china,
                         url: "https://connectivitycheck.platform.hicloud.com/generate_204", method: "GET", acceptsAuthErrors: false),
        NetServiceTarget(id: "miui", name: "Xiaomi 204", group: .china,
                         url: "https://connect.rom.miui.com/generate_204", method: "GET", acceptsAuthErrors: false),
        NetServiceTarget(id: "baidu", name: "Baidu", group: .china,
                         url: "https://www.baidu.com", method: "HEAD", acceptsAuthErrors: false),
        // 国际 / 开发
        NetServiceTarget(id: "google", name: "Google", group: .global,
                         url: "https://www.gstatic.com/generate_204", method: "GET", acceptsAuthErrors: false),
        NetServiceTarget(id: "cloudflare", name: "Cloudflare", group: .global,
                         url: "https://cp.cloudflare.com/generate_204", method: "GET", acceptsAuthErrors: false),
        NetServiceTarget(id: "github", name: "GitHub API", group: .global,
                         url: "https://api.github.com", method: "HEAD", acceptsAuthErrors: true),
        // AI 服务
        NetServiceTarget(id: "openai", name: "OpenAI API", group: .ai,
                         url: "https://api.openai.com/v1/models", method: "GET", acceptsAuthErrors: true),
        NetServiceTarget(id: "anthropic", name: "Anthropic API", group: .ai,
                         url: "https://api.anthropic.com/v1/messages", method: "GET", acceptsAuthErrors: true),
    ]

    /// 解析用户输入的诊断目标：支持完整 URL、`example.com`、`host:port`、`[ipv6]:port`。
    /// 无 scheme 时：未指定端口或端口为 443 / 8443 默认 `https`，其余端口默认 `http`。
    static func parseTarget(_ raw: String) -> NetDiagTarget? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        let hasScheme = trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")
        let candidate: String
        if hasScheme {
            candidate = trimmed
        } else {
            // 先按 http:// 解析出 host 和 port，再决定默认 scheme
            candidate = "http://" + trimmed
        }

        guard let components = URLComponents(string: candidate),
              let rawHost = components.host, !rawHost.isEmpty else { return nil }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }

        let explicitPort = components.port
        if let p = explicitPort, !(1...65535).contains(p) { return nil }

        let scheme: String
        let port: UInt16
        if hasScheme {
            scheme = (components.scheme ?? "https").lowercased()
            if let p = explicitPort {
                port = UInt16(p)
            } else {
                port = scheme == "https" ? 443 : 80
            }
        } else if let p = explicitPort {
            port = UInt16(p)
            scheme = (p == 443 || p == 8443) ? "https" : "http"
        } else {
            scheme = "https"
            port = 443
        }

        var path = components.percentEncodedPath
        if path.isEmpty { path = "/" }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            path += "?" + query
        }

        let isIP = NetCheckLogic.ipv4Bytes(host) != nil || NetCheckLogic.ipv6Bytes(host) != nil
        return NetDiagTarget(rawInput: trimmed, scheme: scheme, host: host, port: port, path: path, isIPLiteral: isIP)
    }

    /// 把 `tls_protocol_version_t.rawValue` 映射成人类可读的协议名。
    static func tlsVersionName(rawValue: UInt16?) -> String? {
        switch rawValue {
        case 0x0301: return "TLS 1.0"
        case 0x0302: return "TLS 1.1"
        case 0x0303: return "TLS 1.2"
        case 0x0304: return "TLS 1.3"
        default: return nil
        }
    }

    /// 证书距离过期还剩多少天（负数 = 已过期）。
    static func daysUntilExpiry(notAfter: Date, now: Date = Date()) -> Int {
        Int(floor(notAfter.timeIntervalSince(now) / 86_400))
    }

    /// 从 `SecCertificateCopyValues` 字典里提取颁发者名和过期时间（纯 Foundation，便于单元测试）。
    static func extractCertificateMeta(values: [String: Any]?,
                                       validityKey: String = "2.5.29.14", // 仅作默认占位，调用方传 kSecOID*
                                       issuerKey: String = "2.5.4",
                                       commonNameKey: String = "2.5.4.3",
                                       orgKey: String = "2.5.4.10",
                                       valueKey: String = "value",
                                       labelKey: String = "label",
                                       fallbackIssuer: String? = nil) -> (issuer: String?, expiresAt: Date?) {
        var expiresAt: Date?
        if let entry = values?[validityKey] as? [String: Any] {
            if let date = entry[valueKey] as? Date {
                expiresAt = date
            } else if let number = entry[valueKey] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                expiresAt = Date(timeIntervalSinceReferenceDate: number.doubleValue)
            }
        }

        var issuer: String?
        if let entry = values?[issuerKey] as? [String: Any],
           let items = entry[valueKey] as? [[String: Any]] {
            var orgFallback: String?
            for item in items {
                let label = item[labelKey] as? String ?? ""
                let text = (item[valueKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { continue }
                if label == commonNameKey {
                    issuer = text
                    break
                }
                if label == orgKey, orgFallback == nil {
                    orgFallback = text
                }
            }
            if issuer == nil { issuer = orgFallback }
        }
        if issuer == nil, let fallbackIssuer, !fallbackIssuer.isEmpty {
            issuer = fallbackIssuer
        }
        return (issuer, expiresAt)
    }

    /// 判断 HTTP 响应在服务连通性检测里的语义状态。
    /// - `acceptsAuthErrors` 为 true 时，401 / 405 表示已通过网络与地区校验、到达鉴权层，算可达。
    /// - 403 且命中 Cloudflare 盾或地区限制关键字时归类为 `.restricted`。
    static func classifyServiceResponse(statusCode: Int,
                                        headers: [String: String],
                                        bodyPrefix: String,
                                        acceptsAuthErrors: Bool) -> NetServiceOutcome {
        if (200..<400).contains(statusCode) {
            return .reachable(status: statusCode)
        }
        if acceptsAuthErrors && (statusCode == 401 || statusCode == 405) {
            return .reachable(status: statusCode)
        }
        if statusCode == 403 {
            if isRestrictedOrChallenged(headers: headers, bodyPrefix: bodyPrefix) {
                return .restricted(status: statusCode)
            }
            // GitHub API 未鉴权超限时也可能回 403；其余 403 统一归为受限
            return .restricted(status: statusCode)
        }
        return .unreachable(.other, detail: "HTTP \(statusCode)")
    }

    /// 判断 403 响应是否明显来自地区限制或 Cloudflare 盾。
    static func isRestrictedOrChallenged(headers: [String: String], bodyPrefix: String) -> Bool {
        for (key, value) in headers {
            if key.lowercased() == "cf-mitigated", value.lowercased().contains("challenge") {
                return true
            }
        }
        let lower = bodyPrefix.lowercased()
        let markers = [
            "unsupported_country",
            "country_region_territory",
            "not available in your country",
            "access denied",
            "just a moment",
            "cf-browser-verification",
            "attention required",
        ]
        return markers.contains(where: { lower.contains($0) })
    }

    /// 把 `URLError` 归类成给人看的网络层原因。
    static func classifyError(_ error: Error) -> NetDiagErrorKind {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .cannotFindHost, .dnsLookupFailed:
                return .dnsFailed
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
                return .tlsError
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return .connectionFailed
            default:
                return .other
            }
        }
        return .other
    }
}
