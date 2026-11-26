import Foundation
import Network
import Security

/// 单目标全链路诊断（DNS → TCP → TLS → HTTP）与常用服务一键连通性探测引擎。
/// 全部只读探测，不修改任何系统代理、DNS 或路由设置；只在用户点击时发请求。
enum NetDiagEngine {

    private static let tcpTimeout: TimeInterval = 5
    private static let httpTimeout: TimeInterval = 6
    private static let maxBodyBytes = 4 * 1024

    // MARK: - 单目标全链路诊断

    static func diagnose(_ target: NetDiagTarget) async -> NetDiagReport {
        let dns = await probeDNS(target)
        let tcp = await probeTCP(host: target.host, port: target.port)
        let httpProbe = await SingleHTTPProbe.run(urlString: target.urlString, method: "GET", timeout: httpTimeout)

        let tls: NetDiagTLSResult
        if !target.usesTLS {
            tls = NetDiagTLSResult(state: .skipped, duration: nil, protocolVersion: nil,
                                   subject: nil, issuer: nil, expiresAt: nil, trusted: nil, error: nil)
        } else if let cert = httpProbe.certificate {
            let isExpired = cert.expiresAt.map { NetDiagLogic.daysUntilExpiry(notAfter: $0) < 0 } ?? false
            let expiringSoon = cert.expiresAt.map { NetDiagLogic.daysUntilExpiry(notAfter: $0) <= 14 } ?? false
            let untrusted = cert.trusted == false
            let state: NetDiagStepState
            if untrusted || isExpired {
                state = .failed
            } else if expiringSoon {
                state = .warning
            } else {
                state = .ok
            }
            tls = NetDiagTLSResult(state: state, duration: httpProbe.tlsDuration,
                                   protocolVersion: NetDiagLogic.tlsVersionName(rawValue: httpProbe.tlsVersionRaw),
                                   subject: cert.subject, issuer: cert.issuer,
                                   expiresAt: cert.expiresAt, trusted: cert.trusted, error: nil)
        } else if httpProbe.statusCode != nil {
            // 走了 HTTP/HTTPS 代理或复用会话未触发 challenge，但请求成功拿到了响应
            tls = NetDiagTLSResult(state: .ok, duration: httpProbe.tlsDuration,
                                   protocolVersion: NetDiagLogic.tlsVersionName(rawValue: httpProbe.tlsVersionRaw),
                                   subject: nil, issuer: nil, expiresAt: nil, trusted: true, error: nil)
        } else {
            let errText = httpProbe.error?.localizedDescription ?? L("netcheck.diag.error.tlsFailed")
            tls = NetDiagTLSResult(state: .failed, duration: httpProbe.tlsDuration,
                                   protocolVersion: NetDiagLogic.tlsVersionName(rawValue: httpProbe.tlsVersionRaw),
                                   subject: nil, issuer: nil, expiresAt: nil, trusted: nil, error: errText)
        }

        let http: NetDiagHTTPResult
        if let status = httpProbe.statusCode {
            let isRestricted = status == 403 && NetDiagLogic.isRestrictedOrChallenged(headers: httpProbe.headers,
                                                                                      bodyPrefix: httpProbe.bodyPrefix)
            let state: NetDiagStepState
            if (200..<400).contains(status) {
                state = .ok
            } else if status == 401 || status == 405 || isRestricted {
                state = .warning
            } else if status >= 500 {
                state = .failed
            } else {
                state = .warning
            }
            let note = isRestricted ? L("netcheck.diag.note.restricted") : nil
            http = NetDiagHTTPResult(state: state, statusCode: status, ttfb: httpProbe.ttfb,
                                     networkProtocol: httpProbe.networkProtocol, viaProxy: httpProbe.viaProxy,
                                     remoteAddress: httpProbe.remoteAddress,
                                     redirectLocation: httpProbe.redirectLocation, note: note, error: nil)
        } else {
            let errText = httpProbe.error?.localizedDescription ?? L("netcheck.diag.error.httpFailed")
            http = NetDiagHTTPResult(state: .failed, statusCode: nil, ttfb: nil,
                                     networkProtocol: httpProbe.networkProtocol, viaProxy: httpProbe.viaProxy,
                                     remoteAddress: httpProbe.remoteAddress,
                                     redirectLocation: nil, note: nil, error: errText)
        }

        return NetDiagReport(at: Date(), target: target, dns: dns, tcp: tcp, tls: tls, http: http)
    }

    // MARK: - 常用服务一键连通性

    static func probeService(_ service: NetServiceTarget) async -> NetServiceResult {
        let probe = await SingleHTTPProbe.run(urlString: service.url, method: service.method, timeout: 5)
        if let status = probe.statusCode {
            let outcome = NetDiagLogic.classifyServiceResponse(statusCode: status,
                                                               headers: probe.headers,
                                                               bodyPrefix: probe.bodyPrefix,
                                                               acceptsAuthErrors: service.acceptsAuthErrors)
            return NetServiceResult(target: service, outcome: outcome,
                                    duration: probe.totalDuration ?? probe.ttfb, viaProxy: probe.viaProxy)
        }
        let kind = probe.error.map(NetDiagLogic.classifyError) ?? .other
        let detail = probe.error?.localizedDescription ?? L("netcheck.diag.error.httpFailed")
        return NetServiceResult(target: service, outcome: .unreachable(kind, detail: detail),
                                duration: probe.totalDuration, viaProxy: probe.viaProxy)
    }

    // MARK: - ① DNS

    private static func probeDNS(_ target: NetDiagTarget) async -> NetDiagDNSResult {
        if target.isIPLiteral {
            return NetDiagDNSResult(state: .skipped, addresses: [target.host], duration: nil, fakeIP: false, error: nil)
        }
        let host = target.host
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = monotonicNow()
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                let rc = getaddrinfo(host, nil, &hints, &list)
                let elapsed = monotonicNow() - start
                guard rc == 0, let first = list else {
                    let message = String(cString: gai_strerror(rc))
                    continuation.resume(returning: NetDiagDNSResult(state: .failed, addresses: [], duration: elapsed,
                                                                    fakeIP: false, error: message))
                    return
                }
                defer { freeaddrinfo(first) }
                var addresses: [String] = []
                var seen: Set<String> = []
                var sawFakeIP = false
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let entry = cursor {
                    cursor = entry.pointee.ai_next
                    guard let addr = entry.pointee.ai_addr else { continue }
                    let family = Int32(addr.pointee.sa_family)
                    guard family == AF_INET || family == AF_INET6 else { continue }
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, entry.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = NetCheckEnvironmentLogic.stripScopeID(String(cString: buf))
                        if !ip.isEmpty, seen.insert(ip).inserted {
                            addresses.append(ip)
                            if NetCheckLogic.isFakeIP(ip) { sawFakeIP = true }
                        }
                    }
                }
                if addresses.isEmpty {
                    continuation.resume(returning: NetDiagDNSResult(state: .failed, addresses: [], duration: elapsed,
                                                                    fakeIP: false, error: L("netcheck.diag.error.noDNS")))
                } else {
                    continuation.resume(returning: NetDiagDNSResult(state: .ok, addresses: addresses, duration: elapsed,
                                                                    fakeIP: sawFakeIP, error: nil))
                }
            }
        }
    }

    // MARK: - ② TCP（NWConnection）

    private static func probeTCP(host: String, port: UInt16) async -> NetDiagTCPResult {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return NetDiagTCPResult(state: .failed, duration: nil, error: L("netcheck.diag.error.badPort"))
        }
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.baobox.netcheck.diag.tcp", qos: .userInitiated)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let started = monotonicNow()
            var finished = false

            let complete: (NetDiagTCPResult) -> Void = { result in
                guard !finished else { return }
                finished = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    complete(NetDiagTCPResult(state: .ok, duration: monotonicNow() - started, error: nil))
                case .failed(let error):
                    complete(NetDiagTCPResult(state: .failed, duration: monotonicNow() - started,
                                              error: error.localizedDescription))
                case .waiting(let error):
                    // 端口被拒或路由不可达时 NWConnection 会先进入 .waiting，不必傻等超时
                    if case .posix(let code) = error,
                       code == .ECONNREFUSED || code == .EHOSTUNREACH || code == .ENETUNREACH || code == .ENETDOWN {
                        complete(NetDiagTCPResult(state: .failed, duration: monotonicNow() - started,
                                                  error: error.localizedDescription))
                    }
                case .cancelled:
                    complete(NetDiagTCPResult(state: .failed, duration: monotonicNow() - started,
                                              error: L("netcheck.diag.error.cancelled")))
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + tcpTimeout) {
                complete(NetDiagTCPResult(state: .failed, duration: tcpTimeout, error: L("netcheck.diag.error.timeout")))
            }
            connection.start(queue: queue)
        }
    }

    private static func monotonicNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    // MARK: - ③ + ④ TLS 与 HTTP（URLSession + SecTrust + URLSessionTaskMetrics）

    private struct CertInfo: Sendable {
        let subject: String?
        let issuer: String?
        let expiresAt: Date?
        let trusted: Bool
    }

    private struct HTTPProbeOutcome: Sendable {
        var statusCode: Int?
        var headers: [String: String] = [:]
        var bodyPrefix: String = ""
        var redirectLocation: String?
        var ttfb: TimeInterval?
        var tlsDuration: TimeInterval?
        var totalDuration: TimeInterval?
        var tlsVersionRaw: UInt16?
        var networkProtocol: String?
        var viaProxy: Bool?
        var remoteAddress: String?
        var certificate: CertInfo?
        var error: Error?
    }

    /// 单次隔离的 URLSession 探测：收证书、收 metrics、禁重定向、限读 4 KB 正文，结束后立即释放 session。
    private final class SingleHTTPProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.baobox.netcheck.diag.http", qos: .userInitiated)
        private let delegateQueue = OperationQueue()
        private var session: URLSession?
        private var continuation: CheckedContinuation<HTTPProbeOutcome, Never>?
        private var outcome = HTTPProbeOutcome()
        private var bodyData = Data()
        private var started: TimeInterval = 0
        private var truncatedByLimit = false
        private var completed = false

        static func run(urlString: String, method: String, timeout: TimeInterval) async -> HTTPProbeOutcome {
            guard let url = URL(string: urlString) else {
                var out = HTTPProbeOutcome()
                out.error = NetCheckFailure(L("netcheck.error.badURL \(urlString)"))
                return out
            }
            let probe = SingleHTTPProbe()
            return await probe.execute(url: url, method: method, timeout: timeout)
        }

        private override init() {
            super.init()
            delegateQueue.underlyingQueue = queue
            delegateQueue.maxConcurrentOperationCount = 1
        }

        private func execute(url: URL, method: String, timeout: TimeInterval) async -> HTTPProbeOutcome {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    self.continuation = continuation
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = timeout
                    config.timeoutIntervalForResource = timeout + 2
                    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    config.httpCookieStorage = nil
                    config.urlCache = nil
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
                    self.session = session
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
                    request.httpMethod = method
                    request.setValue("Baobox-NetCheck", forHTTPHeaderField: "User-Agent")
                    self.started = NetDiagEngine.monotonicNow()
                    session.dataTask(with: request).resume()
                }
            }
        }

        private func finish() {
            guard !completed else { return }
            completed = true
            if outcome.totalDuration == nil {
                outcome.totalDuration = NetDiagEngine.monotonicNow() - started
            }
            if !bodyData.isEmpty {
                outcome.bodyPrefix = String(decoding: bodyData, as: UTF8.self)
            }
            let result = outcome
            let cont = continuation
            continuation = nil
            session?.invalidateAndCancel()
            session = nil
            cont?.resume(returning: result)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            outcome.statusCode = response.statusCode
            outcome.redirectLocation = response.value(forHTTPHeaderField: "Location") ?? request.url?.absoluteString
            outcome.headers = Self.extractHeaders(response)
            // 停在第一跳，展示原始状态码与重定向目标
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                outcome.certificate = Self.readCert(trust)
            }
            // 始终走系统默认证书校验，绝不绕过 TLS 验证
            completionHandler(.performDefaultHandling, nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse {
                outcome.statusCode = http.statusCode
                outcome.headers = Self.extractHeaders(http)
                if outcome.redirectLocation == nil {
                    outcome.redirectLocation = http.value(forHTTPHeaderField: "Location")
                }
            }
            // 仅在 403 时需要读少量正文判断地区限制 / Cloudflare 盾，其余状态直接停读省流量
            if outcome.statusCode == 403 {
                completionHandler(.allow)
            } else {
                truncatedByLimit = true
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let remaining = NetDiagEngine.maxBodyBytes - bodyData.count
            if remaining > 0 {
                bodyData.append(data.prefix(remaining))
            }
            if bodyData.count >= NetDiagEngine.maxBodyBytes {
                truncatedByLimit = true
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            outcome.totalDuration = metrics.taskInterval.duration
            guard let tx = metrics.transactionMetrics.last(where: { $0.responseStartDate != nil })
                    ?? metrics.transactionMetrics.last else { return }
            if let req = tx.requestStartDate, let res = tx.responseStartDate {
                let d = res.timeIntervalSince(req)
                if d >= 0 { outcome.ttfb = d }
            }
            if let tlsStart = tx.secureConnectionStartDate, let tlsEnd = tx.secureConnectionEndDate {
                let d = tlsEnd.timeIntervalSince(tlsStart)
                if d >= 0 { outcome.tlsDuration = d }
            }
            outcome.tlsVersionRaw = tx.negotiatedTLSProtocolVersion?.rawValue
            outcome.networkProtocol = tx.networkProtocolName
            outcome.viaProxy = tx.isProxyConnection
            outcome.remoteAddress = tx.remoteAddress
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, !truncatedByLimit {
                outcome.error = error
            }
            finish()
        }

        private static func extractHeaders(_ response: HTTPURLResponse) -> [String: String] {
            var dict: [String: String] = [:]
            for (k, v) in response.allHeaderFields {
                if let ks = k as? String, let vs = v as? String {
                    dict[ks] = vs
                }
            }
            return dict
        }

        private static func readCert(_ trust: SecTrust) -> CertInfo? {
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            guard let leaf = chain.first else { return nil }
            let subject = SecCertificateCopySubjectSummary(leaf) as String?
            let fallbackIssuer = chain.count >= 2 ? (SecCertificateCopySubjectSummary(chain[1]) as String?) : nil
            let keys: [CFString] = [kSecOIDX509V1ValidityNotAfter, kSecOIDX509V1IssuerName]
            let rawValues = SecCertificateCopyValues(leaf, keys as CFArray, nil) as? [String: Any]
            let meta = NetDiagLogic.extractCertificateMeta(
                values: rawValues,
                validityKey: kSecOIDX509V1ValidityNotAfter as String,
                issuerKey: kSecOIDX509V1IssuerName as String,
                commonNameKey: kSecOIDCommonName as String,
                orgKey: kSecOIDOrganizationName as String,
                valueKey: kSecPropertyKeyValue as String,
                labelKey: kSecPropertyKeyLabel as String,
                fallbackIssuer: fallbackIssuer
            )
            var evalError: CFError?
            let trusted = SecTrustEvaluateWithError(trust, &evalError)
            return CertInfo(subject: subject, issuer: meta.issuer, expiresAt: meta.expiresAt, trusted: trusted)
        }
    }
}

/// 诊断页状态管理（单目标全链路诊断 + 常用服务一键连通性）。
@MainActor
final class NetDiagSession: ObservableObject {
    static let shared = NetDiagSession()

    @Published var targetInput = ""
    @Published private(set) var diagnosing = false
    @Published private(set) var report: NetDiagReport?
    @Published var inputError: String?

    @Published private(set) var probingServices = false
    @Published private(set) var serviceResults: [String: NetServiceResult] = [:]
    @Published private(set) var servicesCheckedAt: Date?

    private var diagTask: Task<Void, Never>?
    private var serviceTask: Task<Void, Never>?

    private init() {}

    /// 运行单目标全链路诊断。传入 `raw` 时先填入输入框。
    func runDiagnostic(raw: String? = nil) {
        if let raw { targetInput = raw }
        let trimmed = targetInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = NetDiagLogic.parseTarget(trimmed) else {
            inputError = L("netcheck.diag.error.invalidTarget")
            return
        }
        inputError = nil
        diagTask?.cancel()
        diagnosing = true
        diagTask = Task { @MainActor in
            let result = await NetDiagEngine.diagnose(target)
            guard !Task.isCancelled else { return }
            self.report = result
            self.diagnosing = false
        }
    }

    /// 并发探测全部内置常用服务，每条返回即刷新。
    func runServiceChecks() {
        serviceTask?.cancel()
        probingServices = true
        serviceResults = [:]
        let targets = NetDiagLogic.builtInServices
        serviceTask = Task { @MainActor in
            await withTaskGroup(of: NetServiceResult.self) { group in
                for target in targets {
                    group.addTask {
                        await NetDiagEngine.probeService(target)
                    }
                }
                for await result in group {
                    guard !Task.isCancelled else { break }
                    self.serviceResults[result.id] = result
                }
            }
            guard !Task.isCancelled else { return }
            self.servicesCheckedAt = Date()
            self.probingServices = false
        }
    }

    func stopAll() {
        diagTask?.cancel()
        diagTask = nil
        diagnosing = false
        serviceTask?.cancel()
        serviceTask = nil
        probingServices = false
    }
}
