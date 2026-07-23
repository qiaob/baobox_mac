import Foundation

/// Claude Code 助手 —— statusline 配置模型、脚本生成、安装 / 移除。
///
/// 勾选段（模型 / 目录 / git 分支 / 会话花费 / 时间）+ 分隔符 → 生成纯 sh 脚本（sed 提取，
/// 不依赖 jq），写 `~/.claude/baobox-statusline.sh`(chmod 755)，并把 settings.json 的
/// `statusLine` 指向它。只在 command 为本脚本路径时才允许移除 / 覆盖（TECH_DESIGN 2.3）。
/// 设置页预览用 Swift 侧模拟同逻辑，不执行脚本。
///
/// 本文件不含 L() 文案（配置项标题由 UI 层提供）。

// MARK: - 配置模型

/// statusline 段开关与分隔符。UserDefaults 存 JSON。
struct StatuslineConfig: Codable, Equatable {
    var model: Bool
    var dir: Bool
    var gitBranch: Bool
    var cost: Bool
    var time: Bool
    var separator: String

    static let `default` = StatuslineConfig(
        model: true, dir: true, gitBranch: true, cost: false, time: false, separator: " | "
    )
}

// MARK: - 管理单例

@MainActor
final class ClaudeStatuslineManager: ObservableObject {
    static let shared = ClaudeStatuslineManager()

    @Published var config: StatuslineConfig
    /// settings.json 的 statusLine 是否指向本 Baobox 脚本。
    @Published private(set) var isInstalled = false
    /// 检测到非 Baobox 的 statusLine（应用前需 UI 二次确认覆盖）。
    @Published private(set) var hasForeignStatusline = false

    static let configKey = "claudecode.statusline.config"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(StatuslineConfig.self, from: data) {
            config = decoded
        } else {
            config = .default
        }
    }

    /// `~/.claude/baobox-statusline.sh`
    var scriptURL: URL {
        ClaudeEnv.claudeDir.appendingPathComponent("baobox-statusline.sh")
    }

    // MARK: - 配置持久化

    func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    // MARK: - 状态刷新

    /// 后台读 settings.json 判断安装状态与是否存在外部 statusLine。
    func refreshState() {
        let scriptPath = scriptURL.path
        DispatchQueue.global(qos: .utility).async {
            let settings = ClaudeSettingsFile.load()
            var installed = false
            var foreign = false
            if let statusLine = settings["statusLine"] as? [String: Any],
               let command = statusLine["command"] as? String {
                if command == scriptPath || command.contains("baobox-statusline.sh") {
                    installed = true
                } else {
                    foreign = true
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isInstalled = installed
                    self.hasForeignStatusline = foreign
                }
            }
        }
    }

    // MARK: - 应用 / 移除

    /// 生成脚本 + 写 settings.json.statusLine。回调是否成功。
    func apply(completion: @escaping (Bool) -> Void) {
        saveConfig()
        let scriptText = generateScript()
        let url = scriptURL
        let path = url.path
        DispatchQueue.global(qos: .utility).async {
            var ok = true
            // 确保 ~/.claude 存在（未装 Claude Code 时理论不该走到这里，但仍容错）。
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try scriptText.data(using: .utf8)?.write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            } catch {
                ok = false
            }
            if ok {
                try? ClaudeSettingsFile.mutate { settings in
                    settings["statusLine"] = ["type": "command", "command": path]
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

    /// 移除：仅当 statusLine 指向本脚本时删除该键，并删脚本文件。回调是否成功。
    func remove(completion: @escaping (Bool) -> Void) {
        let path = scriptURL.path
        let url = scriptURL
        DispatchQueue.global(qos: .utility).async {
            var ok = true
            do {
                try ClaudeSettingsFile.mutate { settings in
                    if let statusLine = settings["statusLine"] as? [String: Any],
                       let command = statusLine["command"] as? String,
                       command == path || command.contains("baobox-statusline.sh") {
                        settings.removeValue(forKey: "statusLine")
                    }
                }
            } catch {
                ok = false
            }
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshState()
                }
                completion(ok)
            }
        }
    }

    // MARK: - 脚本生成 / 预览

    /// 按当前配置生成纯 sh 脚本文本。
    func generateScript() -> String {
        // sed 提取字符串字段的辅助函数（原样保留反斜杠，用 raw string 避免二次转义）。
        let getFunction = #"get(){ printf '%s' "$input" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }"#
        // cost 段：数字提取的独立 sed，前缀 $ 用 \$ 表示字面美元。
        let costLine = #"c=$(printf '%s' "$input" | sed -n 's/.*"total_cost_usd":\([0-9.]*\).*/\1/p' | head -1); [ -n "$c" ] && out="${out:+$out$sep}\$$(printf '%.2f' "$c")""#

        var lines: [String] = []
        lines.append("#!/bin/sh")
        lines.append("input=$(cat)")
        lines.append(getFunction)
        lines.append("sep=\"" + escapeForShellDoubleQuotes(config.separator) + "\"")
        lines.append("out=\"\"")

        if config.model {
            lines.append("m=$(get display_name); [ -n \"$m\" ] && out=\"$m\"")
        }
        // git 分支需要目录变量 d，故 dir 或 gitBranch 任一开启就取 d。
        if config.dir || config.gitBranch {
            lines.append("d=$(get current_dir)")
        }
        if config.dir {
            lines.append("[ -n \"$d\" ] && out=\"${out:+$out$sep}$(basename \"$d\")\"")
        }
        if config.gitBranch {
            lines.append("b=$(cd \"$d\" 2>/dev/null && git branch --show-current 2>/dev/null); [ -n \"$b\" ] && out=\"${out:+$out$sep}$b\"")
        }
        if config.cost {
            lines.append(costLine)
        }
        if config.time {
            lines.append("out=\"${out:+$out$sep}$(date +%H:%M)\"")
        }
        lines.append("printf '%s\\n' \"$out\"")

        return lines.joined(separator: "\n") + "\n"
    }

    /// 设置页预览：用假数据在 Swift 侧模拟同逻辑（不执行脚本）。
    func previewLine() -> String {
        var parts: [String] = []
        if config.model { parts.append("Claude Opus 4") }
        if config.dir { parts.append("myproject") }
        if config.gitBranch { parts.append("main") }
        if config.cost { parts.append("$3.42") }
        if config.time {
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.dateFormat = "HH:mm"
            parts.append(formatter.string(from: Date()))
        }
        return parts.joined(separator: config.separator)
    }

    /// 转义分隔符，使其能安全嵌入 sh 双引号内。
    private func escapeForShellDoubleQuotes(_ string: String) -> String {
        var result = ""
        for char in string {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "$": result += "\\$"
            case "`": result += "\\`"
            default: result.append(char)
            }
        }
        return result
    }
}
