import Foundation

/// 生成**未签名**的 Apple 配置描述文件（`.mobileconfig`，§16.2）：
/// - CA 根证书 payload（`com.apple.security.root`，DER base64）——安装即导入根证书；
/// - 可选 Wi-Fi payload（`com.apple.wifi.managed`）——为当前 SSID 设手动代理指向 Mac。
///
/// 供 iOS 扫码 `http://baobox.proxy/profile` 一键装证书并配代理（信任仍需用户手动到「证书信任设置」开启）。
///
/// 并发：全部为后台可调用的纯字符串拼接 + 子进程读取（`networksetup` 读 SSID），**不**标 `@MainActor`；
/// 由 `ProxyConnection` 在其连接队列上调用。任何一步失败都降级：拿不到 SSID → 仅 CA payload；
/// 拿不到 CA → 返回 nil（调用方回 503），绝不 crash。
enum MobileConfigBuilder {

    private static let networksetup = "/usr/sbin/networksetup"

    /// 构建 `.mobileconfig` plist 文本。CA 未生成返回 nil。SSID 读取失败/非 Wi-Fi → 仅出 CA payload。
    static func build(proxyIP: String, proxyPort: UInt16) -> String? {
        guard let der = caCertDER() else { return nil }
        var payloads = [caPayload(der: der)]
        if let ssid = currentWiFiSSID(), !ssid.isEmpty {
            payloads.append(wifiPayload(ssid: ssid, proxyIP: proxyIP, proxyPort: proxyPort))
        }
        let content = payloads.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>PayloadContent</key>
          <array>
        \(content)
          </array>
          <key>PayloadDisplayName</key>
          <string>Baobox Proxy</string>
          <key>PayloadDescription</key>
          <string>Baobox capture CA and Wi-Fi proxy</string>
          <key>PayloadIdentifier</key>
          <string>com.baobox.netcapture.profile</string>
          <key>PayloadOrganization</key>
          <string>Baobox</string>
          <key>PayloadRemovalDisallowed</key>
          <false/>
          <key>PayloadType</key>
          <string>Configuration</string>
          <key>PayloadUUID</key>
          <string>\(UUID().uuidString)</string>
          <key>PayloadVersion</key>
          <integer>1</integer>
        </dict>
        </plist>
        """
    }

    // MARK: - Payload 构建

    /// CA 根证书 payload：PayloadContent 为 CA 证书的 DER（plist `<data>` 即 base64）。
    private static func caPayload(der: Data) -> String {
        """
            <dict>
              <key>PayloadCertificateFileName</key>
              <string>baobox-ca.cer</string>
              <key>PayloadContent</key>
              <data>
              \(der.base64EncodedString())
              </data>
              <key>PayloadDescription</key>
              <string>Baobox root CA</string>
              <key>PayloadDisplayName</key>
              <string>Baobox Proxy CA</string>
              <key>PayloadIdentifier</key>
              <string>com.baobox.netcapture.ca</string>
              <key>PayloadType</key>
              <string>com.apple.security.root</string>
              <key>PayloadUUID</key>
              <string>\(UUID().uuidString)</string>
              <key>PayloadVersion</key>
              <integer>1</integer>
            </dict>
        """
    }

    /// Wi-Fi payload：为当前 SSID 设手动代理（普通设备用按 SSID 的 Wi-Fi payload，不用监督级全局代理）。
    private static func wifiPayload(ssid: String, proxyIP: String, proxyPort: UInt16) -> String {
        """
            <dict>
              <key>PayloadType</key>
              <string>com.apple.wifi.managed</string>
              <key>PayloadIdentifier</key>
              <string>com.baobox.netcapture.wifi</string>
              <key>PayloadUUID</key>
              <string>\(UUID().uuidString)</string>
              <key>PayloadVersion</key>
              <integer>1</integer>
              <key>PayloadDisplayName</key>
              <string>Wi-Fi Proxy</string>
              <key>SSID_STR</key>
              <string>\(xmlEscape(ssid))</string>
              <key>HIDDEN_NETWORK</key>
              <false/>
              <key>AutoJoin</key>
              <true/>
              <key>EncryptionType</key>
              <string>Any</string>
              <key>ProxyType</key>
              <string>Manual</string>
              <key>ProxyServer</key>
              <string>\(xmlEscape(proxyIP))</string>
              <key>ProxyServerPort</key>
              <integer>\(proxyPort)</integer>
            </dict>
        """
    }

    // MARK: - CA PEM → DER

    /// 读 `baobox-ca.pem`，剥离 PEM 头尾（`-----BEGIN/END-----`）后 base64-decode 得 DER 字节。失败 nil。
    private static func caCertDER() -> Data? {
        guard let pem = MITMCertAuthority.shared.caCertPEM(),
              let text = String(data: pem, encoding: .utf8) else { return nil }
        let base64 = text
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: base64)
    }

    // MARK: - 当前 Wi-Fi SSID

    /// 读当前连接的 Wi-Fi SSID。非 Wi-Fi / 未关联 / 读取失败 → nil。
    private static func currentWiFiSSID() -> String? {
        guard let iface = wifiInterface() else { return nil }
        let result = NetCaptureEnv.run(networksetup, ["-getairportnetwork", iface])
        guard result.ok else { return nil }
        // 关联时输出 "Current Wi-Fi Network: <SSID>"；未关联输出 "You are not associated ..."。
        let out = result.stdoutString
        let marker = "Current Wi-Fi Network: "
        guard let range = out.range(of: marker) else { return nil }
        let ssid = String(out[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ssid.isEmpty ? nil : ssid
    }

    /// 找 Wi-Fi 硬件端口对应的 BSD 设备名（如 `en0`）。解析 `networksetup -listallhardwareports`。
    private static func wifiInterface() -> String? {
        let result = NetCaptureEnv.run(networksetup, ["-listallhardwareports"])
        guard result.ok else { return nil }
        var inWiFiBlock = false
        for line in result.stdoutString.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                let name = trimmed.replacingOccurrences(of: "Hardware Port:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                inWiFiBlock = (name == "Wi-Fi" || name == "AirPort")
            } else if inWiFiBlock, trimmed.hasPrefix("Device:") {
                let dev = trimmed.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return dev.isEmpty ? nil : dev
            }
        }
        return nil
    }

    // MARK: - 辅助

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
