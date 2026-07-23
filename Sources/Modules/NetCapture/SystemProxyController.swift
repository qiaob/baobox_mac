import Foundation

/// 用 `networksetup`（用户级，无需管理员）读/设/还原当前网络服务的 HTTP/HTTPS 系统代理。
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

    /// 把当前活跃服务的 HTTP/HTTPS 代理指向 `127.0.0.1:port`。开启前保存原状态。**后台线程调用**。
    static func enable(port: UInt16) {
        guard let service = activeServiceName() else { return }
        // 仅在没有已保存状态时保存（避免多次 enable 覆盖真正的原始状态）。
        if UserDefaults.standard.data(forKey: NetCaptureEnv.Keys.savedProxyState) == nil {
            let state = readState(service: service)
            if let data = try? JSONEncoder().encode(state) {
                UserDefaults.standard.set(data, forKey: NetCaptureEnv.Keys.savedProxyState)
            }
        }
        let portStr = String(port)
        NetCaptureEnv.run(networksetup, ["-setwebproxy", service, "127.0.0.1", portStr])
        NetCaptureEnv.run(networksetup, ["-setsecurewebproxy", service, "127.0.0.1", portStr])
        NetCaptureEnv.run(networksetup, ["-setwebproxystate", service, "on"])
        NetCaptureEnv.run(networksetup, ["-setsecurewebproxystate", service, "on"])
    }

    /// 还原为开启前保存的状态；无保存状态则不动。**后台线程调用**。
    static func restore() {
        guard let data = UserDefaults.standard.data(forKey: NetCaptureEnv.Keys.savedProxyState),
              let state = try? JSONDecoder().decode(ProxyState.self, from: data) else {
            return
        }
        let service = state.service
        // 还原 web 代理。
        if state.webEnabled, !state.webHost.isEmpty {
            NetCaptureEnv.run(networksetup, ["-setwebproxy", service, state.webHost, String(state.webPort)])
            NetCaptureEnv.run(networksetup, ["-setwebproxystate", service, "on"])
        } else {
            NetCaptureEnv.run(networksetup, ["-setwebproxystate", service, "off"])
        }
        // 还原 secure 代理。
        if state.secureEnabled, !state.secureHost.isEmpty {
            NetCaptureEnv.run(networksetup,
                              ["-setsecurewebproxy", service, state.secureHost, String(state.securePort)])
            NetCaptureEnv.run(networksetup, ["-setsecurewebproxystate", service, "on"])
        } else {
            NetCaptureEnv.run(networksetup, ["-setsecurewebproxystate", service, "off"])
        }
        UserDefaults.standard.removeObject(forKey: NetCaptureEnv.Keys.savedProxyState)
    }

    /// 崩溃残留还原：`activate()` 启动时调一次。有保存状态即说明上次异常退出没还原，补还原。
    static func restoreIfLeftover() {
        guard UserDefaults.standard.data(forKey: NetCaptureEnv.Keys.savedProxyState) != nil else { return }
        restore()
    }
}
