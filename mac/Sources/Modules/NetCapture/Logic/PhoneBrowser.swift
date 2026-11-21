import Foundation

/// 手机配置页按来访浏览器的 User-Agent 决定给什么内容。
enum PhoneBrowser {
    /// iPhone / iPad / iPod。iPad 上「桌面版网站」的 Safari 自称 Macintosh，认不出来，按其它设备处理。
    static func isIOS(userAgent: String) -> Bool {
        userAgent.contains("iPhone") || userAgent.contains("iPad") || userAgent.contains("iPod")
    }

    /// iOS 上别的浏览器、App 内置的网页自己带的标记。它们同样带着 `Safari/`，有的还带 `Version/`。
    private static let otherIOSBrowsers = [
        "CriOS", "FxiOS", "EdgiOS", "OPiOS", "OPT/", "DuckDuckGo", "YaBrowser", "Brave",
        "MicroMessenger", "QQ/", "MQQBrowser", "DingTalk", "Lark", "AlipayClient", "Weibo", "UCBrowser", "Quark",
    ]

    /// iOS 上只有 Safari 能把下载的描述文件交给「设置」安装；Chrome 等只会把它存成一个打不开的文件。
    /// Safari 的 UA 带 `Version/x` 和 `Safari/x`，并且没有别的浏览器的标记。
    static func isIOSSafari(userAgent: String) -> Bool {
        guard isIOS(userAgent: userAgent) else { return false }
        guard userAgent.contains("Version/"), userAgent.contains("Safari/") else { return false }
        return !otherIOSBrowsers.contains { userAgent.contains($0) }
    }
}
