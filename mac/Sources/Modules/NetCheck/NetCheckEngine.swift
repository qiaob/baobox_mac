import Foundation

/// IP 检测的网络部分：IPv4 / IPv6 出口、DNS 探测、系统时区。WebRTC 在 `NetCheckWebRTC`。
/// 全部 async，阻塞的系统解析器调用放在后台队列。见 docs/netcheck/DESIGN.md §4.1。
struct NetCheckEngine {
    let apiKey: String
    let dnsProbes: Int

    /// 走系统代理设置（要测的就是普通 App 看到的那条路），不缓存、不带 cookie，10 秒超时。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// 服务回了非 2xx。
    private struct HTTPStatusError: Error {
        let host: String
        let status: Int
    }

    /// GET，返回正文。抛原始的错（`URLError`、`HTTPStatusError`；地址不对是 `NetCheckFailure`）：IPv6 要据此分「没有」和「没测出来」。
    private func fetch(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw NetCheckFailure(L("netcheck.error.badURL \(urlString)"))
        }
        var request = URLRequest(url: url)
        request.setValue("Baobox-NetCheck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPStatusError(host: url.host ?? urlString, status: http.statusCode)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// GET，返回正文。连不上、超时、非 2xx 都抛 `NetCheckFailure`（给人看的原因）。
    private func get(_ urlString: String) async throws -> String {
        do {
            return try await fetch(urlString)
        } catch {
            throw Self.failure(error, urlString)
        }
    }

    private static func failure(_ error: Error, _ urlString: String) -> NetCheckFailure {
        if let failure = error as? NetCheckFailure { return failure }
        if let status = error as? HTTPStatusError {
            return NetCheckFailure(L("netcheck.error.status \(status.host) \(status.status)"))
        }
        let host = URL(string: urlString)?.host ?? urlString
        return NetCheckFailure(L("netcheck.error.unreachable \(host) \(error.localizedDescription)"))
    }

    /// ipapi.is 的地址：`q=<ip>` 与 `key=<key>`，没有就不带。
    private func ipapiURL(_ ip: String?) -> String {
        var components = URLComponents(string: NetCheckSettings.ipEndpoint)
        var items: [URLQueryItem] = []
        if let ip { items.append(URLQueryItem(name: "q", value: ip)) }
        if !apiKey.isEmpty { items.append(URLQueryItem(name: "key", value: apiKey)) }
        components?.queryItems = items.isEmpty ? nil : items
        return components?.string ?? NetCheckSettings.ipEndpoint
    }

    /// 查一个 IP 的归属。`ip` 为 nil 时查请求方自己。
    func lookup(_ ip: String? = nil) async -> Result<NetCheckIPInfo, NetCheckFailure> {
        do {
            let body = try await get(ipapiURL(ip))
            guard let info = NetCheckLogic.parseIPAPI(body) else {
                return .failure(NetCheckFailure(L("netcheck.error.ipapiUnreadable")))
            }
            return .success(info)
        } catch let failure as NetCheckFailure {
            return .failure(failure)
        } catch {
            return .failure(NetCheckFailure(error.localizedDescription))
        }
    }

    /// IPv6：连得上纯 IPv6 的服务就有。连接立刻失败（没有 IPv6 路由、找不到 / 连不上、代理 CONNECT 失败）= 没有；
    /// 超时、服务回错 = 没测出来（`NetCheckLogic.meansNoIPv6`）。最后算不算「没有」还要看 IPv4 那一行
    /// （`NetCheckLogic.resolveIPv6`）：IPv4 自己都没测出来时一律算没测出来。
    func ipv6Exit() async -> NetCheckIPv6Probe {
        let body: String
        do {
            body = try await fetch(NetCheckSettings.ipv6Endpoint)
        } catch {
            let failure = Self.failure(error, NetCheckSettings.ipv6Endpoint)
            return NetCheckLogic.meansNoIPv6(error) ? .absent(failure) : .failed(failure)
        }
        let ip = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只认一个真正的 IPv6 地址：回了 IPv4（服务被换成了双栈的）或一页 HTML（门户页）都测不了
        guard NetCheckLogic.ipv6Bytes(ip) != nil else {
            return .failed(NetCheckFailure(L("netcheck.error.notIPv6")))
        }
        switch await lookup(ip) {
        case .success(let info): return .found(info)
        case .failure(let why): return .failed(why)
        }
    }

    /// DNS：拿 id → 系统解析器解析一串带 id 的域名 → 取结果。
    func dnsLeak() async -> Result<NetCheckDNSResult, NetCheckFailure> {
        // 上一次检测的探测还卡着没返回：这一次不再发新的（不往后台堆线程）
        guard !NetCheckParallel.isBusy else { return .failure(NetCheckFailure(L("netcheck.error.dnsBusy"))) }
        do {
            let id = try await get("\(NetCheckSettings.dnsEndpoint)/id").trimmingCharacters(in: .whitespacesAndNewlines)
            // id 要拼进域名：只收字母数字，别让一个异常回包把任意文字塞进 DNS 查询
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                return .failure(NetCheckFailure(L("netcheck.error.badID")))
            }
            let hosts = (1...dnsProbes).map { "\($0).\(id).\(NetCheckSettings.dnsHost)" }
            guard await Self.resolve(hosts) else { return .failure(NetCheckFailure(L("netcheck.error.dnsBusy"))) }
            let body = try await get("\(NetCheckSettings.dnsEndpoint)/dnsleak/test/\(id)?json=2")
            guard let result = NetCheckLogic.parseBashWS(body) else {
                return .failure(NetCheckFailure(L("netcheck.error.bashwsUnreadable")))
            }
            return .success(result)
        } catch let failure as NetCheckFailure {
            return .failure(failure)
        } catch {
            return .failure(NetCheckFailure(error.localizedDescription))
        }
    }

    /// 用系统解析器（getaddrinfo → mDNSResponder）并发解析（最多 8 个同时），整段最多等 10 秒：到点就去取结果，没回来的不等
    /// （它们在后台自己结束）。结果不要紧，要的是查询发出去了。上一次的还没返回完时不发，返回 false。
    private static func resolve(_ hosts: [String]) async -> Bool {
        let jobs: [@Sendable () -> Void] = hosts.map { host in
            {
                var result: UnsafeMutablePointer<addrinfo>?
                if getaddrinfo(host, nil, nil, &result) == 0, let result {
                    freeaddrinfo(result)
                }
            }
        }
        return await NetCheckParallel.run(jobs, deadline: NetCheckSettings.dnsProbeDeadline) != .busy
    }

    static var systemTimezone: String? {
        let identifier = TimeZone.current.identifier
        return identifier.isEmpty ? nil : identifier
    }
}
