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

    static func script(proxyHost: String, proxyPort: UInt16) -> String {
        let host = jsString(proxyHost)
        return """
        function FindProxyForURL(url, host) {
          if (host === "\(host)" || host === "localhost" || host === "127.0.0.1" || isPlainHostName(host)) {
            return "DIRECT";
          }
          return "PROXY \(host):\(proxyPort); DIRECT";
        }

        """
    }

    /// 地址只会是 IP 或主机名；仍然把会破坏字符串字面量的字符去掉，免得拼出坏脚本。
    private static func jsString(_ text: String) -> String {
        String(text.filter { $0 != "\"" && $0 != "\\" && !$0.isNewline })
    }
}
