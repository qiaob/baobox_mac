import Foundation

/// 用 `networksetup`（用户级，无需管理员）读/设/还原当前网络服务的 HTTP / HTTPS / SOCKS 系统代理。
/// HTTP（含 HTTPS）和 SOCKS 两组各自可选：「本机」的 HTTP / HTTPS 子开关管前一组，WebSocket、TCP 子开关管后一组。
///
/// SOCKS 那一项是给 WebSocket 的：苹果平台的 WebSocket 不走 HTTP 代理，只走系统的 SOCKS 代理
/// （2026-11-21 在 iOS 模拟器上实测，见 docs/packet-capture/TECH_DESIGN.md §1）。
///
/// 崩溃兜底：开启前先读并保存原状态到 UserDefaults；停止或下次启动都能还原（防残留代理导致断网）。
/// 本类不标 `@MainActor`：`networksetup` 子进程同步阻塞，须后台调用。
enum SystemProxyController {

    /// 保存的原始代理状态（开启前快照，用于还原）。
    private struct ProxyState: Codable {
        var service: String
        var webEnabled: Bool
        var webHost: String
        var webPort: Int
        var secureEnabled: Bool
        var secureHost: String
        var securePort: Int
        // 可选：早先存下来的状态里没有这三项（那时只管 HTTP / HTTPS），解出来是 nil，还原时就不碰 SOCKS。
        var socksEnabled: Bool?
        var socksHost: String?
        var socksPort: Int?
    }

    private static let networksetup = "/usr/sbin/networksetup"

    // MARK: - 网络服务解析

    /// 取当前活跃网络服务名。优先设置里手动指定；否则取第一个「已启用且有 IP」的服务（通常 Wi-Fi）。
    static func activeServiceName() -> String? {
        let manual = (UserDefaults.standard.string(forKey: NetCaptureEnv.Keys.serviceName) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty { return manual }

        let list = NetCaptureEnv.run(networksetup, ["-listallnetworkservices"])
        guard list.ok else { return nil }
        let services = list.stdoutString
            .components(separatedBy: "\n")
            .dropFirst() // 首行是说明文字
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") } // `*` 前缀表示已禁用

        // 取第一个能拿到 IP 的服务。
        for service in services {
            let info = NetCaptureEnv.run(networksetup, ["-getinfo", service])
            if info.ok, info.stdoutString.range(of: #"IP address: (\d+\.\d+\.\d+\.\d+)"#,
                                                options: .regularExpression) != nil {
                return service
            }
        }
        return services.first
    }

    // MARK: - 读当前状态

    private static func readState(service: String) -> ProxyState {
        var state = ProxyState(service: service, webEnabled: false, webHost: "", webPort: 0,
                               secureEnabled: false, secureHost: "", securePort: 0)
        let web = NetCaptureEnv.run(networksetup, ["-getwebproxy", service])
        if web.ok { parse(web.stdoutString, into: &state.webEnabled, &state.webHost, &state.webPort) }
        let secure = NetCaptureEnv.run(networksetup, ["-getsecurewebproxy", service])
        if secure.ok {
            parse(secure.stdoutString, into: &state.secureEnabled, &state.secureHost, &state.securePort)
        }
        let socks = NetCaptureEnv.run(networksetup, ["-getsocksfirewallproxy", service])
        if socks.ok {
            var enabled = false, host = "", port = 0
            parse(socks.stdoutString, into: &enabled, &host, &port)
            state.socksEnabled = enabled
            state.socksHost = host
            state.socksPort = port
        }
        return state
    }

    /// 解析 `-getwebproxy` 输出：`Enabled: Yes` / `Server: host` / `Port: 1234`。
    private static func parse(_ text: String, into enabled: inout Bool,
                              _ host: inout String, _ port: inout Int) {
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
            switch key {
            case "enabled": enabled = value.lowercased() == "yes"
            case "server": host = value
            case "port": port = Int(value) ?? 0
            default: break
            }
        }
    }

    // MARK: - 启用 / 还原

    /// 把当前活跃服务的系统代理指向引擎：`httpPort` 不为 nil 时 HTTP / HTTPS 代理指向 `127.0.0.1:httpPort`，
    /// `socksPort` 不为 nil 时 SOCKS 代理指向 `127.0.0.1:socksPort`；为 nil 的那一项还原成开启前的样子。
    /// 两个都是 nil 等于 `restore()`。抓包中「本机」的子开关一变就再调一次（docs/packet-capture/CONTROL.md §2.2）。
    ///
    /// 「开启前的快照」只在还没有快照时拍一次：再次调用时系统代理已经是我们设的了，不能把它当成原状态存下来，
    /// 否则还原时还原成的是指向引擎的代理（整机断网）。**后台线程调用**。
    static func apply(httpPort: UInt16?, socksPort: UInt16?) {
        guard httpPort != nil || socksPort != nil else {
            restore()
            return
        }
        guard let service = savedState()?.service ?? activeServiceName() else { return }
        let original: ProxyState
        if let saved = savedState() {
            original = saved
        } else {
            original = readState(service: service)
            if let data = try? JSONEncoder().encode(original) {
                UserDefaults.standard.set(data, forKey: NetCaptureEnv.Keys.savedProxyState)
            }
        }
        if let httpPort {
            let portStr = String(httpPort)
            NetCaptureEnv.run(networksetup, ["-setwebproxy", service, "127.0.0.1", portStr])
            NetCaptureEnv.run(networksetup, ["-setsecurewebproxy", service, "127.0.0.1", portStr])
            NetCaptureEnv.run(networksetup, ["-setwebproxystate", service, "on"])
            NetCaptureEnv.run(networksetup, ["-setsecurewebproxystate", service, "on"])
        } else {
            restoreWeb(original)
        }
        if let socksPort {
            NetCaptureEnv.run(networksetup, ["-setsocksfirewallproxy", service, "127.0.0.1", String(socksPort)])
            NetCaptureEnv.run(networksetup, ["-setsocksfirewallproxystate", service, "on"])
        } else {
            restoreSocks(original)
        }
    }

    /// 还原为开启前保存的状态；无保存状态则不动。**后台线程调用**。
    static func restore() {
        guard let state = savedState() else { return }
        restoreWeb(state)
        restoreSocks(state)
        UserDefaults.standard.removeObject(forKey: NetCaptureEnv.Keys.savedProxyState)
    }

    private static func savedState() -> ProxyState? {
        guard let data = UserDefaults.standard.data(forKey: NetCaptureEnv.Keys.savedProxyState) else { return nil }
        return try? JSONDecoder().decode(ProxyState.self, from: data)
    }

    /// HTTP、HTTPS 两项还原成快照里的样子。
    private static func restoreWeb(_ state: ProxyState) {
        let service = state.service
        if state.webEnabled, !state.webHost.isEmpty {
            NetCaptureEnv.run(networksetup, ["-setwebproxy", service, state.webHost, String(state.webPort)])
            NetCaptureEnv.run(networksetup, ["-setwebproxystate", service, "on"])
        } else {
            NetCaptureEnv.run(networksetup, ["-setwebproxystate", service, "off"])
        }
        if state.secureEnabled, !state.secureHost.isEmpty {
            NetCaptureEnv.run(networksetup,
                              ["-setsecurewebproxy", service, state.secureHost, String(state.securePort)])
            NetCaptureEnv.run(networksetup, ["-setsecurewebproxystate", service, "on"])
        } else {
            NetCaptureEnv.run(networksetup, ["-setsecurewebproxystate", service, "off"])
        }
    }

    /// SOCKS 还原成快照里的样子（早先存下的快照里没有这一项就不碰）。
    private static func restoreSocks(_ state: ProxyState) {
        guard let wasOn = state.socksEnabled else { return }
        let service = state.service
        if wasOn, let host = state.socksHost, !host.isEmpty {
            NetCaptureEnv.run(networksetup, ["-setsocksfirewallproxy", service, host, String(state.socksPort ?? 0)])
            NetCaptureEnv.run(networksetup, ["-setsocksfirewallproxystate", service, "on"])
        } else {
            NetCaptureEnv.run(networksetup, ["-setsocksfirewallproxystate", service, "off"])
        }
    }

    /// 崩溃残留还原：`activate()` 启动时调一次。有保存状态即说明上次异常退出没还原，补还原。
    static func restoreIfLeftover() {
        guard UserDefaults.standard.data(forKey: NetCaptureEnv.Keys.savedProxyState) != nil else { return }
        restore()
    }
}
