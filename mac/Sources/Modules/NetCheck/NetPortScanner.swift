import Foundation

/// 本机监听端口扫描与进程结束（纯本地只读/本机信号，不联网、无需 root）。
enum NetPortScanner {

    /// 扫描本机监听端口：通过 `lsof -nP -F pcLPn` 取端口与进程，再用 `ps` 补完整命令行。
    /// 阻塞操作：只在后台队列调用。
    static func scan(includeUDP: Bool) -> Result<[NetPortEntry], NetCheckFailure> {
        guard let tcpRaw = Shell.output("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcLPn"]) else {
            return .failure(NetCheckFailure(L("netcheck.ports.error.lsof")))
        }
        var combined = NetPortLogic.parseLsofFieldOutput(tcpRaw, defaultProtocol: .tcp)

        if includeUDP, let udpRaw = Shell.output("/usr/sbin/lsof", ["-nP", "-iUDP", "-F", "pcLPn"]) {
            let udpEntries = NetPortLogic.parseLsofFieldOutput(udpRaw, defaultProtocol: .udp)
            var seen = Set(combined.map(\.id))
            for entry in udpEntries where seen.insert(entry.id).inserted {
                combined.append(entry)
            }
            combined.sort { lhs, rhs in
                if lhs.port != rhs.port { return lhs.port < rhs.port }
                if lhs.proto != rhs.proto { return lhs.proto == .tcp }
                if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
                return lhs.address < rhs.address
            }
        }

        let pids = Array(Set(combined.map(\.pid))).sorted()
        if !pids.isEmpty {
            let pidArg = pids.map(String.init).joined(separator: ",")
            if let psRaw = Shell.output("/bin/ps", ["-ww", "-o", "pid=,args=", "-p", pidArg]) {
                let commands = NetPortLogic.parsePSOutput(psRaw)
                combined = NetPortLogic.attachCommandLines(combined, commands: commands)
            }
        }
        return .success(combined)
    }

    /// 结束占用端口的进程：`force == false` 发 SIGTERM，`force == true` 发 SIGKILL。
    /// 禁止操作 PID <= 1 或 Baobox 自身进程。
    static func terminate(pid: Int32, force: Bool) -> Result<Void, NetCheckFailure> {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else {
            return .failure(NetCheckFailure(L("netcheck.ports.error.protected")))
        }
        let signal: Int32 = force ? SIGKILL : SIGTERM
        if Darwin.kill(pid, signal) == 0 {
            return .success(())
        }
        let code = errno
        switch code {
        case EPERM:
            return .failure(NetCheckFailure(L("netcheck.ports.error.permission \(Int(pid))")))
        case ESRCH:
            return .success(())
        default:
            let message = String(cString: strerror(code))
            return .failure(NetCheckFailure(L("netcheck.ports.error.kill \(Int(pid)) \(message)")))
        }
    }
}

/// 端口占用页的状态管理（@MainActor，扫描与发信号均在后台队列执行）。
@MainActor
final class NetPortSession: ObservableObject {
    static let shared = NetPortSession()

    @Published private(set) var entries: [NetPortEntry] = []
    @Published private(set) var loading = false
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var includeUDP = false

    private var scanGeneration = 0

    private init() {}

    var filteredEntries: [NetPortEntry] {
        NetPortLogic.filter(entries, query: searchText)
    }

    /// 后台刷新本机监听端口列表。
    func refresh() {
        scanGeneration += 1
        let gen = scanGeneration
        let withUDP = includeUDP
        loading = true
        errorMessage = nil
        DispatchQueue.global(qos: .utility).async {
            let outcome = NetPortScanner.scan(includeUDP: withUDP)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let session = NetPortSession.shared
                    guard session.scanGeneration == gen else { return }
                    session.loading = false
                    switch outcome {
                    case .success(let list):
                        session.entries = list
                        session.lastUpdated = Date()
                    case .failure(let why):
                        session.errorMessage = why.message
                    }
                }
            }
        }
    }

    /// 结束指定条目对应的进程；成功后稍等片刻自动刷新列表。
    func terminate(_ entry: NetPortEntry, force: Bool = false) {
        let pid = entry.pid
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NetPortScanner.terminate(pid: pid, force: force)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success:
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            MainActor.assumeIsolated { NetPortSession.shared.refresh() }
                        }
                    case .failure(let why):
                        NetPortSession.shared.errorMessage = why.message
                    }
                }
            }
        }
    }
}
