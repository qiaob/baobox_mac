# Claude Code 助手 — 技术方案

> 对应需求见同目录 `REQUIREMENTS.md`。模块 id `claudecode`,名称「Claude Code 助手」,symbol `terminal`。

## 0. 硬约束(实现者必读)

- Swift 5.9 / macOS 14 / 零第三方依赖;所有类型遵循仓库现有并发风格:UI 与状态类标 `@MainActor`,重 IO 用 `Task.detached` 或 `DispatchQueue.global()` 后回主线程。
- 本仓库在 Linux 环境开发、**无法本地编译**,CI 也只在 main 上构建。写法保守:不用新 API(Swift Charts、Observation 等),只用项目里已出现的模式(SwiftUI Form/List/Table、NSMenu、NSWindow + NSHostingController、DispatchSource、Process、URLSession)。
- 文案一律走 `L("claudecode.xxx")` / SwiftUI key 字面量,词条同时给 en 与 zh-Hans,统一加进 `Sources/Resources/Localizable.xcstrings`(JSON,手工合并或写脚本合并均可,保持文件合法)。
- 对用户文件(settings.json 等)读-改-写必须基于 `JSONSerialization`([String: Any]),只动自己的键,写前把原文件复制为 `<name>.baobox.bak`(每次覆盖)。
- 菜单构建在 `menuNeedsUpdate` 同步调用,**不得做磁盘扫描**;只读内存缓存,同时触发后台刷新。

## 1. 文件划分

全部新文件位于 `Sources/Modules/ClaudeCode/`:

| 文件 | 职责 | 大致规模 |
|---|---|---|
| `ClaudeEnv.swift` | 路径常量、claude 二进制探测、settings.json/.claude.json 安全读写、终端启动器 | ~250 行 |
| `ClaudeSessionIndex.swift` | 会话扫描/索引(快扫+全解析)、审计提取、磁盘统计与清理 | ~450 行 |
| `ClaudeUsage.swift` | 定价表、usage 聚合、5 小时窗口计算、报表数据 | ~300 行 |
| `ClaudeLiveStatus.swift` | events.jsonl 监听、会话状态机、系统通知(含额度提醒) | ~300 行 |
| `ClaudeHooks.swift` | Baobox hooks 安装/卸载(事件上报 + 危险命令卫士)、卫士规则管理 | ~300 行 |
| `ClaudeStatusline.swift` | statusline 配置模型、脚本生成、安装/移除 | ~200 行 |
| `ClaudeCodeTool.swift` | ToolModule 壳:菜单、快捷键、activate | ~250 行 |
| `ClaudeCodeSettingsView.swift` | 设置 Tab(内部分节:通知/卫士/Statusline/权限/MCP/CLAUDE.md/维护) | ~600 行 |
| `ClaudeCodeCenterWindow.swift` | 中心窗口(会话浏览 / 用量报表 / 改动审计 三个 Tab)+ 窗口控制器 | ~500 行 |

接入点改动:`Sources/App/AppDelegate.swift` 注册 `ClaudeCodeTool()`(放在 WindowManagerTool 之后);`Localizable.xcstrings` 增词条;`README.md` / `README.zh-CN.md` / `docs/REQUIREMENTS.md`(第 6 节加一行)更新。

## 2. 数据源(事实依据,实现照此解析)

### 2.1 目录布局

```
~/.claude/
  projects/<munged-path>/<session-uuid>.jsonl   # 会话记录;munged-path 为 cwd 中 / 和 . 替换为 -
  settings.json                                  # 用户级配置(permissions/hooks/statusLine/includeCoAuthoredBy/...)
  todos/ shell-snapshots/ ...                    # 其他,仅磁盘统计涉及
~/.claude.json                                   # CLI 状态大文件;顶层 mcpServers 为用户级 MCP 配置
```

`CLAUDE_CONFIG_DIR` 环境变量可改目录,MVP 不支持,固定 `~/.claude`(用 `FileManager.default.homeDirectoryForCurrentUser`,注意 GUI App 非沙箱,取真实家目录)。

### 2.2 会话 JSONL 行格式(逐行 JSON)

关注的行类型与字段(其余忽略,解析必须容错——**任何字段缺失都不能 crash**):

```jsonc
// type=="user":用户输入
{"type":"user","timestamp":"2026-07-23T03:12:45.123Z","sessionId":"<uuid>","cwd":"/Users/x/proj","gitBranch":"main",
 "message":{"role":"user","content":"文本或[{type:text,...}]数组"}}
// type=="assistant":模型回复,usage 是用量与费用之源;tool_use 是审计之源
{"type":"assistant","timestamp":"...","sessionId":"...","cwd":"...","requestId":"req_...",
 "message":{"id":"msg_...","model":"claude-opus-4-...","usage":{"input_tokens":5,"output_tokens":100,
   "cache_creation_input_tokens":200,"cache_read_input_tokens":3000},
  "content":[{"type":"text","text":"..."},
             {"type":"tool_use","name":"Edit","input":{"file_path":"/abs/path.swift", ...}}]}}
// type=="summary":会话标题(在续接产生的文件顶部)
{"type":"summary","summary":"Fix hotkey conflict"}
```

- 时间戳:ISO8601 带毫秒。用 `ISO8601DateFormatter`,`formatOptions` 先试 `[.withInternetDateTime,.withFractionalSeconds]`,失败退 `[.withInternetDateTime]`。两个 formatter 建成静态常量复用。
- 会话标题:优先 summary 行,否则第一条 user 行的文本前 60 字(content 为数组时取第一个 text 块;以 `<` 开头的系统注入如 `<command-name>` 跳过,继续找下一条)。
- cwd:取文件中最后一次出现的 cwd(续接后目录可能变)。
- **用量去重**:同一条 assistant 消息在续接/分叉的多个文件里会重复。聚合时用 `message.id + requestId` 组成 key 的 Set 去重;两者都缺的行不去重直接计入。
- 审计:遍历 assistant 行 content 里 `type=="tool_use"` 且 `name ∈ {Edit, Write, MultiEdit, NotebookEdit}` 的块,取 `input.file_path`(NotebookEdit 为 `input.notebook_path`)。

### 2.3 settings.json 中本模块会写的键

```jsonc
{"includeCoAuthoredBy": false,
 "statusLine": {"type":"command","command":"/Users/x/.claude/baobox-statusline.sh"},
 "permissions": {"allow":["Bash(npm run *)"],"deny":[]},
 "hooks": {
   "Stop":             [{"hooks":[{"type":"command","command":"<reporter>"}]}],
   "Notification":     [{"hooks":[{"type":"command","command":"<reporter>"}]}],
   "SessionStart":     [{"hooks":[{"type":"command","command":"<reporter>"}]}],
   "UserPromptSubmit": [{"hooks":[{"type":"command","command":"<reporter>"}]}],
   "PreToolUse":       [{"matcher":"Bash","hooks":[{"type":"command","command":"<guard>"}]}]}}
```

hooks 合并规则:每个事件键的值是数组;安装时**追加** Baobox 条目(识别标志:command 路径包含 `/Baobox/ClaudeCode/`),卸载时只移除含该标志的条目,其余原样保留;数组变空则删除该事件键,`hooks` 变空字典则删除 `hooks` 键。statusLine 同理:只在 command 为 Baobox 脚本路径时才允许移除/覆盖,发现用户自己的 statusLine 时 UI 要先确认再覆盖。

### 2.4 hook 协议(Claude Code → 脚本)

- 事件 JSON 经 **stdin** 传入,单行;含 `session_id`,`cwd`,`hook_event_name`;Notification 事件另有 `message`;PreToolUse 另有 `tool_name`,`tool_input`(对 Bash 即 `{"command":"...","description":"..."}`)。
- PreToolUse 拦截:**exit code 2**,stderr 内容会反馈给 Claude。exit 0 放行。
- 脚本必须秒回,不得阻塞 Claude Code。

### 2.5 statusline 协议

settings.json `statusLine.command` 指向可执行脚本;每次刷新 Claude Code 把上下文 JSON 写入 stdin,脚本 stdout 第一行成为状态栏内容。可用字段(保守子集):`model.display_name`、`workspace.current_dir`、`cost.total_cost_usd`。

## 3. 各组件设计

### 3.1 ClaudeEnv

```swift
@MainActor enum ClaudeEnv {
    static var claudeDir: URL            // ~/.claude
    static var projectsDir: URL
    static var settingsFile: URL         // ~/.claude/settings.json
    static var cliStateFile: URL         // ~/.claude.json
    static var supportDir: URL           // ~/Library/Application Support/Baobox/ClaudeCode/
    static var isInstalled: Bool         // claudeDir 存在
    static func findClaudeBinary() -> String?   // 依次探测,结果缓存
    static func cliVersion() -> String?         // 运行 `claude --version`(后台线程调用方负责)
}
```

- 二进制探测顺序:`~/.claude/local/claude`、`/opt/homebrew/bin/claude`、`/usr/local/bin/claude`、`~/.local/bin/claude`、`/usr/bin/claude`;都不在则回退字符串 `"claude"`(终端里 PATH 通常有)。
- `ClaudeSettingsFile`:`load() -> [String: Any]`、`mutate(_ transform: (inout [String: Any]) -> Void) throws`。mutate 内:读原文(不存在则 `[:]`)→ 备份 `settings.json.baobox.bak` → 变换 → `JSONSerialization` 写回(`[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]`)。`.claude.json` 用同一套工具函数(独立备份名)。**该文件可能几 MB,读写放后台线程,完成回主线程刷 UI。**
- `TerminalLauncher.run(command:in:)`:把 `#!/bin/zsh\ncd '<dir>'\n<command>\n` 写入 `supportDir/launch/<uuid>.command`,`chmod 755`,`NSWorkspace.shared.open`(.command 默认由终端接管);目录里超过 20 个旧文件时顺手清理。cwd 与 sessionId 拼进命令前用单引号包裹并转义内部单引号。

### 3.2 ClaudeSessionIndex(ObservableObject,单例 shared)

```swift
struct ClaudeSessionSummary: Identifiable {
    let id: String            // 文件名里的 uuid
    let fileURL: URL
    let projectPath: String   // cwd
    var projectName: String   // cwd 末段
    let title: String
    let lastActivity: Date
    let fileSize: Int64
}
@Published private(set) var sessions: [ClaudeSessionSummary]   // 新→旧
func refresh()                     // 后台快扫全部 jsonl → 回主线程发布;去抖,进行中不重入
func recentSessions(limit: Int) -> [ClaudeSessionSummary]
func auditEntries(on day: Date, completion: @escaping ([ClaudeAuditProject]) -> Void)
func diskStats(completion:)/cleanup(olderThanDays:completion:)
```

- **快扫**:每文件只读头 64KB + 尾 8KB(`FileHandle.seekToEnd` 再回读),从头块取 summary/首条 user/cwd,从尾块最后一个可解析行取时间戳(解析失败退 mtime)。头块取不到 cwd 时从目录名反推展示名(仅展示用,resume 仍可用)。
- 快扫结果缓存在内存 + `supportDir/index-cache.json`(键:路径,值:mtime/size/标题/cwd),mtime+size 未变的文件跳过重扫。App 启动 `activate()` 与中心窗口打开时各触发一次 refresh。
- 审计/清理为全量操作,后台线程逐文件逐行流式处理(整读 Data 后按 `\n` split 可接受,单文件解析完立即释放)。
- 删除会话 = 删对应 jsonl 文件(NSAlert 确认)。

### 3.3 ClaudeUsage

```swift
struct ModelPricing { let inputPerM, outputPerM, cacheWritePerM, cacheReadPerM: Double }
// 匹配规则:model id 含 "opus"→(15,75,18.75,1.5);"sonnet"→(3,15,3.75,0.3);"haiku"→(1,5,1.25,0.1);未知→全 0 并标记 unpriced
struct UsageTotals { var input, output, cacheWrite, cacheRead: Int; var costUSD: Double; var unpriced: Bool }
struct UsageWindow { let start: Date; let end: Date; var totals: UsageTotals }   // end = start + 5h
final class ClaudeUsageStore: ObservableObject {  // @MainActor 单例
    @Published var currentWindow: UsageWindow?    // nil = 无活跃窗口
    @Published var todayTotals: UsageTotals?
    func refresh()                                // 后台解析近 24h 内 mtime 的文件
    func report(days: Int, completion: @escaping (ClaudeUsageReport) -> Void)  // 按天/项目/模型三组
}
```

- 5h 窗口算法(对齐 ccusage):把(去重后)带 usage 的条目按时间升序,`blockStart` 初始为首条时间戳向下取整到小时;条目时间 > blockStart+5h 时开新块(该条时间取整到小时)。`now <= blockStart+5h` 则末块为活跃窗口。
- 额度提醒挂在 refresh 末尾:预算(UserDefaults,0=未设)>0 且 window tokens ≥ 80% 预算 → 经 ClaudeNotifier 通知一次(记录已提醒的 windowStart 防重);检测到窗口切换且旧窗口曾提醒 → 可选发"额度已恢复"。
- refresh 触发:activate 后首次 + Timer 每 5 分钟 + 收到 hook 事件时(节流 ≥60s)。

### 3.4 ClaudeLiveStatus(@MainActor 单例)

- 事件文件:`supportDir/events.jsonl`(reporter 脚本追加,见 3.5)。activate 时确保存在,>5MB 截断保尾 1000 行;`DispatchSourceFileSystemObject`(.write/.extend)监听,维护读取偏移,增量读新行。
- 状态机:`session_id → (state, cwd, lastEvent: Date)`;SessionStart/UserPromptSubmit→`.running`;Notification→`.waiting(message)`;Stop→`.idle`;SessionEnd 或 6h 无事件→移除。
- `summaryLine() -> String?`:如"2 运行中 · 1 等待确认";无 hooks 降级:`ClaudeSessionIndex` 中 lastActivity 距今 <2min 的文件数 → "N 个会话活跃(推断)"。
- `ClaudeNotifier`:封装 `UNUserNotificationCenter`(首次开启通知开关时 `requestAuthorization(options:[.alert,.sound])`);Stop→"会话完成 · <项目名>",Notification→"等你确认 · <项目名>"(正文带 message);受 UserDefaults 开关与提示音开关控制。**注意** UN 通知在未签名 dev 包可用,但要判空失败不 crash。

### 3.5 ClaudeHooks

- reporter 脚本 `supportDir/report-event.sh`(安装时生成,内容固定):

```sh
#!/bin/sh
d="$HOME/Library/Application Support/Baobox/ClaudeCode"
mkdir -p "$d"
cat >> "$d/events.jsonl"
printf "\n" >> "$d/events.jsonl"
exit 0
```

- guard 脚本 `supportDir/guard.sh`:stdin 存入变量,对规则文件 `guard-patterns.txt`(每行一个 ERE,`#` 注释)逐行 `printf '%s' "$input" | grep -qE -- "$p"`,命中则 `echo "Baobox 卫士已拦截:命令匹配规则 [$p]。如确需执行,请让用户在 Baobox 设置中调整规则。" >&2; exit 2`。注意 tool_input JSON 里命令是转义过的字符串,正则直接匹配整行 JSON 即可(规则写法上文档提示用户)。预置规则:`rm -rf /`、`rm -rf ~`、`sudo rm`、`git push[^\n]*--force`、`git reset --hard`、`git clean -fd`、`DROP TABLE`、`mkfs`、`chmod -R 777`。
- `ClaudeHooksManager`(@MainActor):`isReporterInstalled/isGuardInstalled`(读 settings.json 判定)、`installReporter()/removeReporter()/installGuard()/removeGuard()`、规则数组读写(重写 patterns.txt)。安装 = 生成脚本(chmod 755)+ 按 2.3 合并进 settings.json。脚本路径含空格(`Application Support`),写入 settings.json 的 command 需整体加双引号:`"\"/Users/x/Library/Application Support/Baobox/ClaudeCode/report-event.sh\""`。

### 3.6 ClaudeStatusline

- 配置模型:`struct StatuslineConfig: Codable { var model, dir, gitBranch, cost, time: Bool; var separator: String }`(UserDefaults 存 JSON;默认 model+dir+gitBranch 开,separator `" | "`)。
- 生成脚本(纯 sh,sed 提取,不依赖 jq),写 `~/.claude/baobox-statusline.sh` + chmod 755,settings.json 写入 `statusLine`。示例骨架:

```sh
#!/bin/sh
input=$(cat)
get(){ printf '%s' "$input" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }
out=""
sep=" | "
m=$(get display_name); [ -n "$m" ] && out="$m"
d=$(get current_dir); [ -n "$d" ] && out="${out:+$out$sep}$(basename "$d")"
b=$(cd "$d" 2>/dev/null && git branch --show-current 2>/dev/null); [ -n "$b" ] && out="${out:+$out$sep}$b"
c=$(printf '%s' "$input" | sed -n 's/.*"total_cost_usd":\([0-9.]*\).*/\1/p' | head -1); [ -n "$c" ] && out="${out:+$out$sep}\$$(printf '%.2f' "$c")"
[ "$TIME_ON" ] && out="${out:+$out$sep}$(date +%H:%M)"   # 生成时按配置内联,不用环境变量
printf '%s\n' "$out"
```

  (生成器按开关拼接对应片段;cost 用数字提取的独立 sed。)
- 设置页内嵌预览:用假数据跑一遍同逻辑(Swift 侧模拟输出,不执行脚本)。

### 3.7 菜单结构(ClaudeCodeTool.submenuItems,顺序=常用度)

```
[状态行,置灰] 2 运行中 · 1 等待 · 今日 $3.42        ← LiveStatus + UsageStore,纯内存
──────
最近会话(≤5 条,ClosureMenuItem,图标 clock.arrow.circlepath)
  <proj> — <标题前 30 字>        点击 → TerminalLauncher resume
浏览会话历史…                     → 中心窗口 tab .sessions(hotkeyID claudecode.center)
──────
[置灰] 额度窗口:已用 123.4k tok ≈ $2.1 · 2h15m 后重置   ← 或"当前无活跃额度窗口"
用量报表…                         → 中心窗口 tab .usage
今日改动…                         → 中心窗口 tab .audit
──────
完成/等待通知(state 勾选,点击切换开关;未装 hooks 时先触发安装)
```

- 未安装 Claude Code(`!ClaudeEnv.isInstalled`):只显示一条置灰"未检测到 Claude Code(~/.claude 不存在)"+ 设置入口。
- 快捷键:`claudecode.center`,标题「打开 Claude Code 中心」,`defaultCombo: nil`(出厂不绑定,同取色器惯例)。
- `activate()`:LiveStatus.start、SessionIndex.refresh、UsageStore 定时器;`willTerminate()`:落盘索引缓存。

### 3.8 中心窗口(ClaudeCodeCenterWindow)

- `ClaudeCodeCenterController`(单例,仿 SettingsWindowController:NSWindow + NSHostingController,isReleasedWhenClosed=false,show(tab:))。尺寸 720×480,titled/closable/resizable。
- SwiftUI 根视图:`TabView`(或顶部 segmented Picker)三页:
  - **会话**:搜索框(标题/项目名包含匹配)+ List(标题、项目、相对时间、大小);行按钮:续接(终端图标)、复制 resume 命令、导出 Markdown(NSSavePanel;导出=逐行解析该 jsonl,user/assistant 文本块拼 `## User / ## Assistant`)、删除。
  - **用量**:顶部窗口卡片(进度条对预算,无预算则只显示量)+ 三个小节表(按天 30 行/按项目/按模型):列 = 名称、输入、输出、缓存写、缓存读、估算费用;费用列头标"估算"。刷新按钮。
  - **审计**:DatePicker(默认今天)+ 按项目分组的 List(文件路径、次数、末次时间;点击 → `NSWorkspace.shared.activateFileViewerSelecting`)。加载中转圈,后台计算。

### 3.9 设置 Tab(ClaudeCodeSettingsView)

顶部状态卡(claude 版本 / hooks 状态 / 会话总数)+ segmented Picker 分节。
「编辑 Claude Code 配置」类的功能(权限/卫士/Co-Authored-By/CLAUDE.md)**合并为一个「配置」节**,
用 DisclosureGroup 折叠分组呈现,一屏总览所有已做的定制;Statusline(带预览的生成器)与
MCP(列表+表单)交互形态不同,保持独立节。共 5 节:

1. **通知**:总开关、提示音开关、额度预算(TextField,k tokens)、80% 提醒开关、恢复提醒开关。
2. **配置**(DisclosureGroup ×4,默认展开第一个):
   - *权限规则*:allow/deny 两个可编辑列表 + 预设菜单(前端 npm/pnpm/yarn/eslint、Python pip/pytest、Git 常用只读)。
   - *危险命令卫士*:开关(装/卸 hook)、规则列表(增删,TextField 校验非空)、恢复默认规则按钮。
   - *提交署名*:Co-Authored-By Toggle(直写 settings.json),说明文字注明仅影响以后提交、不改写历史。
   - *CLAUDE.md*:全局行 + 项目行列表(存在→打开,缺失→从模板创建);模板内容内置常量(简短的项目说明骨架)。
3. **Statusline**:5 个段开关 + 分隔符输入 + 预览行 + 「应用到 Claude Code」/「移除」按钮;检测到非 Baobox statusLine 时黄条提示将覆盖。
4. **MCP**:用户级服务器 List(名称/type/命令或 URL)+ 删除;添加 sheet:name、type(stdio/http)、command+args 或 url、env(k=v 每行一条)。
5. **维护**:磁盘统计 + 清理(Picker 30/60/90 天 + 按钮)、版本行 + 检查按钮(URLSession GET `https://registry.npmjs.org/@anthropic-ai/claude-code/latest` 取 `version` 字段,10s 超时)+「复制升级命令」(`npm install -g @anthropic-ai/claude-code`)。

## 4. 本地化

命名空间 `claudecode.*`,约 90 词条(菜单/窗口/设置/通知/确认弹窗)。合并进 xcstrings 时保持既有紧凑单行风格。带参数示例:`claudecode.menu.summary %lld %lld`。UI 里数字/费用格式化用 `String(format:)`,费用统一 `$%.2f`,token 数 ≥1000 显示 `%.1fk`。

## 5. 风险与取舍(已决策)

- JSONL 字段属非公开实现,版本升级可能变动 → 全部解析容错,取不到即降级显示,决不 crash。
- 费用为估算(定价表内置常量),UI 处处标"估算"。
- 无法本地编译 → 实现者自查:每个 L() key 均已入 catalog(可写脚本比对);所有 @Published 只在主线程写;Process/URLSession 不在主线程同步等待。
- 危险命令卫士为正则黑名单,防手滑不防绕过,设置页文案明示。
