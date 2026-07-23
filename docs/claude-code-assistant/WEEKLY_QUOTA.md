# Claude Code 助手 — 周额度与重置时间（增量设计）

> 版本：v1.0（2026-07-23）· 设计者：Fable · 实现者：Opus 4.8
> 前置文档：同目录 `REQUIREMENTS.md`（需求）、`TECH_DESIGN.md`（技术方案，本文件复用其数据源与并发约定）
> 本文件是对已实现的「额度/用量展示（功能 #3）」的**增量**：在既有 5 小时窗口之外，新增**周额度窗口**与**重置时间**的展示。不改动已存在的 5h 窗口逻辑，只做并列扩展。

## 1. 背景

Anthropic 订阅账户当前有**两级速率限制**：滚动 5 小时窗口 + 每周窗口（Pro/Max 于 2025 年起对齐）。既有实现只算了 5h 窗口（`ClaudeUsageStore.currentWindow`），菜单里「用量报表」副标题只显示 5h 的「已用 · 估算花费 · Nh 后重置」。

用户诉求（原文）：**「用量那块，需要能展示周额度和重置时间」**。即在同一处再展示当前**周窗口**的用量、估算花费与距重置倒计时。

## 2. 数据来源的现实约束（必须先讲清楚）

本地文件（会话 JSONL）里**没有**账户的套餐周上限，也**没有**服务端下发的周重置时间戳——这些只在服务端 `/usage`。因此与既有 5h 窗口一样，周窗口只能**从本地用量数据推算**，费用与 token 均为**估算**，UI 处处标注「估算 / 近似」。

周窗口的「起点/重置时刻」有两种可选口径，本设计**两者都做**，用户在设置里选（默认「滚动块」）：

- **滚动块（默认）**：完全复用既有 5h 的分块算法，只把窗口跨度从 5h 换成 **168h（7×24）**。即：把带 usage 的条目按时间升序，`blockStart` 向下取整到整点；条目时间 > `blockStart + 168h` 时开新块。末块若满足 `now ≤ blockStart + 168h` 即为当前周窗口，`end = start + 168h` 作为「重置时刻」。优点：零配置、与 5h 口径一致、自洽。缺点：与服务端真实周重置时刻不一定对齐。
- **固定锚点（可选）**：用户在设置里填写「每周重置：星期几 + 几点」（对照 Claude `/usage` 里看到的真实重置时间填一次）。周窗口 = 包含 `now` 的那个「锚点→锚点+7d」区间；`end` = 下一个锚点时刻。优点：与账户真实周期对齐。缺点：需用户手填一次。

> 结论：默认滚动块（免配置即可用），设置里给一个「按固定重置时间对齐」的开关 + 星期/小时选择器，切换后菜单与报表即时改用固定锚点口径。

## 3. 交互与 UI

### 3.1 菜单副标题（`ClaudeCodeTool.quotaText()` 扩展）

菜单「用量报表…」项当前是两行（标题 + 副标题，`twoLineTitle`）。副标题由单行 5h 文案扩为**两行**，5h 在上、周在下：

```
用量报表…
5 小时：已用 123.4k ≈ $2.10 · 2h15m 后重置
本周：已用 4.5M ≈ $86.81 · 3天4小时 后重置
```

- 5h 行文案沿用既有 `claudecode.menu.quota`（改 key 名见 §5，语义加「5 小时：」前缀）。
- 周行新增 key `claudecode.menu.quotaWeek %@ %@ %@`（tokens / cost / countdown）。
- 无 5h 活跃窗口时，5h 行降级 `claudecode.menu.noWindow`（既有）；无周活跃窗口（近 7 天完全无用量）时，周行降级为新 key `claudecode.menu.noWeekWindow`「本周暂无用量」。
- `twoLineTitle` 只支持一条副标题；改为支持多行副标题：新增 `multiLineTitle(_ title:, subtitles: [String])`，每条副标题 `\n` 拼接、小号次要色（保持既有样式，仅行数增加）。菜单项高度由 AppKit 自适应，无需手动设置。

### 3.2 设置页「通知」节扩展

既有「通知」节已有「额度预算（k tokens）」+「80% 提醒」+「恢复提醒」。**在其后追加一组周相关控件**（同节，不新增 segmented 分节）：

- **周额度预算**（TextField，单位 M tokens 或 k tokens，与既有 5h 预算并列；`0 = 未设`）：存 UserDefaults `claudecode.weeklyTokenBudget`。设了则周提醒（达 80%）复用既有 `checkBudgetReminder` 的机制，独立防重记录集合。
- **按固定重置时间对齐**（Toggle）：存 `claudecode.weeklyResetFixed`（默认 false）。开启时展开两个选择器：
  - 重置星期：Picker（周一…周日），存 `claudecode.weeklyResetWeekday`（1–7，Calendar 口径）。
  - 重置小时：Picker（0…23），存 `claudecode.weeklyResetHour`。
  - 一行灰字说明：「对照 Claude `/usage` 显示的周重置时间填写；不填则按近 7 天滚动估算」。

### 3.3 中心窗口「用量」页扩展

「用量」页顶部当前是「5h 窗口卡片（进度条对预算）」。改为**并排/上下两张窗口卡片**：

- 卡片 A（既有）：**5 小时窗口** —— 起止时间、已用 tokens、估算花费、距重置倒计时；有预算则进度条。
- 卡片 B（新增）：**本周窗口** —— 同结构，起止时间按选定口径（滚动块 or 固定锚点），已用 / 估算花费 / 倒计时；有周预算则进度条。卡片右上角小字标注当前口径：「近 7 天滚动」或「固定重置：周三 09:00」。

两卡片之下，既有「按天 / 按项目 / 按模型」三表**保持不变**。可选新增一句总计脚注：「本周合计（近 7 天）：X tokens ≈ $Y（估算）」——其实就是 168h 块的 totals，避免用户困惑「表里按天加起来对不对」。

## 4. 技术实现（对齐 `ClaudeUsage.swift` 现有风格）

所有改动集中在 `Sources/Modules/ClaudeCode/ClaudeUsage.swift`（聚合层）与 `ClaudeCodeTool.swift`（菜单）、`ClaudeCodeSettingsView.swift`（设置）、`ClaudeCodeCenterWindow.swift`（用量页）。并发与容错约定不变：重 IO 后台、`@Published` 仅主线程写、解析容错。

### 4.1 `ClaudeUsageStore` 新增发布属性

```swift
/// nil = 近 7 天无用量。end 依口径而定。
@Published private(set) var weeklyWindow: UsageWindow?
```

在 `refresh()` 里与 `currentWindow`、`todayTotals` **一次扫描一起算出**——关键点：既有 `refresh()` 只 `collectEntries(sinceHoursAgo: 24)`，**周窗口需要近 7 天数据**，所以把 refresh 的采集窗口从 24h 扩到 **`max(24, 168+ 余量)`（取 180h）**，5h 与今日照旧从这批条目里筛（它们只关心近 24h，天然是子集），周窗口用全量 180h 条目算。多扫的量：近 7 天 mtime 的会话文件，量级可接受（仍是后台线程 + 去重）。

```swift
func refresh() {
    guard !refreshing else { return }
    refreshing = true; isRefreshing = true
    let fixed = Self.weeklyAnchorConfig()   // 主线程读 UserDefaults 后传入后台
    DispatchQueue.global(qos: .utility).async {
        let entries = Self.collectEntries(sinceHoursAgo: 180)
        let window = Self.activeWindow(from: entries)               // 既有 5h（内部仍 5h）
        let today  = Self.todayTotals(from: entries)                // 既有今日
        let weekly = Self.weeklyWindow(from: entries, anchor: fixed) // 新增
        DispatchQueue.main.async { MainActor.assumeIsolated {
            self.currentWindow = window
            self.todayTotals = today
            self.weeklyWindow = weekly
            self.refreshing = false; self.isRefreshing = false
            self.checkBudgetReminder(window: window)
            self.checkWeeklyBudgetReminder(window: weekly)          // 新增，独立防重集合
        }}
    }
}
```

> 注意：`activeWindow(from:)` 内部按 5h 分块，若直接喂 180h 条目仍只返回**末个 5h 块**，逻辑正确（末块 = 最近的 5h 活跃窗口）。不需要为 5h 单独二次采集。

### 4.2 周窗口算法

```swift
/// 周窗口锚点配置（主线程读 UserDefaults 构造，值类型跨线程安全）。
struct WeeklyAnchor: Sendable {
    let fixed: Bool       // false = 滚动 168h 块；true = 固定锚点
    let weekday: Int      // 1...7（Calendar.current，1=周日 或按 firstWeekday，见实现注释）
    let hour: Int         // 0...23
}

nonisolated fileprivate static func weeklyWindow(from entries: [UsageEntry], anchor: WeeklyAnchor) -> UsageWindow? {
    guard !entries.isEmpty else { return nil }
    let weekSpan: TimeInterval = 168 * 3_600
    if !anchor.fixed {
        // 滚动块：复用 5h 分块算法，跨度换 168h。抽出通用 blockedWindows(entries:span:)，
        // 5h 与周共用；末块满足 now <= end 则为活跃周窗口。
        return Self.lastActiveBlock(from: entries, span: weekSpan)
    } else {
        // 固定锚点：算包含 now 的 [anchorStart, anchorStart+7d)，聚合落在区间内的条目。
        let start = Self.weekAnchorStart(before: Date(), weekday: anchor.weekday, hour: anchor.hour)
        let end = start.addingTimeInterval(weekSpan)
        var totals = UsageTotals.zero
        var any = false
        for e in entries where e.timestamp >= start && e.timestamp < end {
            any = true
            totals.add(input: e.input, output: e.output, cacheWrite: e.cacheWrite, cacheRead: e.cacheRead, modelID: e.modelID)
        }
        return any ? UsageWindow(start: start, end: end, totals: totals) : UsageWindow(start: start, end: end, totals: .zero)
    }
}
```

- 建议把既有 `activeWindow` 里的分块循环抽成 `lastActiveBlock(from:span:)`（参数化跨度），`activeWindow` = `lastActiveBlock(span: 5h)`，周 = `lastActiveBlock(span: 168h)`——**消除重复、保证两口径一致**。这是本次唯一的既有代码重构，需保持 5h 行为逐字节等价（floor 到整点、超跨度开新块、末块判活跃）。
- `weekAnchorStart(before:weekday:hour:)`：用 `Calendar.current` 找 `now` 之前最近一个「指定星期几的指定小时:00:00」。实现用 `nextDate(after:matching:matchingPolicy:direction:.backward)`（`DateComponents(hour:weekday:)`）。取不到则回退滚动块口径。
- 固定锚点下即使 totals 为 0 也返回一个 window（有明确的起止与倒计时可展示）；滚动块下无条目才返回 nil。

### 4.3 周预算提醒

```swift
static let weeklyBudgetKey = "claudecode.weeklyTokenBudget"
private var remindedWeekStarts: Set<Date> = []
private func checkWeeklyBudgetReminder(window: UsageWindow?) { /* 同 checkBudgetReminder，独立 key 与集合 */ }
```

- 与 5h 提醒同构：周预算 >0 且周 tokens ≥80% → 通知一次（记 `window.start` 防重）；检测到周窗口切换且旧窗曾提醒 → 可选「本周额度已恢复」（复用 `budgetRestoreEnabled` 开关，文案区分 5h/周）。
- 通知文案新增 `ClaudeNotifier.notifyWeeklyBudget(percent:windowEnd:)`（与 `notifyBudget` 并列）。

### 4.4 倒计时格式化（跨度可能到「天」）

既有 `ClaudeFormat.countdown(_:)` 面向 5h（输出 `2h15m`）。周窗口可到数天，扩展格式化：≥24h 显示 `N天Mh`（如 `3天4h`），<24h 沿用既有 `HhMm`，<1h 显示 `Mm`。新增或改造 `ClaudeFormat.countdownLong(_:)` 供周行使用，5h 行不动。

## 5. 本地化词条（`Localizable.xcstrings`，`claudecode.*`）

新增（en / zh-Hans 双语，紧凑单行风格）：

| key | zh-Hans | en |
|---|---|---|
| `claudecode.menu.quotaWeek %@ %@ %@` | 本周：已用 %@ ≈ %@ · %@ 后重置 | Week: %@ ≈ %@ · resets in %@ |
| `claudecode.menu.noWeekWindow` | 本周暂无用量 | No usage this week |
| `claudecode.settings.notify.weeklyBudget` | 周额度预算（k tokens） | Weekly budget (k tokens) |
| `claudecode.settings.notify.weeklyFixed` | 按固定重置时间对齐 | Align to fixed weekly reset |
| `claudecode.settings.notify.weeklyWeekday` | 重置星期 | Reset weekday |
| `claudecode.settings.notify.weeklyHour` | 重置小时 | Reset hour |
| `claudecode.settings.notify.weeklyHint` | 对照 Claude /usage 的周重置时间填写；留空按近 7 天滚动估算 | Match the weekly reset shown in Claude /usage; leave off for a rolling 7-day estimate |
| `claudecode.usage.weekCard.title` | 本周窗口 | Weekly window |
| `claudecode.usage.weekCard.rolling` | 近 7 天滚动 | Rolling 7 days |
| `claudecode.usage.weekCard.fixed %@` | 固定重置：%@ | Fixed reset: %@ |
| `claudecode.usage.weekFootnote %@ %@` | 本周合计（近 7 天）：%@ ≈ %@（估算） | This week (7 days): %@ ≈ %@ (est.) |

既有 `claudecode.menu.quota %@ %@ %@` 的 zh 文案由「额度：已用 …」微调为「5 小时：已用 …」以与周行并列（en 同理加 `5h:` 前缀）。若不想动既有 key，可保留旧 key 语义、仅在菜单里给两行分别取词——实现者二选一，保持 catalog 合法。

## 6. 验收标准

1. 菜单「用量报表…」副标题稳定显示两行：5 小时窗口 + 本周窗口，各含「已用 · 估算花费 · 倒计时」；无对应窗口时各自降级文案，互不影响。
2. 中心窗口「用量」页出现两张窗口卡片（5h / 本周），倒计时随时间推进；切到「固定重置」口径后卡片起止与倒计时按锚点变化，右上角标注口径。
3. 设置「通知」节可设周预算并触发一次 80% 周提醒（不重复）；固定锚点选择器改动后菜单与报表即时反映。
4. 周窗口与 5h 窗口共用同一次后台扫描，菜单打开无卡顿（沿用内存缓存，无同步磁盘 IO）。
5. 5h 窗口的既有数值与重构前逐一致（回归：`lastActiveBlock(span:5h)` == 原 `activeWindow`）。
6. 费用/重置均标「估算」；解析仍全程容错，字段缺失不 crash。
