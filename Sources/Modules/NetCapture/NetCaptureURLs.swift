import Foundation

/// 网络抓包专属的地址常量。
///
/// `NetworkInterfaces` 本体（网卡枚举 / 本机局域网 IP）已下沉到 `Sources/Core/`，供抓包与
/// 局域网传输共用；magic 域名与这两个 URL 是抓包独有的，留在模块内以扩展形式挂回同一命名空间，
/// 因此 `NetworkInterfaces.landingPageURL` 这类既有调用点写法完全不变。
///
/// 全部写成计算属性（扩展里的存储型静态属性虽合法，但计算属性更直白，且这两个值本就依赖动态 IP）。
extension NetworkInterfaces {

    /// magic 域名：被代理设备访问 `http://baobox.proxy/` 可下载 CA 证书（由 ProxyConnection 本地应答）。
    static var magicHost: String { "baobox.proxy" }

    /// 证书下载 URL（保留，供直链 / 展示）——扫码下载 CA 文件。
    static var certDownloadURL: String { "http://\(magicHost)/cert" }

    /// 配置页 URL（供二维码 / 展示）——手机**未设代理**时也能同 Wi-Fi 直连打开（装证书 / 配代理，§16.2）。
    /// 用本机局域网 IP:端口直连；不能用 magic 域名 `baobox.proxy`（那要先设代理才能解析，首次配置时打不开）。
    static var landingPageURL: String { "http://\(primaryIP()):\(NetCaptureEnv.port)/" }
}
