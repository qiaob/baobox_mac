# Claude Code 助手 —— 核心数据层 API 清单

给 UI 实现代理的交接文档。本目录 6 个 Swift 文件已实现「Claude Code 助手」模块的**数据层**，
不含任何 UI。UI 层只调用这里暴露的类型与方法，**不要**自己碰 `~/.claude` 下的文件。

约束回顾：Swift 5.9 / macOS 14 / 零依赖。所有 `@Published` 只在主线程写；重 IO 已在内部走后台，
完成回调都在主线程触发。解析全程容错，无 force unwrap / try! / fatalError。

---

## 1. ClaudeEnv.swift —— 环境与文件底座

### `enum ClaudeEnv`（非 @MainActor，路径/IO 可后台调用）
| 成员 | 说明 |
|---|---|
| `static var homeDir/claudeDir/projectsDir/settingsFile/cliStateFile/supportDir: URL` | 路径常量。`supportDir` = `~/Library/Application Support/Baobox/ClaudeCode/` |
| `static var isInstalled: Bool` | `~/.claude` 是否存在 |
| `static func ensureSupportDir() -> URL` | 幂等创建支持目录 |
| `static func findClaudeBinary() -> String?` | 探测 claude 二进制（缓存），回退 `"claude"` |
| `static func cliVersion() -> String?` | 运行 `claude --version`（**必须后台调用**） |
| `static func mcpServers() -> [(name: String, config: [String: Any])]` | 读 `.claude.json` 顶层 mcpServers（后台） |
| `static func setMCPServer(name:config:) throws` / `removeMCPServer(name:) throws` | 增改 / 删 MCP 条目（后台） |
| `enum PermissionKind { case allow, deny }` | 权限种类 |
| `static func permissionRules(_:) -> [String]` | 读 settings.json permissions.allow/deny（后台） |
| `static func setPermissionRules(_:kind:) throws` / `addPermissionRule(_:kind:) throws` / `removePermissionRule(_:kind:) throws` | 权限增删改（后台） |
| `static func includeCoAuthoredBy() -> Bool` / `setIncludeCoAuthoredBy(_:) throws` | Co-Authored-By 读/写（后台） |
| `static func defaultMode() -> String?` / `setDefaultMode(_:) throws` / `removeDefaultMode() throws` | permissions.defaultMode 读/写/移除（移除后 permissions 空则删键） |
| `static func model() -> String?` / `setModel(_:) throws` / `removeModel() throws` | 顶层 model 读/写/移除 |
| `static func cleanupPeriodDays() -> Int?` / `setCleanupPeriodDays(_:) throws` / `removeCleanupPeriodDays() throws` | cleanupPeriodDays 读(容错取整)/写/移除 |
| `static func envValue(_ key:) -> String?` / `setEnvFlag(_ key:) throws` / `removeEnvKey(_ key:) throws` | env 字典单键读 / 设为 "1" / 移除；只动指定键，env 空则删 env 键 |

> 单引号 shell 转义 2026-11（#164）起用 Core 的 `Shell.quote`（`mac/Sources/Core/Shell.swift`，`BaoboxTests` 有单元测试），原 `shellSingleQuote` 已删。

> 以上标量键接口供「配置」节可视化控件（Picker 单选 / 隐私多选勾选）使用，全部走 `ClaudeSettingsFile`、只动自己的键、后台调用。

### `enum ClaudeJSONFile` / `enum ClaudeSettingsFile`
- `ClaudeJSONFile.load(_ url:) -> [String: Any]` / `write(_:to:) throws` / `mutate(_ url:_ transform:) throws` —— 通用 JSON 读-改-写，写前备份 `<name>.baobox.bak`，只动自己的键。
- `ClaudeSettingsFile.load() -> [String: Any]` / `mutate(_ transform:) throws` —— 绑定 `settings.json` 的便捷入口。
- 均为**后台调用**（文件可能几 MB）。

### `@MainActor enum ClaudeTerminal`（`ClaudeTerminal.swift`，主线程调用）

2026-11（#164）起，原 `TerminalLauncher` 拆成两半（`docs/codex-assistant/DEDUPE-P2.md` §2.4 类 5）：通用的「在偏好终端里跑一条命令」
`TerminalLauncher.run(command:in:)` 与「按 tty 选中 iTerm2 / 系统终端的标签页」`TerminalLauncher.selectTab(bundleID:ttyPath:)` 搬进
`mac/Sources/Core/Terminal/`（名字与签名不变，Codex 助手也调；一次性脚本写到 `~/Library/Application Support/Baobox/Terminal/launch/`，只留最近 20 个，
脚本内容与清理在 `TerminalLaunchScript`，`BaoboxTests` 有单元测试）；认得 `claude` 的部分留在本模块，改名 `ClaudeTerminal`：
- `resume(sessionID:in:binary:)` —— 续接会话 `claude --resume <id>`（经 `TerminalLauncher.run`）。
- `resumeCommandString(sessionID:in:)` —— 可直接粘贴执行的续接命令（含 cd）。
- `focusRunningSession(sessionID:projectPath:location:confirmRunning:isNewestInProject:completion:)` —— 把正在跑的会话所在的终端切到前台：
  先用 hook 记下的位置（`confirmRunning` 时先在后台确认那个 tty 上有 claude 在跑），再按进程找；`completion(false)` = 都不行，调用方兜底。
  点通知跳回（位置直接用）与快速切换面板续接（位置要确认，false 时开新窗口）共用，见 `docs/claude-code-assistant/NOTIFY_JUMP.md` §3。
  按进程找（`findRunningSession`，ps / lsof 经 `Shell.output`）与切窗口（`focusTerminalWindow`，选标签页经 `TerminalLauncher.selectTab`）只在它里面用，都是 private。
- 旧脚本目录 `Baobox/ClaudeCode/launch/` 由 `ClaudeCodeTool.activate()` 每次启动在后台删一次（随 0.0.9 发出，0.0.11 起去掉）。
- `enum ClaudeRunningSession`（`ClaudeRunningSession.swift`，纯 Foundation，`BaoboxTests` 有单元测试）—— 上面「位置要确认」的两关：
  会话还占着那个 tty（`ownsTerminal`）、那个 tty 上有 claude 进程（`claudeRuns(onTTY:processes:)`），以及 `isClaudeCommand`。

---

## 2. ClaudeSessionIndex.swift —— 会话索引 / 审计 / 磁盘

> 2026-11（#109）起，刷新、复用、排序、删除、导出外壳、磁盘缓存与清理旧会话在与 Codex 助手共用的
> `mac/Sources/Core/CLISession/`（`CLISessionIndex<Format>` 基类，`BaoboxTests` 有单元测试，见 `docs/codex-assistant/DEDUPE.md` §4.1）。
> 本文件只留 Claude Code 的格式 `ClaudeSessionFormat` 与独有的审计、磁盘分布；下表的成员名与签名不变，UI 照旧这样调。

### 解析工具
- 逐行解析与时间戳：共用的 `CLIJSONL.parseDate(_:) -> Date?`、`CLIJSONL.parseObject(_ data:) -> [String:Any]?`（Usage / FileIndex / LiveStatus 也用它）；
  整份逐行的 `CLIJSONL.forEachObject(in:_:)`（按字节切行，坏行只丢那一行；两边的导出用）。
- `enum ClaudeJSONLParsing` 只剩 Claude 独有的 `extractText(fromContent:) -> String?`（在 `ClaudeSessionMarkdown.swift`：纯逻辑，编进 `BaoboxTests`）。
- `enum ClaudeSessionMarkdown` —— `markdown(from: Data, title:, headings: CLISessionMarkdown.Headings) -> String`：导出 Markdown 的拼法（逐行读、跳过用户消息里的系统注入，DEDUPE.md §5.1 B2）；小标题文案由 `ClaudeSessionFormat.markdown` 用 `L("claudecode.export.user" / "claudecode.export.assistant")` 取好传进来。

### 数据模型
- `struct ClaudeSessionSummary: Identifiable, Equatable, CLISessionSummary` —— `id, fileURL, projectPath, projectName, title, lastActivity, fileSize, model?, contextTokens?`
- `struct ClaudeSessionRecord: CLISessionRecord` —— `index-cache-v2.json` 的一条记录（原 `ClaudeSessionIndex.CacheRecord`，字段名即缓存文件里的键，别改）
- `enum ClaudeSessionFormat: CLISessionFormat` —— 会话文件在哪（`projects/<项目>/*.jsonl`）、怎么快扫（头 64K + 尾 8K）、怎么导出、缓存放哪
- `struct ClaudeAuditEntry: Identifiable` —— `id(=filePath), filePath, count, lastEdited`
- `struct ClaudeAuditProject: Identifiable` —— `id(=projectPath), projectPath, projectName, entries, totalCount`
- `struct ClaudeDiskStats` —— `projectsBytes, todosBytes, shellSnapshotsBytes, otherBytes, totalBytes, sessionFileCount`

### `@MainActor final class ClaudeSessionIndex: CLISessionIndex<ClaudeSessionFormat>`（`.shared`）
| 成员 | 说明 |
|---|---|
| `@Published private(set) var sessions: [ClaudeSessionSummary]` | 新→旧（基类） |
| `@Published private(set) var isRefreshing: Bool` | 刷新中（基类） |
| `func refresh()` | 后台快扫（头64K+尾8K）+ 缓存复用，回主线程发布；进行中不重入，再请求合并成结束后补扫一轮（基类） |
| `func auditEntries(on day:completion: @escaping ([ClaudeAuditProject]) -> Void)` | 某日改动审计 |
| `func diskStats(completion: @escaping (ClaudeDiskStats) -> Void)` | 磁盘占用 |
| `func cleanup(olderThanDays:completion: @escaping (Int, Int64) -> Void)` | 清理旧会话，回调 (删除数, 释放字节)，随后自动 refresh（基类） |
| `func deleteSession(_:completion: @escaping (Bool) -> Void)` | 删单个会话文件（基类） |
| `func exportMarkdown(_:completion: @escaping (String?) -> Void)` | 导出 Markdown 文本（UI 负责 NSSavePanel；基类调格式的 `markdown`） |
| `func flushCache()` | willTerminate 同步落盘索引缓存，返回时已写好（基类） |

> 静态工具 `ClaudeSessionIndex.projectName(fromPath:)`（继承自基类，转给 `CLISessionPaths`）/ `demungeDirName(_:)` / `editToolNames` 供其他文件复用。
> 原来的 `recentSessions(limit:)` 没有调用方，已删。

---

## 3. ClaudeUsage.swift —— 定价 / 用量 / 额度窗口 / 报表

- `struct ModelPricing` + `static func pricing(for modelID:) -> (pricing, unpriced)` —— opus/sonnet/haiku 关键字匹配，未知全 0 且 `unpriced=true`。
- `struct UsageTotals` —— `input, output, cacheWrite, cacheRead, costUSD, unpriced`；`totalTokens`；`mutating add(...)`。
- `struct UsageWindow` —— `start, end(=start+5h), totals`；`secondsUntilReset`。
- `struct UsageBucket: Identifiable` —— `id, label, totals, date?`（报表一行）。
- `struct ClaudeUsageReport` —— `byDay, byProject, byModel: [UsageBucket]`。
- `struct ClaudeMCPServerStat: Sendable` —— `server, total: Int, tools: [String: Int]`（MCP 两级统计的值）。
- `struct ClaudeInvocationStats: Sendable` —— 三字段:`skills: [String: Int]`(Skill+斜杠命令合并) / `mcp: [String: ClaudeMCPServerStat]`(服务器›工具) / `builtin: [String: Int]`(其余工具);排序留给 UI。

### `@MainActor final class ClaudeUsageStore: ObservableObject`（`.shared`）
| 成员 | 说明 |
|---|---|
| `@Published private(set) var currentWindow: UsageWindow?` | nil=无活跃窗口 |
| `@Published private(set) var todayTotals: UsageTotals?` | 今日累计 |
| `@Published private(set) var isRefreshing: Bool` | |
| `static let budgetKey = "claudecode.tokenBudget"` | 每窗口 token 预算（UserDefaults Int，0=未设） |
| `func startAutoRefresh()` / `stopAutoRefresh()` | activate 时启动 5 分钟定时刷新 |
| `func refresh()` | 后台收集近 180h 改过的文件的用量（`usageCollector`：只重新解析改过的文件），算 5h 窗口 + 今日 + 周窗口，末尾做 80% 额度提醒；进行中再调合并成结束后补一轮 |
| `func refreshThrottledFromHook()` | 收到 hook 事件的节流刷新：≥60s 马上刷，60s 内来的在窗口结束时补刷一次（只补一次，规则在共用的 `CLIUsageRefreshThrottle`）；`ClaudeLiveStatus` 在 Stop / Notification 时调（启动回放不调） |
| `nonisolated static let usageCollector: ClaudeUsageCollector` | 用量条目的收集器（`ClaudeUsageCollector.swift`，纯 Foundation，`BaoboxTests` 有差分测试）：按文件缓存解析结果（只在内存，保留 180h），结果与全量解析逐条相同；刷新与报表共用 |
| `func report(days:completion: @escaping (ClaudeUsageReport) -> Void)` | 三维度报表 |
| `func invocationStats(days:completion: @escaping (ClaudeInvocationStats) -> Void)` | 调用统计(Skill/斜杠命令、MCP 两级、内置工具);后台算主线程回调，同 report 线程约定。**无新 L() key**(名称均为数据) |

---

## 4. ClaudeLiveStatus.swift —— 实时状态 + 通知

- `enum ClaudeSessionState: Equatable { case running; case waiting(String); case idle }`
- `struct ClaudeLiveSession` —— `sessionID, state, cwd?, terminal?（hook 记下的终端位置）, lastEvent`；`projectName`。
- `enum ClaudeNotifierSettings` —— UserDefaults 键与读值：`enabled`(默认关) / `soundEnabled`(默认开) / `budgetAlertEnabled`(默认开) / `budgetRestoreEnabled`(默认关)，键名见文件。

### `@MainActor final class ClaudeNotifier`（`.shared`）
`requestAuthorizationIfNeeded()`、`notifyStop(project:)`、`notifyWaiting(project:message:)`、`notifyBudget(percent:windowEnd:)`、`notifyBudgetRestored()`。未签名 dev 包失败静默。

### `@MainActor final class ClaudeLiveStatus: ObservableObject`（`.shared`）
| 成员 | 说明 |
|---|---|
| `@Published private(set) var sessions: [String: ClaudeLiveSession]` | sessionID → 状态 |
| `func start()` / `stop()` | 监听 events.jsonl（DispatchSource 增量），维护状态机 |
| `var runningCount / waitingCount: Int` | 计数 |
| `func summaryLine() -> String?` | 菜单状态行；无 hooks 时按 mtime<2min 降级推断；无内容→nil |
| `func currentTerminal(of:) -> TerminalLocation?` | 会话现在还占着的终端（同一个 tty 后来没见过别的会话），快速切换面板续接用；nil = 没见过 / 没记 tty / 已让给后来的会话 |

> Stop / Notification（非回放）时顺带调 `ClaudeUsageStore.shared.refreshThrottledFromHook()`。

> 事件文件的建 / 截断 / 回放 / 增量监听用 Core 的 `EventFileFollower`（`Sources/Core/EventFile/`，与 Codex 助手共用），UI 不直接用。

---

## 5. ClaudeHooks.swift —— hooks 安装 / 卫士规则

- `struct ClaudeGuardPreset: Identifiable, Equatable` —— `id, descriptionKey(L() key), pattern(ERE)`。预置危险命令规则模型。
- `enum ClaudeHookScripts` —— 脚本内容与常量：`reporterScript`、`guardScript`、`guardPresets: [ClaudeGuardPreset]`、`presetPatternSet: Set<String>`、`defaultGuardPatterns`(=全部预置)、`markerFragment("/Baobox/ClaudeCode/")`、`reporterEvents`、`guardEvent`。

### `@MainActor final class ClaudeHooksManager: ObservableObject`（`.shared`）
| 成员 | 说明 |
|---|---|
| `@Published private(set) var isReporterInstalled / isGuardInstalled: Bool` | |
| `@Published private(set) var guardPatterns: [String]` | 卫士规则（预置+自定义混合数组） |
| `func refreshState()` | 后台读 settings.json 判定安装态 + 读规则，发布 |
| `func installReporter(completion:)` / `removeReporter(completion:)` | 事件上报 hooks 装/卸（回调 Bool） |
| `func installGuard(completion:)` / `removeGuard(completion:)` | 危险命令卫士装/卸 |
| `func loadGuardPatterns()` / `saveGuardPatterns(_:)` / `resetGuardPatterns()` | 规则读/写/恢复默认 |
| `var guardPresets: [ClaudeGuardPreset]` | 预置规则表（内置常量，供 UI 勾选列表） |
| `func isPresetEnabled(_:) -> Bool` | 某预置是否启用（=其 pattern 是否在 guardPatterns，不另存状态） |
| `func setPreset(_:enabled:)` | 启用/禁用一条预置（增删其 pattern 后落盘） |
| `func customPatterns() -> [String]` | 非预置的自定义规则（「高级」折叠增删） |

安装 = 生成脚本(chmod 755) + 合并进 settings.json（识别标志 `/Baobox/ClaudeCode/`，幂等追加/移除）。
guard-patterns.txt 只写入「已启用的预置规则 + 自定义规则」；启用态由 pattern 是否在文件中反推。

---

## 6. ClaudeStatusline.swift —— statusline 配置 / 脚本

- `struct StatuslineConfig: Codable, Equatable` —— `model, dir, gitBranch, cost, time: Bool; separator: String`；`.default`。

### `@MainActor final class ClaudeStatuslineManager: ObservableObject`（`.shared`）
| 成员 | 说明 |
|---|---|
| `@Published var config: StatuslineConfig` | 修改后调 `saveConfig()` |
| `@Published private(set) var isInstalled: Bool` | statusLine 指向 Baobox 脚本 |
| `@Published private(set) var hasForeignStatusline: Bool` | 存在非 Baobox statusLine（应用前 UI 需确认覆盖） |
| `var scriptURL: URL` | `~/.claude/baobox-statusline.sh` |
| `func saveConfig()` / `refreshState()` | 存配置 / 后台刷新安装态 |
| `func apply(completion:)` / `remove(completion:)` | 生成脚本+写/删 settings.json（回调 Bool） |
| `func generateScript() -> String` | 生成 sh 脚本文本 |
| `func previewLine() -> String` | 设置页预览（Swift 侧模拟，不执行脚本） |

---

## 7. 本地化 key 清单（共 19 个，待 UI 阶段并入 Localizable.xcstrings）

### 状态 / 通知（10 个）
| key | zh-Hans | en |
|---|---|---|
| `claudecode.session.untitled` | (无标题会话) | (untitled session) |
| `claudecode.status.running %lld` | %lld 运行中 | %lld running |
| `claudecode.status.waiting %lld` | %lld 等待确认 | %lld awaiting confirmation |
| `claudecode.status.inferredActive %lld` | %lld 个会话活跃（推断） | %lld session(s) active (inferred) |
| `claudecode.notify.stop.title %@` | 会话完成 · %@ | Session finished · %@ |
| `claudecode.notify.waiting.title %@` | 等你确认 · %@ | Awaiting confirmation · %@ |
| `claudecode.notify.budget.title` | 额度提醒 | Usage budget alert |
| `claudecode.notify.budget.body %lld` | 本额度窗口已用 %lld%% 预算 | You've used %lld%% of this window's budget |
| `claudecode.notify.budgetRestored.title` | 额度已恢复 | Budget window reset |
| `claudecode.notify.budgetRestored.body` | 新的 5 小时额度窗口已开始 | A new 5-hour usage window has started |

### 预置卫士规则描述（9 个，`ClaudeGuardPreset.descriptionKey`）
| key | zh-Hans | en |
|---|---|---|
| `claudecode.guard.preset.rmRfRoot` | 递归删除根目录（rm -rf /） | Recursively delete root (rm -rf /) |
| `claudecode.guard.preset.rmRfHome` | 递归删除主目录（rm -rf ~） | Recursively delete home (rm -rf ~) |
| `claudecode.guard.preset.sudoRm` | 以管理员删除（sudo rm） | Delete as root (sudo rm) |
| `claudecode.guard.preset.gitPushForce` | 强制推送（git push --force） | Force push (git push --force) |
| `claudecode.guard.preset.gitResetHard` | 硬重置（git reset --hard） | Hard reset (git reset --hard) |
| `claudecode.guard.preset.gitCleanForce` | 强制清理（git clean -fd） | Force clean (git clean -fd) |
| `claudecode.guard.preset.dropTable` | 删除数据表（DROP TABLE） | Drop database table (DROP TABLE) |
| `claudecode.guard.preset.mkfs` | 格式化文件系统（mkfs） | Format filesystem (mkfs) |
| `claudecode.guard.preset.chmod777` | 递归开放全部权限（chmod -R 777） | Recursively grant all permissions (chmod -R 777) |

> 卫士脚本 stderr 里那条「Baobox 卫士已拦截…」是喂给 Claude 的固定串，不走 L()。

---

## 8. 偏离 TECH_DESIGN 说明（仅 1 处）

- **3.1 `@MainActor enum ClaudeEnv` → 改为非 @MainActor**：`ClaudeEnv`/`ClaudeJSONFile`/`ClaudeSettingsFile`
  的成员要么是纯路径计算、要么是可能读写数 MB 文件的重 IO，必须能在后台线程直接调用。若标 `@MainActor`
  会把大文件 IO 逼回主线程，违反「重 IO 一律后台」硬约束。触碰 NSWorkspace 的 `ClaudeTerminal`（原 `TerminalLauncher`，#164 起通用部分在 Core）单独标
  `@MainActor`。其余签名与 3.x 节一致（`@Published` 部分改用 `private(set)` 强化封装，属加强非削减）。
