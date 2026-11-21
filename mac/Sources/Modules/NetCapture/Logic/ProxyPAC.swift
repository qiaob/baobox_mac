import Foundation

/// iPhone 的「自动代理」用的那段脚本（PAC）。
///
/// 手机里存的不是代理地址，而是这段脚本的网址；每个请求由脚本决定怎么走。规则只有两条：
/// 发给这台 Mac 自己的（配置页、证书检测）直连；其余先走代理，**代理连不上就直连**。
/// 所以 Baobox 没在抓包、而 Mac 还在网络上时（代理端口被立刻回绝），手机马上改走直连，不用来回关代理。
/// 脚本取不到时由描述文件里的 `ProxyPACFallbackAllowed` 兜底，同样是直连。
///
/// **Mac 不在网络上（睡眠、关机、带走）时并不顺**：连接不是被回绝而是没人应答，系统要等超时。
/// 2026-11-21 用 macOS 的同一套网络栈实测，请求会卡十几秒到两分钟，明文 HTTP 还会失败
/// （docs/packet-capture/TECH_DESIGN.md §1.z）。这种情况页面上请用户关代理。
enum ProxyPAC {
    static let contentType = "application/x-ns-proxy-autoconfig"

    /// - `proxyHost`：代理写成什么。这台 Mac 的 IP，或者它在局域网里的名字（`xxx.local`）——
    ///   用名字的话 Mac 换了 IP 也不用重装描述文件。
    /// - `ownHosts`：这台 Mac 自己的各种写法（IP、名字），发给它们的请求直连。
    static func script(proxyHost: String, proxyPort: UInt16, ownHosts: [String] = []) -> String {
        let host = jsString(proxyHost)
        var own = [host.lowercased()]
        for extra in ownHosts.map({ jsString($0).lowercased() }) where !extra.isEmpty && !own.contains(extra) {
            own.append(extra)
        }
        let list = own.map { "\"\($0)\"" }.joined(separator: ", ")
        // `.local` 是局域网里的名字，也直连：它们本来就只在这个网络里有意义。
        return """
        function FindProxyForURL(url, host) {
          var h = host.toLowerCase();
          var own = [\(list)];
          if (own.indexOf(h) >= 0 || h === "localhost" || h === "127.0.0.1" || isPlainHostName(h) || shExpMatch(h, "*.local")) {
            return "DIRECT";
          }
          return "PROXY \(host):\(proxyPort); DIRECT";
        }

        """
    }

    /// 能不能当主机名写进脚本和描述文件：字母、数字、连字符、点。
    static func isSafeHostName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "."
        }
    }

    /// 地址只会是 IP 或主机名；仍然把会破坏字符串字面量的字符去掉，免得拼出坏脚本。
    private static func jsString(_ text: String) -> String {
        String(text.filter { $0 != "\"" && $0 != "\\" && !$0.isNewline })
    }
}
