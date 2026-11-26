import Foundation

// 本机端口占用的纯逻辑：解析 `lsof -nP -F pcLPn` 与 `ps` 输出、按端口/进程/命令行过滤、提取快速入口端口查询。
// 只依赖 Foundation，进 BaoboxTests。

enum NetPortProtocol: String, Equatable, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
}

/// 一条本机监听端口记录。
struct NetPortEntry: Equatable, Identifiable, Sendable {
    let pid: Int32
    let processName: String
    let user: String
    let proto: NetPortProtocol
    /// 绑定地址，如 `127.0.0.1`、`::1`、`*`。
    let address: String
    let port: Int
    /// 完整命令行（来自 `ps`，取不到时为空）。
    var commandLine: String = ""

    var id: String { "\(proto.rawValue)|\(pid)|\(address)|\(port)" }

    /// 是否只绑定在回环地址（仅本机可访问）。
    var isLocalOnly: Bool {
        let lower = address.lowercased()
        return lower == "127.0.0.1" || lower == "::1" || lower == "localhost"
    }

    /// 供展示和复制的绑定端点，如 `127.0.0.1:3000`、`*:8080`、`[::1]:5173`。
    var bindLabel: String {
        if address.contains(":"), !address.hasPrefix("[") {
            return "[\(address)]:\(port)"
        }
        return "\(address):\(port)"
    }
}

enum NetPortLogic {

    /// 解析 `lsof -nP -F pcLPn` 的机读输出（每行一个单字符前缀字段）。
    /// - 跳过已建立的远端连接（`n` 字段包含 `->`）以及无明确端口号的条目（如 `*:*`）。
    /// - 按 `(proto, pid, address, port)` 去重，默认按端口号升序、PID 升序排列。
    static func parseLsofFieldOutput(_ text: String, defaultProtocol: NetPortProtocol = .tcp) -> [NetPortEntry] {
        var currentPID: Int32?
        var currentCommand = ""
        var currentUser = ""
        var currentProto: NetPortProtocol?

        var entries: [NetPortEntry] = []
        var seen: Set<String> = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let tag = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch tag {
            case "p":
                currentPID = Int32(value)
                currentCommand = ""
                currentUser = ""
                currentProto = nil
            case "c":
                currentCommand = value
            case "L":
                currentUser = value
            case "f":
                // 新文件描述符：重置协议，防止上一个 FD 的协议串到下一个
                currentProto = nil
            case "P":
                let upper = value.uppercased()
                if upper == "TCP" {
                    currentProto = .tcp
                } else if upper == "UDP" {
                    currentProto = .udp
                } else {
                    currentProto = nil
                }
            case "n":
                guard let pid = currentPID, !value.contains("->"),
                      let parsed = parseEndpoint(value) else { continue }
                let proto = currentProto ?? defaultProtocol
                let name = currentCommand.isEmpty ? "pid \(pid)" : currentCommand
                let entry = NetPortEntry(pid: pid, processName: name, user: currentUser,
                                         proto: proto, address: parsed.address, port: parsed.port)
                if seen.insert(entry.id).inserted {
                    entries.append(entry)
                }
            default:
                continue
            }
        }

        return entries.sorted { lhs, rhs in
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            if lhs.proto != rhs.proto { return lhs.proto == .tcp }
            if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
            return lhs.address < rhs.address
        }
    }

    /// 解析 `lsof` 的 `n` 字段，如 `*:3000`、`127.0.0.1:8080`、`[::1]:5173`、`[::]:443`。
    /// 端口号不在 1...65535 时返回 nil。
    static func parseEndpoint(_ raw: String) -> (address: String, port: Int)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let colon = text.lastIndex(of: ":") else { return nil }
        let portPart = String(text[text.index(after: colon)...])
        guard let port = Int(portPart), (1...65535).contains(port) else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.isEmpty { host = "*" }
        return (address: host, port: port)
    }

    /// 解析 `ps -ww -o pid=,args= -p <pids>`：每行 `<pid> <command line>`。
    static func parsePSOutput(_ text: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let pid = Int32(digits) else { continue }
            let args = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            if !args.isEmpty { result[pid] = args }
        }
        return result
    }

    /// 把 `ps` 拿到的完整命令行挂回端口条目上。
    static func attachCommandLines(_ entries: [NetPortEntry], commands: [Int32: String]) -> [NetPortEntry] {
        entries.map { entry in
            var copy = entry
            if let cmd = commands[entry.pid] { copy.commandLine = cmd }
            return copy
        }
    }

    /// 按搜索词过滤：支持 `:3000` / `3000`（端口）、进程名、PID、地址、命令行或协议。
    static func filter(_ entries: [NetPortEntry], query: String) -> [NetPortEntry] {
        var cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return entries }
        if cleaned.hasPrefix(":") { cleaned.removeFirst() }
        let needle = cleaned.lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            String(entry.port).contains(needle)
                || entry.processName.lowercased().contains(needle)
                || String(entry.pid).contains(needle)
                || entry.address.lowercased().contains(needle)
                || entry.commandLine.lowercased().contains(needle)
                || entry.proto.rawValue.lowercased() == needle
        }
    }

    /// 从快速入口输入中识别端口查询：`:3000`、`port 3000`、`端口 3000`、`端口:3000`。
    /// 返回标准化后的端口数字串（如 `"3000"`）；不是端口查询返回 nil。
    static func extractPortQuery(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix(":") {
            let rest = String(trimmed.dropFirst())
            if let port = Int(rest), (1...65535).contains(port), rest.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return String(port)
            }
            return nil
        }
        let lower = trimmed.lowercased()
        for prefix in ["port ", "port:", "端口 ", "端口:", "端口："] where lower.hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if let port = Int(rest), (1...65535).contains(port), rest.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return String(port)
            }
        }
        return nil
    }
}
