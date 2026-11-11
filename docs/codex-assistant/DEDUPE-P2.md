# Claude / Codex 两套实现去重 · 第三步（#164：中心窗口、TerminalLauncher、格式化…）· 技术设计

> issue #164：#109 第二步（`DEDUPE.md`）§5.3 列出、按 D8 拍板另开的 P2。状态：**待拍板**（§7 D1–D10）。
> 基线：main `a4833c8`（#171–#175 之后）。下文路径都相对 `mac/Sources/`，行号以这个提交为准；issue 里的数字以 §1.1 重新量的为准。
> 口径、写法照 `DEDUPE.md`：共用层放 Core、纯 Foundation 的部分进 `BaoboxTests`、模块留差异、对外名字尽量不变。
> 相关：`DEDUPE.md` §1.1（量化口径）、§4（已抽出的 `Core/CLISession` / `EventFile` / `QuickSwitch`）、§5.3；`DESIGN.md` §9.1；
> `../claude-code-assistant/TECH_DESIGN.md` §3.1、`NOTIFY_JUMP.md` §3；`Modules/ClaudeCode/CORE_API.md` §1。

## 0. 一页看懂

**现在**：#109 第二步之后，Claude Code 助手（`Modules/ClaudeCode/`）与 Codex 助手（`Modules/AITools/`）之间还剩 issue 列的九类重复。
最要紧的是 issue 的两条验收：`TerminalLauncher` 定义在 `ClaudeCode/ClaudeEnv.swift`，AITools 和 `Core/TerminalFocus.swift` 都反向调它
（Codex 的续接脚本也写进 `Baobox/ClaudeCode/launch/`）；两个中心窗口各有一份会话页。重新量过（§1.1）：中心窗口按顺序相同的 420 行里，
会话页只占 86 行，**用量页与调用统计占 246 行（59%）**。

**九类的结论**（第二列是 issue 表里的一行）：

| # | 重复 | 结论 | 抽到哪 | PR |
|---|---|---|---|---|
| 1 | 中心窗口 · 会话页 | 做（验收） | `Core/CLICenter/CLISessionsPage.swift`；第二行、续接、复制命令走面板同一个数据源（改名 `CLISessionSource`） | PR3 |
| 1 | 中心窗口 · 用量页 + 调用统计 | 做（抽部件） | `Core/CLICenter/CLIUsageViews.swift`；卡片组合、列、Claude 的周脚注留模块 | PR5 |
| 1 | 中心窗口 · 窗口外壳 | 不做 | 各 30 行，与设置 / 手机互传 / 听写历史是同一种样板（D10） | — |
| 2 | `ClaudeFormat` / `AIToolsFormat` | 做 | `Core/CLIFormat.swift`：`CLIFormat<Localization>`，两个旧名字变 typealias（调用点一行不改），`countdownLong` 的文案 key 各留各的 | PR2 |
| 3 | 菜单多行标题 | 做 | `ClosureMenuItem.multiLineTitle(_:subtitles:)`（`Core/ClosureMenuItem.swift`） | PR2 |
| 4 | 单引号转义 | 做 | `Core/Shell.swift` 的 `Shell.quote`；CLI 三份 + 范围外两份（D3） | PR1 |
| 5 | `TerminalLauncher` 在 ClaudeCode | 做（验收） | 通用部分**留名**搬进 `Core/Terminal/TerminalLauncher.swift`；Claude 专有部分改名 `ClaudeTerminal` 留在模块；脚本改写到 `Baobox/Terminal/launch/`（D2） | PR1 |
| 6 | 会话目录遍历 | 做 6 处，留 1 处 | `CLISessionFiles`；`ClaudeUsageCollector` 那处不改（差分测试钉着它的口径） | PR6 |
| 7 | `ClaudeFileIndex` 外壳 | 做 | 从会话索引抽出 `CLICacheFile`（`Core/CLISession/`）两边共用，文件索引顺带补上合并刷新 | PR6 |
| 8 | 用量 Store 外壳 | 做 | `Core/CLIUsage/CLIUsageStore.swift`：泛型基类 + `CLIUsageSource`，两个 Store 变非泛型子类 | PR4 |
| 9 | 设置页 | 只做一小块 | 版本检查（npm 最新版 + 本地 `--version`）→ `Core/CLIVersion.swift`，星期名进 `CLIFormat`；各节视图不共用 | PR2 |

**分 6 个 PR**（§5）：PR1 `TerminalLauncher` 进 Core → PR2 小件 → PR3 会话页 → PR4 用量 Store → PR5 用量页部件 → PR6 遍历与最近文件索引。
**PR1 + PR3 完成 issue 的两条验收**；PR2、PR4 是小件与刷新规则统一（PR4 的行为变化看 D6）；PR5、PR6 与 PR2 里的设置页部分按 D7–D9 决定做不做。

**行为变化**（§3，都要你点头）：续接脚本换目录、旧目录清掉（D2）；Codex 中心窗口的会话行改成 Claude 的样子，Claude 从中心窗口续接
改成先切到正在跑的终端（D4）；Codex 的用量刷新补上 Claude 已有的合并请求与节流补刷（D6）；最近文件索引补上会话索引 PR4 修过的三处（D8）。
其余一律行为不变，用单测、差分与逐像素渲染探针证明（§4）。

术语：**数据源（Source）**= 会话「第二行写什么、怎么续接、复制什么命令」这几件两边不同的事（#109 PR3 起面板在用，这次中心窗口也用）；
**部件** = 抽出来的小视图 / 小函数，由模块拼起来（同 `DEDUPE.md` D1 对面板的取舍）；**用量来源（Usage Source）**= 用量 Store 里两边不同的
「日志怎么收成条目、报表怎么排、调用统计怎么算」。

## 1. 现状

### 1.1 量化

口径同 `DEDUPE.md` §1.1：去掉所有空白后逐行比，空行不算、注释算。**两边都出现的不同行** = 两份各自去重后的交集（issue 里的数就是这个）；
**按顺序对得上的相同行** = `difflib`（`autojunk=False`）最长匹配块的总行数；**连续 ≥ 3 行的相同段** = 其中 ≥ 3 行的块之和。
脚本沿用 #109 设计时的 `dup.py` / `alt.py`，在 `5a6ef26` 上复现得出 issue 的 248 / 420 / 98 / 164，再在 `a4833c8` 上重量。

| 对比 | 总行数 / 非空行 | 两边都出现的不同行 | 按顺序对得上的相同行 | 连续 ≥ 3 行 | issue 里写的 |
|---|---|---|---|---|---|
| 中心窗口 `ClaudeCodeCenterWindow.swift` / `AIToolsCenterWindow.swift` | 866 / 783 · 704 / 627 | 248 | 420 | 367 | 248 / 420（两个文件自 #109 以来没动过） |
| ├ 格式化（Claude :11–64 / Codex :10–63） | 54 / 47 · 54 / 47 | 34 | 44 | 43 | 「只差 `countdownLong` 的 key」，属实 |
| ├ 窗口外壳（卡片、Tab、控制器、根视图） | 84 / 67 · 76 / 60 | 29 | 40 | 31 | — |
| ├ 会话页（Claude :151–327 / Codex :165–325） | 177 / 162 · 161 / 147 | 59 | 86 | 60 | — |
| ├ 用量页（:329–603 / :327–586） | 275 / 255 · 260 / 238 | 103 | 152 | 138 | — |
| └ 调用统计（:605–725 / :588–704） | 121 / 112 · 117 / 108 | 52 | 94 | 90 | — |
| 用量 Store `ClaudeUsage.swift` / `CodexUsage.swift` | 406 / 362 · 453 / 397 | 89 | 136 | 70 | 98 / 连续约 74 |
| 设置页 `ClaudeCodeSettingsView.swift` / `AIToolsSettingsView.swift` | 1491 / 1367 · 673 / 616 | 164 | 253 | 200（最长一段 29 行） | 164 |
| 菜单多行标题 | 16 · 16 | — | 16（逐行相同） | 16 | 逐行相同，行号已移（§1.5） |

### 1.2 类 1 · 中心窗口逐段对比

| 段 | Claude `ClaudeCodeCenterWindow.swift` | Codex `AIToolsCenterWindow.swift` | 判定 | 去向 |
|---|---|---|---|---|
| 格式化 | :14–64 | :13–63 | 只差 `countdownLong` 的文案 key（:49 / :48） | 类 2 |
| 续接命令 / 单引号 | —（在 `ClaudeEnv`） | :66–79 `CodexResumeCommand`、:81–86 `CodexEnv.shellQuote` | 命令是真差异；单引号属类 4 | 留模块 / 类 4 |
| 卡片修饰 `centerCard()` | :69–75 | :90–96 | 完全相同 | 用量页部件 |
| Tab 枚举 + 选中态 | :80–92（三页，多审计） | :100–110（两页） | 同构 | 留模块 |
| 窗口控制器 | :97–126 | :115–144 | 只差标题 key、根视图、刷新哪两个单例 | 留模块（D10） |
| 根视图 | :130–149 | :148–163 | 同构 | 留模块 |
| 会话页：搜索栏 + 过滤 + 列表 | :153–201 | :167–214 | 相同（去首尾空格、标题 / 项目名；Claude 多斑马纹 :197） | `CLISessionsPage` |
| 会话行：布局 | :211–269：标题 + 会话行方案第二行；悬停时右侧四个图标按钮；右键菜单带图标 | :222–268：标题 + 「项目 · 时间」三个 `Text`；悬停时**行下方**多一排带字按钮（行高跟着变）；右键菜单无图标 | 无意分叉 | 统一成 Claude 的（D4） |
| 会话行：续接 | :271–273 `TerminalLauncher.resume`：总开新窗口 | :270–273 `codex resume`：总开新窗口 | 命令是真差异；Claude 没跟上面板的「先切到正在跑的」（#109 B3） | 数据源 `resume`（Claude 改为同面板，D4） |
| 会话行：复制命令 | :275–279 | :275–279 | 骨架相同，命令不同 | 数据源 `resumeCommand` |
| 会话行：导出 | :281–299：存盘框限定 .md，写盘失败不说原因 | :281–296：不限类型，写盘失败带 `localizedDescription` | 无意分叉 | 共用，取两边好的一半（D4） |
| 会话行：删除确认 | :301–310 | :298–307 | 相同（key 不同） | 共用 |
| 导出文件名 | :313–318（兜底 `session`） | :309–316（兜底 `codex-session`） | 逻辑等价，兜底名不同 | `CLISessionMarkdown.exportFileName`，兜底名由模块传 |
| 弹窗 | :320–326 | :318–324 | 相同 | 共用 |
| 用量页：维度枚举 | :342–361 | :339–358 | 同构（label key 不同） | `CLIUsageDimension` + 模块给文案 |
| 用量页：5 小时卡 | :386–426（指标、预算条内联） | :378–403 + :432–455（抽成 `metricsRow` / `budgetBar`） | 相同（标题 key 不同） | 部件 |
| 用量页：周卡 | :440–479 | :407–430 | 相同 | 部件 |
| 用量页：指标 `metric` | :428–436 | :457–465 | 完全相同 | 部件 |
| 用量页：锚点描述 | :482–489 | :468–475 | 完全相同 | `CLIFormat.weekAnchor` |
| 用量页：明细卡 + 维度切换 | :493–531 | :479–517 | 相同 | 部件 |
| 用量页：明细表 | :533–582：5 列（输入 / 输出 / 缓存写 / 缓存读 / 费用），宽 80 | :519–566：4 列（输入 / 缓存输入 / 输出 / 费用），宽 90 | 骨架相同，**列是真差异** | `CLIUsageBucketTable`，列由模块给 |
| 用量页：合计 `summed` | :584–595（四项 token） | :568–578（三项；缓存写恒为 0） | 等价（加 0 不改结果，费用相加顺序相同） | `CLIUsageTotals.sum(of:)` |
| 用量页：周脚注（滚动口径） | :369–373 | — | Claude 独有 | 留 Claude |
| 调用统计 | :609–725（Skill / MCP / 内置） | :591–704（内置 / MCP） | 分组视图完全相同，组合与顺序不同；两个 `…MCPServerStat` 结构体相同 | 部件 + 模块组合 |
| 审计页 | :729–866 | — | Claude 独有 | 不动 |

### 1.3 类 5 · `TerminalLauncher`（`ClaudeEnv.swift:370–673`）

| 成员 | 行 | 性质 | 去向 |
|---|---|---|---|
| `run(command:in:)` | :382–422 | **通用**：写一次性 `.command`（目录 `ClaudeEnv.ensureSupportDir()/launch`，:383）→ 按偏好终端的启动方式打开 | Core `TerminalLauncher` |
| `cleanupOldLaunchers(in:)` | :657–672 | 通用：超过 20 个删最旧的 | Core（纯逻辑进 `TerminalLaunchScript`） |
| `selectTab(bundleID:ttyPath:)` | :553–559 | 通用：iTerm2 / 系统终端按 tty 选标签页；`Core/TerminalFocus.swift:47` 调它 | Core |
| `tabSelectScript(bundleID:ttyPath:)` | :574–610 | 通用 | Core（private） |
| `runForOutput(_:_:)` | :643–654 | 通用：同步跑小命令取 stdout | `Shell.output`（Core） |
| `resume(sessionID:in:binary:)` | :425–429 | **Claude**：`claude --resume <id>` | `ClaudeTerminal` |
| `resumeCommandString(sessionID:in:)` | :432–436 | Claude | `ClaudeTerminal` |
| `focusRunningSession(…)` | :448–483 | Claude：位置优先 → 确认 tty 上有 claude（`ClaudeRunningSession`）→ 按进程找 | `ClaudeTerminal` |
| `RunningSessionProcess`、`findRunningSession`、`focusTerminalWindow` | :486–551 | Claude：认 claude 进程（`--resume <id>`、项目里最新的裸 `claude`），沿父进程找宿主终端 | `ClaudeTerminal`（private） |
| `terminalApp(inCommand:)`、`terminalBundleIDs`、`processTable`、`workingDirectory(ofPID:)`、`normalizedPath` | :561–571、:613–640 | 本身通用，但只有按进程找用 | `ClaudeTerminal`（private）；哪天 Codex 也要「切到正在跑的会话」再挪进 Core |

调用方：

| 被调 | 调用方 |
|---|---|
| `TerminalLauncher.run` | `AIToolsQuickSwitchPanel.swift:32`、`AIToolsCenterWindow.swift:271`（**反向依赖**）；`NetCapture/NetCaptureWindow.swift:511`（模块暂缓、不参与编译，名字与签名要保住） |
| `TerminalLauncher.selectTab` | `Core/TerminalFocus.swift:47`（**Core → 模块**） |
| `resume` / `resumeCommandString` | `ClaudeQuickSwitchPanel.swift:50/56`、`ClaudeCodeCenterWindow.swift:272/276` |
| `focusRunningSession` | `ClaudeQuickSwitchPanel.swift:44`、`ClaudeLiveStatus.swift:387` |

顺带的毛病：只装了 Codex 的用户续接一次，`ClaudeEnv.ensureSupportDir()` 也会建出 `Baobox/ClaudeCode/` 目录。

### 1.4 其余六类

**类 2 格式化**：`ClaudeFormat`（`ClaudeCodeCenterWindow.swift:14–64`）/ `AIToolsFormat`（`AIToolsCenterWindow.swift:13–63`）六个函数逐行相同，
只有 `countdownLong` 的 key 不同（`claudecode.usage.countdown.dayHour %lld %lld` / `aitools.usage.countdown.dayHour %lld %lld`，译文写法也略不同，
渲染一样）—— 这是**有意的差别**（key 按模块分命名空间），保留。调用（不算注释）：Claude 35 处（中心窗口、菜单、设置、面板、会话行方案），Codex 21 处。

**类 3 菜单多行标题**：`ClaudeCodeTool.swift:176–192` / `AIToolsTool.swift:149–165` 逐行相同，各一处调用（用量报表项的两行副标题）。

**类 4 单引号转义**：五份编译中的逐字副本，外加一份不编译的：

| 位置 | 名字 | 调用 |
|---|---|---|
| `ClaudeEnv.swift:310–313` | `ClaudeEnv.shellSingleQuote` | `ClaudeEnv.swift:104`（`--version`）、:389 / :427 / :434–435（续接脚本与命令） |
| `AIToolsNotify.swift:287–290` | `CodexNotify.shellSingleQuote`（nonisolated） | :266–267（notify 脚本里的事件文件路径） |
| `AIToolsCenterWindow.swift:81–86` | `extension CodexEnv { shellQuote }` | :70 / :77（`CodexResumeCommand`）、`CodexEnv.swift:131`（`--version`） |
| `LiveTranslate/LiveTranslateVoiceOutput.swift:501–504` | `quoted`（private） | :481–488（管理员权限装 / 卸虚拟麦克风驱动） |
| `Clipboard/TextTools/CurlCommand.swift:199–202` | `CurlCommand.shellQuote` | 同文件 7 处、`URLRecognizer.swift:46` |
| `NetCapture/NetCaptureEnv.swift:242–245` | `shellSingleQuote` | 模块不参与编译 |

**类 6 会话目录遍历**（issue 说两边各 5 遍，现在的情况）：

| # | 遍历 | 位置 | 写法 | 去向 |
|---|---|---|---|---|
| C1 | Claude 会话索引 | `Core/CLISession/CLISessionFiles.swift:9–39` | 已共用（#167） | — |
| C2 | 今日改动审计 | `ClaudeSessionIndex.swift:290–308` | 两层手写；取不到修改时间时照读 | 改用 `jsonlInSubdirectories` |
| C3 | 最近文件索引 | `ClaudeFileIndex.swift:307–330` | 两层手写；与 C1 逐项相同（取不到记 1970 / 0） | 改用 `jsonlInSubdirectories`（零差别） |
| C4 | 用量收集器（#174 新增） | `ClaudeUsageCollector.swift:75–90` | 两层手写；**区分「取不到修改时间 / 大小」决定缓不缓存** | **不改** |
| C5 | 调用统计 | `ClaudeUsage.swift:310–327` | 两层手写；取不到修改时间时照读 | 改用 `jsonlInSubdirectories` |
| X1 | Codex 会话索引 | `CLISessionFiles.swift:42–62` | 已共用 | — |
| X2 | 清理旧会话 | `CLISessionFiles.swift:66–89` | 已共用 | — |
| X3 | 用量 | `CodexUsage.swift:245–261` | 递归手写；取不到修改时间当「现在」 | 改用 `jsonlRecursively` |
| X4 | 调用统计 | `CodexUsage.swift:388–397` | 递归手写；取不到修改时间时照读 | 改用 `jsonlRecursively` |
| X5 | 磁盘统计 | `CodexEnv.swift:151–167` | 递归手写；只算 .jsonl 普通文件 | 改用 `jsonlRecursively`（零差别） |

**类 7 `ClaudeFileIndex` 外壳**（对照会话索引 #170 之后的 `CLISessionIndex.swift`）：

| 段 | `ClaudeFileIndex.swift` | `CLISessionIndex.swift` | 差别 |
|---|---|---|---|
| 刷新防重入 | :216–234：进行中再调直接丢 | :85–118：记一笔，结束后补一轮（补扫那轮不发布） | 文件索引没跟上 `DEDUPE.md` §5.2 C4 |
| 防抖落盘 | :246–255（1 秒） | :184–194 | 相同 |
| 写盘 | :257–266：`DispatchQueue.global` **并发**队列 | :197–203 + :216–228：串行写盘队列 | 文件索引两次写可能乱序（旧快照盖掉新的） |
| flush | :238–242：取消防抖后**异步**写 | :172–180：同步写 | 文件索引没跟上 C6（PR4 落地第 8 条写明留给这一条） |
| 读缓存 | :268–275（`init` 里同步读） | :205–212 | 相同 |
| 扫描 | :303–360：复用 / **只读追加部分** / 全量 | `CLISessionScanner`：复用 / 全量 | 真差异，留在文件索引 |

另外它的「包含内部文件」开关（设置里拨动会 `refresh()`）在启动那轮全量扫描期间拨动会被吞掉，要等下次刷新才生效 —— 就是上面「请求被吞」的一个实例。

**类 8 用量 Store 外壳**：

| 段 | `ClaudeUsageStore`（`ClaudeUsage.swift:83–269`） | `CodexUsageStore`（`CodexUsage.swift:97–233`） | 判定 |
|---|---|---|---|
| 四个 `@Published` | :87–91（5 小时窗口叫 `currentWindow`） | :101–105（叫 `fiveHourWindow`） | 同构，名字不同 |
| 设置键 | :94–102（`claudecode.*`） | :108–116（`codex.*`） | 真差异（键名不动） |
| 定时器 `startAutoRefresh` / `stopAutoRefresh` | :122–139（停的时候顺带取消补刷） | :130–145 | 相同 |
| 事件触发的节流刷新 | :143–168 `refreshThrottledFromHook`：`CLIUsageRefreshThrottle`，60 秒内来的在窗口末尾补刷一次 | :148–152 `refreshThrottledFromEvent`：60 秒内来的直接丢 | **#174 之后分叉**（`CLIUsageRefreshThrottle.swift:7` 写明留到这一步） |
| `refresh()` | :177–208：进行中再来的合并成结束后补一轮 | :158–180：直接丢 | **#174 之后分叉** |
| 周窗口 | 共用算法 | :359–362：近 180h 没有用量返回 nil | **有意的差别**（`DESIGN.md` §7 记着），保留 |
| `weeklyAnchorConfig()` | :211–218 | :183–190 | 相同（键不同） |
| `report(days:)` / `invocationStats(days:)` 外壳 | :221–240 | :193–211 | 相同 |
| 80% 提醒 | :244–268：两种提醒 + 「额度已恢复」 | :216–232：只有提醒 | 真差异（发什么留模块） |
| 解析、定价、报表排序、调用统计 | :18–44、:273–405 | :24–53、:237–452 | 真差异，留模块 |

**类 9 设置页**：连续相同的 200 行分布在整页容器（状态卡、分段选择、未安装提示、读版本号，约 55 行）、MCP 节（约 50 行）、
维护节（约 67 行）、预算 / 周窗口（约 28 行）。逐段看：

| 段 | Claude | Codex | 判定 |
|---|---|---|---|
| 查 npm 最新版 `checkUpdate` | `ClaudeCodeSettingsView.swift:1225–1257` | `AIToolsSettingsView.swift:640–672` | 29 行逐行相同，只差包名 |
| 本地版本 `cliVersion()` | `ClaudeEnv.swift:99–119` | `CodexEnv.swift:126–146` | 14 行逐行相同（issue 没列） |
| 星期名 `weekdayName` | :149–156 | :357–363 | 完全相同；两个用量页的锚点描述（§1.2）是第三、四份 |
| 维护节其余（磁盘、清理） | :1132–1224 | :544–639 | 磁盘口径不同（`~/.claude` 分项 vs `sessions/` 一行）；清理按钮文案一个带天数一个不带 |
| 通知 / 预算 / 周窗口 | :124–267（周窗口放在通知节） | :285–390（单独一个用量节） | 结构不同，键不同 |
| MCP 节 | :949–1128（JSON：stdio + http） | :394–540（TOML：command / args） | 配置格式与能力不同 |
| 整页容器 | :14–120（状态卡多一项 hooks） | :16–108 | 同一种写法，内容不同 |

### 1.5 与 issue 描述的出入

1. 中心窗口的 248 / 420 没变，但**会话页只占按顺序相同的 86 行**；用量页 152 + 调用统计 94 = 246 行（59%），格式化 44、窗口外壳 40。
   会话页（issue 的验收）和格式化都做完，按顺序相同的行还剩约 290 行（七成），大头在用量页 —— 所以建议用量页一起做（D7）。
2. 菜单多行标题的行号移了：现在是 `ClaudeCodeTool.swift:177–192` / `AIToolsTool.swift:150–165`（#174 在 `submenuItems()` 里加了注释），仍逐行相同。
3. 单引号转义：`AIToolsNotify.swift:387` 现在是 :288（#166 把事件监听搬进 Core，文件从 390 行缩到 291 行）；另有两份编译中的逐字副本不在 CLI 模块
   （实时翻译、剪贴板 curl），NetCapture 一份（不编译）。
4. `TerminalLauncher` 自 #174 起多了 `focusRunningSession`（点通知与面板续接共用），现在约 300 行，其中通用的约 120 行；反向依赖照旧
   （AITools 两处 + `Core/TerminalFocus.swift:47`）；不参与编译的 NetCapture 也调 `TerminalLauncher.run`。
5. 会话目录遍历：现在 Claude 是 1 处已共用 + 4 处手写，Codex 2 处已共用 + 3 处手写（§1.4 类 6）；Claude 的用量收集器是 #174 新增的，有意不并。
6. `ClaudeFileIndex` 外壳不只是「同款」：会话索引在 #170 修过的三处（请求被吞、退出异步落盘、并发写盘）它都还有。
7. 用量 Store：98 → 89 个相同的不同行；而且 #174 之后两边不只是重复，**行为也分叉了**（Claude 合并刷新请求 + 节流补刷，Codex 都没有）。
8. 设置页的 164 多是 SwiftUI 短句（`.formStyle(.grouped)` 这类）；语义一样、能干净抽出来的只有版本检查与星期名（§2.4 类 9）。
9. issue 没列、这次量到的，都并进对应的 PR：`cliVersion()` 子进程 14 行相同（PR2）；星期名四份（PR2）；`ClaudeMCPServerStat` / `CodexMCPServerStat`
   两个一样的结构体、明细表合计两份（PR5）。

### 1.6 顺带查到的（不在 #164 的九类里）

- 两个中心窗口（还有会议窗口、听写历史）建窗口没用 `DesktopSpaceWindow`：从全屏 App 里打开会叠进那个全屏空间、点回去也一直盖着
  （`mac/CLAUDE.md`「普通窗口与全屏空间」，设置窗口在 #75 修过）。属全 App 的窗口约定，建议另开 issue（D10）。
- 隐私文档（`docs/manual/privacy-and-data.md` 与英文版）写「Claude Code / Codex 助手**不存**」，实际支持目录里有会话索引缓存（含会话标题、项目路径）、
  hooks / notify 事件、最近文件索引、续接脚本。PR1 动脚本位置时顺手改（D2）。
- `tokens` 在 999,950–999,999 之间显示「1000.0k」（先判 ≥ 1000，再按一位小数四舍五入）。一直如此，不改；PR2 的单测把它钉住，想改另说。
- 两个面板控制器的 `handleKey` 还有 14 行相同：#172 有意把按键含义留在各自控制器（`DEDUPE.md` §4.3），不动。

## 2. 设计

### 2.1 目标与非目标

目标：

1. 两个模块之间、Core → 模块之间没有代码依赖（验收 1，PR1）。
2. 中心窗口会话页只剩一份实现（验收 2，PR3）；用量页的部件、调用统计的分组只剩一份（PR5）。
3. 格式化、多行标题、单引号、版本检查、用量 Store 的定时器 / 合并刷新 / 节流补刷 / 报表外壳、派生缓存文件的读写各只剩一份；会话文件只在 `CLISessionFiles` 里列。
4. 纯逻辑进 `BaoboxTests`：`Core/Shell.swift`、`Core/Terminal/TerminalLaunchScript.swift`、`Core/CLIFormat.swift`、`Core/CLIVersion.swift`，
   以及 `Core/CLISession/`、`Core/CLIUsage/` 里新增的文件（这两个目录本来就整目录进测试）。
5. 每个 PR 单独可合并、能编译；除 §3 列的变化外用户看不出；设置键、文案 key、缓存文件名与格式不变；模块对外名字尽量不变
   （`ClaudeFormat` / `AIToolsFormat` 变 typealias；`ClaudeUsageStore.shared` / `CodexUsageStore.shared` 与设置键常量照旧；改名的只有 D1 表里列的）。

非目标：

- 不做「通用中心窗口」：审计页、Claude 的周脚注、两边的列、卡片顺序留在模块（同 `DEDUPE.md` D1 对面板的取舍）。
- 不统一两边文案的措辞（D5）；不合并两边的日志解析；不改 `ClaudeUsageCollector`。
- 不碰 #172 有意留在模块里的面板控制器；不处理窗口的全屏空间约定（D10）；不开 Swift 6 严格并发。
- NetCapture 不动（暂缓、不编译）；只保证 `TerminalLauncher.run(command:in:)` 的名字与签名不变，恢复时照样能编。

### 2.2 目录与新名字

```
Core/Terminal/                      （新目录）
  TerminalLauncher.swift            run(command:in:)、selectTab(bundleID:ttyPath:)              —— AppKit，主线程
  TerminalLaunchScript.swift        脚本内容、只留最近 20 个                                    —— 纯 Foundation，进测试
  TerminalAppPreference.swift       （从 Core/ 挪进来，内容不动）
  TerminalFocus.swift               （从 Core/ 挪进来，selectTab 改成同目录调用）
Core/Shell.swift                    Shell.quote（单引号）、Shell.output（跑小命令取 stdout）     —— 纯 Foundation，进测试
Core/CLIFormat.swift                CLIFormat<Localization>、CLIFormatLocalization              —— 纯 Foundation，进测试
Core/CLIVersion.swift               本地 --version、npm 最新版                                  —— 纯 Foundation，进测试
Core/ClosureMenuItem.swift          + multiLineTitle(_:subtitles:)
Core/CLISession/
  CLISessionSource.swift            原 Core/QuickSwitch/QuickSwitchSessionSource.swift，改名后挪来（面板与中心窗口共用）
  CLICacheFile.swift                派生缓存文件：同步读、1 秒防抖写、串行写盘、同步 flush（从 CLISessionIndex 抽出）
  CLISessionMarkdown.swift          + exportFileName(title:fallback:)
Core/CLIUsage/
  CLIUsageStore.swift               CLIUsageStore<Source>、CLIUsageSource、CLIUsageSettings
  CLIUsageModels.swift              + CLIUsageMCPServerStat、CLIUsageTotals.sum(of:)、CLIUsageDimension
Core/CLICenter/                     （新目录，SwiftUI，不进测试）
  CLISessionsPage.swift             会话页 + 行 + 动作、CLISessionsPageStrings
  CLIUsageViews.swift               cliCenterCard()、指标、预算条、周标注、明细表、调用统计分组

Modules/ClaudeCode/ClaudeTerminal.swift      原 TerminalLauncher 里 Claude 专有的部分（resume、resumeCommandString、focusRunningSession + 按进程找）
Modules/ClaudeCode/ClaudeSessionSource.swift 原 ClaudeQuickSwitchSource（从面板文件挪出、改名）
Modules/AITools/CodexSessionSource.swift     原 CodexQuickSwitchSource（同上），CodexResumeCommand 跟过来
```

改名汇总（D1）：`QuickSwitchSessionSource` → `CLISessionSource`；`ClaudeQuickSwitchSource` / `CodexQuickSwitchSource` → `ClaudeSessionSource` / `CodexSessionSource`；
`TerminalLauncher.resume / resumeCommandString / focusRunningSession` → `ClaudeTerminal.` 同名方法；`ClaudeUsageStore.currentWindow` → `fiveHourWindow`、
`refreshThrottledFromHook()` → `refreshThrottledFromEvent()`（与 Codex 同名，挪到基类）。`TerminalLauncher`、`ClaudeFormat`、`AIToolsFormat`、两个 Store 的类名不变。

### 2.3 依赖规则

1. Core 里的新代码不引用模块类型（`ClaudeEnv`、`CodexEnv`、`SessionRowFormatStore`…），不用模块的文案 key；`common.ok` / `common.cancel` 这类全 App 共用的 key
   只在不进测试的视图（`Core/CLICenter/`）里用。
2. 进 `BaoboxTests` 的文件只 import Foundation（`CLIUsageStore`、`CLICacheFile` 另用 Combine / Dispatch），不调 `L()`、`NotifyCenter`、`StorageWriteFailure`、
   `UserDefaults` —— 设置、文案、语言都由模块读好传进来（同 `DEDUPE.md` §3.2）。
3. 两个模块之间不新增依赖：数据源、续接命令、文案、列定义、设置键都在各自模块。
4. **共用视图的文案由模块传**：SwiftUI 里显示的传 `LocalizedStringKey`，带参数的传返回 `Text` 的闭包，AppKit 弹窗用的传 `L()` 取好的 `String`
   （同 `Core/QuickSwitch/QuickSwitchViews.swift`、`CLISessionMarkdown.Headings`）。`Localizable.xcstrings` 一条不动（D5）。
5. 后台闭包要捕获泛型参数元类型的协议（`CLIUsageSource`）声明 `Sendable`，同 #167 落地时 `CLISessionFormat` 的处理（Xcode 26 / Swift 6.2 下不告警）。

### 2.4 逐类设计

签名是设计稿，实现照搬现有代码。几处泛型写法已在 scratchpad 连同真的 `Core/CLISession/`、`Core/CLIUsage/` 源码用 `swiftc -typecheck` 核过
（Swift 6.0.3，`-swift-version 5`，macOS 14 目标，零告警）：`CLIFormat<Localization>` + typealias 调静态方法；`CLISessionsPage` 用
`@ObservedObject CLISessionIndex<Format>` 接子类单例、`where Source.Session == Format.Summary`；`CLIUsageStore<Source>` 子类覆盖钩子、
`CLIUsageSource` 协议扩展给周窗口默认实现再由 Codex 覆盖；`CLICacheFile<Snapshot>`。仓库里不留这些文件；落地时照 `DEDUPE.md` §4 再连模块桩代码核一遍。

#### 类 5 · `TerminalLauncher` 进 Core（PR1，验收 1）

```swift
// Core/Terminal/TerminalLauncher.swift
/// 在用户偏好的终端里跑一条命令（续接 CLI 会话等）。终端解析见同目录的 `TerminalAppChoice`。触碰 NSWorkspace，主线程调用。
@MainActor
enum TerminalLauncher {
    /// 写一次性 `.command`（内容见 `TerminalLaunchScript.contents`）到 `~/Library/Application Support/Baobox/Terminal/launch/`，
    /// 只留最近 20 个，再按偏好终端的启动方式打开（document / binary，与现在逐行相同）。directory 为 nil 或空串时不 cd。
    static func run(command: String, in directory: String?)
    /// 只按 tty 选中 iTerm2 / 系统终端里的窗口与标签页（App 由调用方前台化）；其他终端什么也不做。osascript 在后台跑。
    static func selectTab(bundleID: String, ttyPath: String)
}

// Core/Terminal/TerminalLaunchScript.swift —— 进 BaoboxTests
enum TerminalLaunchScript {
    /// "#!/bin/zsh\n" + （有目录时）"cd '<目录>'\n" + 命令 + "\n"。
    static func contents(command: String, directory: String?) -> String
    /// 目录里超过 keep 个文件时按修改时间删掉最旧的（跳过隐藏项；同原 cleanupOldLaunchers）。
    static func prune(_ directory: URL, keep: Int)
}

// Core/Shell.swift —— 进 BaoboxTests
enum Shell {
    /// 单引号包裹，内部单引号写成 '\''（sh / zsh / bash 通用）。
    static func quote(_ text: String) -> String
    /// 直接起一个可执行文件（不经过 shell），先读完 stdout 再等退出；起不来返回 nil，不看退出码，stderr 丢弃。后台线程调用。
    static func output(_ executable: String, _ arguments: [String]) -> String?
}

// Modules/ClaudeCode/ClaudeTerminal.swift
@MainActor
enum ClaudeTerminal {
    static func resume(sessionID: String, in directory: String, binary: String? = nil)   // → TerminalLauncher.run("<claude> --resume <id>", in:)
    static func resumeCommandString(sessionID: String, in directory: String) -> String
    static func focusRunningSession(sessionID: String, projectPath: String?, location: TerminalLocation?,
                                    confirmRunning: Bool, isNewestInProject: Bool, completion: @escaping (Bool) -> Void)
    // private：RunningSessionProcess、findRunningSession、focusTerminalWindow（切标签页那步改调 TerminalLauncher.selectTab，逐行等价）、
    // terminalApp(inCommand:)、terminalBundleIDs、processTable / workingDirectory（ps、lsof 改用 Shell.output）、normalizedPath
}
```

模块这边：

- `ClaudeEnv.swift`：删 :308–313（`shellSingleQuote`）与 :370–673；`cliVersion` 改用 `Shell.quote`（PR2 再换成 `CLIVersion`）。
- `ClaudeQuickSwitchPanel.swift:44/50/56`、`ClaudeLiveStatus.swift:387`、`ClaudeCodeCenterWindow.swift:272/276`：`TerminalLauncher.` → `ClaudeTerminal.`。
- `ClaudeCodeTool.activate()` 开头（在「未安装」判断之前：只装 Codex 的用户也有这个目录）：后台删 `ClaudeEnv.supportDir/launch/`（D2）。
- AITools：删 `AIToolsCenterWindow.swift:81–86` 与 `AIToolsNotify.swift:287–290`，`CodexResumeCommand`、`CodexEnv.swift:131`、notify 脚本 :266–267 改用 `Shell.quote`；
  `TerminalLauncher.run` 的两处调用一行不改。
- D3 同意的话：`CurlCommand.shellQuote` 与 `LiveTranslateVoiceOutput.quoted` 的调用改成 `Shell.quote`，两个函数删掉。
- `mac/project.yml`：`BaoboxTests.sources` 加 `Sources/Core/Shell.swift`、`Sources/Core/Terminal/TerminalLaunchScript.swift`，注释同步。
- 文档：`CORE_API.md` §1（`TerminalLauncher` 一节改成 `ClaudeTerminal` + 指向 Core）、`TECH_DESIGN.md` §3.1（:115 那条）、`NOTIFY_JUMP.md`（:10 / :35 / :44）、
  `DESIGN.md` §9.1「跨模块依赖（既存）」改成已解决、根 `CLAUDE.md` 的 Core 清单、隐私文档（D2）。

为什么 Claude 专有的部分不用 `extension TerminalLauncher` 留在模块：那样 `TerminalLauncher.resume` 看着像通用 API、Codex 也调得到（会跑 `claude --resume`），
边界又糊了。按进程找终端的几个函数本身是通用的，但只有 Claude 用，按「只有一个使用者就留在使用者那里」（`DEDUPE.md` §3.3 第 2 条同一原则）留在 `ClaudeTerminal`。

- **行为**：脚本内容、权限（0755）、打开方式、只留 20 个都不变；只有脚本目录换了（`Baobox/Terminal/launch/`），旧目录被删（D2）；Codex 用户不再多出 `Baobox/ClaudeCode/`。
- **验证**：单测 `Shell`（引号、空串、换行、非 ASCII、`$` 与反引号原样；把结果交给 `/bin/zsh -c` 与 `/bin/sh -c` 的 `printf %s` 跑一遍，读回与原串逐字节相同；
  `output` 读 stdout、起不来返回 nil）、`TerminalLaunchScript`（有 / 无目录、空串目录、目录带引号；超过 20 个删最旧、不到 20 个不动、隐藏文件不算、目录不存在不崩）；
  差分（§4.2）比脚本文本、续接命令、Codex notify 脚本逐字节；边界检查（§4.3）；真机 1–8。
- **值不值得**：必做（验收）。

#### 类 4 · 单引号转义（PR1）

`Shell.quote` 见上。三份 CLI 副本必换（`TerminalLauncher.run` 进 Core 后本来就不能再调 `ClaudeEnv.shellSingleQuote`）。
剪贴板 curl、实时翻译两份逐字相同，换掉没风险、有单测覆盖，建议一起换；NetCapture 不编译、改了验证不了，不动（D3）。

- **行为**：不变（输出逐字相同）。**值不值得**：做，顺 PR1。

#### 类 2 · 格式化（PR2）

```swift
// Core/CLIFormat.swift —— 进 BaoboxTests
/// 两边只有「≥ 24 小时的倒计时」用各自模块的文案 key，由 Localization 给；语言（相对时间、星期名）也由它给（模块传 L10n.locale）。
protocol CLIFormatLocalization {
    static func dayHour(days: Int, hours: Int) -> String
    static var locale: Locale { get }
}

enum CLIFormat<Localization: CLIFormatLocalization> {
    static func cost(_ value: Double) -> String                     // "$%.2f"
    static func tokens(_ count: Int) -> String                      // ≥ 100 万 "%.1fM"，≥ 1000 "%.1fk"，否则原样
    static func countdown(_ seconds: TimeInterval) -> String        // "2h15m" / "45m"
    static func countdownLong(_ seconds: TimeInterval) -> String    // ≥ 1 天 → Localization.dayHour，否则 countdown
    static func bytes(_ value: Int64) -> String                     // ByteCountFormatter .file
    static func relative(_ date: Date, now: Date = Date()) -> String // RelativeDateTimeFormatter .abbreviated
    static func weekdayName(_ weekday: Int) -> String               // 1 = 周日 … 7 = 周六（standalone）；越界给数字
    static func weekAnchor(weekday: Int, hour: Int) -> String       // 「周三 09:00」
}

// 模块（Claude 为例，放原 ClaudeFormat 的位置；Codex 同形，key 是 aitools.*）
enum ClaudeFormatLocalization: CLIFormatLocalization {
    static func dayHour(days: Int, hours: Int) -> String { L("claudecode.usage.countdown.dayHour \(days) \(hours)") }
    static var locale: Locale { L10n.locale }
}
typealias ClaudeFormat = CLIFormat<ClaudeFormatLocalization>
```

用泛型 + typealias 而不是 `CLIFormat.countdownLong(_:dayHour:)` 加闭包：56 个调用点一行不改，两个旧名字照旧能用，和 `CLIUsageCalculator<Table>` 同一个写法。
星期名顺带收掉四份：两个设置页的 `weekdayName`、两个用量页的 `weekAnchorDescription`（PR5 之前先在原处改调 `weekAnchor`）。

- **行为**：不变。**验证**：单测（各阈值，包括钉住「999,999 → 1000.0k」；倒计时 0 / 59 秒 / 1 小时；`countdownLong` 用假的 Localization 看天数换算；
  `relative` 固定 `now` 与语言；星期名 1…7 与越界；`weekAnchor` 补零）；差分：旧 `ClaudeFormat` / `AIToolsFormat` 与新 typealias 在随机输入上逐字相同，
  `countdownLong` 在探针里挂真的 `Localizable.xcstrings`（中英各一遍）。**值不值得**：做（小、零调用点改动）。

#### 类 3 · 菜单多行标题（PR2）

`Core/ClosureMenuItem.swift` 加 `static func multiLineTitle(_ title: String, subtitles: [String]) -> NSAttributedString`（照搬），两处
`Self.multiLineTitle` 改成 `ClosureMenuItem.multiLineTitle`。注意：带副标题的项不要再给 `hotkeyID` —— 框架的 `showHotkeyIfTagged` 会用「名称 + 快捷键」盖掉
`attributedTitle`（现在两处都没给，写进注释）。

- **行为**：不变。**验证**：编译 + 探针里新旧 `NSAttributedString` `isEqual`。**值不值得**：做（16 行 × 2，顺 PR2）。

#### 类 9 · 设置页（PR2，只做一小块）

```swift
// Core/CLIVersion.swift —— 进 BaoboxTests（网络那半测试里不跑）
enum CLIVersion {
    /// `zsh -lc '<binary>' --version` 的输出（去首尾空白，空 = nil）。走登录 shell 保证 PATH 完整。后台线程调用（同步等子进程）。
    static func local(binary: String) -> String?
    /// npm registry 上的最新版本（`https://registry.npmjs.org/<package>/latest` 的 version，超时 10 秒）；失败 nil，主线程回调。
    static func latestOnNPM(package: String, completion: @escaping (String?) -> Void)
    /// 上面那个请求的解析（测试用）。
    static func parseNPMLatest(_ data: Data) -> String?
}
```

模块：`ClaudeEnv.cliVersion()` / `CodexEnv.cliVersion()` 留成一行转调（调用方不动）；两个 `checkUpdate()` 只剩改状态 + 调 `latestOnNPM`（包名 `@anthropic-ai/claude-code`、
`@openai/codex`）；`weekdayName` 改调 `ClaudeFormat.weekdayName` / `AIToolsFormat.weekdayName`。

**不共用的**：维护节的磁盘 / 清理（磁盘统计口径不同，清理按钮一个带天数一个不带）、通知节与周窗口（放在不同的节、键不同）、MCP 节（JSON stdio + http vs TOML command / args，
添加表单不同）、整页容器（状态卡项目不同）。这些是同一种 SwiftUI 写法填不同的内容，抽成泛型视图要传的 key 与闭包，和省下的行数差不多（D9）。
二进制探测（`findClaudeBinary` / `findCodexBinary`）候选路径、返回类型都不同，剩下的锁 + 缓存约 8 行，也不并。

- **行为**：不变；`--version` 子进程的 stderr 从「接一个没人读的管道」改成丢弃（看不出，免掉 stderr 写满管道卡住的理论可能）。
  `DESIGN.md` §9.3 记着「`cliVersion()` 的子进程没有超时」，共用之后改一处就行，但那是行为变化，这次不加。
- **验证**：单测 `parseNPMLatest`（正常、缺字段、坏 JSON、非对象）、`local`（临时目录里写个打印版本号的可执行脚本、不存在的路径、只输出空白）；真机 9–11。
- **值不值得**：只做这一小块。

#### 类 1 · 中心窗口会话页（PR3，验收 2）

```swift
// Core/CLISession/CLISessionSource.swift —— 原 QuickSwitchSessionSource，签名不变，只改名
@MainActor
protocol CLISessionSource {
    associatedtype Session: CLISessionSummary
    var sessions: [Session] { get }
    func refresh()
    func metadataLine(for session: Session) -> String
    func resume(_ session: Session)
    func resumeCommand(for session: Session) -> String
}

// Core/CLICenter/CLISessionsPage.swift
/// 会话页的文案（各模块用自己的 key）：SwiftUI 里显示的传 key，AppKit 弹窗用的由模块 L() 取好。
struct CLISessionsPageStrings {
    let search, empty, refreshHelp, rowHint, resume, copyCommand, export, delete: LocalizedStringKey
    let exportFailed, deleteConfirmTitle, deleteConfirmMessage, deleteButton: String
    let exportFileFallback: String          // 标题清洗完为空时的文件名："session" / "codex-session"
}

/// 中心窗口「会话」页：搜索（去首尾空格，标题 / 项目名）+ 转圈 + 刷新 + 斑马纹列表。行 = 标题 + 第二行，悬停时右侧浮出四个图标按钮，
/// 双击续接，右键四项。第二行、续接、复制的命令来自数据源（与快速切换面板同一个）；列表、刷新、导出、删除走索引。
struct CLISessionsPage<Format: CLISessionFormat, Source: CLISessionSource>: View where Source.Session == Format.Summary {
    init(index: CLISessionIndex<Format>, source: Source, strings: CLISessionsPageStrings)
}

// Core/CLISession/CLISessionMarkdown.swift 增加（进测试）
static func exportFileName(title: String, fallback: String) -> String   // "/" ":" 换成 "-"、去首尾空白、截 60 字；空则 fallback
```

- 页面里留一个每次构造都不同的 `renderToken`（同 #172 的 `QuickSwitchSessionList`）：第二行依赖数据源背后的状态（Claude 的会话行方案、相对时间），
  参数没变时 SwiftUI 会跳过 body。Claude 的外层视图照旧 `@ObservedObject` `SessionRowFormatStore.shared`，方案一改就重建页面。
- 模块剩下的：`ClaudeSessionsTab` / `AIToolsSessionsTab` 各十来行（拼文案 + 一行 `CLISessionsPage(...)`）；删 `ClaudeSessionRow`（约 120 行）、`AIToolsSessionRow`（约 110 行）。
- 数据源改名挪文件（D1）：中心窗口也用之后，名字里不该再带 QuickSwitch；`CLISessionSource.swift` 只 import Foundation、依赖 `QuickSwitchSelection`，
  整目录进测试不出问题。`QuickSwitchSessionList<Source: CLISessionSource>`、两个面板的视图模型跟着改类型名。
- 搜索规则照旧（去首尾空格、只看标题与项目名），**不**改成面板那套（不去空格、多看项目路径），两边中心窗口本来就一样，不制造变化。
- **行为**（都在 D4，§3 第 2–6 条）：一份实现必须二选一，统一成 Claude 那版；动作统一走数据源，于是 Claude 中心窗口的续接也「先切到正在跑的终端」；
  导出取两边好的一半（限定 .md + 失败说原因）。这一步没法「先原样搬」，所以变化集中在这一个 PR、逐条写进 PR 描述。
- **验证**：单测 `exportFileName`、`CLISessionSource.sessions(matching:)` 搬家后照旧；渲染探针（§4.2）：Claude 页逐像素相同，Codex 页给前后对照图；
  动作路由用桩确认（Claude 续接 = 先 `focusRunningSession`、失败再开新窗口；复制的命令逐字相同；删除确认文案相同）；真机 12–15。
- **值不值得**：必做（验收）。

#### 类 1 · 中心窗口用量页 + 调用统计（PR5，抽部件）

```swift
// Core/CLICenter/CLIUsageViews.swift —— 文案全由模块传
extension View { func cliCenterCard() -> some View }                     // 原两份 centerCard()：内边距 14、撑满宽、圆角 10 控件底色
struct CLIUsageRefreshControl: View { init(isRefreshing: Bool, help: LocalizedStringKey, action: @escaping () -> Void) }
struct CLIUsageMetric: View { init(value: String, label: LocalizedStringKey) }
struct CLIUsageBudgetBar: View { init(used: Int, budget: Int, caption: Text) }          // budget ≤ 0 不显示
struct CLIUsageWeekBadge: View { init(fixed: Bool, fixedText: Text, rollingText: LocalizedStringKey) }
struct CLIUsageColumn<Table: CLIUsagePricingTable> {
    let title: LocalizedStringKey; let width: CGFloat; let value: (CLIUsageTotals<Table>) -> String
}
struct CLIUsageBucketTable<Table: CLIUsagePricingTable>: View {        // 表头 + 斑马纹行 + 合计行
    init(buckets: [CLIUsageBucket<Table>], firstColumn: LocalizedStringKey, columns: [CLIUsageColumn<Table>], totalLabel: String)
}
struct CLIInvocationCountGroup: View {                                  // 名称 → 次数，整组可折叠，标题带总次数
    init(title: LocalizedStringKey, counts: [String: Int], count: @escaping (Int) -> Text, empty: LocalizedStringKey)
}
struct CLIInvocationMCPGroup: View {                                    // 服务器 › 工具两级
    init(title: LocalizedStringKey, servers: [String: CLIUsageMCPServerStat], count: @escaping (Int) -> Text, empty: LocalizedStringKey)
}

// Core/CLIUsage/CLIUsageModels.swift 增加（进测试）
struct CLIUsageMCPServerStat: Sendable { let server: String; let total: Int; let tools: [String: Int] }   // 两个模块各一份、字段完全相同的结构体并成这个，模块留 typealias
enum CLIUsageDimension: CaseIterable { case day, project, model }       // + buckets(of: report)
extension CLIUsageTotals { static func sum(of buckets: [CLIUsageBucket<Table>]) -> CLIUsageTotals }   // 四项 token + 费用 + unpriced，按桶的顺序加
```

模块留：卡片的组合与顺序、各自的文案、列定义（Claude 四个 token 列宽 80，Codex 三个宽 90）、Claude 的周脚注（:369–373）、调用统计里几组的顺序
（Claude：Skill / MCP / 内置；Codex：内置 / MCP）、维度 label。两边用量页大约各剩 120–150 行。

- **行为**：不变（逐像素）。`sum(of:)` 对 Codex 多加一项恒为 0 的缓存写，费用相加顺序与原来相同，结果逐位相同（单测钉住）。
- **验证**：单测 `sum(of:)`（两种定价表、含 unpriced、空列表）与 `CLIUsageDimension`；渲染探针逐像素（§4.2）；真机 19。
- **值不值得**：建议做（D7）：中心窗口按顺序相同的行有六成在这里；改用量页的人以后改一处。风险在布局，逐像素探针兜得住。

#### 类 8 · 用量 Store 外壳（PR4）

```swift
// Core/CLIUsage/CLIUsageStore.swift —— 进 BaoboxTests
/// 一种 CLI 的用量来源：全是静态成员、后台线程调用。各模块实现一个。
protocol CLIUsageSource: Sendable {
    associatedtype Table: CLIUsagePricingTable
    associatedtype InvocationStats: Sendable
    static func collectEntries(sinceHoursAgo hours: Int) -> [CLIUsageEntry]
    /// 默认 = CLIUsageCalculator.weeklyWindow；Codex 覆盖成「近 180h 没有用量返回 nil」（原有差异，保留）。
    static func weeklyWindow(from entries: [CLIUsageEntry], anchor: CLIUsageWeeklyAnchor) -> CLIUsageWindow<Table>?
    static func buildReport(from entries: [CLIUsageEntry]) -> CLIUsageReport<Table>
    static func invocationStats(days: Int) -> InvocationStats
}

/// 主线程读的设置：预算与周窗口锚点（模块从自己的 UserDefaults 键读）。
struct CLIUsageSettings: Equatable, Sendable { var budget: Int; var weeklyBudget: Int; var anchor: CLIUsageWeeklyAnchor }

@MainActor
class CLIUsageStore<Source: CLIUsageSource>: ObservableObject {
    @Published private(set) var fiveHourWindow: CLIUsageWindow<Source.Table>?
    @Published private(set) var weeklyWindow: CLIUsageWindow<Source.Table>?
    @Published private(set) var todayTotals: CLIUsageTotals<Source.Table>?
    @Published private(set) var isRefreshing: Bool

    init(collectHours: Int = 180, autoRefreshInterval: TimeInterval = 300, eventThrottle: TimeInterval = 60)   // 测试传短间隔
    func startAutoRefresh()             // 立刻刷一次，之后每 5 分钟
    func stopAutoRefresh()              // 停定时器、取消排着的补刷
    func refresh()                      // 进行中再来合并成结束后补一轮（照搬 Claude 现在的）
    func refreshThrottledFromEvent()    // CLIUsageRefreshThrottle：60 秒内马上放行一次，窗口末尾补一次（照搬 Claude 现在的）
    func report(days: Int, completion: @escaping (CLIUsageReport<Source.Table>) -> Void)
    func invocationStats(days: Int, completion: @escaping (Source.InvocationStats) -> Void)

    // 子类覆盖（主线程）：
    func readSettings() -> CLIUsageSettings     // 锚点在刷新开始时读、预算在结果回来时读（与现在相同）
    func budgetWindowChanged(weekly: Bool)      // 防重记录换了窗口：Claude 可选发「额度已恢复」，Codex 不覆盖
    func budgetReached(percent: Int, window: CLIUsageWindow<Source.Table>, weekly: Bool)
}
```

模块：`ClaudeUsageSource`（`usageCollector`、`collectEntries`、`buildReport`、调用统计解析）+ `final class ClaudeUsageStore: CLIUsageStore<ClaudeUsageSource>`
（`shared`、五个设置键常量照旧、三个覆盖）；Codex 同形。写法同 `CLISessionIndex<Format>`（`@Published` 全在基类、`shared` 在子类，`DEDUPE.md` §3.3 第 1 条与 R10 的探针结论）。
`currentWindow` 统一成 `fiveHourWindow`（Claude 两处调用：`ClaudeCodeTool.swift:150`、`ClaudeCodeCenterWindow.swift:403`），`refreshThrottledFromHook` 统一成
`refreshThrottledFromEvent`（`ClaudeLiveStatus.swift:352`）。

- **行为**：Claude 不变；Codex 两处（D6）：刷新进行中再来的请求结束后补一轮（原来丢）；回合完成触发的刷新 60 秒内再来一次时在窗口末尾补刷（原来丢）。
  刷新回来后「先发提醒还是先熄转圈」的先后统一成 Claude 的（同一个主线程回合里，看不出）。
- **验证**：单测（假来源放临时数据）：刷新发布三个值并熄转圈；进行中再请求只补一轮、补的那轮转圈不熄；节流的「马上 / 补刷 / 已排」三种结论与补刷到点；
  `stopAutoRefresh` 取消补刷；Codex 的周窗口覆盖生效；预算钩子按「换窗口 / 到 80%」各调一次；报表与调用统计回调在主线程。差分：新旧 Store 喂同一批条目，
  发布的值与提醒调用序列相同（Codex 除了上面两处时序）。真机 16–18。
- **值不值得**：做。省约 150 行，更要紧的是两边刷新规则以后不会再分叉（#174 才修过一边）。

#### 类 6 · 会话目录遍历（PR6）

§1.4 表里 C2、C3、C5、X3、X4、X5 六处改用 `CLISessionFiles.jsonlInSubdirectories` / `jsonlRecursively`（项目目录名改从文件的上级目录取，同 #167 对
`ClaudeSessionFormat.scan` 的处理）。C4（`ClaudeUsageCollector`）不改：它靠「取不到修改时间或大小就不缓存」保证增量结果与全量逐条相同，`CLISessionFile`
把取不到的值记成 1970 / 0，换过去会让这类文件以假键进缓存 —— 正好落在它的差分测试钉住的边上，省十几行不值得。

- **行为**：C3、X5 零差别；C2、C5、X3、X4 只差「取不到修改时间的文件」：原来照读（X3 当成「现在」），改后按 1970 跳过。修改时间在列目录时已随目录一起预取，
  取不到基本只发生在列完到取值之间文件被删的瞬间，此时读也读不到。
- **验证**：差分：新旧 `computeAudit`、两个 `computeInvocationStats`、Codex `collectEntries`、`sessionsDiskStats`、`ClaudeFileIndex.scanAll` 在生成的夹具与
  开发机真实的 `~/.claude/projects`、`~/.codex/sessions`（**只读**，不调删除，结果不出本机）上输出相同；真机 20。
- **值不值得**：做，优先级最低（D8）。省约 70 行；以后 CLI 改目录布局（比如会话文件挪进子目录）只改一处。

#### 类 7 · `ClaudeFileIndex` 外壳（PR6）

```swift
// Core/CLISession/CLICacheFile.swift —— 进 BaoboxTests
/// 派生数据的磁盘缓存文件（会话索引 index-cache-v2.json、最近文件索引 file-index-cache-v1.json）：启动时同步读；
/// 改了之后 1 秒防抖，到点在串行写盘队列上异步写；退出时同步 flush（排在前面的旧快照一定先写完）。
/// 默认 JSONEncoder 编码，写前建父目录；写失败静默（丢了只是下次多扫几个文件，不走 StorageWriteFailure）。
@MainActor
final class CLICacheFile<Snapshot: Codable & Sendable> {
    init(url: URL?, queueLabel: String, debounce: TimeInterval = 1.0)   // url == nil：不读不写（Codex 会话索引）
    func load() -> Snapshot?
    func scheduleSave(_ snapshot: @escaping @MainActor () -> Snapshot)  // 到点时取当时的快照（同现在）
    func flush(_ snapshot: Snapshot)
}
```

`CLISessionIndex` 改用它（`:59–67`、`:170–228` 的缓存部分换成一个成员，写盘队列名照旧 `com.baobox.clisession.cachesave`）；`ClaudeFileIndex` 改用它
（队列名 `com.baobox.claudecode.fileindex.cachesave`），并照 `CLISessionIndex.refresh` 加上「进行中再请求记一笔、结束后补一轮、补扫那轮不发布」，
补扫开始时重新读一次「包含内部文件」。只读追加部分的扫描原样留在文件索引（真差异，套不进 `CLISessionScanner`）。

- **行为**：会话索引不变（它现有的单测一条不改照样过）；最近文件索引三处（D8）：刷新请求不再被吞、退出时同步落盘、写盘串行。
- **验证**：单测 `CLICacheFile`（防抖合并多次写、flush 同步可读、flush 之前排着的旧快照不会盖掉新的、`url == nil` 不写、坏文件读回 nil）；
  `CLISessionIndex` 现有测试全过；文件缓存新旧互读（`file-index-cache-v1.json` 逐字节相同）；真机 21。
- **值不值得**：做（小），和遍历一个 PR。

## 3. 行为变化汇总

除下表外，六个 PR 都应当用户看不出；表里每一条都要你点头（最后一列）。

| # | 在哪 | 变化 | PR | 拍板 |
|---|---|---|---|---|
| 1 | 续接脚本 | 写到 `Baobox/Terminal/launch/`（原 `Baobox/ClaudeCode/launch/`）；旧目录由 Claude 模块启动时删掉；只装 Codex 的用户不再多出 `Baobox/ClaudeCode/` | PR1 | D2 |
| 2 | Codex 中心窗口 · 会话行 | 操作按钮从「行下方一排带字按钮」改成「右侧图标按钮（悬停看说明）」，行高不再随悬停跳；第二行改成与快速切换面板同一个字符串（「项目 · 3 分钟前」，间距窄一点，过长中间省略）；右键菜单带图标 | PR3 | D4 |
| 3 | Codex 中心窗口 · 会话列表 | 加斑马纹 | PR3 | D4 |
| 4 | Codex 导出 Markdown | 存盘框限定 .md | PR3 | D4 |
| 5 | Claude 中心窗口 · 续接 | 会话正在某个终端里跑时切过去，不再另开一个 `claude --resume`（同面板、同点通知，#109 B3） | PR3 | D4 |
| 6 | Claude 导出 Markdown | 写盘失败的弹窗多一行原因（Codex 原来就有） | PR3 | D4 |
| 7 | Codex 用量刷新 | 进行中再来的请求不再丢，结束后补一轮 | PR4 | D6 |
| 8 | Codex 回合完成后的用量 | 60 秒内的第二次不再丢，窗口末尾补刷一次 | PR4 | D6 |
| 9 | 最近文件索引 | 刷新请求不再被吞（启动扫描期间拨「包含内部文件」也生效）；退出时同步落盘；写盘串行 | PR6 | D8 |
| 10 | 审计、两个调用统计、Codex 用量 | 取不到修改时间的会话文件跳过（原来照读）—— 理论情况 | PR6 | D8 |
| 11 | 本地 `--version` | stderr 改成丢弃（原来接一个没人读的管道）—— 看不出 | PR2 | — |

## 4. 验证

### 4.1 单元测试（BaoboxTests）

现有约 369 个（`grep -c 'func test'`）。测试 target 不链接 App、不设 `TEST_HOST`；文件类测试在临时目录里做；`@MainActor` 的测试类标 `@MainActor`、用
`XCTestExpectation` 等主线程回调（同 `DEDUPE.md` §7.1）。

| PR | 新增 | 约 |
|---|---|---|
| PR1 | `mac/Tests/Shell/ShellTests.swift`、`mac/Tests/Terminal/TerminalLaunchScriptTests.swift` | 18 |
| PR2 | `mac/Tests/CLIFormat/CLIFormatTests.swift`、`mac/Tests/CLIVersion/CLIVersionTests.swift` | 20 |
| PR3 | `exportFileName`（并进 `CLISessionMarkdownTests`）；`CLISessionSource` 搬家后的过滤测试 | 8 |
| PR4 | `mac/Tests/CLIUsage/CLIUsageStoreTests.swift`（假来源） | 14 |
| PR5 | `sum(of:)`、`CLIUsageDimension`（并进 `CLIUsageReportTests`） | 6 |
| PR6 | `mac/Tests/CLISession/CLICacheFileTests.swift`；`CLISessionIndexTests` 一条不改 | 8 |

### 4.2 差分与渲染探针（scratchpad，不进仓库，结果贴进 PR 描述）

照 #109 的做法：把 `a4833c8` 的旧文件用 `sed` 改名（`Old…` 前缀）和新代码编进同一个临时程序，`NSWorkspace` / `NSPasteboard` / 终端 / 会话索引用桩，
不碰真实会话、剪贴板、终端。

- **PR1**：2000 组随机（命令、目录）（含单引号、空格、换行、`$`、反引号、非 ASCII、空串目录）：旧 `run` 写出的脚本文本 = `TerminalLaunchScript.contents`；
  旧 `resumeCommandString` = `ClaudeTerminal.resumeCommandString`；旧 `CodexResumeCommand.command / fullCommand` 与新的逐字相同；旧 / 新 Codex notify `scriptContent` 逐字节相同；
  `focusRunningSession` 的四种结局（位置直接用 / 确认后用 / 按进程找到 / 都不行）与切标签页调用序列相同。
- **PR2**：旧 `ClaudeFormat` / `AIToolsFormat` 与新 typealias 在 10 万个随机输入上逐字相同（`countdownLong` 挂真文案表，中英各一遍）；
  `multiLineTitle` 新旧 `isEqual`；`cliVersion` 新旧对同一个假二进制输出相同。
- **PR3 渲染探针**（`baobox-ui-render-probe` 那套：真视图编进临时程序、`zh-Hans.lproj` 由 xcstrings 转出、离屏窗口、`cacheDisplay` 出 PNG）：
  两个模块 × 中英 × 浅深色 × {有会话、搜索命中、搜索落空、空列表、悬停一行、刷新中}；**Claude 逐像素相同**，Codex 出前后对照图（D4 预期的样子）；
  「窗口开着去设置里换会话行方案」那一步 Claude 第二行跟着变（对照组：去掉 `renderToken` 应当不变，证明 token 起作用）。
  过滤：旧的两个过滤闭包与新页面的过滤在 2 万个随机查询上结果相同。
- **PR4**：新旧 Store 在同一套临时夹具上刷新，三个发布值逐字段相同；脚本化的事件序列（间隔 0 / 30 / 61 秒）下 Claude 的刷新时刻、提醒调用序列完全相同，Codex 只在 D6 两处不同。
- **PR5 渲染探针**：两个用量页 × 中英 × 浅深色 × {无窗口、有窗口无预算、有预算、周窗口固定 / 滚动、三个维度、含未知模型、明细为空、调用统计收起 / 展开}，**逐像素相同**。
- **PR6**：§2.4 类 6 列的六个函数新旧输出相同（夹具 + 真实目录只读）；`file-index-cache-v1.json`、`index-cache-v2.json` 新旧互读、再编码逐字节相同。

### 4.3 编译与静态检查

```bash
# 编译 + 单测（Mac 上；只编不装，不碰 /Applications —— 并行会话会互相覆盖安装）
cd mac && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Baobox -configuration Debug -derivedDataPath "$SCRATCH/DerivedData" \
  -destination 'platform=macOS' test

# 本地化表仍是合法 JSON（仓库根目录）
python3 -c "import json;json.load(open('mac/Sources/Resources/Localizable.xcstrings'));print('valid')"

# 文案 key 集合不变（每个 PR 都跑，diff 必须为空；D5 选了合并 key 才会变）
git grep -hoE '"(claudecode|aitools|codex|common)\.[A-Za-z.]+' a4833c8 -- mac/Sources | sort -u > "$SCRATCH/keys-before"
git grep -hoE '"(claudecode|aitools|codex|common)\.[A-Za-z.]+' HEAD    -- mac/Sources | sort -u > "$SCRATCH/keys-after"
diff "$SCRATCH/keys-before" "$SCRATCH/keys-after"

# 模块边界：一个模块顶层声明的类型，不该出现在另一个模块与 Core 的代码行里（注释行不算）。没有输出 = 通过。
# 按类型名前缀 grep 查不出眼下这个问题（TerminalLauncher 没有模块前缀）；这个按声明查，在 a4833c8 上正好报出那三处：
# AIToolsQuickSwitchPanel.swift:32、AIToolsCenterWindow.swift:271、Core/TerminalFocus.swift:47。PR1 之后应当没有输出。
decls() {
  grep -rhoE '^(@MainActor[[:space:]]+)?((private|fileprivate|internal)[[:space:]]+)?(final[[:space:]]+)?(enum|struct|class|protocol|typealias|actor)[[:space:]]+[A-Z][A-Za-z0-9]*' \
    "$1" --include='*.swift' | awk '{print $NF}' | sort -u
}
check() {   # $1 = 定义所在的模块目录；其余 = 不该引用它的目录
  local pat; pat=$(decls "$1" | paste -sd'|' -); shift
  grep -rnwE "($pat)" "$@" --include='*.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'
}
check mac/Sources/Modules/ClaudeCode mac/Sources/Modules/AITools mac/Sources/Core
check mac/Sources/Modules/AITools mac/Sources/Modules/ClaudeCode mac/Sources/Core

# 进测试的文件只 import Foundation（另允许 Combine / Dispatch），不调 L()
grep -hn '^import' mac/Sources/Core/Shell.swift mac/Sources/Core/CLIFormat.swift mac/Sources/Core/CLIVersion.swift \
  mac/Sources/Core/Terminal/TerminalLaunchScript.swift mac/Sources/Core/CLISession/*.swift mac/Sources/Core/CLIUsage/*.swift | sort -u
grep -nE '\bL\(' mac/Sources/Core/Shell.swift mac/Sources/Core/CLIFormat.swift mac/Sources/Core/CLIVersion.swift \
  mac/Sources/Core/Terminal/TerminalLaunchScript.swift mac/Sources/Core/CLISession/*.swift mac/Sources/Core/CLIUsage/*.swift

# 搬家看着色
git diff -M --color-moved=zebra origin/main...HEAD
```

### 4.4 真机回归清单

装本地构建后跑（安装由主会话 / 用户做）。PR1 跑 1–8，PR2 跑 9–11，PR3 跑 12–15，PR4 跑 16–18，PR5 跑 19，PR6 跑 20–21。

续接与终端（PR1）：

1. Claude 面板续接一个没在跑的会话：偏好终端（iTerm2、Ghostty、系统终端各一次）开新窗口续接；续接一个正在跑的：切到那个标签页。
2. Claude 点「等待确认 / 完成」通知：跳回终端（iTerm2 选中标签页；Otty 选中面板）。
3. Claude 中心窗口续接；「复制续接命令」粘进终端能跑。
4. Codex 面板与中心窗口续接；复制的命令能跑。
5. kitty / WezTerm / Alacritty（binary 方式）有哪个测哪个，续接一次。
6. `~/Library/Application Support/Baobox/Terminal/launch/` 里出现脚本、最多 20 个；`Baobox/ClaudeCode/launch/` 重启后没了（D2）。
7. 设置页状态卡的版本号照常（`--version` 改用 `Shell.quote`）。
8. 关掉再打开 Codex 完成通知（重写 notify 脚本），脚本内容与改动前逐字节相同，跑一回合通知照来。

小件（PR2）：

9. 两个菜单「用量报表」的两行副标题、状态行今日花费；周窗口剩 ≥ 1 天时显示「N 天 M 小时」（中英文各看一次）。
10. 设置 → 维护：检查最新版（有网 / 断网）、复制升级命令。
11. 设置里打开固定周重置：星期名、小时选择照常。

会话页（PR3）：

12. 两个中心窗口会话页：搜索（带首尾空格）、刷新转圈后停、斑马纹、悬停四个按钮、双击续接、右键四项、导出（中文标题、空标题、存到只读目录看失败原因）、删除确认。
13. Claude：中心窗口开着，去设置里换会话行方案 → 第二行跟着变。
14. Claude：从中心窗口续接正在跑的会话 → 切到那个终端；没在跑的 → 开新窗口。
15. Codex：会话行第二行「项目 · 3 分钟前」，没有项目时只有时间。

用量 Store（PR4）：

16. 启动后菜单出现今日花费与额度副标题；中心窗口用量页刷新按钮转圈后停；改周重置设置后数字更新。
17. 预算设得很小：5 小时 / 周的 80% 提醒各来一次（Claude 与 Codex）；Claude 打开「额度已恢复」后窗口切换时来一条。
18. Codex 一回合结束 60 秒内菜单「今日」更新；两回合间隔不到 60 秒时，第二回合的用量在窗口末尾补刷到（D6）。

用量页（PR5）：

19. 两个用量页与改动前的截图逐项对比：5 小时卡、周卡（固定 / 滚动）、预算条、三个维度的明细表与合计、未知模型提示、Claude 的周脚注、调用统计展开 / 收起。

遍历与最近文件（PR6）：

20. 审计页某一天、调用统计 7 / 30 天、Codex 维护节的磁盘数字与改动前一致。
21. 最近文件面板照常；启动后马上去设置拨「包含内部文件」，面板里随后生效；退出再开，面板立刻有列表（缓存命中）。

## 5. PR 拆分与顺序

每个 PR 单独可合并、能编译；搬家的部分用 `git diff -M --color-moved=zebra` 看。规模按「新增 / 删除」行数估，含测试。

| PR | 一句话范围 | 规模（估） | 依赖 |
|---|---|---|---|
| PR1 | `TerminalLauncher` 通用部分 + `Shell` 进 Core（`Core/Terminal/`），Claude 专有部分成 `ClaudeTerminal`；脚本换目录、旧目录清掉；单引号收成一份 | +330 / −330（多是搬家） | 无 |
| PR2 | 小件：`CLIFormat`（含星期名）、菜单多行标题、`CLIVersion`（npm 最新版 + 本地版本） | +330 / −270 | PR1（都动 `AIToolsCenterWindow.swift` 头部，排在后面免冲突） |
| PR3 | 中心窗口会话页一份实现（`Core/CLICenter/CLISessionsPage.swift`），数据源改名 `CLISessionSource` | +260 / −300 | PR1（续接走 `ClaudeTerminal`）、PR2（同文件） |
| PR4 | 用量 Store 外壳（`CLIUsageStore<Source>`），Codex 补上合并刷新与节流补刷 | +480 / −200 | 无硬依赖；排在 PR3 后免冲突 |
| PR5 | 中心窗口用量页与调用统计的部件（`Core/CLICenter/CLIUsageViews.swift`） | +300 / −460 | PR2（`weekAnchor`）、PR3（同文件）、PR4（`fiveHourWindow`） |
| PR6 | 六处会话文件遍历改用 `CLISessionFiles`；`CLICacheFile` 从会话索引抽出，最近文件索引改用并合并刷新 | +190 / −150 | PR4（同改 `ClaudeUsage.swift` / `CodexUsage.swift`） |

PR1 + PR3 合进去，issue 的两条验收就满足了；PR5、PR6、PR2 里的设置页部分按 D7–D9 决定。

### PR1 `TerminalLauncher` 进 Core

`refactor(cli): move the terminal launcher into Core (#164)`

- 新增：`Core/Terminal/TerminalLauncher.swift`、`TerminalLaunchScript.swift`、`Core/Shell.swift`、`Modules/ClaudeCode/ClaudeTerminal.swift`、两个测试文件。
- 挪：`Core/TerminalAppPreference.swift`、`Core/TerminalFocus.swift` → `Core/Terminal/`（`git mv`，内容不动）。
- 改：`ClaudeEnv.swift`（删约 310 行）、`ClaudeQuickSwitchPanel.swift`、`ClaudeLiveStatus.swift`、`ClaudeCodeCenterWindow.swift`、`ClaudeCodeTool.swift`（旧目录清理）、
  `AIToolsCenterWindow.swift`、`AIToolsNotify.swift`、`CodexEnv.swift`；D3 同意的话 `CurlCommand.swift`、`URLRecognizer.swift`、`LiveTranslateVoiceOutput.swift`；`mac/project.yml`。
- 文档：见 §2.4 类 5 末条；本文状态。

### PR2 小件

`refactor(cli): share formatting, the multi-line menu title and the version check (#164)`

- 新增：`Core/CLIFormat.swift`、`Core/CLIVersion.swift`、两个测试文件。
- 改：两个中心窗口（`ClaudeFormat` / `AIToolsFormat` 换成 typealias + 六行的 Localization、锚点描述）、两个 Tool 文件、两个设置页（`checkUpdate`、`weekdayName`）、
  `ClaudeEnv.swift` / `CodexEnv.swift`（`cliVersion`）、`Core/ClosureMenuItem.swift`、`mac/project.yml`。
- 文档：`CORE_API.md` §1 的 `cliVersion` 一行注明转调 `CLIVersion`；`DESIGN.md` §7 当时就建议「多行副标题构件、金额 / token 格式化放 `Sources/Core/`」（:221），
  标成已做；根 `CLAUDE.md` 的 Core 清单。

### PR3 中心窗口会话页

`refactor(cli): one sessions page for both center windows (#164)`

- 新增：`Core/CLICenter/CLISessionsPage.swift`、`Modules/ClaudeCode/ClaudeSessionSource.swift`、`Modules/AITools/CodexSessionSource.swift`。
- 挪 + 改名：`Core/QuickSwitch/QuickSwitchSessionSource.swift` → `Core/CLISession/CLISessionSource.swift`。
- 改：两个中心窗口（会话页缩成外层几行）、两个面板文件（数据源搬走、类型名）、`Core/QuickSwitch/QuickSwitchViews.swift`（泛型约束改名）、`CLISessionMarkdown.swift`。
- 文档：`DESIGN.md` §9.1、`DEDUPE.md` §4.3 加注（数据源改名）、根 `CLAUDE.md` 的 Core 清单；PR 描述贴 Codex 前后对照图。

### PR4 用量 Store 外壳

`refactor(cli): share the usage store between Claude Code and Codex (#164)`

- 新增：`Core/CLIUsage/CLIUsageStore.swift`、测试。
- 改：`ClaudeUsage.swift`、`CodexUsage.swift`（Store 变子类、来源各一个）、`ClaudeCodeTool.swift` / `ClaudeCodeCenterWindow.swift`（`fiveHourWindow`）、`ClaudeLiveStatus.swift`（方法名）、
  `CLIUsageRefreshThrottle.swift` 的注释（:7 那句「留给这一步」改成已完成）。
- 文档：`CORE_API.md` §用量、`DESIGN.md` §9.1、`TECH_DESIGN.md` §3.3 加注。

### PR5 中心窗口用量页部件

`refactor(cli): share the usage page pieces between the two center windows (#164)`

- 新增：`Core/CLICenter/CLIUsageViews.swift`；`CLIUsageModels.swift` 加三样；测试。
- 改：两个中心窗口的用量页与调用统计；`ClaudeUsage.swift` / `CodexUsage.swift`（`…MCPServerStat` 换成 typealias）。
- PR 描述贴逐像素探针的结果。

### PR6 遍历与最近文件索引

`refactor(cli): list session files in one place; give the recent-files index the shared cache file (#164)`

- 新增：`Core/CLISession/CLICacheFile.swift`、测试。
- 改：`CLISessionIndex.swift`（缓存部分换成 `CLICacheFile`）、`ClaudeFileIndex.swift`、`ClaudeSessionIndex.swift`（审计）、`ClaudeUsage.swift` / `CodexUsage.swift`（调用统计、Codex 用量）、`CodexEnv.swift`（磁盘统计）。
- 文档：`RECENT_FILES.md` §4 加注、`CORE_API.md`。

## 6. 风险

| # | 风险 | 现在靠什么 | 搬坏了是什么样 | 怎么防 / 验 |
|---|---|---|---|---|
| R1 | 续接脚本或命令变了 | `run` 拼脚本、`ClaudeEnv.shellSingleQuote` | 终端里跑错命令、cd 到错目录 | 脚本文本逐字差分；`Shell.quote` 交给真 shell 回读的单测；真机 1–5 |
| R2 | 切到正在跑的会话 | `focusRunningSession` 一整条（位置 → 确认 → 按进程） | 点通知不跳、面板切错窗口 | 原样搬进 `ClaudeTerminal`，`--color-moved` 整块着色；四种结局的差分；真机 1–2 |
| R3 | 会话页的第二行不刷新 | Claude 行里自己 `@ObservedObject` 方案 | 换了方案中心窗口还显示旧的 | `renderToken`（#172 验证过的做法）+ 探针的对照组；真机 13 |
| R4 | 会话页的双击 / 右键 / 悬停 | 两份各写各的 | 双击不续接、悬停按钮点不到 | 统一成 Claude 那份（原样搬），探针渲染悬停态；真机 12 |
| R5 | 用量刷新时序 | 两个 Store 各自的定时器与节流 | 菜单数字不更新、提醒重复或漏发 | 单测覆盖合并与补刷；新旧差分；真机 16–18 |
| R6 | 用量页布局 | 两份视图 | 列对不齐、卡片间距变了 | 逐像素探针（中英 × 浅深色 × 多种数据）；真机 19 |
| R7 | 缓存文件兼容 | 记录字段名 = 文件里的键，默认 `JSONEncoder` | 升级后首启全量重扫（不丢数据，只是慢一次） | `CLICacheFile` 用同样的编码器；新旧互读逐字节 |
| R8 | 菜单构建零磁盘 IO | `submenuItems()` 只读 `@Published` | 打开菜单卡顿 | 基类的 `@Published` 仍是内存值；Store 没有新增同步 IO |
| R9 | 文案 key 传错 / 漏传 | 每个视图自己写 key | 中英文显示成 key 或别的模块的文案 | key 集合 diff 为空；探针中英文各渲染一遍 |
| R10 | 泛型基类上的 `ObservableObject`（Store） | — | 菜单 / 用量页不刷新 | 同 `CLISessionIndex<Format>`（`DEDUPE.md` R10 已探针验证）；单测订阅 `objectWillChange` |
| R11 | 旧目录清理删错东西 | — | 删掉 Claude 模块别的文件 | 只删 `ClaudeEnv.supportDir.appendingPathComponent("launch", isDirectory: true)` 这一个子目录（hooks 脚本、两份缓存、事件文件都在它旁边，不在里面）；评审逐字核对路径；真机 6 顺带确认 `Baobox/ClaudeCode/` 里其余文件都在 |

## 7. 待拍板

逐条回「按建议」或改。

1. **D1 新名字与目录**：按 §2.2 的表（`TerminalLauncher` 留名搬进新目录 `Core/Terminal/`，`TerminalAppPreference.swift`、`TerminalFocus.swift` 一起挪进去；
   Claude 专有部分叫 `ClaudeTerminal`；`QuickSwitchSessionSource` 改名 `CLISessionSource`；`currentWindow` 统一叫 `fiveHourWindow`；共用视图放 `Core/CLICenter/`）？
   **建议按表**：AITools、NetCapture 调 `TerminalLauncher.run` 的地方一行不改，`claude --resume` 不再挂在通用名字下；数据源中心窗口也用之后，名字里不该再带 QuickSwitch。
2. **D2 续接脚本放哪、旧目录清不清**：**建议放 `~/Library/Application Support/Baobox/Terminal/launch/`**（同 `Core/Translation` → `Baobox/Translation/` 的约定，照旧只留最近 20 个），
   **旧的 `Baobox/ClaudeCode/launch/` 由 Claude 模块每次启动在后台删一次**（两个版本后去掉这几行），隐私文档（中英）顺手把「Claude Code / Codex 助手不存」改对。
   理由：脚本是 Core 的实现细节，不该写进某个模块的目录；旧目录只有几 KB，但脚本里有项目路径和会话 id，没必要留。备选：放 `$TMPDIR`（系统三天自动清），代价是换到系统临时目录、离开 Baobox 的支持目录。
3. **D3 单引号转义收几份**：**建议 CLI 两个模块的三份 + 剪贴板 curl（`CurlCommand.shellQuote`）+ 实时翻译（`LiveTranslateVoiceOutput.quoted`）都改用 `Shell.quote`，NetCapture 那份不动**。
   理由：五份逐字相同，换掉没风险、有单测；NetCapture 不参与编译，改了也验证不了。
4. **D4 中心窗口会话页统一成 Claude 那一版**（§3 第 2–6 条：Codex 的行改成右侧图标按钮、斑马纹、第二行用面板同一个字符串、存盘限定 .md；
   Claude 续接改成先切到正在跑的终端、导出失败说原因）？**建议按此**。理由：验收要求只剩一份，Claude 那版是后来改进过的（悬停不改行高、第二行可配置），
   续接与面板一致还顺带修掉「从中心窗口续接正在跑的会话会再开一个 claude」。
5. **D5 共用视图的文案**：**建议各模块照旧用自己的 key、由模块传进共用视图，`Localizable.xcstrings` 一条不动**。
   理由：会话页、用量页、中心窗口、`common` 里两边平行的 44 条文案有 23 条译文不同（如「复制续接命令 / 复制命令」「后重置 / 重置倒计时」，有的只差大小写），
   合并 key 等于改文案；想统一措辞可以以后单独做。
6. **D6 用量 Store 合并后 Codex 的两处行为**（刷新进行中再来的请求不再丢、回合完成触发的刷新加窗口末尾补刷，都是 Claude #174 已有的）？**建议接受**。
   理由：`CLIUsageRefreshThrottle.swift` 当时就写明留到这一步；现在 Codex 连续两回合（间隔 < 60 秒）的用量要等 5 分钟定时器。
7. **D7 用量页抽部件做不做**：**建议做**（PR5，排在会话页与 Store 之后），抽卡片、指标、预算条、明细表、调用统计分组，卡片组合、列、Claude 的周脚注留模块。
   理由：中心窗口按顺序相同的 420 行里约 250 行在用量页与调用统计，只做会话页省不下多少；逐像素探针能证明不变。
8. **D8 会话文件遍历 + 最近文件索引外壳**：**建议做**（PR6）：六处遍历改用 `CLISessionFiles`（`ClaudeUsageCollector` 不改），最近文件索引改用抽出来的 `CLICacheFile` 并合并刷新请求。
   理由：遍历只差「取不到修改时间」这一理论情况；最近文件索引顺带补上会话索引 #170 修过的三处（请求被吞、退出异步落盘、并发写盘）。
9. **D9 设置页抽多少**：**建议只抽版本检查（npm 最新版 + 本地 `--version`）和星期名**，维护节的磁盘 / 清理、通知节、MCP 节、整页容器的视图不共用。
   理由：这几块是同一种 SwiftUI 写法填不同的内容（磁盘口径、配置格式、状态卡项目都不同），抽成泛型视图要传的 key 与闭包和省下的行数差不多。
10. **D10 中心窗口的窗口外壳与全屏空间**：外壳不抽（各 30 行，与设置 / 手机互传 / 听写历史同一种样板）；它们没用 `DesktopSpaceWindow`（从全屏 App 里打开会叠进那个全屏空间），
    **建议另开 issue**，把两个中心窗口、会议窗口、听写历史一起看，不在本次改。理由：是全 App 的窗口约定，不是两个 CLI 模块之间的重复，混进来会让重构 PR 带上行为变化。
