# Codex 助手 — 对齐 Claude Code 的功能（需求 + 技术方案）

> 版本：v1.0（2026-07-23）· 设计者：Fable · 实现者：Opus 4.8
> 前身：`docs/cursor-codex-assistant/DESIGN.md`（本文件**取代**其中的 Codex 部分并扩展；**移除 Cursor**）
> 参照：`docs/claude-code-assistant/{REQUIREMENTS,TECH_DESIGN}.md` 与本批次 `docs/claude-code-assistant/WEEKLY_QUOTA.md`
> 定位不变：只读写本地文件，不调 AI API、不需登录；零第三方依赖；文案中英双语；解析全程容错不 crash。

## 0. 本次变更总览

用户诉求（原文）：**「codex 也参考 claudecode 的功能实现一下，cursor 可以暂时移出，不要了」**。

两件事：

1. **移除 Cursor**：`aitools` 模块不再包含 Cursor（Rules 管理、Cursor MCP 面板、项目列表）。
2. **Codex 向 Claude Code 看齐**：在已有的「会话浏览/续接、完成通知、配置可视化」之上，新增 **用量/额度展示（含 5h + 周窗口）、用量报表中心窗口、维护（磁盘清理 + 版本检查）**，并把原轻量会话窗口升级为**带 Tab 的中心窗口**（会话 / 用量）。

模块重命名：显示名 `Cursor / Codex 助手` → **`Codex 助手`**；`symbolName` `wand.and.stars` → `chevron.left.forwardslash.chevron.right`。**模块 `id` 保持 `"aitools"`**（避免动到设置页 Tab 选择与已落盘约定；目录 `Sources/Modules/AITools/` 沿用，不重命名，降低 diff 与风险）。菜单入口文字随显示名变。

## 1. 移除 Cursor（清理清单）

删除 / 改动：

- **删除文件**：`Sources/Modules/AITools/CursorEnv.swift`、`CursorProjectIndex`（若独立文件）。若 `CursorProjectIndex` 与其它类型同文件，则删除相关类型与方法。
- **`AIToolsTool.swift`**：移除 `cursorIndex`、`cursorRulesItem()`、`projectSubmenuItem(...)`、`activate()` 里的 Cursor 分支、`presentTemplateError`；菜单不再有「Cursor Rules」父项与分隔线。
- **`AIToolsSettingsView.swift`**：移除 segmented 里的「Cursor」节及其全部视图（项目列表、模板写入、Cursor MCP 面板）。设置页顶部若有「Codex / Cursor」双状态，改为仅 Codex。
- **本地化**：`aitools.menu.cursorRules`、`aitools.menu.noProjects`、`aitools.menu.noRules`、`aitools.menu.legacyCursorrules`、`aitools.menu.writeTemplate %@`、`aitools.cursor.*`、`aitools.settings.section.cursor` 等 Cursor 词条从 `Localizable.xcstrings` 删除（或保留不引用亦可，但建议删净以免误导）。`aitools.name` / `aitools.menu.notInstalled` 文案改为仅 Codex（见 §6）。
- **`docs/REQUIREMENTS.md` 第 6 节**：把「Cursor / Codex 助手」条目改写为「Codex 助手」，删去 Cursor 描述，补上用量/报表/维护。
- **README / README.zh-CN**：同步模块名与能力描述。

> `aitools.menu.notInstalled` 原为「未检测到 Codex / Cursor」，改为「未检测到 Codex（~/.codex 不存在）」，与 `aitools.menu.codexNotInstalled` 合并语义（模块只剩 Codex，未安装即整体降级一条引导）。

## 2. Codex 用量数据源（事实依据）

Codex rollout jsonl：`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`（已由 `CodexSessionIndex` 快扫）。用量在 **`event_msg` 行且 `payload.type == "token_count"`**：

```jsonc
{"type":"event_msg","timestamp":"2026-07-23T03:12:45.123Z",
 "payload":{"type":"token_count",
   "info":{
     "total_token_usage":   {"input_tokens":12345,"cached_input_tokens":8000,"output_tokens":2222,"total_tokens":14567},
     "last_token_usage":    {"input_tokens":120,"cached_input_tokens":80,"output_tokens":45,"total_tokens":165},
     "model_context_window": 272000 }}}
```

字段兼容性（**必须容错**，不同 Codex 版本字段位置有差异）：

- `token_count` 可能直接把计数放在 `payload` 顶层（`input_tokens` 等），也可能嵌在 `payload.info.total_token_usage` / `last_token_usage`。解析顺序：优先 `info.last_token_usage`（**每回合增量**，可安全累加），否则 `info.total_token_usage`（**累计值**，按会话取最后一条、不累加），否则 `payload` 顶层计数（当作增量累加）。
- **聚合口径（关键，避免双计）**：
  - 若某会话文件用的是 `last_token_usage`（增量）→ 直接把该文件所有 token_count 增量相加，得到该文件用量条目序列（每条带 timestamp）。
  - 若用的是 `total_token_usage`（累计）→ 每个会话只取**该文件内时间最大的一条** token_count 作为该会话总量，timestamp 取该条时间；不与其它 token_count 相加。
  - 判定：文件内若出现过 `last_token_usage` 即走增量路径，否则走累计路径。二者不混用于同一文件。
- 模型 id：Codex 会话的 `model`（在 SessionMeta / turn_context / event 里出现，取会话内最后一次可见值；缺失记 `"unknown"`）。用于分模型报表与估算定价。
- 项目路径：复用 `CodexSessionSummary.projectPath`（会话已扫出 cwd）。用量条目按其所属会话的 cwd 归到项目维度。

> 与 Claude 的差异：Claude 每条 assistant 消息自带独立 usage（天然增量、用 msgId+reqId 去重）；Codex 是会话级 token_count 事件，需按上面的口径处理累计/增量。这是 Codex 用量实现的**唯一难点**，实现者务必按此口径，并在解析处写清注释。

### 2.1 Codex 定价表（估算）

Codex 常用 OpenAI 模型；很多用户走 ChatGPT 订阅（无按量计费），故**费用为粗略估算，UI 重点展示 token 数、费用作次要信息并标「估算」**。按 model id 关键字匹配（每百万 token 美元，缓存读折扣）：

| 关键字 | input | cachedInput | output | 备注 |
|---|---|---|---|---|
| `gpt-5-codex` / `gpt-5` | 1.25 | 0.125 | 10 | 默认 Codex 模型族 |
| `o4-mini` / `o3-mini` | 1.1 | 0.275 | 4.4 | 小模型 |
| `o3` | 2 | 0.5 | 8 | |
| `gpt-4.1` | 2 | 0.5 | 8 | |
| `codex-mini` | 1.5 | 0.375 | 6 | |
| 其它 | 0 | 0 | 0 | 标记 `unpriced`，UI 提示费用可能偏低 |

结构照搬 `ModelPricing`：`CodexPricing { inputPerM, cachedInputPerM, outputPerM }`（Codex 无「缓存写」概念，缓存输入是折扣读）。`cost = (input-cachedInput)/1e6*inputPerM + cachedInput/1e6*cachedInputPerM + output/1e6*outputPerM`（若 provider 把 cached 计入 input 总数，则从 input 里扣除已缓存部分；取不到 cached 就全按 input 计）。定价随时可能变，集中为常量并注明来源日期。

## 3. Codex 用量聚合层（新文件 `CodexUsage.swift`）

新增 `Sources/Modules/AITools/CodexUsage.swift`，结构对照 `ClaudeUsage.swift`，复用其数据模型语义：

```swift
struct CodexUsageTotals { var input, cachedInput, output: Int; var costUSD: Double; var unpriced: Bool
    var totalTokens: Int { input + output }   // Codex 计费口径以 input+output 为主
}
struct CodexUsageWindow { let start, end: Date; var totals: CodexUsageTotals
    var secondsUntilReset: TimeInterval { max(0, end.timeIntervalSinceNow) } }
struct CodexUsageBucket: Identifiable { let id, label: String; var totals: CodexUsageTotals; var date: Date? }
struct CodexUsageReport { var byDay, byProject, byModel: [CodexUsageBucket] }

@MainActor final class CodexUsageStore: ObservableObject {
    static let shared = CodexUsageStore()
    @Published private(set) var fiveHourWindow: CodexUsageWindow?
    @Published private(set) var weeklyWindow: CodexUsageWindow?
    @Published private(set) var todayTotals: CodexUsageTotals?
    @Published private(set) var isRefreshing = false
    func startAutoRefresh()  // activate 时启动：立即刷 + 每 5 分钟；收 notify 事件时节流刷（≥60s）
    func stopAutoRefresh()
    func refresh()
    func report(days: Int, completion: @escaping (CodexUsageReport) -> Void)
    func invocationStats(days: Int, completion: @escaping (CodexInvocationStats) -> Void)
}
```

- **5h / 周窗口算法**：与 Claude 完全同构——抽 `lastActiveBlock(from:span:)`，5h = span 5h，周 = span 168h；周窗口同样支持「滚动块（默认）/ 固定锚点」两口径（复用 `WEEKLY_QUOTA.md §4.2` 的 `WeeklyAnchor`，Codex 用独立 UserDefaults 键 `codex.weekly*`）。
- **今日累计**：本地时区当日聚合。
- **后台扫描**：`collectEntries(sinceHoursAgo: 180)` 递归枚举 `sessions/` jsonl（复用 `CodexSessionIndex` 的目录枚举思路），按 §2 口径产出 `CodexUsageEntry(timestamp, modelID, projectPath, input, cachedInput, output)`。并发/容错同 Claude（后台线程、`@Published` 主线程写）。
- **额度提醒**：可选周/5h token 预算（UserDefaults `codex.tokenBudget` / `codex.weeklyTokenBudget`），达 80% 经 `CodexNotify` 通知一次（防重），与 Claude 同机制。MVP 可先只做展示、提醒作为 P1（与 Claude 对齐则一并做）。

### 3.1 调用统计（Codex 版）

`CodexInvocationStats`：遍历 rollout 里的工具调用事件聚合。Codex 的工具调用体现在 `payload.type` 为 `function_call` / `tool_call` / `mcp_tool_call`（不同版本命名不一，容错匹配）：

- **内置工具**：`shell` / `apply_patch` / `read_file` 等 → 按名计数。
- **MCP**：Codex MCP 调用名形如 `<server>__<tool>` 或事件带 `server` 字段 → 按服务器›工具两级。
- Codex 无「Skill/斜杠命令」概念，该类留空或不展示。

字段不确定处一律容错跳过；取不到就少统计一类，绝不 crash。

## 4. 菜单与中心窗口

### 4.1 菜单结构（`AIToolsTool.submenuItems()` 改造，常用度顺序）

```
[状态行,置灰] 3 个会话 · 今日 $1.20（估算）          ← 会话数 + 今日估算花费
──────
最近 Codex 会话 ≤5（点击 → codex resume）
浏览会话 / 用量…                                     → 中心窗口 tab .sessions
──────
用量报表…                                            ← 两行副标题：5 小时 + 本周（同 Claude）
  5 小时：已用 45.2k ≈ $0.30 · 1h40m 后重置
  本周：已用 1.2M ≈ $12.30 · 4天2h 后重置
──────
完成通知（开关，右侧 switch 或对号；不可编辑时置灰，逻辑不变）
```

- 状态行今日花费用 `CodexUsageStore.todayTotals`；无用量则仅显示会话数。
- 「用量报表…」副标题两行，复用 `WEEKLY_QUOTA.md` 的多行副标题构件（Codex 侧独立实现同样的 `multiLineTitle`，或把该构件提到 Core 复用——见 §7 复用建议）。无窗口各自降级文案。
- 未安装 Codex：整体一条置灰引导（既有逻辑，文案合并）。

### 4.2 中心窗口（`AIToolsCenterWindow.swift`，由 `AIToolsSessionsWindow` 升级）

把现有轻量会话窗口升级为带 Tab 的中心窗口，**仿 `ClaudeCodeCenterWindow`** 但独立实现（不跨模块依赖）：

- 控制器 `AIToolsCenterController`（单例，NSWindow + NSHostingController，`isReleasedWhenClosed=false`，`show(tab:)`），尺寸 720×480，titled/closable/resizable。
- 两个 Tab（segmented Picker 或 TabView）：
  1. **会话**（沿用现窗口内容）：搜索、列表（标题/项目/相对时间/大小）、行操作续接（`codex resume <id>`）/复制命令/删除。
  2. **用量**（新增，仿 Claude 用量页）：顶部两张窗口卡片（5 小时 / 本周，含倒计时与可选预算进度条）+「按天（近 30 天）/ 按项目 / 按模型」三张表（列：模型/项目/日期、输入、缓存输入、输出、估算费用，费用列标「估算」）+「调用统计」小节（内置工具、MCP 两级）。刷新按钮。
- Codex **不做**「今日改动审计」Tab（Codex 的改动经 `apply_patch`，可作为 P1 从 `apply_patch` 事件提取「今日改动文件」，MVP 先不做，避免解析不稳）。

### 4.3 维护（设置页新节，仿 Claude「维护」）

- **磁盘统计 + 清理**：展示 `~/.codex/sessions` 占用与文件数；「清理早于 N 天」（Picker 30/60/90）删除旧 rollout jsonl，删前二次确认 + 显示可释放空间。
- **版本检查**：显示 `codex --version`（后台线程跑 Process）；「检查最新版」请求 `https://registry.npmjs.org/@openai/codex/latest` 取 `version`（10s 超时，唯一联网点，断网优雅失败）；「复制升级命令」`npm install -g @openai/codex`。

## 5. 设置页（`AIToolsSettingsView.swift` 改造）

segmented 分节从「Codex / Cursor」改为 **纯 Codex 的多节**（DisclosureGroup 或 segmented）：

1. **配置**（既有，保留）：`approval_policy` 单选（三档 + 说明）、`sandbox_mode` 单选（三档，danger 红字）、`model` 输入/常用值单选。
2. **通知**（既有开关 + 新增）：完成通知开关（既有）；新增 5h/周 token 预算与 80% 提醒开关（若做提醒）。
3. **用量**（新增）：周窗口口径开关「按固定重置时间对齐」+ 星期/小时选择器（同 Claude）。
4. **MCP**（可选，见 §5.1）。
5. **维护**（新增，见 §4.3）。

顶部状态卡：Codex 版本 / 会话总数 / config.toml 可编辑性。未安装 Codex 时降级引导文案（既有 `aitools.settings.codex.notInstalled`）。

### 5.1 Codex MCP 面板（P1，块级编辑，风险提示）

Codex 的 MCP 配置是 TOML **表**：`[mcp_servers.<name>]` 带 `command` / `args` / `env`。现有 `CodexTOML` 只做顶层标量/数组行编辑，**不能**安全改表。方案分级：

- **MVP**：只读列出 `[mcp_servers.*]` 段（正则扫描段头 + 段内 `command`/`args`），提供「用默认编辑器打开 config.toml」。不做写入。
- **P1（可选）**：`CodexTOML` 增「块级」增删——`addServerBlock(name:command:args:env:)` 追加一个 `\n[mcp_servers.<name>]\n...` 到文件末尾；`removeServerBlock(name:)` 删除从 `[mcp_servers.<name>]` 段头到下一个 `[` 段头（或文件尾）之间的整块。仅在能明确定位段边界时执行，写前备份 `.baobox.bak`；否则置灰并提示手动编辑。不解析既有段内容、不重写，最大限度保全注释与格式。

## 6. 本地化词条（`aitools.*`，新增/改写）

改写：
- `aitools.name`：`Codex 助手` / `Codex Assistant`。
- `aitools.menu.notInstalled`：`未检测到 Codex（~/.codex 不存在）` / `Codex not detected (~/.codex missing)`。

新增（示例，en/zh 双语，紧凑单行；数量约 30 条）：

| key | zh-Hans |
|---|---|
| `aitools.menu.status %lld %@` | %lld 个会话 · 今日 %@（估算） |
| `aitools.menu.usageReport` | 用量报表… |
| `aitools.menu.browse` | 浏览会话 / 用量… |
| `aitools.menu.quota5h %@ %@ %@` | 5 小时：已用 %@ ≈ %@ · %@ 后重置 |
| `aitools.menu.quotaWeek %@ %@ %@` | 本周：已用 %@ ≈ %@ · %@ 后重置 |
| `aitools.menu.noWindow` | 当前无活跃额度窗口 |
| `aitools.menu.noWeekWindow` | 本周暂无用量 |
| `aitools.center.tab.sessions` | 会话 |
| `aitools.center.tab.usage` | 用量 |
| `aitools.usage.byDay` / `byProject` / `byModel` | 按天 / 按项目 / 按模型 |
| `aitools.usage.col.input` / `cachedInput` / `output` / `cost` | 输入 / 缓存输入 / 输出 / 估算费用 |
| `aitools.usage.invocations` | 调用统计 |
| `aitools.usage.weekCard.title` | 本周窗口 |
| `aitools.settings.section.usage` | 用量 |
| `aitools.settings.section.maintenance` | 维护 |
| `aitools.maint.disk %@ %lld` | 占用 %@ · %lld 个会话 |
| `aitools.maint.cleanup %lld` | 清理早于 %lld 天 |
| `aitools.maint.version %@` | Codex 版本 %@ |
| `aitools.maint.checkUpdate` | 检查最新版 |
| `aitools.maint.copyUpgrade` | 复制升级命令 |
| `aitools.notify.weeklyBudget` | 周额度预算（k tokens） |

费用统一 `$%.2f`；token ≥1000 显示 `%.1fk`、≥1e6 显示 `%.1fM`（提取 `CodexFormat`，或复用 Claude 的 `ClaudeFormat`——见 §7）。

## 7. 复用与文件清单

新增 / 改动文件（全在 `Sources/Modules/AITools/`，除标注外）：

| 文件 | 动作 | 说明 |
|---|---|---|
| `CodexUsage.swift` | 新增 | 定价表、用量聚合、5h/周窗口、报表、调用统计 |
| `AIToolsCenterWindow.swift` | 新增（替代 `AIToolsSessionsWindow.swift`） | 会话 + 用量两 Tab 的中心窗口；旧文件内容并入或删除 |
| `AIToolsTool.swift` | 改 | 去 Cursor；菜单加用量副标题、报表入口、状态行今日花费；`activate` 启动 `CodexUsageStore.startAutoRefresh` |
| `AIToolsSettingsView.swift` | 改 | 去 Cursor 节；加用量/维护节；配置/通知节保留 |
| `CodexEnv.swift` | 改 | 加 `cliVersion()`、`sessionsDiskStats/cleanup`、（可选）MCP 块级编辑 |
| `CursorEnv.swift` 等 | 删 | Cursor 全删 |
| `Localizable.xcstrings`（Resources） | 改 | 删 Cursor 词条、改 `aitools.name`、加用量/维护词条 |
| `AppDelegate.swift` | 不改 | 仍 `registry.register(AIToolsTool())`（id 不变） |

**复用建议**（降低重复、便于一致性）：把 Claude 侧几个纯工具**上移到 Core** 供两模块共用，是本次的推荐重构（非强制）：

- `WeeklyAnchor` 与 `lastActiveBlock(from:span:)` 的**算法**（纯函数，泛型化 totals 累加闭包）——放 `Sources/Core/UsageWindowMath.swift`。
- 多行副标题构件 `multiLineTitle(title:subtitles:)`、金额/ token 格式化——放 `Sources/Core/` 一个小工具文件。
- 若不上移，则 Codex 侧平行实现，保持行为一致（与 `CodexSessionIndex` 相对 `ClaudeSessionIndex` 的「平行不耦合」取舍一致）。实现者按 diff 成本二选一，但**周窗口算法两处必须等价**。

## 8. 验收标准

1. 菜单不再出现任何 Cursor 相关项；模块名显示「Codex 助手」。
2. 菜单状态行显示会话数 + 今日估算花费；「用量报表…」副标题两行（5h + 本周），倒计时随时间推进；无窗口各自降级。
3. 中心窗口出现「会话 / 用量」两 Tab；用量页两张窗口卡片 + 三维报表 + 调用统计，数值与手工抽查同数量级，费用标「估算」。
4. token_count 聚合按 §2 口径：累计型会话不双计、增量型会话正确累加；不同 Codex 版本字段缺失不 crash。
5. 维护节可看磁盘占用、清理旧会话、显示/检查 Codex 版本、复制升级命令；断网时检查更新优雅失败。
6. 既有能力（会话续接、完成通知、配置可视化）回归正常；config.toml 写入仍保注释 + 备份。
7. 全部新文案中英双语入 catalog；Cursor 词条已清理，catalog 合法。
