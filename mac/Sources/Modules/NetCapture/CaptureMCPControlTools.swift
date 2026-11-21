import Foundation

/// 本地 MCP 的「配置 + 看包」工具（docs/packet-capture/CONTROL.md §6）：读写抓包窗口「配置」页上的全部开关和取值、
/// 看「TCP 包」、管 Mock 规则、重发、放行设备。在 MCP 连接队列上调用：读状态用 `DispatchQueue.main.sync` 取一次快照，
/// 改状态也在主线程上做（主线程从不反过来同步等这条队列，不会死锁），效果和在界面上拨一样。
enum MCPControlTools {

    // MARK: - schema

    static let schemas: [[String: Any]] = [
        [
            "name": "get_config",
            "description": "Every switch and value of the capture window's Config tab, as JSON: the four master switches (mac, manual_proxy, wireguard, cert_page) and This Mac's sub-switches (mac_http, mac_websocket, mac_tcp), paused, decrypt_https and the decryption scope, ports, body cap, list limit, clear_on_stop, wifi_name; plus read-only state: engine, ca_trusted, proxy_address, wireguard_endpoint, config_page_url, pending_devices, mcp_redact_auth.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "set_config",
            "description": "Change any of the settable keys from get_config (keys not given are left alone); same effect as using the window. Booleans: mac, mac_http, mac_websocket, mac_tcp, manual_proxy, wireguard, cert_page, paused, decrypt_https, clear_on_stop. decrypt_scope: \"all\" or \"allowlist\"; allow_domains / deny_domains: arrays of domains. port, wireguard_port, body_cap (1048576, 5242880 or 20971520) apply the next time the engine starts; max_flows (200-5000). Turning on mac needs this Mac to trust the certificate; when it does not, nothing is changed and the reply says to do it in the window (the trust prompt is the user's). Returns what changed and the config afterwards.",
            "inputSchema": ["type": "object", "properties": [
                "mac": ["type": "boolean"], "mac_http": ["type": "boolean"], "mac_websocket": ["type": "boolean"],
                "mac_tcp": ["type": "boolean"], "manual_proxy": ["type": "boolean"], "wireguard": ["type": "boolean"],
                "cert_page": ["type": "boolean"], "paused": ["type": "boolean"], "decrypt_https": ["type": "boolean"],
                "decrypt_scope": ["type": "string", "enum": ["all", "allowlist"]],
                "allow_domains": ["type": "array", "items": ["type": "string"]],
                "deny_domains": ["type": "array", "items": ["type": "string"]],
                "port": ["type": "integer"], "wireguard_port": ["type": "integer"], "body_cap": ["type": "integer"],
                "max_flows": ["type": "integer"], "clear_on_stop": ["type": "boolean"], "wifi_name": ["type": "string"],
            ]],
        ],
        [
            "name": "get_wireguard_config",
            "description": "The WireGuard client config a phone imports (the same text as the QR code on the Config tab). It contains the tunnel's private key; this server only listens on 127.0.0.1. Creates the key file if there is none yet.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "list_tcp_connections",
            "description": "Raw TCP connections from the TCP tab (not HTTP, not TLS decrypted into HTTP), newest last. Each line: id, state, target:port, protocol (\"?\" = guessed from the port only, \"unknown\" = not recognised), bytes up/down, reads, source device. Filters: limit, device (client IP), protocol (name, e.g. SSH, MQTT, or \"unknown\"), host (substring of the target).",
            "inputSchema": ["type": "object", "properties": [
                "limit": ["type": "integer"], "device": ["type": "string"], "protocol": ["type": "string"],
                "host": ["type": "string"],
            ]],
        ],
        [
            "name": "get_tcp_connection",
            "description": "One TCP connection with its data. TCP is a byte stream, so by default adjacent data in the same direction is merged into blocks, each with direction, offset (running per direction) and length; segments=true returns the reads as they arrived instead. format: hex, text, or auto (default: text where the block looks like text). limit = number of blocks / reads (default 50). Bytes past the body cap are listed as not saved. Raw data is not redacted.",
            "inputSchema": ["type": "object", "properties": [
                "id": ["type": "string"], "limit": ["type": "integer"],
                "format": ["type": "string", "enum": ["auto", "hex", "text"]], "segments": ["type": "boolean"],
            ], "required": ["id"]],
        ],
        [
            "name": "clear_tcp",
            "description": "Clear the TCP tab. Returns how many connections were cleared.",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "list_mock_rules",
            "description": "Mock rules in match order (the first enabled rule that matches answers the request): id, enabled, method (* = any), host, path (* wildcards, query ignored), status, headers, body (text, or body_base64 for binary).",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "set_mock_rule",
            "description": "Create a mock rule (no id, or an unknown id) or change one (fields not given keep their value). Fields: enabled, method, host (required for a new rule), path, status (100-599), headers ([[name, value], ...]), body (text) or body_base64. Only decrypted requests are answered. Returns the saved rule.",
            "inputSchema": ["type": "object", "properties": [
                "id": ["type": "string"], "enabled": ["type": "boolean"], "method": ["type": "string"],
                "host": ["type": "string"], "path": ["type": "string"], "status": ["type": "integer"],
                "headers": ["type": "array", "items": ["type": "array", "items": ["type": "string"]]],
                "body": ["type": "string"], "body_base64": ["type": "string"],
            ]],
        ],
        [
            "name": "delete_mock_rule",
            "description": "Delete a mock rule by id.",
            "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]],
        ],
        [
            "name": "replay_flow",
            "description": "Send a captured HTTP request again (starts the engine if it is not running), optionally changed: method, url, headers ([[name, value], ...], replaces all), body (text) or body_base64. The new request shows up in the HTTP / WebSocket tab marked as a replay; the reply gives its id and, when it finishes within 5 seconds, its status.",
            "inputSchema": ["type": "object", "properties": [
                "id": ["type": "string"], "method": ["type": "string"], "url": ["type": "string"],
                "headers": ["type": "array", "items": ["type": "array", "items": ["type": "string"]]],
                "body": ["type": "string"], "body_base64": ["type": "string"],
            ], "required": ["id"]],
        ],
        [
            "name": "allow_device",
            "description": "Allow a LAN device waiting to use this Mac as its proxy (its IP from get_config's pending_devices).",
            "inputSchema": ["type": "object", "properties": ["ip": ["type": "string"]], "required": ["ip"]],
        ],
        [
            "name": "deny_device",
            "description": "Refuse a LAN device (it gets a 403 page until allowed).",
            "inputSchema": ["type": "object", "properties": ["ip": ["type": "string"]], "required": ["ip"]],
        ],
    ]

    /// 分发；不是这里的工具返回 nil。
    static func call(name: String, arguments: [String: Any]) -> String? {
        switch name {
        case "get_config": return json(config())
        case "set_config": return setConfig(arguments)
        case "get_wireguard_config": return wireguardConfig()
        case "list_tcp_connections": return listTCP(arguments)
        case "get_tcp_connection": return getTCP(arguments)
        case "clear_tcp":
            let count = TCPSnapshotStore.shared.get().count
            DispatchQueue.main.async { MainActor.assumeIsolated { TCPStore.shared.clear() } }
            return "cleared \(count) connections"
        case "list_mock_rules":
            let rules = DispatchQueue.main.sync { MainActor.assumeIsolated { MockRuleStore.shared.rules } }
            return json(rules.map(ruleObject))
        case "set_mock_rule": return setMockRule(arguments)
        case "delete_mock_rule": return deleteMockRule(arguments)
        case "replay_flow": return replay(arguments)
        case "allow_device", "deny_device":
            guard let ip = string(arguments["ip"]), !ip.isEmpty else { return "error: ip is required" }
            let allow = name == "allow_device"
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { allow ? NetCaptureEngine.shared.allow(device: ip) : NetCaptureEngine.shared.deny(device: ip) }
            }
            return allow ? "allowed \(ip)" : "denied \(ip)"
        default:
            return nil
        }
    }

    // MARK: - 配置

    /// 「配置」页的全部开关和取值，加只读的状态。
    static func config() -> [String: Any] {
        // 证书信任状态现查（后台线程上做，不用窗口里缓存的那个）。
        let trusted = CaptureCA.shared.isGenerated && CaptureCA.shared.isTrusted()
        let defaults = UserDefaults.standard
        let scope = defaults.string(forKey: NetCaptureEnv.Keys.decryptScope) ?? "all"
        var object: [String: Any] = DispatchQueue.main.sync {
            MainActor.assumeIsolated { () -> [String: Any] in
                let session = NetCaptureSession.shared
                let engine = NetCaptureEngine.shared
                let engineState: String
                switch engine.state {
                case .running: engineState = "running"
                case .starting: engineState = "starting"
                case .stopped: engineState = "stopped"
                case .failed(let message): engineState = "failed: \(message)"
                }
                let lan = engine.listeners?.lan == true
                var state: [String: Any] = [
                    "engine": engineState,
                    "paused": session.paused,
                    "mac": session.macOn,
                    "manual_proxy": session.manualProxyOn,
                    "wireguard": session.wireguardOn,
                    "cert_page": session.certPageOn,
                    "pending_devices": engine.pendingDevices,
                    "proxy_address": engine.port.map { "\(lan ? NetworkInterfaces.primaryIP() : "127.0.0.1"):\($0)" } ?? NSNull(),
                    "wireguard_endpoint": session.wireguardEndpoint,
                ]
                state["config_page_url"] = session.certPageOn ? NetworkInterfaces.landingPageURL : NSNull()
                return state
            }
        }
        object["mac_http"] = NetCaptureEnv.macHTTP
        object["mac_websocket"] = NetCaptureEnv.macWebSocket
        object["mac_tcp"] = NetCaptureEnv.macTCP
        object["decrypt_https"] = NetCaptureEnv.decryptHTTPS
        object["decrypt_scope"] = scope == "allowlist" ? "allowlist" : "all"
        object["allow_domains"] = DecryptScope.parseDomains(defaults.string(forKey: NetCaptureEnv.Keys.allowDomains) ?? "")
        object["deny_domains"] = DecryptScope.parseDomains(defaults.string(forKey: NetCaptureEnv.Keys.denyDomains) ?? "")
        object["port"] = Int(NetCaptureEnv.port)
        object["socks_port"] = Int(NetCaptureEnv.socksPort)
        object["config_page_port"] = Int(NetCaptureEnv.configPagePort)
        object["wireguard_port"] = Int(NetCaptureEnv.wireguardPort)
        object["mcp_port"] = Int(NetCaptureEnv.mcpPort)
        object["body_cap"] = NetCaptureEnv.bodyCap
        object["max_flows"] = NetCaptureEnv.maxFlows
        object["clear_on_stop"] = NetCaptureEnv.clearOnStop
        object["wifi_name"] = defaults.string(forKey: NetCaptureEnv.Keys.wifiName) ?? ""
        object["ca_trusted"] = trusted
        object["mcp_redact_auth"] = NetCaptureEnv.mcpRedactAuth
        return object
    }

    private static let readOnlyKeys: Set<String> = [
        "engine", "ca_trusted", "proxy_address", "socks_port", "config_page_port", "config_page_url",
        "wireguard_endpoint", "pending_devices", "mcp_port", "mcp_redact_auth",
    ]
    private static let bodyCaps = [1 * 1024 * 1024, 5 * 1024 * 1024, 20 * 1024 * 1024]

    /// 逐项改；没给的不动。顺序：先取值和子开关，再总开关（总开关会按子开关起引擎、指系统代理），最后暂停（要引擎在跑）。
    private static func setConfig(_ arguments: [String: Any]) -> String {
        var changed: [String] = []
        var nextStart: [String] = []
        var needsUser: [String] = []
        var errors: [String] = []
        let defaults = UserDefaults.standard
        let known = Set(config().keys)

        for key in arguments.keys.sorted() where !known.contains(key) || readOnlyKeys.contains(key) {
            errors.append(readOnlyKeys.contains(key) ? "\(key) is read-only" : "unknown key \(key)")
        }

        func setBool(_ key: String, _ defaultsKey: String) {
            guard arguments[key] != nil else { return }
            guard let value = bool(arguments[key]) else { return errors.append("\(key) must be a boolean") }
            defaults.set(value, forKey: defaultsKey)
            changed.append(key)
        }
        func setPort(_ key: String, _ defaultsKey: String) {
            guard arguments[key] != nil else { return }
            guard let value = int(arguments[key]), (1024...65535).contains(value) else {
                return errors.append("\(key) must be an integer 1024-65535")
            }
            defaults.set(value, forKey: defaultsKey)
            changed.append(key)
            nextStart.append(key)
        }

        // 取值、子开关（存起来，和设置页、卡片上改一样）
        let macOptionsBefore = (NetCaptureEnv.macHTTP, NetCaptureEnv.macWebSocket, NetCaptureEnv.macTCP)
        setBool("mac_http", NetCaptureEnv.Keys.macHTTP)
        setBool("mac_websocket", NetCaptureEnv.Keys.macWebSocket)
        setBool("mac_tcp", NetCaptureEnv.Keys.macTCP)
        setBool("clear_on_stop", NetCaptureEnv.Keys.clearOnStop)
        setPort("port", NetCaptureEnv.Keys.port)
        setPort("wireguard_port", NetCaptureEnv.Keys.wireguardPort)
        if arguments["body_cap"] != nil {
            if let value = int(arguments["body_cap"]), bodyCaps.contains(value) {
                defaults.set(value, forKey: NetCaptureEnv.Keys.bodyCap)
                changed.append("body_cap")
                nextStart.append("body_cap")
            } else {
                errors.append("body_cap must be one of \(bodyCaps)")
            }
        }
        if arguments["max_flows"] != nil {
            if let value = int(arguments["max_flows"]), (200...5000).contains(value) {
                defaults.set(value, forKey: NetCaptureEnv.Keys.maxFlows)
                changed.append("max_flows")
            } else {
                errors.append("max_flows must be an integer 200-5000")
            }
        }
        if let value = arguments["wifi_name"] {
            if let name = value as? String {
                defaults.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: NetCaptureEnv.Keys.wifiName)
                changed.append("wifi_name")
            } else {
                errors.append("wifi_name must be a string")
            }
        }
        var scopeChanged = false
        if let value = arguments["decrypt_scope"] {
            if let mode = value as? String, mode == "all" || mode == "allowlist" {
                defaults.set(mode, forKey: NetCaptureEnv.Keys.decryptScope)
                changed.append("decrypt_scope")
                scopeChanged = true
            } else {
                errors.append("decrypt_scope must be \"all\" or \"allowlist\"")
            }
        }
        for (key, defaultsKey) in [("allow_domains", NetCaptureEnv.Keys.allowDomains), ("deny_domains", NetCaptureEnv.Keys.denyDomains)] {
            guard let value = arguments[key] else { continue }
            if let list = value as? [String] {
                defaults.set(list.joined(separator: "\n"), forKey: defaultsKey)
                changed.append(key)
                scopeChanged = true
            } else {
                errors.append("\(key) must be an array of strings")
            }
        }
        let macOptionsChanged = macOptionsBefore != (NetCaptureEnv.macHTTP, NetCaptureEnv.macWebSocket, NetCaptureEnv.macTCP)

        // 总开关。本机要证书已受信：不替用户弹验证框。
        let wantsMac = arguments["mac"] != nil ? bool(arguments["mac"]) : nil
        if arguments["mac"] != nil, wantsMac == nil { errors.append("mac must be a boolean") }
        let trusted = wantsMac == true ? (CaptureCA.shared.isGenerated && CaptureCA.shared.isTrusted()) : true
        var switches: [(String, Bool)] = []
        for key in ["manual_proxy", "wireguard", "cert_page", "decrypt_https", "paused"] where arguments[key] != nil {
            if let value = bool(arguments[key]) { switches.append((key, value)) } else { errors.append("\(key) must be a boolean") }
        }
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                let session = NetCaptureSession.shared
                if scopeChanged { NetCaptureEngine.shared.applyScopeFromSettings() }
                if macOptionsChanged { session.macOptionsChanged() }
                for (key, value) in switches {
                    switch key {
                    case "manual_proxy": session.setManualProxy(value)
                    case "wireguard": session.setWireGuard(value)
                    case "cert_page": session.setCertPage(value)
                    case "decrypt_https": session.setDecryptHTTPS(value)
                    default: break
                    }
                    if key != "paused" { changed.append(key) }
                }
                if let wantsMac {
                    if !wantsMac {
                        session.stopMac()
                        changed.append("mac")
                    } else if trusted {
                        session.startMac(interactive: false)
                        changed.append("mac")
                    } else {
                        needsUser.append("mac: this Mac does not trust Baobox's certificate yet; turn on This Mac in the capture window (macOS asks for a password or Touch ID)")
                    }
                }
            }
        }
        // 暂停要等引擎跑起来（可能是这次刚打开的开关起的）。
        if let paused = switches.first(where: { $0.0 == "paused" })?.1 {
            let running = waitForEngine(seconds: 10)
            if running {
                DispatchQueue.main.sync { MainActor.assumeIsolated { NetCaptureSession.shared.setPaused(paused) } }
                changed.append("paused")
            } else {
                errors.append("paused: the engine is not running (turn on a source first)")
            }
        } else {
            var expected = Dictionary(uniqueKeysWithValues: switches.filter { $0.0 != "decrypt_https" })
            if let wantsMac, wantsMac == false || trusted { expected["mac"] = wantsMac }
            settle(expected)
        }

        var reply: [String: Any] = ["changed": changed, "config": config()]
        if !nextStart.isEmpty {
            reply["applies_next_engine_start"] = nextStart
        }
        if !needsUser.isEmpty { reply["needs_user_in_window"] = needsUser }
        if !errors.isEmpty { reply["errors"] = errors }
        return json(reply)
    }

    /// 改完开关后等一会儿，让回复里的 config 是落定以后的：开关真的变成了要的值（本机要先查证书、WireGuard 要先读密钥，
    /// 都是异步的），引擎跟着起来、重启完或停下。最多 10 秒。
    private static func settle(_ expected: [String: Bool]) {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            let done = DispatchQueue.main.sync {
                MainActor.assumeIsolated { () -> Bool in
                    let session = NetCaptureSession.shared
                    let engine = NetCaptureEngine.shared
                    let now = ["mac": session.macOn, "manual_proxy": session.manualProxyOn,
                               "wireguard": session.wireguardOn, "cert_page": session.certPageOn]
                    guard expected.allSatisfy({ now[$0.key] == $0.value }), session.working == nil else { return false }
                    switch engine.state {
                    case .starting: return false
                    case .running: return true
                    case .stopped, .failed: return !session.anyCardOn
                    }
                }
            }
            if done { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func waitForEngine(seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let state = DispatchQueue.main.sync { MainActor.assumeIsolated { NetCaptureEngine.shared.state } }
            switch state {
            case .running: return true
            case .stopped, .failed: return false
            case .starting: Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return false
    }

    // MARK: - WireGuard

    private static func wireguardConfig() -> String {
        do {
            let keys = try WireGuardKeyFile.loadOrCreate(at: NetCaptureEnv.wireguardKeyURL)
            let endpoint = "\(NetworkInterfaces.primaryIP()):\(NetCaptureEnv.wireguardPort)"
            guard let text = keys.clientConfig(endpoint: endpoint) else { return "error: the key file has an invalid key" }
            let on = DispatchQueue.main.sync { MainActor.assumeIsolated { NetCaptureSession.shared.wireguardOn } }
            return on ? text : text + "\n\n# WireGuard is off in Baobox: turn it on (set_config wireguard=true) before the phone connects."
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    // MARK: - TCP

    private static func listTCP(_ arguments: [String: Any]) -> String {
        var connections = TCPSnapshotStore.shared.get()
        if let device = string(arguments["device"]), !device.isEmpty {
            connections = connections.filter { $0.deviceKey == device }
        }
        if let wanted = string(arguments["protocol"])?.lowercased(), !wanted.isEmpty {
            connections = connections.filter { connection in
                guard let match = connection.detected else { return wanted == "unknown" }
                return match.name.lowercased() == wanted || match.label.lowercased() == wanted
            }
        }
        if let host = string(arguments["host"])?.lowercased(), !host.isEmpty {
            connections = connections.filter { $0.target.lowercased().contains(host) || $0.host.lowercased().contains(host) }
        }
        let limit = int(arguments["limit"]) ?? 50
        guard !connections.isEmpty else { return "(no tcp connections)" }
        let iso = ISO8601DateFormatter()
        return connections.suffix(max(1, limit)).map { c in
            "\(c.id.uuidString) \(c.state.rawValue) \(c.target):\(c.port) \(protocolText(c)) "
                + "up=\(c.bytesUp)B down=\(c.bytesDown)B reads=\(c.segmentCount) @\(c.deviceKey) \(iso.string(from: c.startedAt))"
        }.joined(separator: "\n")
    }

    private static func protocolText(_ connection: TCPConnection) -> String {
        guard let match = connection.detected else { return "unknown" }
        return match.guessed ? "\(match.name)? (guessed from port)" : match.name
    }

    /// 每块最多带这么多字节的内容，整个回复最多这么多（AI 的上下文有限）。
    private static let blockLimit = 8 * 1024
    private static let replyLimit = 96 * 1024

    private static func getTCP(_ arguments: [String: Any]) -> String {
        guard let idText = string(arguments["id"]),
              let connection = TCPSnapshotStore.shared.get().first(where: { $0.id.uuidString.caseInsensitiveCompare(idText) == .orderedSame })
        else { return "tcp connection not found" }
        let merged = !(bool(arguments["segments"]) ?? false)
        let format = string(arguments["format"])?.lowercased() ?? "auto"
        let limit = max(1, int(arguments["limit"]) ?? 50)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines = [
            "TCP \(connection.target):\(connection.port)" + (connection.sni != nil ? " (\(connection.host))" : ""),
            "Device: \(connection.deviceKey)",
            "Protocol: \(protocolText(connection))",
            "State: \(connection.state.rawValue)" + (connection.error.map { " (\($0))" } ?? ""),
            "Started: \(iso.string(from: connection.startedAt))" + (connection.endedAt.map { " · ended \(iso.string(from: $0))" } ?? ""),
            "Bytes: up \(connection.bytesUp), down \(connection.bytesDown) · reads \(connection.segmentCount)"
                + (connection.droppedSegments > 0 ? " (only the first \(TCPLog.maxSegments) reads kept)" : ""),
            merged ? "-- Data: adjacent reads in the same direction merged; offsets run per direction --"
                   : "-- Data: reads as they arrived (boundaries are where reads ended, not messages) --",
        ]
        let blocks = TCPStream.blocks(connection.segments, merge: merged)
        var size = lines.reduce(0) { $0 + $1.count }
        for (index, block) in blocks.prefix(limit).enumerated() {
            let direction = block.fromClient ? "client->server" : "server->client"
            var text = "## #\(index + 1) \(direction) offset=\(block.offset) length=\(block.size)"
                + (block.segmentCount > 1 ? " reads=\(block.segmentCount)" : "") + " at \(iso.string(from: block.startedAt))"
            var shown = 0
            for part in block.parts {
                switch part {
                case .data(let data, let offset):
                    let room = max(0, blockLimit - shown)
                    let visible = data.prefix(room)
                    shown += visible.count
                    let asText = format == "text" || (format == "auto" && TCPPayload.looksLikeText(visible))
                    text += "\n" + (asText ? TCPPayload.text(visible) : TCPPayload.hexDump(visible, startOffset: offset))
                    if visible.count < data.count { text += "\n[\(data.count - visible.count) more bytes not shown]" }
                case .missing(let count, let offset):
                    text += "\n[\(count) bytes not saved at offset \(offset)]"
                }
            }
            size += text.count
            if size > replyLimit {
                lines.append("[reply size limit reached; ask with a smaller limit]")
                break
            }
            lines.append(text)
        }
        if blocks.count > limit { lines.append("[\(blocks.count - limit) more blocks; raise limit to see them]") }
        if blocks.isEmpty { lines.append("(no data yet)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Mock

    private static func ruleObject(_ rule: MockRule) -> [String: Any] {
        var object: [String: Any] = [
            "id": rule.id, "enabled": rule.enabled, "method": rule.method, "host": rule.host, "path": rule.path,
            "status": rule.status, "headers": rule.headers.map { [$0.name, MCPRedaction.value(name: $0.name, value: $0.value)] },
            "body_size": rule.body.count,
        ]
        if let text = String(data: rule.body, encoding: .utf8) {
            object["body"] = text
        } else {
            object["body_base64"] = rule.body.base64EncodedString()
        }
        return object
    }

    private static func setMockRule(_ arguments: [String: Any]) -> String {
        let existing = DispatchQueue.main.sync { MainActor.assumeIsolated { MockRuleStore.shared.rules } }
        let id = string(arguments["id"])
        var rule = id.flatMap { wanted in existing.first { $0.id == wanted } } ?? MockRule(id: id ?? UUID().uuidString.lowercased())
        if arguments["enabled"] != nil {
            guard let value = bool(arguments["enabled"]) else { return "error: enabled must be a boolean" }
            rule.enabled = value
        }
        if let method = string(arguments["method"]) { rule.method = method }
        if let host = string(arguments["host"]) { rule.host = host }
        if let path = string(arguments["path"]) { rule.path = path }
        if arguments["status"] != nil {
            guard let status = int(arguments["status"]) else { return "error: status must be an integer" }
            rule.status = status
        }
        if arguments["headers"] != nil {
            guard let headers = headerPairs(arguments["headers"]) else { return "error: headers must be [[name, value], ...]" }
            rule.headers = headers
        }
        if let body = string(arguments["body"]) { rule.body = Data(body.utf8) }
        if let encoded = string(arguments["body_base64"]) {
            guard let data = Data(base64Encoded: encoded) else { return "error: body_base64 is not base64" }
            rule.body = data
        }
        rule = rule.normalized()
        guard rule.isValid else { return "error: a rule needs a host and a status of 100-599" }
        let saved = rule
        DispatchQueue.main.sync { MainActor.assumeIsolated { MockRuleStore.shared.save(saved) } }
        return json(ruleObject(saved))
    }

    private static func deleteMockRule(_ arguments: [String: Any]) -> String {
        guard let id = string(arguments["id"]) else { return "error: id is required" }
        let found = DispatchQueue.main.sync {
            MainActor.assumeIsolated { () -> Bool in
                guard MockRuleStore.shared.rules.contains(where: { $0.id == id }) else { return false }
                MockRuleStore.shared.remove(id: id)
                return true
            }
        }
        return found ? "deleted \(id)" : "mock rule not found"
    }

    // MARK: - 重发

    private static func replay(_ arguments: [String: Any]) -> String {
        guard let idText = string(arguments["id"]),
              let flow = FlowSnapshotStore.shared.get().first(where: { $0.id.uuidString.caseInsensitiveCompare(idText) == .orderedSame })
        else { return "flow not found" }
        guard flow.decrypted else { return "error: this flow was not decrypted; there is no request to send again" }
        var request = ReplayRequest(id: UUID(), method: flow.method, url: flow.url, headers: flow.requestHeaders, body: flow.requestBody)
        if let method = string(arguments["method"]), !method.isEmpty { request.method = method.uppercased() }
        if let url = string(arguments["url"]), !url.isEmpty { request.url = url }
        if arguments["headers"] != nil {
            guard let headers = headerPairs(arguments["headers"]) else { return "error: headers must be [[name, value], ...]" }
            request.headers = headers
        }
        if let body = string(arguments["body"]) { request.body = Data(body.utf8) }
        if let encoded = string(arguments["body_base64"]) {
            guard let data = Data(base64Encoded: encoded) else { return "error: body_base64 is not base64" }
            request.body = data
        }
        let sent = request
        DispatchQueue.main.sync { MainActor.assumeIsolated { NetCaptureSession.shared.replay(sent) } }
        // 等它回来（最多 5 秒），回复里带上状态码；回不来也给 id，之后用 get_flow 看。
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if let done = FlowSnapshotStore.shared.get().first(where: { $0.id == sent.id }), done.statusCode != nil || done.note != nil {
                let status = done.statusCode.map(String.init) ?? "failed: \(done.note ?? "")"
                return "replayed as \(sent.id.uuidString): \(sent.method) \(sent.url) -> \(status)"
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return "replaying as \(sent.id.uuidString): \(sent.method) \(sent.url) (no answer yet; use get_flow)"
    }

    // MARK: - 参数

    /// JSON 的 true / false（数字 0 / 1 不算布尔）；也认 "true" / "false"。
    private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if let text = value as? String { return ["true": true, "false": false][text.lowercased()] }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func string(_ value: Any?) -> String? { value as? String }

    private static func headerPairs(_ value: Any?) -> [HTTPHeader]? {
        guard let items = value as? [Any] else { return nil }
        var headers: [HTTPHeader] = []
        for item in items {
            guard let pair = item as? [Any], pair.count == 2, let name = pair[0] as? String, let value = pair[1] as? String,
                  !name.isEmpty else { return nil }
            headers.append(HTTPHeader(name: name, value: value))
        }
        return headers
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// 「MCP 返回时脱敏鉴权头」（默认开）：Authorization / Cookie / Set-Cookie / Proxy-Authorization 打码。HTTP 包和 Mock 规则都用它。
enum MCPRedaction {
    static func value(name: String, value: String) -> String {
        guard NetCaptureEnv.mcpRedactAuth else { return value }
        let lower = name.lowercased()
        if lower == "authorization" || lower == "cookie" || lower == "set-cookie" || lower == "proxy-authorization" {
            return "<redacted>"
        }
        return value
    }
}
