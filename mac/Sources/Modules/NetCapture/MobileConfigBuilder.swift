import Foundation

/// 生成**未签名**的 Apple 配置描述文件（`.mobileconfig`，§16.2）与手机端「单一配置网页」HTML。
///
/// 三个**独立**描述文件构建器（各只含一种 payload，标识固定 → 同类可互相覆盖）：
/// - `caProfile()`      —— 仅 CA 根证书 payload（`com.apple.security.root`，DER base64）。
/// - `autoProxyProfile(...)` —— 仅 Wi-Fi payload（`com.apple.wifi.managed`，`ProxyType=Auto` + PAC 地址），默认给这个。
/// - `proxyProfile(...)` —— 同上但 `ProxyType=Manual`（备选）。
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
        return profile(displayName: "Baobox Capture CA",
                       description: "Baobox capture root CA",
                       identifier: "com.baobox.netcapture.ca",
                       payloads: [caPayload(der: der)])
    }

    /// Wi-Fi 自动代理描述文件（默认给这个）：为 `ssid` 设 `ProxyType=Auto`，脚本地址是配置页的 `/proxy.pac`
    /// （内容见 `ProxyPAC`）。Baobox 没在抓包时手机自动直连。和下面两个标识相同，装哪个都会顶掉另外两个。
    static func autoProxyProfile(ssid: String, pacURL: String) -> String {
        profile(displayName: "Baobox Wi-Fi Proxy",
                description: "Baobox capture Wi-Fi proxy (automatic, falls back to direct)",
                identifier: "com.baobox.netcapture.proxy",
                payloads: [wifiPayload(ssid: ssid, proxyType: "Auto", proxyIP: nil, proxyPort: nil, pacURL: pacURL)])
    }

    /// Wi-Fi 手动代理描述文件（备选）：为 `ssid` 设 `ProxyType=Manual`，指向 `ip:port`。
    /// Baobox 没开时手机连不上网，要手动关。
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
              <string>Baobox Capture CA</string>
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
                                    proxyIP: String?, proxyPort: UInt16?, pacURL: String? = nil) -> String {
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
        if proxyType == "Auto", let pacURL {
            lines.append("          <key>ProxyPACURL</key>")
            lines.append("          <string>\(xmlEscape(pacURL))</string>")
            // 脚本取不到（Baobox 没开、Mac 不在这个网络）时直连，而不是断网。
            lines.append("          <key>ProxyPACFallbackAllowed</key>")
            lines.append("          <true/>")
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
        /// 只有 iOS 有这一张：描述文件装完，还要到「证书信任设置」里打开开关，是单独的一步。
        var trustCard = ""
        let proxyCard: String
        let offCard: String
        // 证书上的名字（手机的「证书信任设置」里按它找开关）。
        let caName = htmlEscape(CaptureCA.shared.commonName ?? "Baobox Capture CA")

        // iOS 的「打开设置」用 `com.apple.Preferences://`。2026-11-21 请用户在真 iPhone（Safari 27.2）上把九种写法
        // 逐个点过：只有这一种能跳出去，Safari 弹「在"设置"中打开此页？」后到设置首页；`App-prefs:`（各种写法）、
        // `prefs:`、`settings-navigation://`、`app-settings:` 都报「网址无效」。iOS 18.3 模拟器上 `App-prefs:` 是能用的，
        // 所以模拟器上的结果不能当真机的。到的是首页：下载描述文件后，首页最上面就是「已下载描述文件」。
        let openSettings = #"<a class="btn ghost" href="com.apple.Preferences://">打开设置 / Open Settings</a>"#
        if isIOS {
            // 装证书在 iPhone 上是两件事：装描述文件、打开信任开关。原来写在一张卡片里，看上去像一步
            // （2026-11-21 用户指出不明显），很容易装完就以为好了。拆成两张，第二张自己显示信任了没有。
            certCard = card(
                num: "1", title: "安装证书 / Install the certificate",
                body: """
                <p class="ok" id="trusted" hidden>✓ 这台设备已经信任 Baobox 的证书，不用再装。<br>This device already trusts the Baobox certificate. No need to install it again.</p>
                <a class="btn" id="certbtn" href="/cert">安装证书描述文件 / Install CA profile</a>
                \(openSettings)
                <p class="hint">点「允许」下载完，点<b>打开设置</b>：最上面会出现<b>已下载描述文件</b>，点进去，再点右上角的<b>安装</b>。<br>After allowing the download, tap <b>Open Settings</b>: <b>Profile Downloaded</b> appears at the top. Open it and tap <b>Install</b> in the top right.</p>
                <p class="hint"><b>装完还不能用，要接着做第 2 步。</b><br><b>Installing is not enough. Continue with step 2.</b></p>
                """)

            trustCard = card(
                num: "2", title: "信任证书 / Trust the certificate",
                body: """
                <p class="ok" id="trusted2" hidden>✓ 已信任，这一步完成了。<br>Trusted. This step is done.</p>
                <p class="warn" id="untrusted" hidden>还没信任。只安装、不信任，HTTPS 抓不到。<br>Not trusted yet. Without this step HTTPS cannot be captured.</p>
                \(openSettings)
                <p class="hint">在<b>设置</b>里进 <b>通用 › 关于本机</b>，拉到最下面进<b>证书信任设置</b>，打开 <b>\(caName)</b> 的开关。做完回到这个页面，这里会自己变成已信任。<br>In <b>Settings</b> go to <b>General › About</b>, scroll to the bottom, open <b>Certificate Trust Settings</b> and turn on the switch for <b>\(caName)</b>. Come back to this page and it updates by itself.</p>
                """)

            // 代理只用装一次。装的是自动代理的话，开关都在 Mac 上：开始抓包手机就走代理，停止就直连
            // （2026-11-21 用苹果的网络栈实测，两个方向都是下一个请求就切过去）。原来的页面是「开」「关」各一个
            // 描述文件，用户关掉以后不知道怎么再开 —— 其实平时根本不用关。所以这张卡片按现在的状态显示：
            // 代理没生效时给安装按钮；生效了就说明以后不用动手机。「移除」单独放在最后，写明一般不需要。
            if hasSSID {
                proxyCard = card(
                    num: "3", title: "配代理（只用装一次） / Set proxy (once)",
                    body: """
                    <div id="proxy-on" hidden>
                    <p class="ok">✓ 代理已生效，手机上不用再操作。<br>The proxy is in use. Nothing more to do on the phone.</p>
                    <p class="hint">以后开关都在 Mac 上：<b>停止抓包，手机自动直连；再开始抓包，手机又走代理。</b>（这是自动代理的行为；装的是固定代理的话，Baobox 没开时手机上不了网。）<br>From now on you switch it on the Mac: <b>stop capturing and the phone connects directly, start again and it goes through the proxy.</b> (That is the automatic proxy. With the fixed proxy the phone is offline while Baobox is not running.)</p>
                    </div>
                    <div id="proxy-setup">
                    <a class="btn" id="proxyauto" href="/proxy">自动代理（推荐） / Automatic (recommended)</a>
                    <a class="btn ghost" id="proxyfixed" href="/proxy-manual">固定代理 / Fixed</a>
                    \(openSettings)
                    <p class="hint">点一个 → 允许 → <b>打开设置</b> → 最上面的<b>已下载描述文件</b> → 安装。系统会要锁屏密码，可能还要这个 Wi-Fi 的密码，都是正常的。<br>Tap one → Allow → <b>Open Settings</b> → <b>Profile Downloaded</b> at the top → Install. iOS asks for the passcode and maybe this Wi-Fi's password; both are expected.</p>
                    <p class="hint"><b>自动代理装一次就行</b>：以后在 Mac 上开始、停止抓包，手机自动跟着切换。固定代理在 Baobox 没开时手机上不了网。<br><b>Automatic is install-once</b>: the phone follows the capture being started and stopped on the Mac. With Fixed the phone is offline while Baobox is not running.</p>
                    <p class="hint" id="hostnote">代理按这台 Mac 现在的 IP（\(htmlEscape(ip))）配置，IP 变了要回这个页面重装。<br>Set up with this Mac's current IP (\(htmlEscape(ip))). Reinstall from this page if it changes.</p>
                    </div>
                    """)
            } else {
                proxyCard = card(
                    num: "3", title: "配代理 / Set proxy",
                    body: """
                    <p class="addr">\(addrEsc)</p>
                    <p class="hint">未能读取本机 Wi-Fi 名称，请到 <b>设置 › Wi-Fi › （当前网络）› 配置代理 › 手动</b> 填入上面的地址。<br>Could not read this Mac's Wi-Fi name; set it manually in <b>Settings › Wi-Fi › (current) › Configure Proxy › Manual</b> with the address above.</p>
                    """)
            }

            offCard = card(
                num: "4", title: "移除代理（一般不需要） / Remove the proxy (rarely needed)",
                body: """
                <p class="hint" style="margin-top:0">装的是自动代理就不用移除：Mac 上停止抓包，手机就是直连。<b>不再用了</b>，或者 <b>Mac 要睡眠、关机、带走</b>（手机留在这个 Wi-Fi 会变得很慢）时再移除。<br>Nothing to remove with the automatic proxy: stop capturing on the Mac and the phone connects directly. Remove it when you are done for good, or before the Mac sleeps, shuts down or leaves (the phone gets very slow on this Wi-Fi then).</p>
                <a class="btn ghost" href="/proxy-off">移除代理 / Remove the proxy</a>
                <p class="hint"><b>以后要再用，回到这个页面重新点「自动代理」。</b>也可以到 <b>设置 › 通用 › VPN与设备管理</b> 删除 <b>Baobox Wi-Fi Proxy</b>。<br><b>To use it again, come back to this page and tap Automatic.</b> You can also delete <b>Baobox Wi-Fi Proxy</b> in <b>Settings › General › VPN &amp; Device Management</b>.</p>
                """)
        } else {
            certCard = card(
                num: "1", title: "装证书 / Install CA",
                body: """
                <p class="ok" id="trusted" hidden>✓ 这台设备已经信任 Baobox 的证书，不用再装。<br>This device already trusts the Baobox certificate. No need to install it again.</p>
                <a class="btn" id="certbtn" href="/cert">下载证书 / Download CA (.crt)</a>
                <a class="btn ghost" href="intent:#Intent;action=android.settings.SECURITY_SETTINGS;end">打开安全设置 / Open security settings</a>
                <p class="hint">Chrome 提示「无法安全下载」时选<b>保留</b>。<br>If Chrome says the file can't be downloaded securely, choose <b>Keep</b>.</p>
                <p class="hint">下载后到系统设置里安装（直接点开下载的文件装不了）。点<b>打开安全设置</b>能直接到「安全和隐私」，剩下几层浏览器不让直接跳：<b>设置 › 安全和隐私 › 更多安全和隐私 › 加密与凭据 › 安装证书 › CA 证书</b>，选刚下载的文件。<br>Then install it from Settings (opening the downloaded file won't work): <b>Settings › Security &amp; privacy › More security &amp; privacy › Encryption &amp; credentials › Install a certificate › CA certificate</b>, and pick the downloaded file.</p>
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
        let pageHost = "\(ip):\(NetCaptureEnv.configPagePort)/?k=\(NetCaptureEnv.pairingToken)"
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
            cards = [certCard, trustCard, proxyCard, offCard].filter { !$0.isEmpty }.joined(separator: "\n")
        }

        // 三项状态自己查、自己打勾，每 3 秒一次（都好了以后放慢到 10 秒）：
        // - 证书：向引擎的代理端口发一个 https 请求。引擎对直接连上来的 TLS 用自己的 CA 现签一张证书
        //   （SAN 是这台 Mac 的地址），握手成得了就是已经信任，桥对这个路径回 204。没装、或者 iPhone 上装了
        //   但没在「证书信任设置」里打开开关，握手都失败。
        // - 代理、放行：请求一个不存在的域名 `check.baobox.invalid`。设了代理它才到得了引擎，桥直接应答
        //   `{"proxy":true,"allowed":…}`；没设代理就是解析失败。
        let statusCard = needsSafari ? "" : """
        <div class="card">
        <div class="st" id="st-cert"><i></i>证书已信任 / Certificate trusted</div>
        <div class="st" id="st-proxy"><i></i>代理已生效 / Proxy in use</div>
        <div class="st" id="st-allow"><i></i>Mac 已允许这台设备 / Allowed on the Mac</div>
        <p class="ok" id="ready" style="margin:10px 0 0" hidden>全部就绪，可以开始抓包了。<br>All set. Start capturing.</p>
        </div>
        """
        // 手机能按名字（xxx.local）找到这台 Mac 的话，代理就按名字配：Mac 换了 IP 不用重装。
        // 能不能找到要在手机上试（有的网络不放行这种名字解析），所以由页面去请求一下 `/ping`，
        // 通了才把两个按钮的链接换成带 `?h=local` 的。
        let localName = NetworkInterfaces.localHostName ?? ""
        let nameJS = (needsSafari || !isIOS || localName.isEmpty) ? "" : """
        <script>
        (function(){
          if (!window.fetch) return;
          var name = "\(localName)";
          var ctl = window.AbortController ? new AbortController() : null;
          if (ctl) setTimeout(function(){ ctl.abort(); }, 4000);
          fetch('http://' + name + ':\(NetCaptureEnv.configPagePort)/ping?' + Date.now(),
                {mode: 'no-cors', cache: 'no-store', signal: ctl ? ctl.signal : undefined})
            .then(function(){
              ['proxyauto', 'proxyfixed'].forEach(function(id){
                var a = document.getElementById(id);
                if (a && a.href.indexOf('h=local') < 0) a.href += '?h=local';
              });
              var note = document.getElementById('hostnote');
              if (note) note.innerHTML = '代理按这台 Mac 的名字（' + name + '）配置，Mac 换了 IP 也不用重装。<br>Set up with this Mac\\'s name (' + name + '); it keeps working when the IP changes.';
            }, function(){});
        })();
        </script>
        """

        let trustJS = needsSafari ? "" : """
        <script>
        (function(){
          if (!window.fetch) return;
          var state = {cert: false, proxy: false, allow: false};
          function get(url, ms){
            var ctl = window.AbortController ? new AbortController() : null;
            if (ctl) setTimeout(function(){ ctl.abort(); }, ms);
            return fetch(url, {cache: 'no-store', signal: ctl ? ctl.signal : undefined});
          }
          function mark(id, on){ var e = document.getElementById(id); if (e) e.className = on ? 'st on' : 'st'; }
          function render(){
            mark('st-cert', state.cert); mark('st-proxy', state.proxy); mark('st-allow', state.allow);
            var note = document.getElementById('trusted'), btn = document.getElementById('certbtn');
            if (note) note.hidden = !state.cert;
            var on = document.getElementById('proxy-on'), setup = document.getElementById('proxy-setup');
            if (on) on.hidden = !state.proxy;
            if (setup) setup.hidden = state.proxy;
            var done = document.getElementById('trusted2'), todo = document.getElementById('untrusted');
            if (done) done.hidden = !state.cert;
            if (todo) todo.hidden = state.cert;
            if (btn && state.cert) { btn.className = 'btn ghost'; btn.textContent = '重新下载 / Download again'; }
            var ready = document.getElementById('ready');
            if (ready) ready.hidden = !(state.cert && state.proxy && state.allow);
          }
          function check(){
            var cert = get('https://\(addr)/baobox-trust-check?' + Date.now(), 4000)
              .then(function(r){ state.cert = r.status === 204; }, function(){ state.cert = false; });
            var proxy = get('http://check.baobox.invalid/status?' + Date.now(), 4000)
              .then(function(r){ return r.json(); })
              .then(function(j){ state.proxy = true; state.allow = !!j.allowed; },
                    function(){ state.proxy = false; state.allow = false; });
            Promise.all([cert, proxy]).then(function(){
              render();
              setTimeout(check, (state.cert && state.proxy && state.allow) ? 10000 : 3000);
            });
          }
          check();
        })();
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
        .kv{display:flex;align-items:center;gap:10px;margin:10px 0}
        .kv span{color:var(--sub);font-size:13px;flex:0 0 auto}
        .kv b{font-size:19px;flex:1;white-space:nowrap;-webkit-user-select:all;user-select:all}
        .mini{flex:0 0 auto;padding:8px 12px;border-radius:8px;border:1.5px solid var(--accent);background:transparent;color:var(--accent);font-size:13px;font-weight:600}
        .card .btn{margin:0 8px 8px 0}
        .ok{color:var(--accent);font-weight:600;font-size:15px;margin:0 0 12px}
        .warn{color:#d9730d;font-weight:600;font-size:15px;margin:0 0 12px}
        .st{display:flex;align-items:center;gap:10px;padding:5px 0;color:var(--sub);font-size:15px}
        .st i{width:20px;height:20px;border-radius:50%;border:2px solid var(--line);flex:0 0 auto;font-style:normal;font-size:13px;line-height:16px;text-align:center;color:#fff}
        .st.on{color:var(--fg)}
        .st.on i{background:var(--accent);border-color:var(--accent)}
        .st.on i::after{content:"✓"}
        .foot{font-size:12px;color:var(--sub);text-align:center;margin-top:24px}
        </style></head>
        <body><div class="wrap">
        <h1>Baobox 抓包配置 / Capture Setup</h1>
        <p class="hint" style="text-align:center">当前代理 / Proxy</p>
        <div class="big">\(addrEsc)</div>
        \(statusCard)
        \(cards)
        <p class="foot">仅用于本机调试，请勿抓取他人隐私。<br>For local debugging only.</p>
        </div>\(copyJS)\(trustJS)\(nameJS)</body></html>
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
