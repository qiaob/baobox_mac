import AppKit

/// 在用户偏好的终端里跑一条命令（续接 CLI 会话等），终端解析见同目录的 `TerminalAppChoice`。
///
/// Claude Code 助手、Codex 助手（还有暂缓、不参与编译的网络抓包）共用，只认「命令 + 目录」。2026-11（#164）从
/// `Modules/ClaudeCode/ClaudeEnv.swift` 搬来，名字与签名不变；认得 `claude` 的部分（`claude --resume`、按进程找正在跑的会话）
/// 留在 Claude 模块的 `ClaudeTerminal`（docs/codex-assistant/DEDUPE-P2.md §2.4 类 5）。
/// 触碰 NSWorkspace，故标 `@MainActor`，由菜单点击等主线程场景调用。写入的是极小的 `.command` 脚本，主线程落盘可接受。
@MainActor
enum TerminalLauncher {

    /// 一次性脚本放这儿：`~/Library/Application Support/Baobox/Terminal/launch/`（以前在 `Baobox/ClaudeCode/launch/`，
    /// 旧目录由 Claude 模块启动时删掉，DEDUPE-P2.md D2）。
    nonisolated static var launchDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("Baobox/Terminal/launch", isDirectory: true)
    }

    /// 把命令包成一次性 `.command` 脚本（内容见 `TerminalLaunchScript.contents`）并用偏好终端打开；目录里只留最近 20 个。
    /// - Parameters:
    ///   - command: 要执行的命令行（不含 cd）。
    ///   - directory: 执行目录；nil 或空串则不 cd。
    static func run(command: String, in directory: String?) {
        let launchDir = launchDirectory
        try? FileManager.default.createDirectory(at: launchDir, withIntermediateDirectories: true)
        TerminalLaunchScript.prune(launchDir, keep: TerminalLaunchScript.keepCount)

        let script = TerminalLaunchScript.contents(command: command, directory: directory)

        let fileURL = launchDir.appendingPathComponent("\(UUID().uuidString).command")
        guard let data = script.data(using: .utf8) else { return }
        do {
            try data.write(to: fileURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        } catch {
            return
        }
        // `.command` 的系统默认关联是 Terminal.app，会脱离用户日常终端的主题/字体
        // 环境（真彩色在 Terminal.app 下渲染成乱码），必须显式指定偏好终端打开。
        guard let launch = TerminalAppChoice.resolveLaunch() else {
            NSWorkspace.shared.open(fileURL)
            return
        }
        switch launch.choice.launchStyle {
        case .document:
            NSWorkspace.shared.open([fileURL], withApplicationAt: launch.appURL,
                                    configuration: NSWorkspace.OpenConfiguration())
        case .binary(let argsPrefix):
            // kitty / WezTerm / Alacritty 不接管 .command,直接拉起可执行文件运行脚本。
            guard let executable = Bundle(url: launch.appURL)?.executableURL else {
                NSWorkspace.shared.open(fileURL)
                return
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = argsPrefix + [fileURL.path]
            try? process.run()
        }
    }

    /// 只按 tty 选中 iTerm2 / 系统 Terminal 里承载会话的窗口与标签页（App 本身由调用方前台化）；
    /// 其他终端没有按 tty 选标签页的脚本接口，什么都不做。osascript 在后台跑（逐个会话查 tty 是多次 Apple Event 往返），
    /// 首次会弹系统「自动化」授权。点通知跳回（同目录的 `TerminalFocus`）与 Claude 按进程找到会话后切窗口用。
    static func selectTab(bundleID: String, ttyPath: String) {
        guard let script = tabSelectScript(bundleID: bundleID, ttyPath: ttyPath) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Shell.output("/usr/bin/osascript", ["-e", script])
        }
    }

    /// 按 tty 选中承载会话的窗口/标签页的 AppleScript;仅 iTerm2 与系统 Terminal 支持。
    nonisolated private static func tabSelectScript(bundleID: String, ttyPath: String) -> String? {
        switch bundleID {
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(ttyPath)" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(ttyPath)" then
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        default:
            return nil
        }
    }
}
