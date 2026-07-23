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
| `static func shellSingleQuote(_:) -> String` | 单引号 shell 转义 |

### `enum ClaudeJSONFile` / `enum ClaudeSettingsFile`
- `ClaudeJSONFile.load(_ url:) -> [String: Any]` / `write(_:to:) throws` / `mutate(_ url:_ transform:) throws` —— 通用 JSON 读-改-写，写前备份 `<name>.baobox.bak`，只动自己的键。
- `ClaudeSettingsFile.load() -> [String: Any]` / `mutate(_ transform:) throws` —— 绑定 `settings.json` 的便捷入口。
- 均为**后台调用**（文件可能几 MB）。

### `@MainActor enum TerminalLauncher`（主线程调用）
- `run(command:in:)` —— 把命令写成一次性 `.command` 脚本用默认终端打开。
- `resume(sessionID:in:binary:)` —— 续接会话 `claude --resume <id>`。

---

## 2. ClaudeSessionIndex.swift —— 会话索引 / 审计 / 磁盘

### 共享解析工具 `enum ClaudeJSONLParsing`
`parseDate(_:) -> Date?`、`parseObject(_ data:) -> [String:Any]?`、`extractText(fromContent:) -> String?`（Usage / LiveStatus 也用它）。

### 数据模型
- `struct ClaudeSessionSummary: Identifiable, Equatable` —— `id, fileURL, projectPath, projectName, title, lastActivity, fileSize`
- `struct ClaudeAuditEntry: Identifiable` —— `id(=filePath), filePath, count, lastEdited`
- `struct ClaudeAuditProject: Identifiable` —— `id(=projectPath), projectPath, projectName, entries, totalCount`
- `struct ClaudeDiskStats` —— `projectsBytes, todosBytes, shellSnapshotsBytes, otherBytes, totalBytes, sessionFileCount`

### `@MainActor final class ClaudeSessionIndex: ObservableObject`（`.shared`）
| 成员 | 说明 |
|---|---|
| `@Published private(set) var sessions: [ClaudeSessionSummary]` | 新→旧 |
| `@Published private(set) var isRefreshing: Bool` | 刷新中 |
| `func refresh()` | 后台快扫（头64K+尾8K）+ 缓存复用，回主线程发布；去抖防重入 |
| `func recentSessions(limit:) -> [ClaudeSessionSummary]` | 取前 N 条（内存） |
| `func auditEntries(on day:completion: @escaping ([ClaudeAuditProject]) -> Void)` | 某日改动审计 |
| `func diskStats(completion: @escaping (ClaudeDiskStats) -> Void)` | 磁盘占用 |
| `func cleanup(olderThanDays:completion: @escaping (Int, Int64) -> Void)` | 清理旧会话，回调 (删除数, 释放字节)，随后自动 refresh |
| `func deleteSession(_:completion: @escaping (Bool) -> Void)` | 删单个会话文件 |
| `func exportMarkdown(_:completion: @escaping (String?) -> Void)` | 导出 Markdown 文本（UI 负责 NSSavePanel） |
| `func flushCache()` | willTerminate 落盘索引缓存 |

> 静态工具 `ClaudeSessionIndex.projectName(fromPath:)` / `demungeDirName(_:)` 供其他文件复用。

---

## 3. ClaudeUsage.swift —— 定价 / 用量 / 额度窗口 / 报表

- `struct ModelPricing` + `static func pricing(for modelID:) -> (pricing, unpriced)` —— opus/sonnet/haiku 关键字匹配，未知全 0 且 `unpriced=true`。
- `struct UsageTotals` —— `input, output, cacheWrite, cacheRead, costUSD, unpriced`；`totalTokens`；`mutating add(...)`。
- `struct UsageWindow` —— `start, end(=start+5h), totals`；`secondsUntilReset`。
- `struct UsageBucket: Identifiable` —— `id, label, totals, date?`（报表一行）。
- `struct ClaudeUsageReport` —— `byDay, byProject, byModel: [UsageBucket]`。

### `@MainActor final class ClaudeUsageStore: ObservableObject`（`.shared`）
| 成员 | 说明 |
|---|---|
| `@Published private(set) var currentWindow: UsageWindow?` | nil=无活跃窗口 |
| `@Published private(set) var todayTotals: UsageTotals?` | 今日累计 |
| `@Published private(set) var isRefreshing: Bool` | |
| `static let budgetKey = "claudecode.tokenBudget"` | 每窗口 token 预算（UserDefaults Int，0=未设） |
| `func startAutoRefresh()` / `stopAutoRefresh()` | activate 时启动 5 分钟定时刷新 |
| `func refresh()` | 后台解析近 24h 文件，算窗口+今日，末尾做 80% 额度提醒 |
| `func refreshThrottledFromHook()` | 收到 hook 事件的节流刷新（≥60s） |
| `func report(days:completion: @escaping (ClaudeUsageReport) -> Void)` | 三维度报表 |

---

## 4. ClaudeLiveStatus.swift —— 实时状态 + 通知

- `enum ClaudeSessionState: Equatable { case running; case waiting(String); case idle }`
- `struct ClaudeLiveSession` —— `sessionID, state, cwd?, lastEvent`；`projectName`。
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

> `final class ClaudeEventWatcher`（非 @MainActor）是内部增量监听器，UI 不直接用。

---

## 5. ClaudeHooks.swift —— hooks 安装 / 卫士规则

- `enum ClaudeHookScripts` —— 脚本内容与常量：`reporterScript`、`guardScript`、`defaultGuardPatterns`、`markerFragment("/Baobox/ClaudeCode/")`、`reporterEvents`、`guardEvent`。

### `@MainActor final class ClaudeHooksManager: ObservableObject`（`.shared`）
| 成员 | 说明 |
|---|---|
| `@Published private(set) var isReporterInstalled / isGuardInstalled: Bool` | |
| `@Published private(set) var guardPatterns: [String]` | 卫士规则 |
| `func refreshState()` | 后台读 settings.json 判定安装态 + 读规则，发布 |
| `func installReporter(completion:)` / `removeReporter(completion:)` | 事件上报 hooks 装/卸（回调 Bool） |
| `func installGuard(completion:)` / `removeGuard(completion:)` | 危险命令卫士装/卸 |
| `func loadGuardPatterns()` / `saveGuardPatterns(_:)` / `resetGuardPatterns()` | 规则读/写/恢复默认 |

安装 = 生成脚本(chmod 755) + 合并进 settings.json（识别标志 `/Baobox/ClaudeCode/`，幂等追加/移除）。

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

## 7. 本地化 key 清单（共 10 个，待 UI 阶段并入 Localizable.xcstrings）

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

> 卫士脚本 stderr 里那条「Baobox 卫士已拦截…」是喂给 Claude 的固定串，不走 L()。

---

## 8. 偏离 TECH_DESIGN 说明（仅 1 处）

- **3.1 `@MainActor enum ClaudeEnv` → 改为非 @MainActor**：`ClaudeEnv`/`ClaudeJSONFile`/`ClaudeSettingsFile`
  的成员要么是纯路径计算、要么是可能读写数 MB 文件的重 IO，必须能在后台线程直接调用。若标 `@MainActor`
  会把大文件 IO 逼回主线程，违反「重 IO 一律后台」硬约束。触碰 NSWorkspace 的 `TerminalLauncher` 单独标
  `@MainActor`。其余签名与 3.x 节一致（`@Published` 部分改用 `private(set)` 强化封装，属加强非削减）。
