import Foundation

/// 网络抓包专用的地址（通用的接口枚举在 `Core/NetworkInterfaces.swift`）。
extension NetworkInterfaces {
    /// 手机配置页的地址（二维码里就是它）：这台 Mac 的局域网 IP + 配置页端口，由 `ConfigPageServer` 应答。
    /// 不经过代理，手机还没设好代理时也能打开。
    static var landingPageURL: String { "http://\(primaryIP()):\(NetCaptureEnv.configPagePort)/" }
}
