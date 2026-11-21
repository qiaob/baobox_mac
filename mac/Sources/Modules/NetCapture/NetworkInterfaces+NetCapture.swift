import Foundation

/// 网络抓包专用的地址（通用的接口枚举在 `Core/NetworkInterfaces.swift`）。
extension NetworkInterfaces {
    /// 手机配置页的地址（二维码里就是它）：这台 Mac 的局域网 IP + 配置页端口，由 `ConfigPageServer` 应答。
    /// 不经过代理，手机还没设好代理时也能打开。
    /// 带着扫码即放行的口令（`?k=`）：从二维码进来的设备不用再到 Mac 上点「允许」。
    static var landingPageURL: String {
        "http://\(primaryIP()):\(NetCaptureEnv.configPagePort)/?k=\(NetCaptureEnv.pairingToken)"
    }

    /// 这台 Mac 在局域网里的名字（`xxx.local`，系统设置 › 通用 › 共享里那个「本地主机名」）。
    /// 手机能按这个名字找到 Mac 时，代理就按名字配，Mac 换了 IP 不用重装描述文件。取不到或名字里有怪字符返回 nil。
    /// 起一个子进程读，只读一次；别在主线程调。
    static let localHostName: String? = {
        let result = NetCaptureEnv.run("/usr/sbin/scutil", ["--get", "LocalHostName"])
        let name = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, ProxyPAC.isSafeHostName(name), !name.contains(".") else { return nil }
        return name + ".local"
    }()
}
