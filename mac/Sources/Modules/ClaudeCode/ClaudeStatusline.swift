import Foundation

/// Claude Code 助手 —— statusline 方案模型、脚本生成、安装 / 移除。
///
/// 段(有序 + 开关)+ 分隔符组成「方案」:内置「简洁 / 标准 / 详细」只读模板,
/// 支持另存多个命名自定义方案(字段勾选、排序、命名、增删)。按当前方案生成纯 sh
/// 脚本(sed 提取 stdin JSON,不依赖 jq),写 `~/.claude/baobox-statusline.sh`
/// (chmod 755),并把 settings.json 的 `statusLine` 指向它。只在 command 为本脚本
/// 路径时才允许移除 / 覆盖(TECH_DESIGN 2.3)。设置页预览用 Swift 侧模拟,不执行脚本。
///
/// stdin JSON 字段以 Claude Code statusline 文档为准(model.display_name、
/// workspace.current_dir、cost.*、context_window.*、effort.level、rate_limits.* 等)。

// MARK: - 段定义

/// statusline 可选段。rawValue 入 UserDefaults,勿改。声明顺序即默认展示顺序。
enum StatuslineSegment: String, Codable, CaseIterable, Identifiable {
    case model
    case dir
    case gitBranch
    case sessionName    // 会话名(自定义或 AI 生成)
    case context        // 上下文占用百分比
    case contextTokens  // 上下文 token 数
    case cost
    case duration       // 会话时长
    case lines          // 代码行 +/-
    case pr             // 当前分支开放 PR 编号
    case effort
    case outputStyle
    case rateLimit5h    // 5 小时窗口用量百分比
    case version
    case time

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .model: return L("claudecode.statusline.seg.model")
        case .dir: return L("claudecode.statusline.seg.dir")
        case .gitBranch: return L("claudecode.statusline.seg.gitBranch")
        case .sessionName: return L("claudecode.statusline.seg.sessionName")
        case .context: return L("claudecode.statusline.seg.context")
        case .contextTokens: return L("claudecode.statusline.seg.contextTokens")
        case .cost: return L("claudecode.statusline.seg.cost")
        case .duration: return L("claudecode.statusline.seg.duration")
        case .lines: return L("claudecode.statusline.seg.lines")
        case .pr: return L("claudecode.statusline.seg.pr")
        case .effort: return L("claudecode.statusline.seg.effort")
        case .outputStyle: return L("claudecode.statusline.seg.outputStyle")
        case .rateLimit5h: return L("claudecode.statusline.seg.rateLimit5h")
        case .version: return L("claudecode.statusline.seg.version")
        case .time: return L("claudecode.statusline.seg.time")
        }
    }

    /// 设置页预览样例值。
    var previewValue: String {
        switch self {
        case .model: return "Fable 5"
        case .dir: return "tools_mac"
        case .gitBranch: return "main"
        case .sessionName: return "date-nudge"
        case .context: return "ctx 36%"
        case .contextTokens: return "72k"
        case .cost: return "$3.42"
        case .duration: return "1h23m"
        case .lines: return "+120/-45"
        case .pr: return "PR#128"
        case .effort: return "xhigh"
        case .outputStyle: return "default"
        case .rateLimit5h: return "5h 42%"
        case .version: return "v2.1.218"
        case .time:
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: Date())
        }
    }
}

// MARK: - 方案模型

/// 一个 statusline 方案:全段有序列表 + 各自开关 + 分隔符。
struct StatuslineScheme: Codable, Identifiable, Equatable {
    struct SegmentConfig: Codable, Equatable {
        var segment: StatuslineSegment
        var enabled: Bool
    }

    var id: UUID
    /// 内置方案存空串(展示名走 L() 随语言切换),自定义方案存用户输入。
    var name: String
    var segments: [SegmentConfig]
    var separator: String

    /// 解码后补齐后续版本新增的段(保持既有顺序,新段默认关闭追加尾部)。
    mutating func fillMissingSegments() {
        let present = Set(segments.map(\.segment))
        for segment in StatuslineSegment.allCases where !present.contains(segment) {
            segments.append(SegmentConfig(segment: segment, enabled: false))
        }
    }
}

// MARK: - 管理单例

@MainActor
final class ClaudeStatuslineManager: ObservableObject {
    static let shared = ClaudeStatuslineManager()

    static let schemesKey = "claudecode.statusline.schemes"
    static let selectedKey = "claudecode.statusline.selected"
    /// 旧版单方案配置键(Bool 开关 + 分隔符),读到即迁移为自定义方案。
    static let legacyConfigKey = "claudecode.statusline.config"

    private static let compactID = UUID(uuidString: "57A70000-0000-0000-0000-000000000001")!
    private static let standardID = UUID(uuidString: "57A70000-0000-0000-0000-000000000002")!
    private static let detailedID = UUID(uuidString: "57A70000-0000-0000-0000-000000000003")!

    static let builtins: [StatuslineScheme] = [
        StatuslineScheme(id: compactID, name: "",
                         segments: configs([.model: true, .dir: true, .gitBranch: true]),
                         separator: " | "),
        StatuslineScheme(id: standardID, name: "",
                         segments: configs([.model: true, .dir: true, .gitBranch: true,
                                            .context: true, .cost: true]),
                         separator: " | "),
        StatuslineScheme(id: detailedID, name: "",
                         segments: configs([.model: true, .dir: true, .gitBranch: true,
                                            .context: true, .contextTokens: true, .cost: true,
                                            .duration: true, .lines: true, .effort: true]),
                         separator: " | "),
    ]

    private static func configs(_ enabled: [StatuslineSegment: Bool]) -> [StatuslineScheme.SegmentConfig] {
        StatuslineSegment.allCases.map { StatuslineScheme.SegmentConfig(segment: $0, enabled: enabled[$0] ?? false) }
    }

    @Published var customSchemes: [StatuslineScheme] {
        didSet { persist() }
    }
    @Published var selectedID: UUID {
        didSet { UserDefaults.standard.set(selectedID.uuidString, forKey: Self.selectedKey) }
    }
    /// settings.json 的 statusLine 是否指向本 Baobox 脚本。
    @Published private(set) var isInstalled = false
    /// 检测到非 Baobox 的 statusLine（应用前需 UI 二次确认覆盖）。
    @Published private(set) var hasForeignStatusline = false

    private init() {
        var loaded: [StatuslineScheme] = []
        if let data = UserDefaults.standard.data(forKey: Self.schemesKey),
           let decoded = try? JSONDecoder().decode([StatuslineScheme].self, from: data) {
            loaded = decoded
            for index in loaded.indices { loaded[index].fillMissingSegments() }
        }
        var selected: UUID?
        if let raw = UserDefaults.standard.string(forKey: Self.selectedKey) {
            selected = UUID(uuidString: raw)
        }

        // 旧版单方案配置迁移:转成自定义方案并选中,然后清掉旧键。
        if loaded.isEmpty, selected == nil,
           let data = UserDefaults.standard.data(forKey: Self.legacyConfigKey),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var scheme = StatuslineScheme(
                id: UUID(),
                name: "\(L("claudecode.rowformat.customDefault")) 1",
                segments: Self.configs([
                    .model: (object["model"] as? Bool) ?? true,
                    .dir: (object["dir"] as? Bool) ?? true,
                    .gitBranch: (object["gitBranch"] as? Bool) ?? true,
                    .cost: (object["cost"] as? Bool) ?? false,
                    .time: (object["time"] as? Bool) ?? false,
                ]),
                separator: (object["separator"] as? String) ?? " | "
            )
            scheme.fillMissingSegments()
            loaded = [scheme]
            selected = scheme.id
            UserDefaults.standard.removeObject(forKey: Self.legacyConfigKey)
        }

        customSchemes = loaded
        selectedID = selected ?? Self.standardID
        if scheme(with: selectedID) == nil {
            selectedID = Self.standardID
        }
        persist()
    }

    /// `~/.claude/baobox-statusline.sh`
    var scriptURL: URL {
        ClaudeEnv.claudeDir.appendingPathComponent("baobox-statusline.sh")
    }

    var allSchemes: [StatuslineScheme] { Self.builtins + customSchemes }

    var activeScheme: StatuslineScheme {
        scheme(with: selectedID) ?? Self.builtins[1]
    }

    func scheme(with id: UUID) -> StatuslineScheme? {
        allSchemes.first { $0.id == id }
    }

    func isBuiltin(_ id: UUID) -> Bool {
        Self.builtins.contains { $0.id == id }
    }

    func displayName(of scheme: StatuslineScheme) -> String {
        switch scheme.id {
        case Self.compactID: return L("claudecode.rowformat.preset.compact")
        case Self.standardID: return L("claudecode.rowformat.preset.standard")
        case Self.detailedID: return L("claudecode.rowformat.preset.detailed")
        default: return scheme.name
        }
    }

    // MARK: 自定义方案 CRUD

    /// 以当前方案为底新建自定义方案并选中。
    @discardableResult
    func addScheme() -> UUID {
        var scheme = activeScheme
        scheme.id = UUID()
        scheme.name = "\(L("claudecode.rowformat.customDefault")) \(customSchemes.count + 1)"
        customSchemes.append(scheme)
        selectedID = scheme.id
        return scheme.id
    }

    func deleteScheme(_ id: UUID) {
        guard !isBuiltin(id) else { return }
        customSchemes.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = Self.standardID
        }
    }

    func updateScheme(_ scheme: StatuslineScheme) {
        guard let index = customSchemes.firstIndex(where: { $0.id == scheme.id }) else { return }
        customSchemes[index] = scheme
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(customSchemes) {
            UserDefaults.standard.set(data, forKey: Self.schemesKey)
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

    /// 按当前方案生成纯 sh 脚本文本。段按方案顺序输出,统一 `${out:+$out$sep}` 拼接。
    func generateScript() -> String {
        let scheme = activeScheme
        let enabled = scheme.segments.filter(\.enabled).map(\.segment)

        var lines: [String] = []
        lines.append("#!/bin/sh")
        lines.append("input=$(cat)")
        // 字符串字段(顶层 "key":"value")。
        lines.append(#"get(){ printf '%s' "$input" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }"#)
        // 数字字段。
        lines.append(#"num(){ printf '%s' "$input" | sed -n "s/.*\"$1\":\([0-9.]*\).*/\1/p" | head -1; }"#)
        // 嵌套对象里的字符串字段("obj":{"key":"value")。
        if enabled.contains(.outputStyle) || enabled.contains(.effort) {
            lines.append(#"obj(){ printf '%s' "$input" | sed -n "s/.*\"$1\":{\"$2\":\"\([^\"]*\)\".*/\1/p" | head -1; }"#)
        }
        lines.append("sep=\"" + escapeForShellDoubleQuotes(scheme.separator) + "\"")
        lines.append("out=\"\"")

        // 前置变量:目录、context_window / five_hour 子串(截取到首个 } 前,
        // used_percentage 等扁平字段都在其中)。
        if enabled.contains(.dir) || enabled.contains(.gitBranch) {
            lines.append("d=$(get current_dir)")
        }
        if enabled.contains(.context) || enabled.contains(.contextTokens) {
            lines.append(#"cw=$(printf '%s' "$input" | sed -n 's/.*"context_window":{\([^}]*\)}.*/\1/p' | head -1)"#)
        }
        if enabled.contains(.rateLimit5h) {
            lines.append(#"fh=$(printf '%s' "$input" | sed -n 's/.*"five_hour":{\([^}]*\)}.*/\1/p' | head -1)"#)
        }

        for segment in enabled {
            lines.append(snippet(for: segment))
        }
        lines.append("printf '%s\\n' \"$out\"")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 单段的 sh 片段。约定:值非空才拼接,统一 `${out:+$out$sep}` 前缀。
    private func snippet(for segment: StatuslineSegment) -> String {
        switch segment {
        case .model:
            return #"m=$(get display_name); [ -n "$m" ] && out="${out:+$out$sep}$m""#
        case .dir:
            return #"[ -n "$d" ] && out="${out:+$out$sep}$(basename "$d")""#
        case .gitBranch:
            return #"b=$(cd "$d" 2>/dev/null && git branch --show-current 2>/dev/null); [ -n "$b" ] && out="${out:+$out$sep}$b""#
        case .sessionName:
            return #"sn=$(get session_name); [ -n "$sn" ] && out="${out:+$out$sep}$sn""#
        case .context:
            return #"p=$(printf '%s' "$cw" | sed -n 's/.*"used_percentage":\([0-9.]*\).*/\1/p'); [ -n "$p" ] && out="${out:+$out$sep}ctx ${p%%.*}%""#
        case .contextTokens:
            return #"t=$(printf '%s' "$cw" | sed -n 's/.*"total_input_tokens":\([0-9]*\).*/\1/p'); [ -n "$t" ] && { [ "$t" -ge 1000 ] && t="$((t/1000))k"; out="${out:+$out$sep}$t"; }"#
        case .cost:
            return #"c=$(num total_cost_usd); [ -n "$c" ] && out="${out:+$out$sep}\$$(printf '%.2f' "$c")""#
        case .duration:
            return #"ms=$(num total_duration_ms); [ -n "$ms" ] && { s=$((${ms%%.*}/1000)); if [ "$s" -ge 3600 ]; then dv="$((s/3600))h$(((s%3600)/60))m"; else dv="$((s/60))m"; fi; out="${out:+$out$sep}$dv"; }"#
        case .lines:
            return #"la=$(num total_lines_added); lr=$(num total_lines_removed); [ -n "$la" ] && out="${out:+$out$sep}+${la%%.*}/-${lr%%.*}""#
        case .pr:
            return #"prn=$(printf '%s' "$input" | sed -n 's/.*"pr":{"number":\([0-9]*\).*/\1/p' | head -1); [ -n "$prn" ] && out="${out:+$out$sep}PR#$prn""#
        case .effort:
            return #"e=$(obj effort level); [ -n "$e" ] && out="${out:+$out$sep}$e""#
        case .outputStyle:
            return #"os=$(obj output_style name); [ -n "$os" ] && out="${out:+$out$sep}$os""#
        case .rateLimit5h:
            return #"rp=$(printf '%s' "$fh" | sed -n 's/.*"used_percentage":\([0-9.]*\).*/\1/p'); [ -n "$rp" ] && out="${out:+$out$sep}5h ${rp%%.*}%""#
        case .version:
            return #"v=$(get version); [ -n "$v" ] && out="${out:+$out$sep}v$v""#
        case .time:
            return #"out="${out:+$out$sep}$(date +%H:%M)""#
        }
    }

    /// 设置页预览:样例值按当前方案拼接(不执行脚本)。
    func previewLine() -> String {
        let scheme = activeScheme
        return scheme.segments.filter(\.enabled)
            .map { $0.segment.previewValue }
            .joined(separator: scheme.separator)
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
