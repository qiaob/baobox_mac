import Foundation

/// 网络泄露检测的网络部分：IPv4 / IPv6 出口、DNS 探测、系统时区。WebRTC 在 `NetCheckWebRTC`。
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

    /// GET，返回正文。连不上、超时、非 2xx 都抛 `NetCheckFailure`。
    private func get(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw NetCheckFailure(L("netcheck.error.badURL \(urlString)"))
        }
        var request = URLRequest(url: url)
        request.setValue("Baobox-NetCheck", forHTTPHeaderField: "User-Agent")
        let fetched: (Data, URLResponse)
        do {
            fetched = try await Self.session.data(for: request)
        } catch {
            let host = url.host ?? urlString
            throw NetCheckFailure(L("netcheck.error.unreachable \(host) \(error.localizedDescription)"))
        }
        let (data, response) = fetched
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetCheckFailure(L("netcheck.error.status \(url.host ?? urlString) \(http.statusCode)"))
        }
        return String(data: data, encoding: .utf8) ?? ""
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

    /// IPv6 出口：连得上纯 IPv6 的服务就有，连不上就当没有（这正是不会漏的那种情况）。
    func ipv6Exit() async -> Result<NetCheckIPInfo?, NetCheckFailure> {
        guard let body = try? await get(NetCheckSettings.ipv6Endpoint) else { return .success(nil) }
        let ip = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ip.contains(":") else {
            return .failure(NetCheckFailure(L("netcheck.error.notIPv6")))
        }
        return await lookup(ip).map { Optional($0) }
    }

    /// DNS 泄露：拿 id → 系统解析器解析一串带 id 的域名 → 取结果。
    func dnsLeak() async -> Result<NetCheckDNSResult, NetCheckFailure> {
        do {
            let id = try await get("\(NetCheckSettings.dnsEndpoint)/id").trimmingCharacters(in: .whitespacesAndNewlines)
            // id 要拼进域名：只收字母数字，别让一个异常回包把任意文字塞进 DNS 查询
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                return .failure(NetCheckFailure(L("netcheck.error.badID")))
            }
            let hosts = (1...dnsProbes).map { "\($0).\(id).\(NetCheckSettings.dnsHost)" }
            await Self.resolve(hosts)
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

    /// 用系统解析器（getaddrinfo → mDNSResponder）逐个解析。结果不要紧，要的是查询发出去了。
    private static func resolve(_ hosts: [String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                for host in hosts {
                    var result: UnsafeMutablePointer<addrinfo>?
                    if getaddrinfo(host, nil, nil, &result) == 0, let result {
                        freeaddrinfo(result)
                    }
                }
                continuation.resume()
            }
        }
    }

    static var systemTimezone: String? {
        let identifier = TimeZone.current.identifier
        return identifier.isEmpty ? nil : identifier
    }
}
