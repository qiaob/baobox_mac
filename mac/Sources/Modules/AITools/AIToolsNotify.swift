import Foundation

/// Codex 助手 —— Codex 完成通知：notify 程序生成 + 事件文件监听 + 系统通知。
///
/// 机制（DESIGN 第 2 节）：把 `codex-notify.sh` 写进支持目录并 chmod 0755，再把其路径装进
/// `~/.codex/config.toml` 的 `notify` 键。Codex 每个回合结束会调用该程序，并把事件 JSON
/// 作为**最后一个参数**传入；脚本取末位参数追加到独立 events 文件。Baobox 用与 Claude Code 助手共用的
/// `EventFileFollower`（Core/EventFile）跟随该文件的增量，回合完成（agent-turn-complete）时发系统通知。
///
/// events 文件与 `ClaudeLiveStatus` 的各自独立；两个模块之间不互相依赖。
/// 通知经通知内核（NotifyCenter，桌面宠物模块）投递：宠物呈现，宠物关时由内核回退系统通知（权限也归内核管）。
///
/// 用户可见文案（L key）：
///   - aitools.notify.turnComplete.title      zh:「Codex 回合完成」   en:「Codex turn complete」
///   - aitools.notify.turnComplete.titleProject %@  zh:「Codex 完成 · %@」 en:「Codex done · %@」

// MARK: - 通知设置（UserDefaults 键）

enum AIToolsNotifierSettings {
    static let soundKey = "aitools.notificationSound"
    static let budgetAlertKey = "aitools.budgetAlertEnabled"

    /// 提示音（默认开）。
    static var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }

    /// 额度 80% 提醒（默认开；仅在设置了预算时生效）。
    static var budgetAlertEnabled: Bool {
        UserDefaults.standard.object(forKey: budgetAlertKey) as? Bool ?? true
    }
}

// MARK: - Codex 完成通知管理器（@MainActor 单例）

@MainActor
final class CodexNotify: ObservableObject {
    static let shared = CodexNotify()

    /// notify 是否已装入 config.toml（内存缓存，供菜单零 IO 读取与设置页联动）。
    @Published private(set) var isInstalled = false
    /// config.toml 的 notify 键当前不可安全编辑（多行 / 非字符串数组）时置真，UI 据此置灰。
    @Published private(set) var isUneditable = false

    /// events 文件的回放 + 跟随。
    private lazy var follower = EventFileFollower(
        url: eventsURL,
        limits: CodexNotify.eventFileLimits,
        queueLabel: "com.baobox.aitools.eventwatcher"
    )

    /// 通知摘要截断长度。
    private static let summaryClip = 60
    /// events 文件超过 2 MB 则截断，保留最后 500 行。
    nonisolated private static let eventFileLimits = EventFileLog.Limits(maxBytes: 2 * 1_024 * 1_024, keepTailLines: 500)

    private init() {}

    // MARK: 路径

    var scriptURL: URL {
        CodexEnv.supportDir.appendingPathComponent("codex-notify.sh")
    }

    var eventsURL: URL {
        CodexEnv.supportDir.appendingPathComponent("codex-events.jsonl")
    }

    // MARK: 状态

    /// 后台读 config.toml 判定 notify 是否指向本模块脚本，回主线程刷新缓存。
    func refreshState() {
        let scriptURL = self.scriptURL
        let scriptPath = scriptURL.path
        let eventsPath = eventsURL.path
        DispatchQueue.global(qos: .utility).async {
            let value = CodexEnv.notify()
            var installed = false
            var uneditable = false
            switch value {
            case .array(let programs): installed = programs.contains(scriptPath)
            case .uneditable: uneditable = true
            case .absent: break
            }
            // 已装的是旧版脚本（比如还不记终端位置）：换成新版。只动自家脚本，不碰 config.toml。
            if installed,
               (try? String(contentsOf: scriptURL, encoding: .utf8)) != Self.scriptContent(eventsPath: eventsPath) {
                _ = Self.writeScript(to: scriptURL, eventsPath: eventsPath)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isInstalled = installed
                    self.isUneditable = uneditable
                }
            }
        }
    }

    // MARK: 生命周期

    /// 已安装则启动事件监听（初始回放不发通知）。未安装则空转。已启动则直接返回。
    func start() {
        follower.start(
            replay: { [weak self] lines in
                guard let self else { return }
                for line in lines { self.apply(line: line, notify: false) }
            },
            follow: { [weak self] newLines in
                guard let self else { return }
                for line in newLines { self.apply(line: line, notify: true) }
            }
        )
    }

    func stop() {
        follower.stop()
    }

    // MARK: 安装 / 卸载

    /// 生成脚本 + chmod 0755 + 写入 config.toml notify → 刷新状态并启动监听。
    func install(completion: @escaping (Bool) -> Void) {
        let scriptURL = self.scriptURL
        let scriptPath = scriptURL.path
        let eventsPath = eventsURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            let wrote = Self.writeScript(to: scriptURL, eventsPath: eventsPath)
            var ok = wrote
            if wrote {
                do {
                    var programs: [String]
                    switch CodexEnv.notify() {
                    case .array(let existing): programs = existing
                    case .absent: programs = []
                    case .uneditable: throw CodexTOML.EditError.uneditable
                    }
                    if !programs.contains(scriptPath) { programs.append(scriptPath) }
                    try CodexEnv.setNotify(programs)
                } catch {
                    ok = false
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshState()
                    if ok { self.start() }
                    completion(ok)
                }
            }
        }
    }

    /// 从 config.toml notify 中移除本脚本路径（数组空则删键）→ 刷新状态并停监听。
    func remove(completion: @escaping (Bool) -> Void) {
        let scriptPath = scriptURL.path
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = true
            do {
                switch CodexEnv.notify() {
                case .array(var programs):
                    programs.removeAll { $0 == scriptPath }
                    if programs.isEmpty {
                        try CodexEnv.removeNotify()
                    } else {
                        try CodexEnv.setNotify(programs)
                    }
                case .absent:
                    break
                case .uneditable:
                    throw CodexTOML.EditError.uneditable
                }
            } catch {
                ok = false
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.stop()
                    self.refreshState()
                    completion(ok)
                }
            }
        }
    }

    // MARK: 通知

    /// 额度 80% 提醒（5h 或周）。与 Claude 同机制，防重由 `CodexUsageStore` 负责。
    func notifyBudget(percent: Int, weekly: Bool) {
        // 改走通知内核（DesktopPet）：宠物呈现，宠物关时由内核回退系统通知。
        NotifyCenter.shared.post(PetNotification(
            source: "codex",
            level: .ambient,
            title: weekly ? L("aitools.notify.weeklyBudget.title") : L("aitools.notify.budget.title"),
            body: L("aitools.notify.budget.body \(percent)"),
            playSound: AIToolsNotifierSettings.soundEnabled
        ))
    }

    /// 处理一行事件 JSON。notify=false 用于初始回放。
    private func apply(line: String, notify: Bool) {
        guard notify,
              let data = line.data(using: .utf8),
              let object = CLIJSONL.parseObject(data) else { return }

        // 兼容顶层与 payload 嵌套两种写法。
        let type = (object["type"] as? String)
            ?? ((object["payload"] as? [String: Any])?["type"] as? String)
        guard type == "agent-turn-complete" || type == "agent_turn_complete" else { return }

        let message = lastAssistantMessage(from: object)
        let cwd = CodexJSONLParsing.extractMeta(from: object).cwd
        let project = cwd.flatMap { $0.isEmpty ? nil : CodexSessionIndex.projectName(fromPath: $0) }
        postTurnComplete(project: project, summary: message, terminal: TerminalLocation(json: object["baobox_terminal"]))
        // 回合完成 → 节流刷新用量（≥60s 才真正刷），使菜单/用量页近实时。
        CodexUsageStore.shared.refreshThrottledFromEvent()
    }

    /// 从事件对象里取 last-assistant-message（兼容连字符 / 下划线 / payload 嵌套）。
    private func lastAssistantMessage(from object: [String: Any]) -> String {
        let keys = ["last-assistant-message", "last_assistant_message"]
        for key in keys {
            if let s = object[key] as? String { return s }
        }
        if let payload = object["payload"] as? [String: Any] {
            for key in keys {
                if let s = payload[key] as? String { return s }
            }
        }
        return ""
    }

    /// `terminal`：notify 脚本记下的会话所在终端；点通知卡片（或系统通知）时跳回那个窗口。
    private func postTurnComplete(project: String?, summary: String, terminal: TerminalLocation?) {
        let title: String
        if let project, !project.isEmpty {
            title = L("aitools.notify.turnComplete.titleProject \(project)")
        } else {
            title = L("aitools.notify.turnComplete.title")
        }
        let body = String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.summaryClip))

        NotifyCenter.shared.post(PetNotification(
            source: "codex",
            level: .bubble,
            title: title,
            body: body,
            playSound: AIToolsNotifierSettings.soundEnabled
        ), onAction: terminal.map { location in { action in if action == "open" { TerminalFocus.focus(location) } } })
    }

    // MARK: 脚本生成（nonisolated static）

    /// notify 脚本内容。事件 JSON 是最后一个参数，用 `for` 循环取末位后追加到 events 文件。
    /// 顺带在同一个 JSON 里补上 `baobox_terminal`：会话开在哪个终端（终端 App、Otty 面板、控制终端），
    /// 点通知时据此跳回那个窗口（docs/claude-code-assistant/NOTIFY_JUMP.md）。与 Claude 的 reporter 同一写法。
    nonisolated static func scriptContent(eventsPath: String) -> String {
        #"""
        #!/bin/sh
        # Baobox Codex notify hook —— Codex 把事件 JSON 作为最后一个参数传入。
        last=""
        for a in "$@"; do last=$a; done
        clean() { printf '%s' "$1" | tr -d '"\\\r\n'; }
        tty=$(ps -o tty= -p "$PPID" 2>/dev/null)
        term="\"baobox_terminal\":{\"app\":\"$(clean "$__CFBundleIdentifier")\",\"otty_pane\":\"$(clean "$OTTY_PANE_ID")\",\"tty\":\"$(clean "$tty" | tr -d ' ')\"}"
        case "$last" in
            \{*\}) printf '%s,%s}\n' "${last%\}}" "$term" >> \#(shellSingleQuote(eventsPath)) ;;
            *) printf '%s\n' "$last" >> \#(shellSingleQuote(eventsPath)) ;;
        esac
        exit 0
        """#
    }

    /// 写 notify 脚本。
    nonisolated static func writeScript(to url: URL, eventsPath: String) -> Bool {
        CodexEnv.ensureSupportDir()
        let script = scriptContent(eventsPath: eventsPath)
        guard let data = script.data(using: .utf8) else { return false }
        do {
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// 单引号安全包裹（供脚本内路径拼接）。与 `ClaudeEnv.shellSingleQuote` 同实现，独立以避免耦合。
    nonisolated static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
