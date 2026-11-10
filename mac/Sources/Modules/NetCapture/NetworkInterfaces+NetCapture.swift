import Foundation

/// 网络抓包专用的地址常量（通用的接口枚举在 `Core/NetworkInterfaces.swift`）。
extension NetworkInterfaces {
    /// magic 域名：被代理设备访问 `http://baobox.proxy/` 可下载 CA 证书（由 ProxyConnection 本地应答）。
    static let magicHost = "baobox.proxy"

    /// 证书下载 URL（保留，供直链 / 展示）——扫码下载 CA 文件。
    static var certDownloadURL: String { "http://\(magicHost)/cert" }

    /// 配置页 URL（供二维码 / 展示）——手机**未设代理**时也能同 Wi-Fi 直连打开（装证书 / 配代理，§16.2）。
    /// 用本机局域网 IP:端口直连；不能用 magic 域名 `baobox.proxy`（那要先设代理才能解析，首次配置时打不开）。
    static var landingPageURL: String { "http://\(primaryIP()):\(NetCaptureEnv.port)/" }
}
