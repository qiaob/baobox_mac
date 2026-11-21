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
/// 由 `ConfigPageServer` 在它的队列上调用。任何一步失败都降级：拿不到 CA → 返回 nil（调用方回 503），
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

    /// 给 iPhone 代理描述文件用的 Wi-Fi 名称：读得到就用系统的，读不到用用户在手机面板里填的；都没有 → nil
    /// （`/proxy` 回首页，页面改为手动说明）。macOS 14.4 起没有定位权限读不到当前 Wi-Fi 名，
    /// 2026-11 在 macOS 27 上实测 networksetup、ipconfig、CoreWLAN 都拿不到，所以实际走的基本是手填这条。
    static func currentSSID() -> String? {
        if let detected = currentWiFiSSID() { return detected }
        let saved = (UserDefaults.standard.string(forKey: NetCaptureEnv.Keys.wifiName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? nil : saved
    }

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
    /// - Android·其它：证书链接 + 主机名 / 端口各带一个复制按钮 + 直达 Wi-Fi 设置的按钮 + 手动步骤（含 ADB 提示）。
    /// `ssid` 为空时 iOS 的「配代理」改为手动说明（因无 SSID 无法出 Wi-Fi 描述文件）。
    static func landingPageHTML(ip: String, port: UInt16, ssid: String?, userAgent: String) -> String {
        let isIOS = PhoneBrowser.isIOS(userAgent: userAgent)
        // iOS 上只有 Safari 能装描述文件。相机扫码开的是默认浏览器，默认浏览器是 Chrome 时只会下到一个打不开的文件
        // （2026-11-21 用户真机遇到）。这种情况不给安装按钮，只请他换到 Safari。
        let needsSafari = isIOS && !PhoneBrowser.isIOSSafari(userAgent: userAgent)
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
                <p class="hint">Chrome 提示「无法安全下载」时选<b>保留</b>。<br>If Chrome says the file can't be downloaded securely, choose <b>Keep</b>.</p>
                <p class="hint">下载后到系统设置里安装（直接点开下载的文件装不了）：<b>设置 › 安全和隐私 › 更多安全和隐私 › 加密与凭据 › 安装证书 › CA 证书</b>，选刚下载的文件。<br>Then install it from Settings (opening the downloaded file won't work): <b>Settings › Security &amp; privacy › More security &amp; privacy › Encryption &amp; credentials › Install a certificate › CA certificate</b>, and pick the downloaded file.</p>
                """)

            // Android 没有让网页设置 Wi-Fi 代理的机制（iOS 靠描述文件，Android 没有对应的东西），只能手填。
            // 所以把手填做到最省事：主机名和端口分开各一个复制按钮（系统的代理表单就是这两个框），再给一个直达 Wi-Fi 设置的按钮。
            proxyCard = card(
                num: "2", title: "配代理 / Set proxy",
                body: """
                <div class="kv"><span>主机名 Host</span><b id="host">\(htmlEscape(ip))</b><button class="mini" onclick="copyText('host',this)">复制 Copy</button></div>
                <div class="kv"><span>端口 Port</span><b id="port">\(port)</b><button class="mini" onclick="copyText('port',this)">复制 Copy</button></div>
                <a class="btn ghost" href="intent:#Intent;action=android.settings.WIFI_SETTINGS;end">打开 Wi-Fi 设置 / Open Wi-Fi settings</a>
                <p class="hint">Android 不允许网页修改代理，需要手动填一次：<b>Wi-Fi › 当前网络 › 修改 › 高级选项 › 代理 › 手动</b>，填入上面的主机名和端口。<br>Android doesn't let a web page change the proxy. Enter it once by hand: <b>Wi-Fi › current network › Modify › Advanced › Proxy › Manual</b>.<br>连着 USB 调试时，可以在电脑的抓包窗口里一键设置。 / With USB debugging connected, the Mac can set it in one click.</p>
                """)

            offCard = card(
                num: "3", title: "关代理 / Turn proxy off",
                body: """
                <p class="hint">到 <b>Wi-Fi › 修改网络 › 代理</b> 改回 <b>无</b>。<br>Set <b>Wi-Fi › Modify network › Proxy</b> back to <b>None</b>. / 或用 ADB 清除。 / or clear via ADB.</p>
                """)
        }

        // 复制：这个页面是 http 的局域网地址，不算「安全上下文」，`navigator.clipboard` 在这里不存在
        // （2026-11-21 用户在 Android 上点复制没反应就是这个原因）。所以走老办法：临时文本框 + execCommand。
        // 都不行时把按钮文字换成「长按复制」，数值本身设了 user-select: all，长按就是整段选中。
        let copyJS = (isIOS && !needsSafari) ? "" : """
        <script>
        function copyText(id, btn){
          var t = document.getElementById(id).textContent;
          function done(ok){ btn.textContent = ok ? '已复制 ✓' : '长按复制'; }
          function legacy(){
            var ta = document.createElement('textarea');
            ta.value = t; ta.setAttribute('readonly', '');
            ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
            document.body.appendChild(ta);
            ta.focus(); ta.select(); ta.setSelectionRange(0, t.length);
            var ok = false;
            try { ok = document.execCommand('copy'); } catch (e) {}
            document.body.removeChild(ta);
            done(ok);
          }
          if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(t).then(function(){ done(true); }, legacy);
          } else {
            legacy();
          }
        }
        </script>
        """

        // 换到 Safari：只能请他复制地址。`x-safari-https://` 能从别的浏览器直接跳到 Safari，但只有 https 这一种；
        // 这个页面是 http 的，对应的 `x-safari-http://` 系统不认（2026-11-21 在 iOS 18.3 模拟器上试过，没有 App 接这个地址）。
        let pageHost = "\(ip):\(NetCaptureEnv.configPagePort)/"
        let cards: String
        if needsSafari {
            cards = """
            <div class="card"><h2>请用 Safari 打开这个页面 / Open this page in Safari</h2>
            <p class="hint" style="margin:0 0 12px">iOS 只允许 Safari 安装证书和代理的描述文件，这个浏览器下载后装不了。<br>On iOS only Safari can install the certificate and proxy profiles. This browser cannot.</p>
            <div class="kv"><b id="pageurl" style="font-size:16px">http://\(htmlEscape(pageHost))</b><button class="mini" onclick="copyText('pageurl',this)">复制 Copy</button></div>
            <p class="hint">复制上面的地址，打开 Safari，粘贴到地址栏。<br>Copy the address above, open Safari and paste it into the address bar.</p>
            </div>
            """
        } else {
            cards = certCard + "\n" + proxyCard + "\n" + offCard
        }

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
        .kv{display:flex;align-items:center;gap:10px;margin:10px 0}
        .kv span{color:var(--sub);font-size:13px;flex:0 0 auto}
        .kv b{font-size:19px;flex:1;white-space:nowrap;-webkit-user-select:all;user-select:all}
        .mini{flex:0 0 auto;padding:8px 12px;border-radius:8px;border:1.5px solid var(--accent);background:transparent;color:var(--accent);font-size:13px;font-weight:600}
        .card .btn.ghost{margin-top:4px}
        .foot{font-size:12px;color:var(--sub);text-align:center;margin-top:24px}
        </style></head>
        <body><div class="wrap">
        <h1>Baobox 抓包配置 / Capture Setup</h1>
        <p class="hint" style="text-align:center">当前代理 / Proxy</p>
        <div class="big">\(addrEsc)</div>
        \(cards)
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

    // MARK: - CA 的 DER 字节

    private static func caCertDER() -> Data? { CaptureCA.shared.certDER() }

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
