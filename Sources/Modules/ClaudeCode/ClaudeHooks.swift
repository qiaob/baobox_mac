import Foundation

/// Claude Code 助手 —— Baobox hooks 安装 / 卸载（事件上报 + 危险命令卫士）与卫士规则管理。
///
/// 安装 = 生成 sh 脚本(chmod 755) + 按 TECH_DESIGN 2.3 把条目合并进 settings.json；
/// 识别自家条目的标志是 command 路径含 `/Baobox/ClaudeCode/`。卸载只移除自家条目，其余原样保留。
/// 脚本纯 POSIX sh，不依赖 jq/python。重 IO 后台，`@Published` 主线程写。
///
/// 用户可见文案：脚本内 stderr 提示是喂给 Claude 的固定串，不走 L()。预置规则的人话描述以
/// L() key 形式声明在 `guardPresets`（由 UI 渲染），key 与建议中英文案见 CORE_API.md 第 7 节，
/// 命名空间 `claudecode.guard.preset.*`（rmRfRoot/rmRfHome/sudoRm/gitPushForce/gitResetHard/
/// gitCleanForce/dropTable/mkfs/chmod777 共 9 条）。

// MARK: - 预置卫士规则模型

/// 一条预置危险命令规则。启用状态不落额外文件：以其 `pattern` 是否出现在 guard-patterns.txt 反推。
struct ClaudeGuardPreset: Identifiable, Equatable {
    /// 稳定标识（供 UI ForEach / 勾选状态）。
    let id: String
    /// 人话描述的 L() key（中英文案见 CORE_API.md）。
    let descriptionKey: String
    /// ERE 正则，匹配整行 tool_input JSON。
    let pattern: String
}

// MARK: - 脚本与规则常量

enum ClaudeHookScripts {
    static let reporterFileName = "report-event.sh"
    static let guardFileName = "guard.sh"
    static let guardPatternsFileName = "guard-patterns.txt"

    /// 识别自家条目 / 脚本的路径标志。
    static let markerFragment = "/Baobox/ClaudeCode/"

    /// reporter 脚本内容固定：把 stdin 追加进 events.jsonl，再补一个换行。
    static let reporterScript = """
    #!/bin/sh
    d="$HOME/Library/Application Support/Baobox/ClaudeCode"
    mkdir -p "$d"
    cat >> "$d/events.jsonl"
    printf "\\n" >> "$d/events.jsonl"
    exit 0
    """

    /// guard 脚本内容固定：逐条 ERE 规则匹配整行 JSON，命中则反馈原因并 exit 2。
    static let guardScript = """
    #!/bin/sh
    d="$HOME/Library/Application Support/Baobox/ClaudeCode"
    patterns="$d/guard-patterns.txt"
    input=$(cat)
    [ -f "$patterns" ] || exit 0
    while IFS= read -r p || [ -n "$p" ]; do
        case "$p" in ''|\\#*) continue ;; esac
        if printf '%s' "$input" | grep -qE -- "$p"; then
            echo "Baobox 卫士已拦截：命令匹配规则 [$p]。如确需执行，请让用户在 Baobox 设置中调整规则。" >&2
            exit 2
        fi
    done < "$patterns"
    exit 0
    """

    /// 预置危险命令规则表（内置常量，暴露给 UI 做勾选列表）。
    /// 启用状态不另存：由「该 pattern 是否在 guard-patterns.txt 中」反推。
    static let guardPresets: [ClaudeGuardPreset] = [
        ClaudeGuardPreset(id: "rmRfRoot", descriptionKey: "claudecode.guard.preset.rmRfRoot", pattern: "rm -rf /"),
        ClaudeGuardPreset(id: "rmRfHome", descriptionKey: "claudecode.guard.preset.rmRfHome", pattern: "rm -rf ~"),
        ClaudeGuardPreset(id: "sudoRm", descriptionKey: "claudecode.guard.preset.sudoRm", pattern: "sudo rm"),
        ClaudeGuardPreset(id: "gitPushForce", descriptionKey: "claudecode.guard.preset.gitPushForce", pattern: "git push[^\\n]*--force"),
        ClaudeGuardPreset(id: "gitResetHard", descriptionKey: "claudecode.guard.preset.gitResetHard", pattern: "git reset --hard"),
        ClaudeGuardPreset(id: "gitCleanForce", descriptionKey: "claudecode.guard.preset.gitCleanForce", pattern: "git clean -fd"),
        ClaudeGuardPreset(id: "dropTable", descriptionKey: "claudecode.guard.preset.dropTable", pattern: "DROP TABLE"),
        ClaudeGuardPreset(id: "mkfs", descriptionKey: "claudecode.guard.preset.mkfs", pattern: "mkfs"),
        ClaudeGuardPreset(id: "chmod777", descriptionKey: "claudecode.guard.preset.chmod777", pattern: "chmod -R 777")
    ]

    /// 预置规则的 pattern 集合（快速判定某条自定义规则是否其实是预置）。
    static let presetPatternSet: Set<String> = Set(guardPresets.map { $0.pattern })

    /// 默认规则集（全新安装时全部预置启用）。
    static let defaultGuardPatterns: [String] = guardPresets.map { $0.pattern }

    /// 上报类事件（reporter 挂这四个）。
    static let reporterEvents = ["Stop", "Notification", "SessionStart", "UserPromptSubmit"]
    /// 卫士事件。
    static let guardEvent = "PreToolUse"
}

// MARK: - Hooks 管理单例

@MainActor
final class ClaudeHooksManager: ObservableObject {
    static let shared = ClaudeHooksManager()

    @Published private(set) var isReporterInstalled = false
    @Published private(set) var isGuardInstalled = false
    @Published private(set) var guardPatterns: [String] = []

    private init() {}

    private var reporterURL: URL {
        ClaudeEnv.supportDir.appendingPathComponent(ClaudeHookScripts.reporterFileName)
    }
    private var guardURL: URL {
        ClaudeEnv.supportDir.appendingPathComponent(ClaudeHookScripts.guardFileName)
    }
    private var patternsURL: URL {
        ClaudeEnv.supportDir.appendingPathComponent(ClaudeHookScripts.guardPatternsFileName)
    }

    // MARK: - 状态刷新

    /// 后台读 settings.json 判定安装状态，读规则文件，回主线程发布。
    func refreshState() {
        let patternsURL = self.patternsURL
        DispatchQueue.global(qos: .utility).async {
            let settings = ClaudeSettingsFile.load()
            let reporterOn = Self.hasBaoboxEntry(in: settings, events: ClaudeHookScripts.reporterEvents)
            let guardOn = Self.hasBaoboxEntry(in: settings, events: [ClaudeHookScripts.guardEvent])
            let patterns = Self.readPatterns(url: patternsURL)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isReporterInstalled = reporterOn
                    self.isGuardInstalled = guardOn
                    self.guardPatterns = patterns
                }
            }
        }
    }

    // MARK: - reporter

    func installReporter(completion: @escaping (Bool) -> Void) {
        let url = reporterURL
        DispatchQueue.global(qos: .utility).async {
            let ok = Self.writeScript(ClaudeHookScripts.reporterScript, to: url)
            if ok {
                let command = Self.quotedCommand(url.path)
                try? ClaudeSettingsFile.mutate { settings in
                    for event in ClaudeHookScripts.reporterEvents {
                        Self.appendBaoboxHook(into: &settings, event: event, matcher: nil, command: command)
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshState()
                }
                completion(ok)
            }
        }
    }

    func removeReporter(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var ok = true
            do {
                try ClaudeSettingsFile.mutate { settings in
                    for event in ClaudeHookScripts.reporterEvents {
                        Self.removeBaoboxHooks(from: &settings, event: event)
                    }
                }
            } catch {
                ok = false
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshState()
                }
                completion(ok)
            }
        }
    }

    // MARK: - guard

    func installGuard(completion: @escaping (Bool) -> Void) {
        let url = guardURL
        let patternsURL = self.patternsURL
        DispatchQueue.global(qos: .utility).async {
            let ok = Self.writeScript(ClaudeHookScripts.guardScript, to: url)
            // 规则文件不存在则写默认规则。
            if !FileManager.default.fileExists(atPath: patternsURL.path) {
                Self.writePatterns(ClaudeHookScripts.defaultGuardPatterns, url: patternsURL)
            }
            if ok {
                let command = Self.quotedCommand(url.path)
                try? ClaudeSettingsFile.mutate { settings in
                    Self.appendBaoboxHook(into: &settings, event: ClaudeHookScripts.guardEvent, matcher: "Bash", command: command)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshState()
                }
                completion(ok)
            }
        }
    }

    func removeGuard(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var ok = true
            do {
                try ClaudeSettingsFile.mutate { settings in
                    Self.removeBaoboxHooks(from: &settings, event: ClaudeHookScripts.guardEvent)
                }
            } catch {
                ok = false
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshState()
                }
                completion(ok)
            }
        }
    }

    // MARK: - 卫士规则读写

    /// 从磁盘加载规则并发布。
    func loadGuardPatterns() {
        let url = patternsURL
        DispatchQueue.global(qos: .utility).async {
            let patterns = Self.readPatterns(url: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.guardPatterns = patterns
                }
            }
        }
    }

    /// 覆盖写入规则（去空白空行），并即时更新内存。
    func saveGuardPatterns(_ patterns: [String]) {
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guardPatterns = cleaned
        let url = patternsURL
        DispatchQueue.global(qos: .utility).async {
            Self.writePatterns(cleaned, url: url)
        }
    }

    /// 恢复默认规则。
    func resetGuardPatterns() {
        saveGuardPatterns(ClaudeHookScripts.defaultGuardPatterns)
    }

    // MARK: - 预置规则勾选（启用状态由 pattern 是否在 guardPatterns 反推）

    /// 全部预置规则（内置常量，供 UI 勾选列表）。
    var guardPresets: [ClaudeGuardPreset] { ClaudeHookScripts.guardPresets }

    /// 某预置规则当前是否启用（其 pattern 是否在规则文件中）。
    func isPresetEnabled(_ preset: ClaudeGuardPreset) -> Bool {
        guardPatterns.contains(preset.pattern)
    }

    /// 启用 / 禁用一条预置规则（增删其 pattern 后落盘）。
    func setPreset(_ preset: ClaudeGuardPreset, enabled: Bool) {
        var patterns = guardPatterns
        if enabled {
            guard !patterns.contains(preset.pattern) else { return }
            patterns.append(preset.pattern)
        } else {
            patterns.removeAll { $0 == preset.pattern }
        }
        saveGuardPatterns(patterns)
    }

    /// 自定义规则 = 规则文件中不属于任何预置的条目（「高级」折叠里增删的兜底规则）。
    func customPatterns() -> [String] {
        guardPatterns.filter { !ClaudeHookScripts.presetPatternSet.contains($0) }
    }
}

// MARK: - 脚本落盘 / settings.json 合并（nonisolated static）

extension ClaudeHooksManager {

    /// 写脚本内容并 chmod 755。返回是否成功。
    nonisolated static func writeScript(_ content: String, to url: URL) -> Bool {
        ClaudeEnv.ensureSupportDir()
        guard let data = content.data(using: .utf8) else { return false }
        do {
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// 把脚本路径包成 settings.json 里安全的 command 串（路径含空格，整体加双引号）。
    nonisolated static func quotedCommand(_ path: String) -> String {
        "\"" + path + "\""
    }

    /// 判断某 hook 条目是否属于 Baobox（任一 command 含标志路径）。
    nonisolated static func isBaoboxEntry(_ entry: [String: Any]) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { hook in
            (hook["command"] as? String)?.contains(ClaudeHookScripts.markerFragment) ?? false
        }
    }

    /// 指定事件里是否已存在 Baobox 条目。
    nonisolated static func hasBaoboxEntry(in settings: [String: Any], events: [String]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for event in events {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            if entries.contains(where: { isBaoboxEntry($0) }) { return true }
        }
        return false
    }

    /// 追加一个 Baobox 条目（先移除同事件下旧的 Baobox 条目，保证幂等）。
    nonisolated static func appendBaoboxHook(into settings: inout [String: Any], event: String, matcher: String?, command: String) {
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var entries = (hooks[event] as? [[String: Any]]) ?? []
        entries.removeAll { isBaoboxEntry($0) }
        var entry: [String: Any] = ["hooks": [["type": "command", "command": command]]]
        if let matcher { entry["matcher"] = matcher }
        entries.append(entry)
        hooks[event] = entries
        settings["hooks"] = hooks
    }

    /// 移除某事件下全部 Baobox 条目；数组空则删事件键，hooks 空则删 hooks 键。
    nonisolated static func removeBaoboxHooks(from settings: inout [String: Any], event: String) {
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        guard var entries = hooks[event] as? [[String: Any]] else { return }
        entries.removeAll { isBaoboxEntry($0) }
        if entries.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = entries
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
    }

    // MARK: - 规则文件

    /// 读规则文件为数组（去注释与空行）。
    nonisolated static func readPatterns(url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// 覆盖写规则文件（每行一条）。
    nonisolated static func writePatterns(_ patterns: [String], url: URL) {
        ClaudeEnv.ensureSupportDir()
        let body = patterns.joined(separator: "\n") + "\n"
        try? body.data(using: .utf8)?.write(to: url)
    }
}
