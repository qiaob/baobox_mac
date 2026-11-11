import AppKit

/// 某个 CLI 会话（Claude Code / Codex）开在哪个终端里。由 hook / notify 脚本在会话的进程环境里记下来，
/// 随事件一起写进 events 文件（字段 `baobox_terminal`）。点通知时据此跳回那个窗口（docs/claude-code-assistant/NOTIFY_JUMP.md）。
struct TerminalLocation: Equatable, Sendable {
    /// 终端 App 的 bundle id（`__CFBundleIdentifier`：终端起 shell 时系统带上的）。
    var bundleID: String?
    /// Otty 的面板 id（`OTTY_PANE_ID`）。
    var ottyPane: String?
    /// 控制终端（`/dev/ttys012`）：iTerm2 / 系统 Terminal 按它选中标签页。
    var tty: String?

    /// 解析 events 里的 `baobox_terminal` 对象；什么都没有返回 nil。
    init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        func value(_ key: String) -> String? {
            guard let text = (object[key] as? String)?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty, text != "??" else { return nil }
            return text
        }
        bundleID = value("app")
        ottyPane = value("otty_pane")
        tty = value("tty").map { $0.hasPrefix("/dev/") ? $0 : "/dev/" + $0 }
        if bundleID == nil, ottyPane == nil, tty == nil { return nil }
    }
}

@MainActor
enum TerminalFocus {
    static let ottyBundleID = "io.appmakes.otty"

    /// 把会话所在的终端切到前台，能精确到标签页 / 面板的就精确到。返回 false = 不知道在哪（调用方兜底）。
    @discardableResult
    static func focus(_ location: TerminalLocation) -> Bool {
        let bundleID = location.bundleID ?? (location.ottyPane != nil ? ottyBundleID : nil)
        guard let bundleID, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        // macOS 14 起后台 App 直接 activate() 会被协作式激活拒绝，走 Launch Services 前台化（等价 `open -a`）。
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        if bundleID == ottyBundleID, let pane = location.ottyPane {
            let cli = appURL.appendingPathComponent("Contents/MacOS/otty-cli").path
            DispatchQueue.global(qos: .userInitiated).async {
                focusOttyPane(pane, cli: cli)
            }
        } else if let tty = location.tty {
            TerminalLauncher.selectTab(bundleID: bundleID, ttyPath: tty)
        }
        return true
    }

    /// Otty：环境变量里的面板 id 不带 `p_` 前缀。先查出面板所在的窗口和标签页，依次切过去，再切到面板（分屏时）。
    nonisolated private static func focusOttyPane(_ pane: String, cli: String) {
        let id = pane.hasPrefix("p_") ? pane : "p_" + pane
        var window: String?
        var tab: String?
        if let data = run(cli, ["pane", "list", "--json"]),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let panes = object["data"] as? [[String: Any]],
           let match = panes.first(where: { ($0["id"] as? String) == id }) {
            window = match["window_id"] as? String
            tab = match["tab_id"] as? String
        }
        if let window { _ = run(cli, ["window", "focus", window]) }
        if let tab { _ = run(cli, ["tab", "focus", tab]) }
        _ = run(cli, ["pane", "focus", id])
    }

    /// 跑一个命令拿标准输出；失败 / 非零退出返回 nil。只在后台队列调用。
    nonisolated private static func run(_ path: String, _ arguments: [String]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
