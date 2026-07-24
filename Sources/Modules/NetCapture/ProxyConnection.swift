import Foundation
import Network
import Security

/// 单连接状态机：判定 CONNECT / 明文 → MITM 解密或盲隧道透传 → 上下游中继 → 产出 Flow。
///
/// 并发：本类的所有可变状态只在自己的串行 `queue` 上访问（NWConnection 回调也派发到该队列），
/// 故 `@unchecked Sendable` 安全。写 `FlowStore`（@MainActor）时用 `DispatchQueue.main.async` 回主线程。
///
/// 故障透传（硬约束）：任何 MITM 失败——不在解密范围、拿不到证书、上游 TLS 握手失败/疑似 Pinning——
/// 都退化为**盲隧道**（原始 TCP 双向中继），保证被代理设备照常上网，只记录 CONNECT 元数据。
/// 每条 fallback 路径都在注释里标明。
final class ProxyConnection: @unchecked Sendable {

    private let client: NWConnection
    private let queue: DispatchQueue
    private let ca: MITMCertAuthority
    private let onDone: (ProxyConnection) -> Void

    /// 会话内所有子连接（上游 / 回环），停止时统一取消。
    private var children: [NWConnection] = []
    private var loopbackListener: NWListener?
    private var finished = false

    /// 盲隧道字节计数（未解密 flow 用）。
    private var tunnelUpBytes = 0
    private var tunnelDownBytes = 0
    private var tunnelFlow: Flow?

    /// 源设备 LAN IP（客户端连到代理的 remote 端）。只在本连接串行队列写/读。
    /// 多设备区分（§17）：`appendFlow` 一处统一给所有 flow 打标。
    private var clientIP: String?

    /// 是否本机（回环）客户端。未知源（clientIP 尚未取到）保守视为远程 → 只透传不断网。
    private var isLocalClient: Bool {
        guard let ip = clientIP else { return false }
        return ip == "127.0.0.1" || ip == "::1" || ip.lowercased() == "localhost"
    }

    init(client: NWConnection,
         queue: DispatchQueue,
         ca: MITMCertAuthority,
         onDone: @escaping (ProxyConnection) -> Void) {
        self.client = client
        self.queue = queue
        self.ca = ca
        self.onDone = onDone
    }

    // MARK: - 启动

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.captureClientIP()
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        client.start(queue: queue)
        readFirstRequest()
    }

    /// 从客户端连接的 remote 端提取源设备 IP（与 `remoteIP(of:)` 同法，但归一化）。幂等，只在队列上调。
    private func captureClientIP() {
        guard clientIP == nil else { return }
        guard let endpoint = client.currentPath?.remoteEndpoint else { return }
        if case let .hostPort(host, _) = endpoint {
            let raw: String
            switch host {
            case .ipv4(let addr): raw = "\(addr)"
            case .ipv6(let addr): raw = "\(addr)"
            case .name(let name, _): raw = name
            @unknown default: return
            }
            clientIP = Self.normalizeIP(raw)
        }
    }

    /// 归一化源 IP：去 IPv6 作用域后缀 `%en0`、去 IPv4-mapped 前缀 `::ffff:`。
    private static func normalizeIP(_ s: String) -> String {
        var out = s
        if let pct = out.firstIndex(of: "%") { out = String(out[out.startIndex..<pct]) }
        if out.lowercased().hasPrefix("::ffff:") { out = String(out.dropFirst("::ffff:".count)) }
        return out
    }

    func cancel() {
        queue.async { [weak self] in self?.finish() }
    }

    /// 幂等收尾：取消所有连接、结算未解密 flow、通知登记表移除。
    private func finish() {
        guard !finished else { return }
        finished = true
        // 结算盲隧道 flow（记录最终字节数与结束时间）。
        if var flow = tunnelFlow {
            flow.requestBytes = tunnelUpBytes
            flow.responseBytes = tunnelDownBytes
            flow.endedAt = Date()
            appendFlow(flow)
            tunnelFlow = nil
        }
        client.cancel()
        for child in children { child.cancel() }
        children.removeAll()
        loopbackListener?.cancel()
        loopbackListener = nil
        onDone(self)
    }

    // MARK: - 首请求判定

    /// 读第一段数据，判定 CONNECT（HTTPS 隧道）还是明文绝对形式请求。
    private func readFirstRequest() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                _ = error
                self.finish()
                return
            }
            guard let data, !data.isEmpty else {
                if isComplete { self.finish() }
                return
            }
            // 兜底：首段数据到达时 path 必已就绪，若 .ready 回调早于 handler 设定则在此补取。
            self.captureClientIP()
            self.routeFirstRequest(data)
        }
    }

    /// 依据首段字节路由：`CONNECT ` → HTTPS；否则按明文代理请求处理。
    private func routeFirstRequest(_ data: Data) {
        guard let headerEnd = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            // 头还没收全（罕见），继续读并拼接。为简洁起见，超大头视为异常直接关。
            if data.count > 64 * 1024 { finish() } else { continueReadingFirst(prefix: data) }
            return
        }
        let headText = String(data: data.subdata(in: data.startIndex..<headerEnd.lowerBound),
                              encoding: .isoLatin1) ?? ""
        let firstLine = headText.components(separatedBy: "\r\n").first ?? ""

        if firstLine.hasPrefix("CONNECT ") {
            handleConnect(firstLine: firstLine)
        } else {
            // 明文绝对形式：GET http://host/path HTTP/1.1。剩余字节（含首请求）交给中继引擎。
            handlePlainHTTP(firstLine: firstLine, initialData: data)
        }
    }

    /// 首请求头不完整时继续读拼接（上限保护见调用处）。
    private func continueReadingFirst(prefix: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil { self.finish(); return }
            var combined = prefix
            if let data { combined.append(data) }
            if combined.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil {
                self.routeFirstRequest(combined)
            } else if isComplete || combined.count > 64 * 1024 {
                self.finish()
            } else {
                self.continueReadingFirst(prefix: combined)
            }
        }
    }

    // MARK: - CONNECT（HTTPS）

    private func handleConnect(firstLine: String) {
        // CONNECT example.com:443 HTTP/1.1
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { finish(); return }
        let target = String(parts[1])
        let (host, port) = splitHostPort(target, defaultPort: 443)

        // 回写隧道已建立。
        let ok = "HTTP/1.1 200 Connection Established\r\n\r\n"
        client.send(content: Data(ok.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.finish(); return }
            // magic 域名很少走 CONNECT（证书页是明文），这里只处理常规 HTTPS。
            // 判定是否尝试 MITM：解密范围内 + 能拿到证书。否则直接盲隧道（不消费后续字节前决定）。
            // 本机：仅当 CA 已被本机信任才 MITM，否则透传——避免「本机网络走代理」打开却没装/没信任
            // 证书时本机 HTTPS 断网。远程设备由 shouldDecrypt 的 decryptRemote 控制。
            let localTrustOK = !self.isLocalClient || self.ca.isTrustedCached
            guard NetCaptureEnv.shouldDecrypt(host: host, isLocalClient: self.isLocalClient),
                  localTrustOK,
                  self.ca.identity(forHost: host) != nil else {
                // —— 故障透传路径 1：不在解密范围 / 本机未信任 / 无证书 → 盲隧道 ——
                self.startBlindTunnel(host: host, port: port, note: L("netcapture.note.passthrough"))
                return
            }
            self.attemptMITM(host: host, port: port)
        })
    }

    /// 上游 TLS 是否已作出「MITM 或透传」决定（只在本连接串行队列访问，无需锁）。
    private var mitmDecided = false

    /// 尝试 MITM：先连上游 TLS；上游就绪才终止客户端 TLS，上游失败即盲隧道（故障透传路径 2）。
    private func attemptMITM(host: String, port: Int) {
        let upstream = makeUpstreamConnection(host: host, port: port, tls: true)
        mitmDecided = false
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.mitmDecided else { return }
                self.mitmDecided = true
                self.startMITMTermination(host: host, port: port, upstream: upstream)
            case .failed, .cancelled:
                guard !self.mitmDecided else { return }
                self.mitmDecided = true
                // —— 故障透传路径 2：上游 TLS 握手失败/疑似 Pinning → 盲隧道 ——
                upstream.cancel()
                self.startBlindTunnel(host: host, port: port,
                                      note: L("netcapture.note.upstreamFailed"))
            default:
                break
            }
        }
        children.append(upstream)
        upstream.start(queue: queue)
    }

    /// 起内部回环 TLS 服务端（用 host 的证书），把客户端明文字节 pump 进去，握手后得到明文 HTTP。
    ///
    /// §4.3 实现取舍：Network.framework **没有**公开的「服务端按 SNI 回调选 identity」API
    /// （`sec_protocol_options_set_local_identity` 只能在建 options 时定死一张证书）。因 CONNECT
    /// 已明确告知目标 host，此处为该会话起一个**单证书**回环 listener 即可，无需 SNI 动态选择——
    /// 这是唯一只依赖公开 API 的稳妥路径。TODO(有 Mac 者验证)：如需「一个共享 listener 服务所有
    /// host」的优化，须确认是否有可用的服务端 SNI 选择回调；当前按会话建 listener（开销略高但正确）。
    private func startMITMTermination(host: String, port: Int, upstream: NWConnection) {
        guard let identity = ca.identity(forHost: host) else {
            // 理论上 attemptMITM 前已校验过；防御性兜底为盲隧道。
            startBlindTunnel(host: host, port: port, note: L("netcapture.note.passthrough"))
            return
        }
        let tlsOptions = NWProtocolTLS.Options()
        let sec = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_local_identity(sec, identity)
        sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)

        let params = NWParameters(tls: tlsOptions)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: .any) else {
            // 起不了回环 listener → 盲隧道兜底。
            startBlindTunnel(host: host, port: port, note: L("netcapture.note.mitmSetupFailed"))
            return
        }
        loopbackListener = listener

        listener.newConnectionHandler = { [weak self] serverSide in
            guard let self else { serverSide.cancel(); return }
            // 只需一个连接，收到后关掉 listener。
            self.loopbackListener?.cancel()
            self.loopbackListener = nil
            self.children.append(serverSide)
            serverSide.start(queue: self.queue)
            // 明文侧（serverSide，已解密）↔ 上游 TLS。tee 解析出 flow。
            self.startRelayEngine(clientSide: serverSide, upstream: upstream,
                                  scheme: "https", host: host, port: port, initialClientData: nil)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let assigned = self.loopbackListener?.port else { return }
                // 连回环 listener 的原始 TCP 连接，与客户端做纯字节 pump（承载 TLS 记录）。
                let rawLoopback = NWConnection(host: "127.0.0.1", port: assigned, using: .tcp)
                self.children.append(rawLoopback)
                rawLoopback.stateUpdateHandler = { [weak self] rlState in
                    guard let self else { return }
                    if case .ready = rlState {
                        // 双向纯字节中继：客户端(真手机) ↔ 回环 listener 的服务端 TLS 栈。
                        self.pump(from: self.client, to: rawLoopback, tee: nil) { [weak self] in self?.finish() }
                        self.pump(from: rawLoopback, to: self.client, tee: nil) { [weak self] in self?.finish() }
                    } else if case .failed = rlState {
                        self.finish()
                    }
                }
                rawLoopback.start(queue: self.queue)
            case .failed:
                self.startBlindTunnel(host: host, port: port, note: L("netcapture.note.mitmSetupFailed"))
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    // MARK: - 明文 HTTP

    private func handlePlainHTTP(firstLine: String, initialData: Data) {
        // GET http://host/path HTTP/1.1  或  GET /path（少见的非绝对形式，直接失败关）。
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { finish(); return }
        let target = String(parts[1])
        guard let comps = URLComponents(string: target), let host = comps.host else {
            // 非绝对形式（有人直接访问代理端口，如手机未设代理时扫码 http://<Mac-IP>:<port>/）→
            // 当作配置页请求本地应答（装证书 / 配代理），使扫码无需先设代理即可打开，破解「先有鸡还是先有蛋」。
            serveMagicDomain(path: target, userAgent: userAgent(fromRequestHead: initialData))
            return
        }
        let port = comps.port ?? 80

        // magic 域名 或 直连本机代理端口（已设代理后访问自身 IP:port）→ 本地应答配置页，不走上游。
        let isSelfDirect = (host == NetworkInterfaces.primaryIP() && port == Int(NetCaptureEnv.port))
        if host.lowercased() == NetworkInterfaces.magicHost || isSelfDirect {
            serveMagicDomain(path: comps.path, userAgent: userAgent(fromRequestHead: initialData))
            return
        }

        let upstream = makeUpstreamConnection(host: host, port: port, tls: false)
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // 明文中继：客户端(已读首请求) ↔ 上游明文。initialData 含首请求，一并转发+解析。
                self.startRelayEngine(clientSide: self.client, upstream: upstream,
                                      scheme: "http", host: host, port: port, initialClientData: initialData)
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        children.append(upstream)
        upstream.start(queue: queue)
    }

    /// magic 域名本地应答（§16.2 单一配置网页）：
    /// - `/`         → 自适应配置页（`landingPageHTML`，按 UA 区分 iOS / Android）。
    /// - `/cert`     → iOS 返回 CA-only 描述文件；其它 UA 返回原始 `.crt`。
    /// - `/proxy`    → iOS + 有 SSID 返回仅 Wi-Fi 手动代理描述文件；否则 302 回 `/`。
    /// - `/proxy-off`→ iOS 返回 `ProxyType=None` 描述文件；否则 302 回 `/`。
    private func serveMagicDomain(path: String, userAgent: String) {
        let isIOS = userAgent.contains("iPhone") || userAgent.contains("iPad") || userAgent.contains("iPod")
        let response: Data

        if path == "/proxy-off" {
            if isIOS, let ssid = MobileConfigBuilder.currentSSID(), !ssid.isEmpty {
                response = profileResponse(MobileConfigBuilder.proxyOffProfile(ssid: ssid),
                                           filename: "baobox-proxy-off.mobileconfig")
            } else {
                response = redirectToIndex()
            }
        } else if path == "/proxy" {
            let ip = NetworkInterfaces.primaryIP()
            if isIOS, let ssid = MobileConfigBuilder.currentSSID(), !ssid.isEmpty {
                let profile = MobileConfigBuilder.proxyProfile(ssid: ssid, ip: ip, port: NetCaptureEnv.port)
                response = profileResponse(profile, filename: "baobox-proxy.mobileconfig")
            } else {
                // 非 iOS 或拿不到 SSID → 回配置页（其中含 Android 手动指引 / iOS 手动说明）。
                response = redirectToIndex()
            }
        } else if path.contains("cert") || path.contains(".pem") || path.contains(".crt") {
            if isIOS {
                // iOS：CA-only 描述文件，点开即进「安装描述文件」流程。
                if let profile = MobileConfigBuilder.caProfile() {
                    response = profileResponse(profile, filename: "baobox-ca.mobileconfig")
                } else {
                    response = simpleHTTP(status: "503 Service Unavailable",
                                          contentType: "text/plain; charset=utf-8",
                                          body: Data("CA not generated yet.".utf8))
                }
            } else if let pem = ca.caCertPEM() {
                // 其它平台：原始证书文件（保留原有行为）。
                var head = "HTTP/1.1 200 OK\r\n"
                head += "Content-Type: application/x-x509-ca-cert\r\n"
                head += "Content-Disposition: attachment; filename=\"baobox-ca.crt\"\r\n"
                head += "Content-Length: \(pem.count)\r\n"
                head += "Connection: close\r\n\r\n"
                response = Data(head.utf8) + pem
            } else {
                response = simpleHTTP(status: "503 Service Unavailable",
                                      contentType: "text/plain; charset=utf-8",
                                      body: Data("CA not generated yet.".utf8))
            }
        } else {
            // 配置页 `/`（及任何未知路径的降级）。
            let ip = NetworkInterfaces.primaryIP()
            let ssid = MobileConfigBuilder.currentSSID()
            let html = MobileConfigBuilder.landingPageHTML(ip: ip, port: NetCaptureEnv.port,
                                                           ssid: ssid, userAgent: userAgent)
            response = simpleHTTP(status: "200 OK",
                                  contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        }

        client.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    /// 描述文件（`.mobileconfig`）HTTP 响应。
    private func profileResponse(_ profile: String, filename: String) -> Data {
        let data = Data(profile.utf8)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/x-apple-aspen-config\r\n"
        head += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + data
    }

    /// 302 回配置页 `/`。
    private func redirectToIndex() -> Data {
        var head = "HTTP/1.1 302 Found\r\n"
        head += "Location: /\r\n"
        head += "Content-Length: 0\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    private func simpleHTTP(status: String, contentType: String, body: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// 从原始请求头字节里解析 `User-Agent`（大小写不敏感）。取不到返回空串。
    private func userAgent(fromRequestHead data: Data) -> String {
        guard let headerEnd = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return "" }
        let headText = String(data: data.subdata(in: data.startIndex..<headerEnd.lowerBound),
                              encoding: .isoLatin1) ?? ""
        for line in headText.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("user-agent:") {
                let idx = line.index(line.startIndex, offsetBy: "user-agent:".count)
                return String(line[idx...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    // MARK: - 中继引擎（明文侧 ↔ 上游，tee 解析产出 Flow）

    /// 在「已是明文」的两端之间做全双工中继，并 tee 出请求/响应解析器产出 Flow。
    /// 适用于明文 HTTP（clientSide = 原客户端连接）与 MITM（clientSide = 回环 TLS 服务端连接）。
    private func startRelayEngine(clientSide: NWConnection, upstream: NWConnection,
                                  scheme: String, host: String, port: Int,
                                  initialClientData: Data?) {
        let engine = RelayEngine(scheme: scheme, host: host, port: port,
                                 remoteIP: remoteIP(of: upstream)) { [weak self] flow in
            self?.appendFlow(flow)
        }

        // 客户端 → 上游：tee 进请求解析器。
        let reqTee: (Data) -> Void = { data in engine.consumeRequestBytes(data) }
        // 上游 → 客户端：tee 进响应解析器。
        let respTee: (Data) -> Void = { data in engine.consumeResponseBytes(data) }

        if let initial = initialClientData, !initial.isEmpty {
            reqTee(initial)
            upstream.send(content: initial, completion: .contentProcessed { _ in })
        }
        pump(from: clientSide, to: upstream, tee: reqTee) { [weak self] in self?.finish() }
        pump(from: upstream, to: clientSide, tee: respTee) { [weak self] in
            engine.finishResponses()
            self?.finish()
        }
    }

    // MARK: - 盲隧道（透传）

    /// 原始 TCP 双向中继，只记录 CONNECT 元数据（host/port、上下行字节）。绝不中断设备。
    private func startBlindTunnel(host: String, port: Int, note: String) {
        // 记一条「未解密」flow，结束时结算字节。
        tunnelFlow = Flow(method: "CONNECT", scheme: "https", host: host, port: port, path: "",
                          startedAt: Date(), decrypted: false, note: note)

        let upstream = makeUpstreamConnection(host: host, port: port, tls: false)
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(from: self.client, to: upstream,
                          tee: { [weak self] d in self?.tunnelUpBytes += d.count }) { [weak self] in self?.finish() }
                self.pump(from: upstream, to: self.client,
                          tee: { [weak self] d in self?.tunnelDownBytes += d.count }) { [weak self] in self?.finish() }
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        children.append(upstream)
        upstream.start(queue: queue)
    }

    // MARK: - 中继原语

    /// 从 source 循环读并写入 dest；每段字节回调 tee（用于计数/解析）。EOF/错误时调 onEOF 一次。
    private func pump(from source: NWConnection, to dest: NWConnection,
                      tee: ((Data) -> Void)?, onEOF: @escaping () -> Void) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard self != nil else { return }
            if let data, !data.isEmpty {
                tee?(data)
                dest.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                onEOF()
                return
            }
            self?.pump(from: source, to: dest, tee: tee, onEOF: onEOF)
        }
    }

    // MARK: - 辅助

    /// 建到上游的连接。tls=true 用 TLS 客户端（SNI=host，ALPN 仅 http/1.1，系统信任校验服务器证书）。
    private func makeUpstreamConnection(host: String, port: Int, tls: Bool) -> NWConnection {
        let nwHost = NWEndpoint.Host(host)
        // 安全构造端口：越界值退回默认端口，避免 UInt16 溢出崩溃。
        let nwPort: NWEndpoint.Port
        if let raw = UInt16(exactly: port), let p = NWEndpoint.Port(rawValue: raw) {
            nwPort = p
        } else {
            nwPort = tls ? 443 : 80
        }
        let params: NWParameters
        if tls {
            let tlsOptions = NWProtocolTLS.Options()
            let sec = tlsOptions.securityProtocolOptions
            sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
            sec_protocol_options_set_tls_server_name(sec, host)
            sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
            // 默认使用系统信任评估校验真实服务器证书。
            params = NWParameters(tls: tlsOptions)
        } else {
            params = NWParameters.tcp
        }
        return NWConnection(host: nwHost, port: nwPort, using: params)
    }

    /// 取上游远端 IP（尽力，可能为 nil）。
    private func remoteIP(of connection: NWConnection) -> String? {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return nil }
        if case let .hostPort(host, _) = endpoint {
            switch host {
            case .ipv4(let addr): return "\(addr)"
            case .ipv6(let addr): return "\(addr)"
            case .name(let name, _): return name
            @unknown default: return nil
            }
        }
        return nil
    }

    /// "host:port" → (host, port)；无端口用 default。
    private func splitHostPort(_ target: String, defaultPort: Int) -> (String, Int) {
        if let idx = target.lastIndex(of: ":") {
            let host = String(target[target.startIndex..<idx])
            let portStr = String(target[target.index(after: idx)...])
            return (host, Int(portStr) ?? defaultPort)
        }
        return (target, defaultPort)
    }

    /// 回主线程追加 flow。一处统一给所有 flow 打上源设备 IP（§17）：RelayEngine 产出、
    /// 盲隧道 tunnelFlow、magic 域名本地应答的 flow 都经此，故设备标记不遗漏。
    private func appendFlow(_ flow: Flow) {
        var f = flow
        f.clientIP = clientIP
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                FlowStore.shared.append(f)
            }
        }
    }
}

// MARK: - 中继解析引擎

/// 把明文请求/响应字节流增量解析为成对的 Flow（keep-alive 下 FIFO 配对）。
/// 只在所属 `ProxyConnection` 的串行队列上被调用，无需额外锁（故 `@unchecked Sendable`）。
private final class RelayEngine: @unchecked Sendable {
    private let scheme: String
    private let host: String
    private let port: Int
    private let remoteIP: String?
    private let emit: (Flow) -> Void

    private let reqParser = HTTPParser(role: .request)
    private let respParser = HTTPParser(role: .response)
    /// 已完成、等待配对响应的请求（FIFO）。
    private var pendingRequests: [(ParsedHTTPMessage, Date)] = []

    init(scheme: String, host: String, port: Int, remoteIP: String?, emit: @escaping (Flow) -> Void) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.remoteIP = remoteIP
        self.emit = emit
    }

    func consumeRequestBytes(_ data: Data) {
        reqParser.feed(data)
        while let message = reqParser.nextMessage() {
            pendingRequests.append((message, Date()))
            // 让响应解析器知道最近的请求方法（HEAD 等无 body 语义判定）。
            respParser.lastRequestMethod = message.method
        }
    }

    func consumeResponseBytes(_ data: Data) {
        respParser.feed(data)
        while let response = respParser.nextMessage() {
            pairAndEmit(response)
        }
    }

    /// 上游连接结束：对「读到连接关闭」型响应收尾。
    func finishResponses() {
        if let response = respParser.finish() {
            pairAndEmit(response)
        }
    }

    private func pairAndEmit(_ response: ParsedHTTPMessage) {
        guard !pendingRequests.isEmpty else { return }
        let (request, started) = pendingRequests.removeFirst()
        let path = pathFromTarget(request.requestTarget)
        var flow = Flow(
            method: request.method,
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            requestHeaders: request.headers,
            requestBody: request.body.isEmpty ? nil : request.body,
            requestTruncated: request.truncated,
            statusCode: response.statusCode,
            responseHeaders: response.headers,
            responseBody: response.body.isEmpty ? nil : response.body,
            responseTruncated: response.truncated,
            startedAt: started,
            endedAt: Date(),
            requestBytes: request.consumedBytes,
            responseBytes: response.consumedBytes,
            remoteIP: remoteIP,
            decrypted: true,
            note: response.truncated || request.truncated ? L("netcapture.note.truncated") : nil
        )
        // brotli 等未解压提示挪到 note。
        if let ce = response.headers.value(for: "Content-Encoding")?.lowercased(),
           ce.contains("br"), flow.note == nil {
            flow.note = L("netcapture.note.brotli")
        }
        emit(flow)
    }

    /// 请求目标 → path：绝对形式取 URL 的 path+query；origin 形式原样。
    private func pathFromTarget(_ target: String) -> String {
        if target.lowercased().hasPrefix("http://") || target.lowercased().hasPrefix("https://") {
            if let comps = URLComponents(string: target) {
                let query = comps.query.map { "?\($0)" } ?? ""
                return (comps.path.isEmpty ? "/" : comps.path) + query
            }
        }
        return target.isEmpty ? "/" : target
    }
}
