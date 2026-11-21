import Foundation
import Network

/// 手机配置页的小 HTTP 服务（docs/packet-capture/TECH_DESIGN.md §7）。
///
/// 手机扫码打开 `http://<Mac 的局域网 IP>:<端口>/`，页面里装证书、配代理、关代理。它不经过代理，
/// 所以手机还没设好代理时也打得开（v1 靠代理拦截一个假域名来给页面，必须先设代理）。
///
/// 只应答四个 GET 路由，内容都由 `MobileConfigBuilder` 生成；只发公开证书和描述文件，不涉及抓到的内容，
/// 所以不做设备准入。只在听局域网时开着。带着二维码里的口令来开 `/` 的设备，顺手在引擎那边放行。
final class ConfigPageServer: @unchecked Sendable {
    static let shared = ConfigPageServer()

    private let queue = DispatchQueue(label: "com.baobox.netcapture.configpage")
    private var listener: NWListener?
    private var proxyPort: UInt16 = 0

    private init() {}

    /// 开始监听。已在监听就先停掉重来（端口可能变了）。
    func start(port: UInt16) {
        let proxyPort = NetCaptureEnv.port
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.proxyPort = proxyPort
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port),
                  let listener = try? NWListener(using: params, on: nwPort) else { return }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: self.queue)
            self.listener = listener
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    // MARK: - 扫码即放行

    /// 带着二维码里的口令来开配置页的设备直接放行（`PhonePairing`）。
    private func admitIfPaired(_ connection: NWConnection, requestTarget: String, forwardedClient: String?, localIP: String) {
        guard PhonePairing.tokenMatches(requestTarget: requestTarget, token: NetCaptureEnv.pairingToken),
              case .hostPort(let host, _) = connection.endpoint,
              let address = PhonePairing.deviceToAdmit(remote: "\(host)", forwardedClient: forwardedClient,
                                                       localAddresses: [localIP]) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { NetCaptureEngine.shared.allow(device: address) }
        }
    }

    // MARK: - 一条连接：读请求头 → 回一次 → 关

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.respond(connection, requestHead: head)
            } else if error != nil || isComplete || buffer.count > 32 * 1024 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, requestHead: String) {
        let lines = requestHead.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2, requestLine[0] == "GET" else {
            send(connection, status: "405 Method Not Allowed", contentType: "text/plain", body: Data())
            return
        }
        // 只看路径，查询串忽略。
        let path = requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let userAgent = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("user-agent:") }
            .map { String($0.dropFirst("user-agent:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        let isIOS = PhoneBrowser.isIOS(userAgent: userAgent)
        let ip = NetworkInterfaces.primaryIP()

        switch path {
        case "/":
            let forwarded = lines.dropFirst()
                .first { $0.lowercased().hasPrefix("x-baobox-client:") }
                .map { String($0.dropFirst("x-baobox-client:".count)).trimmingCharacters(in: .whitespaces) }
            admitIfPaired(connection, requestTarget: String(requestLine[1]), forwardedClient: forwarded, localIP: ip)
            let html = MobileConfigBuilder.landingPageHTML(ip: ip, port: proxyPort,
                                                           ssid: MobileConfigBuilder.currentSSID(),
                                                           userAgent: userAgent)
            send(connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8))
        case "/cert":
            CaptureCA.shared.ensureGenerated()
            if isIOS, let profile = MobileConfigBuilder.caProfile() {
                send(connection, status: "200 OK", contentType: "application/x-apple-aspen-config",
                     body: Data(profile.utf8), filename: "baobox-ca.mobileconfig")
            } else if !isIOS, let pem = CaptureCA.shared.certPEM() {
                send(connection, status: "200 OK", contentType: "application/x-x509-ca-cert",
                     body: pem, filename: "baobox-ca.crt")
            } else {
                send(connection, status: "503 Service Unavailable", contentType: "text/plain", body: Data())
            }
        case "/proxy":
            if isIOS, let ssid = MobileConfigBuilder.currentSSID() {
                let profile = MobileConfigBuilder.proxyProfile(ssid: ssid, ip: ip, port: proxyPort)
                send(connection, status: "200 OK", contentType: "application/x-apple-aspen-config",
                     body: Data(profile.utf8), filename: "baobox-proxy.mobileconfig")
            } else {
                redirectHome(connection)
            }
        case "/proxy-off":
            if isIOS, let ssid = MobileConfigBuilder.currentSSID() {
                let profile = MobileConfigBuilder.proxyOffProfile(ssid: ssid)
                send(connection, status: "200 OK", contentType: "application/x-apple-aspen-config",
                     body: Data(profile.utf8), filename: "baobox-proxy-off.mobileconfig")
            } else {
                redirectHome(connection)
            }
        case "/favicon.ico":
            // 浏览器会自己来要图标；没有，安静地回个空。
            send(connection, status: "204 No Content", contentType: "image/x-icon", body: Data())
        default:
            send(connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func redirectHome(_ connection: NWConnection) {
        let head = "HTTP/1.1 302 Found\r\nLocation: /\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func send(_ connection: NWConnection, status: String, contentType: String, body: Data,
                      filename: String? = nil) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        if let filename { head += "Content-Disposition: attachment; filename=\"\(filename)\"\r\n" }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}
