import Foundation

// 网络抓包的纯逻辑（只依赖 Foundation，进 BaoboxTests）：引擎这一次听哪些端口、桥的几个开关取什么值。
// 见 docs/packet-capture/CONTROL.md §2.1。

/// 一台 WireGuard 设备的监听：它的密钥文件（格式是引擎自己的，见 `WireGuardKeys`）+ UDP 端口。
/// 桥按密钥文件名认设备（docs/packet-capture/WIREGUARD-DEVICES.md §4）。
struct WireGuardListener: Equatable, Sendable {
    var keyFile: String
    var port: UInt16
}

/// 引擎的监听组合。由「配置」页的开关决定，变了就要重启引擎（监听地址只能在启动时定）。
struct EngineListeners: Equatable, Sendable {
    /// HTTP 代理端口；SOCKS 在它 + 2。
    var port: UInt16
    /// HTTP 代理听 `0.0.0.0`（「手动代理」或「给其他设备装证书」开着），否则只听 `127.0.0.1`。
    var lan: Bool
    /// 每台 WireGuard 设备一个监听（按设备表的顺序）；WireGuard 开关关着 = 空。
    var wireguard: [WireGuardListener] = []

    var socksPort: UInt16 { Self.neighbour(of: port, offset: 2) }

    /// 传给引擎的 `--mode …` 参数。
    var modeArguments: [String] {
        var arguments = [
            "--mode", "regular@\(lan ? "0.0.0.0" : "127.0.0.1"):\(port)",
            // SOCKS5 永远只听本机：苹果平台的 WebSocket 只走系统的 SOCKS 代理，「本机」把系统的 SOCKS 指到这里。
            "--mode", "socks5@127.0.0.1:\(socksPort)",
        ]
        for listener in wireguard {
            arguments += ["--mode", "wireguard:\(listener.keyFile)@\(listener.port)"]
        }
        return arguments
    }

    /// 代理端口旁边的端口；紧贴上限时往下取，保证不溢出、也不和代理端口重合。
    static func neighbour(of port: UInt16, offset: UInt16) -> UInt16 {
        port <= UInt16.max - offset ? port + offset : port - offset
    }
}

/// 桥脚本运行中能改的几个开关。启动时作为选项给初值，之后变了就发指令，不用重启引擎。
struct BridgeFlags: Equatable, Sendable {
    /// false = 暂停（CONTROL.md §5）。
    var record = true
    /// 局域网设备能不能拿引擎当代理（「手动代理」）。
    var lanProxy = false
    /// 记不记这台 Mac 发出的原始 TCP（「本机」开着且「TCP」开着）。
    var macTCP = false
    /// 手机配置页的端口，0 = 没开。
    var pagePort: UInt16 = 0

    /// 启动引擎时的 `--set baobox_…=…`。
    var optionArguments: [String] {
        [
            "--set", "baobox_record=\(record)",
            "--set", "baobox_lan_proxy=\(lanProxy)",
            "--set", "baobox_mac_tcp=\(macTCP)",
            "--set", "baobox_page_port=\(pagePort)",
        ]
    }

    /// 从 `self` 变成 `next` 要发的指令（只发变了的）。
    func commands(toReach next: BridgeFlags) -> [CaptureCommand] {
        var commands: [CaptureCommand] = []
        if next.record != record { commands.append(.record(next.record)) }
        if next.lanProxy != lanProxy { commands.append(.lanProxy(next.lanProxy)) }
        if next.macTCP != macTCP { commands.append(.macTCP(next.macTCP)) }
        if next.pagePort != pagePort { commands.append(.pagePort(next.pagePort)) }
        return commands
    }
}
