import Foundation

/// 生成**未签名**的 Apple 配置描述文件（`.mobileconfig`，§16.2）与手机端「单一配置网页」HTML。
///
/// 三个**独立**描述文件构建器（各只含一种 payload，标识固定 → 同类可互相覆盖）：
/// - `caProfile()`      —— 仅 CA 根证书 payload（`com.apple.security.root`，DER base64）。
/// - `proxyProfile(...)` —— 仅 Wi-Fi payload（`com.apple.wifi.managed`，`ProxyType=Manual`）。
/// - `proxyOffProfile(...)` —— 同 Wi-Fi payload 但 `ProxyType=None`（关代理）。
///
/// 外加 `landingPageHTML(...)` 生成给手机浏览器的自适应配置页（内联 CSS、双语、深浅色）。
///
/// 并发：全部为后台可调用的纯字符串拼接 + 子进程读取（`networksetup` 读 SSID），**不**标 `@MainActor`；
/// 由 `ProxyConnection` 在其连接队列上调用。任何一步失败都降级：拿不到 CA → 返回 nil（调用方回 503），
/// 拿不到 SSID → 网页照常渲染（Android 路径 / iOS 显示手动说明），`/proxy` 回 302，绝不 crash。
enum MobileConfigBuilder {

    private static let networksetup = "/usr/sbin/networksetup"

    // MARK: - 描述文件构建器（各一种 payload）

    /// CA-only 描述文件（`application/x-apple-aspen-config`）。CA 未生成返回 nil。
    static func caProfile() -> String? {
        guard let der = caCertDER() else { return nil }
        return profile(displayName: "Baobox Proxy CA",
                       description: "Baobox capture root CA",
                       identifier: "com.baobox.netcapture.ca",
                       payloads: [caPayload(der: der)])
    }

    /// 仅 Wi-Fi 手动代理描述文件：为 `ssid` 设 `ProxyType=Manual`，指向 `ip:port`。
    static func proxyProfile(ssid: String, ip: String, port: UInt16) -> String {
        profile(displayName: "Baobox Wi-Fi Proxy",
                description: "Baobox capture Wi-Fi proxy",
                identifier: "com.baobox.netcapture.proxy",
                payloads: [wifiPayload(ssid: ssid, proxyType: "Manual", proxyIP: ip, proxyPort: port)])
    }

    /// 关代理描述文件：同 Wi-Fi payload 但 `ProxyType=None`（覆盖此前的手动代理设置）。
    static func proxyOffProfile(ssid: String) -> String {
        profile(displayName: "Baobox Wi-Fi Proxy Off",
                description: "Baobox turn Wi-Fi proxy off",
                identifier: "com.baobox.netcapture.proxy",
                payloads: [wifiPayload(ssid: ssid, proxyType: "None", proxyIP: nil, proxyPort: nil)])
    }

    /// 当前连接的 Wi-Fi SSID（供路由决定 `/proxy` 是否可出描述文件）。非 Wi-Fi / 读取失败 → nil。
    static func currentSSID() -> String? { currentWiFiSSID() }

    // MARK: - plist 外壳

    /// 把若干 payload 段包进 `Configuration` plist 外壳。
    private static func profile(displayName: String, description: String,
                                identifier: String, payloads: [String]) -> String {
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
          <string>\(xmlEscape(displayName))</string>
          <key>PayloadDescription</key>
          <string>\(xmlEscape(description))</string>
          <key>PayloadIdentifier</key>
          <string>\(identifier)</string>
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

    /// Wi-Fi payload：为 `ssid` 设代理（`Manual` 时带 server/port；`None` 时省略）。
    /// 普通设备用按 SSID 的 Wi-Fi payload，不用监督级全局代理。
    private static func wifiPayload(ssid: String, proxyType: String,
                                    proxyIP: String?, proxyPort: UInt16?) -> String {
        var lines = [
            "        <dict>",
            "          <key>PayloadType</key>",
            "          <string>com.apple.wifi.managed</string>",
            "          <key>PayloadIdentifier</key>",
            "          <string>com.baobox.netcapture.wifi</string>",
            "          <key>PayloadUUID</key>",
            "          <string>\(UUID().uuidString)</string>",
            "          <key>PayloadVersion</key>",
            "          <integer>1</integer>",
            "          <key>PayloadDisplayName</key>",
            "          <string>Wi-Fi Proxy</string>",
            "          <key>SSID_STR</key>",
            "          <string>\(xmlEscape(ssid))</string>",
            "          <key>HIDDEN_NETWORK</key>",
            "          <false/>",
            "          <key>AutoJoin</key>",
            "          <true/>",
            "          <key>EncryptionType</key>",
            "          <string>Any</string>",
            "          <key>ProxyType</key>",
            "          <string>\(proxyType)</string>"
        ]
        if proxyType == "Manual", let ip = proxyIP, let port = proxyPort {
            lines.append("          <key>ProxyServer</key>")
            lines.append("          <string>\(xmlEscape(ip))</string>")
            lines.append("          <key>ProxyServerPort</key>")
            lines.append("          <integer>\(port)</integer>")
        }
        lines.append("        </dict>")
        return lines.joined(separator: "\n")
    }

    // MARK: - 配置网页（给手机浏览器，非 App UI，双语内联，不走 xcstrings）

    /// 生成 `GET /` 的自包含 HTML。按 `userAgent` 区分 iOS / Android·其它。
    /// - iOS：三张卡各给一个可点的描述文件链接（`/cert`、`/proxy`、`/proxy-off`）。
    /// - Android·其它：证书链接 + 大字 `IP:端口` + 复制按钮 + 手动步骤（含 ADB 提示）。
    /// `ssid` 为空时 iOS 的「配代理」改为手动说明（因无 SSID 无法出 Wi-Fi 描述文件）。
    static func landingPageHTML(ip: String, port: UInt16, ssid: String?, userAgent: String) -> String {
        let isIOS = userAgent.contains("iPhone") || userAgent.contains("iPad") || userAgent.contains("iPod")
        let addr = "\(ip):\(port)"
        let addrEsc = htmlEscape(addr)
        let hasSSID = (ssid?.isEmpty == false)

        let certCard: String
        let proxyCard: String
        let offCard: String

        if isIOS {
            certCard = card(
                num: "1", title: "装证书 / Install CA",
                body: """
                <a class="btn" href="/cert">安装证书描述文件 / Install CA profile</a>
                <p class="hint">安装后到 <b>设置 › 通用 › VPN与设备管理</b> 完成安装，再到 <b>设置 › 通用 › 关于本机 › 证书信任设置</b> 开启完全信任。<br>After installing, finish in <b>Settings › General › VPN &amp; Device Management</b>, then enable full trust in <b>Settings › General › About › Certificate Trust Settings</b>.</p>
                """)

            if hasSSID {
                proxyCard = card(
                    num: "2", title: "配代理 / Set proxy",
                    body: """
                    <a class="btn" href="/proxy">一键配置代理 / One-tap set proxy</a>
                    <p class="addr">\(addrEsc)</p>
                    <p class="hint">为当前 Wi-Fi 自动设手动代理，指向本机。<br>Installs a Manual proxy for the current Wi-Fi pointing to this Mac.</p>
                    """)
            } else {
                proxyCard = card(
                    num: "2", title: "配代理 / Set proxy",
                    body: """
                    <p class="addr">\(addrEsc)</p>
                    <p class="hint">未能读取本机 Wi-Fi 名称，请到 <b>设置 › Wi-Fi › （当前网络）› 配置代理 › 手动</b> 填入上面的地址。<br>Could not read this Mac's Wi-Fi name; set it manually in <b>Settings › Wi-Fi › (current) › Configure Proxy › Manual</b> with the address above.</p>
                    """)
            }

            offCard = card(
                num: "3", title: "关代理 / Turn proxy off",
                body: """
                <a class="btn ghost" href="/proxy-off">一键关闭代理 / One-tap turn off</a>
                <p class="hint">或到 <b>设置 › 通用 › VPN与设备管理</b> 删除 Baobox 描述文件。<br>Or delete the Baobox profile in <b>Settings › General › VPN &amp; Device Management</b>.</p>
                """)
        } else {
            certCard = card(
                num: "1", title: "装证书 / Install CA",
                body: """
                <a class="btn" href="/cert">下载证书 / Download CA (.crt)</a>
                <p class="hint">下载后按系统提示安装（<b>设置 › 安全 › 加密与凭据 › 安装证书 › CA 证书</b>）。<br>Install the downloaded file (<b>Settings › Security › Encryption &amp; credentials › Install a certificate › CA certificate</b>).</p>
                """)

            proxyCard = card(
                num: "2", title: "配代理 / Set proxy",
                body: """
                <p class="addr" id="addr">\(addrEsc)</p>
                <button class="btn" onclick="copyAddr()">复制 / Copy</button>
                <p class="hint">在 <b>Wi-Fi › 修改网络 › 代理 › 手动</b> 填入主机与端口。<br>In <b>Wi-Fi › Modify network › Proxy › Manual</b> enter the host and port.<br>或在电脑上用 ADB 一键。 / or use ADB on the computer.</p>
                """)

            offCard = card(
                num: "3", title: "关代理 / Turn proxy off",
                body: """
                <p class="hint">到 <b>Wi-Fi › 修改网络 › 代理</b> 改回 <b>无</b>。<br>Set <b>Wi-Fi › Modify network › Proxy</b> back to <b>None</b>. / 或用 ADB 清除。 / or clear via ADB.</p>
                """)
        }

        let copyJS = isIOS ? "" : """
        <script>
        function copyAddr(){var t=document.getElementById('addr').textContent;
        if(navigator.clipboard){navigator.clipboard.writeText(t);}
        }
        </script>
        """

        return """
        <!doctype html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Baobox 抓包配置 / Baobox Capture Setup</title>
        <style>
        :root{--accent:#17A398;--bg:#f5f5f7;--card:#ffffff;--fg:#1c1c1e;--sub:#6e6e73;--line:#e2e2e5}
        @media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--fg:#f5f5f7;--sub:#98989d;--line:#3a3a3c}}
        *{box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;margin:0;background:var(--bg);color:var(--fg);line-height:1.5}
        .wrap{max-width:520px;margin:0 auto;padding:24px 16px 48px}
        h1{font-size:20px;margin:8px 0 2px}
        .big{font-size:30px;font-weight:700;color:var(--accent);text-align:center;margin:14px 0;word-break:break-all}
        .card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin:14px 0}
        .card h2{font-size:16px;margin:0 0 10px;display:flex;align-items:center;gap:8px}
        .num{display:inline-flex;width:24px;height:24px;border-radius:50%;background:var(--accent);color:#fff;align-items:center;justify-content:center;font-size:14px;flex:0 0 auto}
        .btn{display:inline-block;padding:11px 18px;background:var(--accent);color:#fff;border:none;border-radius:10px;text-decoration:none;font-size:15px;font-weight:600;cursor:pointer}
        .btn.ghost{background:transparent;color:var(--accent);border:1.5px solid var(--accent)}
        .addr{font-size:22px;font-weight:700;text-align:center;margin:10px 0;word-break:break-all}
        .hint{font-size:13px;color:var(--sub);margin:10px 0 0}
        .foot{font-size:12px;color:var(--sub);text-align:center;margin-top:24px}
        </style></head>
        <body><div class="wrap">
        <h1>Baobox 抓包配置 / Capture Setup</h1>
        <p class="hint" style="text-align:center">当前代理 / Proxy</p>
        <div class="big">\(addrEsc)</div>
        \(certCard)
        \(proxyCard)
        \(offCard)
        <p class="foot">仅用于本机调试，请勿抓取他人隐私。<br>For local debugging only.</p>
        </div>\(copyJS)</body></html>
        """
    }

    /// 拼一张操作卡。
    private static func card(num: String, title: String, body: String) -> String {
        """
        <div class="card"><h2><span class="num">\(num)</span>\(title)</h2>\(body)</div>
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

    /// XML 转义（用于 plist `<string>` 值）。
    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// HTML 转义（用于网页里的动态文本，如 IP:端口）。
    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
