import AppKit

/// Claude Code 助手 —— 在终端里续接会话、把正在跑的会话所在的终端切到前台。
///
/// 2026-11（#164）从原 `TerminalLauncher`（`ClaudeEnv.swift`）分出来的 Claude 专有部分：`claude --resume <id>`、
/// 点通知跳回与快速切换面板续接共用的 `focusRunningSession`，以及它按进程找会话用的几个函数（本身通用，但只有这里用，
/// 留在使用者这边；哪天 Codex 也要「切到正在跑的会话」再挪进 Core）。「在偏好终端里跑一条命令」「按 tty 选中标签页」是通用的，
/// 在 `Core/Terminal/TerminalLauncher.swift`（docs/codex-assistant/DEDUPE-P2.md §2.4 类 5）。
/// 触碰 NSWorkspace，故标 `@MainActor`；ps、lsof 在后台队列跑。
@MainActor
enum ClaudeTerminal {

    /// 在指定项目目录续接会话：`<claude> --resume <id>`。
    static func resume(sessionID: String, in directory: String, binary: String? = nil) {
        let bin = binary ?? ClaudeEnv.findClaudeBinary() ?? "claude"
        let command = "\(Shell.quote(bin)) --resume \(Shell.quote(sessionID))"
        TerminalLauncher.run(command: command, in: directory)
    }

    /// 可直接粘贴执行的续接命令(含 cd),供「复制续接命令」类功能共用。
    static func resumeCommandString(sessionID: String, in directory: String) -> String {
        let bin = ClaudeEnv.findClaudeBinary() ?? "claude"
        return "cd \(Shell.quote(directory)) && "
            + "\(Shell.quote(bin)) --resume \(Shell.quote(sessionID))"
    }

    // MARK: 已开窗口检测与聚焦

    /// 把正在跑的会话所在的终端切到前台（#109 B3，docs/claude-code-assistant/NOTIFY_JUMP.md §3）。点通知跳回、快速切换面板续接共用：
    /// 先用 hook 记下的终端位置（精确到标签页 / Otty 面板，同一目录开着几个会话也不会认错），用不了再按进程找（`findRunningSession`）。
    /// `completion` 在主线程回调：true = 切过去了；false = 都不行，调用方兜底（面板开新窗口续接，通知什么也不做）。
    ///
    /// - location: hook 记下的终端位置；nil = 没装 hooks、旧版脚本，或者 6 小时内没见过这个会话。
    /// - confirmRunning: false = 位置直接用（点通知：位置是发通知那一刻记下的）；true = 先确认那个终端（tty）上现在还有 claude
    ///   在跑（面板：会话可能早结束了，见 `ClaudeRunningSession`），没记 tty 的位置确认不了、只按进程找。
    /// - projectPath: 按进程找时比对的项目目录；nil = 不按进程找。
    static func focusRunningSession(sessionID: String, projectPath: String?, location: TerminalLocation?,
                                    confirmRunning: Bool, isNewestInProject: Bool,
                                    completion: @escaping (Bool) -> Void) {
        if let location, !confirmRunning, TerminalFocus.focus(location) {
            completion(true)
            return
        }
        let unconfirmed = confirmRunning ? location : nil
        guard unconfirmed?.tty != nil || projectPath != nil else {
            completion(false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let table = processTable()
            var confirmed: TerminalLocation?
            if let unconfirmed, let tty = unconfirmed.tty,
               ClaudeRunningSession.claudeRuns(onTTY: tty,
                                               processes: table.values.map { (tty: $0.tty, command: $0.command) }) {
                confirmed = unconfirmed
            }
            let running = projectPath.flatMap {
                findRunningSession(sessionID: sessionID, projectPath: $0, isNewestInProject: isNewestInProject, in: table)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let confirmed, TerminalFocus.focus(confirmed) {
                        completion(true)
                    } else if let running, focusTerminalWindow(of: running) {
                        completion(true)
                    } else {
                        completion(false)
                    }
                }
            }
        }
    }

    /// 运行中的会话进程定位结果：宿主终端 App（沿父进程链解析）与会话的 tty。
    private struct RunningSessionProcess: Sendable {
        let terminalAppURL: URL?
        let terminalBundleID: String?
        let ttyPath: String?
    }

    /// 尽力找到某会话对应的运行中 CLI 进程（`table` 是 ps 快照；还会跑 lsof,须在后台队列调用）：
    /// 1) 任一进程命令行含 `--resume <id>` → 必然是该会话；
    /// 2) 项目目录下裸跑的 `claude`（无 --resume）且该会话是此项目最新一条 →
    ///    大概率是那次首启（运行中的首启会话必然产生项目里最新的 JSONL）。
    /// 找到后沿父链定位宿主终端 App：iTerm2 的会话可能挂在独立的 iTermServer
    /// 守护进程下,故按「祖先命令路径含 .app/Contents/MacOS/」匹配而非直接父进程。
    nonisolated private static func findRunningSession(sessionID: String, projectPath: String, isNewestInProject: Bool,
                                                       in table: [Int32: (ppid: Int32, tty: String?, command: String)])
        -> RunningSessionProcess? {
        let claudes = table.filter { ClaudeRunningSession.isClaudeCommand($0.value.command) }

        var matched: Int32?
        if let hit = claudes.first(where: { $0.value.command.contains("--resume \(sessionID)") }) {
            matched = hit.key
        } else if isNewestInProject {
            let target = normalizedPath(projectPath)
            matched = claudes.first { pid, info in
                !info.command.contains("--resume")
                    && workingDirectory(ofPID: pid).map(normalizedPath) == target
            }?.key
        }
        guard let pid = matched, let process = table[pid] else { return nil }

        var terminalURL: URL?
        var terminalBundleID: String?
        var cursor = process.ppid
        var hops = 0
        while cursor > 1, hops < 15, let ancestor = table[cursor] {
            if let (url, bundleID) = terminalApp(inCommand: ancestor.command) {
                terminalURL = url
                terminalBundleID = bundleID
                break
            }
            cursor = ancestor.ppid
            hops += 1
        }
        return RunningSessionProcess(terminalAppURL: terminalURL,
                                     terminalBundleID: terminalBundleID,
                                     ttyPath: process.tty.map { "/dev/\($0)" })
    }

    /// 把按进程找到的会话所在的终端窗口切到前台。定位不到宿主终端返回 false,调用方回退。
    /// macOS 14 起后台 App 直接 `NSRunningApplication.activate()` 会被协作式激活拒绝,
    /// 这里走 Launch Services（等价 `open -a`）前台化;iTerm2 / 系统 Terminal 再用
    /// AppleScript 按 tty 精确选中窗口与标签页（`TerminalLauncher.selectTab`，后台跑；首次触发系统「自动化」授权弹窗）。
    private static func focusTerminalWindow(of process: RunningSessionProcess) -> Bool {
        guard let appURL = process.terminalAppURL, let bundleID = process.terminalBundleID else {
            return false
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        if let tty = process.ttyPath {
            TerminalLauncher.selectTab(bundleID: bundleID, ttyPath: tty)
        }
        return true
    }

    /// 从进程命令行解析终端 App：命令路径形如 `/Applications/iTerm.app/Contents/MacOS/...`。
    nonisolated private static func terminalApp(inCommand command: String) -> (URL, String)? {
        guard let appPath = ClaudeRunningSession.appBundlePath(inCommand: command),
              let bundleID = Bundle(path: appPath)?.bundleIdentifier,
              terminalBundleIDs.contains(bundleID) else { return nil }
        return (URL(fileURLWithPath: appPath), bundleID)
    }

    nonisolated private static var terminalBundleIDs: Set<String> {
        Set(TerminalAppChoice.allCases.compactMap(\.bundleID))
    }

    /// 进程快照：pid → (ppid, tty, command)。tty 为 `??`（无控制终端）时记 nil。
    nonisolated private static func processTable()
        -> [Int32: (ppid: Int32, tty: String?, command: String)] {
        guard let output = Shell.output("/bin/ps", ["-axo", "pid=,ppid=,tty=,command="]) else { return [:] }
        return ClaudeRunningSession.parseProcessTable(output)
    }

    /// 取进程当前工作目录（lsof cwd）。
    nonisolated private static func workingDirectory(ofPID pid: Int32) -> String? {
        guard let output = Shell.output("/usr/sbin/lsof",
                                        ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    /// 路径归一（解符号链接），避免 /tmp 与 /private/tmp 之类的假不等。
    nonisolated private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
