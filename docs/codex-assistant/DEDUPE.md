# Claude / Codex 两套实现去重 · 第二步（会话索引、快速切换面板、事件文件监听）· 技术设计

> issue #109「Claude 与 Codex 两套实现大面积重复」的第二步。状态：**已拍板（2026-11-10，§9）**：用户同意 D1–D8 全部按建议做。**PR1（会话索引共用层）已实现**（2026-11-11，分支 `refactor/cli-session-index`），与本文的出入记在 §6 PR1 末尾。**PR3（快速切换部件 + 会话数据源）已实现**（2026-11-11，分支 `refactor/cli-quick-switch`），出入记在 §6 PR3 末尾。
> 第一步（用量层）已由 #134 合入：定价 / 窗口 / 报表 / 80% 提醒在 `mac/Sources/Core/CLIUsage/`，`BaoboxTests` 单元测试 target 已在 main，
> issue 的两条验收（改一次定价两边一起变、用量计算有测试覆盖）已满足。本文只管 issue 范围里剩下的三件：`SessionIndex<Summary>` 泛型、
> `QuickSwitchPanel` 数据源协议、`EventFileWatcher`。
> 基线：main `5a6ef26`。下文路径都相对 `mac/Sources/`，行号以这个提交为准。
> 相关：`../claude-code-assistant/TECH_DESIGN.md` §0、§3.2–§3.4，`../claude-code-assistant/RECENT_FILES.md` §4.2，
> `../claude-code-assistant/NOTIFY_JUMP.md`，`DESIGN.md` §7、§9，`Modules/ClaudeCode/CORE_API.md` §2。

## 0. 一页看懂

**现在**：Claude Code 助手（`Modules/ClaudeCode/`，id `claudecode`）与 Codex 助手（`Modules/AITools/`，id `aitools`）各写了一份
会话索引、一份快速切换面板、一份事件文件监听。Codex 那几份是 2026-07-23、24 照 Claude 抄的（`f2c6651`、`95becae`），之后两边各改各的。
按 issue 的口径（去空白后两边都出现的不同行）分别有 103 / 165 / 82 行相同；按顺序对得上的相同行是 148 / 230 / 125（§1.1）。

**改成**（照 #134 的路子：共用层放 Core、纯 Foundation 的部分进测试、模块留差异、类型名不变）：

1. **会话索引** → `Core/CLISession/`。`CLISessionIndex<Format>` 是一个泛型 `ObservableObject` 基类，管刷新（防重入、后台扫描、
   mtime + 大小没变就复用）、排序、删除、导出外壳、可选的磁盘缓存（1 秒防抖、退出 flush）、清理旧会话。每个工具实现一个
   `CLISessionFormat`（会话文件在哪、怎么快扫一个文件、怎么导出、缓存放哪），模块里的 `ClaudeSessionIndex` / `CodexSessionIndex`
   变成它的非泛型子类，`shared` 与全部调用方原样不动；Claude 的审计、磁盘分布留在子类里。
2. **事件文件监听** → `Core/EventFile/`。`EventFileWatcher`（`DispatchSourceFileSystemObject` 增量读）、`EventFileLog`（建文件、
   超限截断、读全部）、`EventFileFollower`（后台准备 → 主线程回放已有行 → 跟随新行）。两个模块只留「一行事件怎么处理」。
3. **快速切换面板** → `Core/QuickSwitch/`。抽的是部件而不是一个多栏框架：窗口外壳 `QuickSwitchPanelHost`、按键解码 `QuickSwitchKey`、
   过滤与选中逻辑 `QuickSwitchSelection`、会话栏的视图（外框 / 搜索栏 / 会话列表 / 行 / 底栏提示），加一个**会话数据源协议**
   `QuickSwitchSessionSource`，两边真正不同的四件事（会话从哪来、第二行写什么、怎么续接、复制什么命令）都在它里面。
   Claude 的「最近文件」模式只有一个使用者，留在 Claude。
4. **先原样搬、后单独修**：三个重构 PR 一律行为不变，用差分测试证明；查到的分叉 bug（§5）另开修复 PR，修不修由你定（§9）。

分 **3 个重构 PR**（§6）：PR1 会话索引 → PR3 面板（依赖 PR1 的 `CLISessionSummary`）；PR2 事件文件独立，可并行。
另有按 §9 决定做的修复 PR：PR4（Core 里的修复，一个）、PR5（两个模块里的行为修复，建议拆成两个）。

**查到的分叉 bug**（§5.1）：Claude 收到 hook 事件从不刷新用量（`refreshThrottledFromHook()` 定义了没人调，Codex 那边调了）；
导出 Markdown 三处不一致（Claude 小标题写死英文、Claude 不跳过 `<…>` 系统注入、Codex 一处坏字节整份导出失败）；
快速切换续接没跟上「点通知跳回终端」的修法。**两边一样的潜在问题**（§5.2）里最要紧的是事件文件的「半行」：
一行事件被分两次写入时会整条丢掉，切在汉字中间时连同一批读到的完整事件一起丢 —— 已在 scratchpad 用与现在相同的读取逻辑复现。

术语：**格式（Format）**= 一种 CLI 的会话日志怎么读；**数据源（Source）**= 面板会话栏里两边不同的那几件事；
**回放** = 启动时读入事件文件里已有的行（不发通知）；**跟随** = 盯着事件文件之后新写入的行。

## 1. 现状

### 1.1 量化

去掉所有空白后逐行比较，空行不算。两种口径：

- **两边都出现的不同行**：两份文件各自去重后的交集。issue 里的 103 / 165 / 82 就是这个口径（`}` 这类行只算一次；
  「165/219」= Codex 面板 219 个不同行里有 165 个也在 Claude 面板里）。
- **按顺序对得上的相同行**：`difflib` 最长匹配块的总行数（顺序一致才算，`}` 也算）。

| 对比 | 总行数 / 非空行 | 两边都出现的不同行 | 按顺序对得上的相同行 | 连续 ≥ 3 行的相同段 |
|---|---|---|---|---|
| 会话索引 `ClaudeSessionIndex.swift` / `CodexSessionIndex.swift` | 654 / 577 · 330 / 289 | 103 | 148 | 23 段 108 行 |
| 快速切换 `ClaudeQuickSwitchPanel.swift` / `AIToolsQuickSwitchPanel.swift` | 614 / 558 · 324 / 286 | 165（Codex 不同行的 75%） | 230（Codex 非空行的 80%） | 25 段 201 行 |
| 事件监听 `ClaudeLiveStatus.swift` / `AIToolsNotify.swift` | 509 / 454 · 390 / 348 | 82 | 125 | 15 段 94 行 |

文件大小会误导：Claude 的会话索引文件里约 170 行是 Claude 独有的审计与磁盘分布；`AIToolsNotify.swift` 里约 140 行是 notify 脚本的生成与安装，
`ClaudeLiveStatus.swift` 里约 280 行是通知器、状态机与菜单汇总。下面三张表把每一段归成「完全相同 / 真差异 / 无意分叉」，并写明去向。

### 1.2 会话索引逐段对比

| 段 | Claude `ClaudeSessionIndex.swift` | Codex `CodexSessionIndex.swift` | 判定 | 去向 |
|---|---|---|---|---|
| ISO8601 两个 formatter、`parseDate`、`parseObject` | :17–40 | :17–36 | 完全相同 | `CLIJSONL` |
| `extractText` | :44–54（只认 `text` 块） | :40–51（还认 `input_text` / `output_text` / 无 type，跳过空串） | 真差异（两种日志格式） | 留模块 |
| `extractMeta` / `extractUserText` | — | :54–83 | 真差异（rollout 三种写法） | 留模块 |
| 摘要结构体 | :60–75（多 `model`、`contextTokens`） | :89–100 | 公共字段相同 | 留模块，声明遵循 `CLISessionSummary` |
| 单例、`@Published sessions / isRefreshing`、缓存字典、防重入标记 | :107–119 | :104–114 | 完全相同 | `CLISessionIndex` |
| `refresh()` | :137–154 | :121–137 | 相同（Claude 多一行 `scheduleCacheSave()`） | `CLISessionIndex` |
| `recentSessions(limit:)` | :157–159 | :140–142 | 完全相同，**两边都没有调用方** | 删 |
| `deleteSession` | :199–214 | :145–159 | 相同（Claude 多 `scheduleCacheSave()`） | `CLISessionIndex` |
| `exportMarkdown` 外壳 | :217–226 | :162–169 | 完全相同 | `CLISessionIndex` |
| 磁盘缓存（文件名、1 秒防抖、`flushCache`、启动读入） | :120、:126–132、:229–266 | —（不落盘，`DESIGN.md` 的「简化」） | 真差异（落不落盘） | `CLISessionIndex`，`cacheFileURL == nil` 即不落盘 |
| 缓存记录 + `toSummary` | :273–297（Codable，多两字段） | :175–195 | 结构相同 | 记录留模块（字段不动）；共用层只要 `modified` / `size` |
| `scanAll` 列文件 | :306–331（`projects/<项目>/*.jsonl` 两层） | :204–221（`sessions/` 递归、只要普通文件） | 真差异（目录布局） | `CLISessionFiles` 两个函数，格式选一个 |
| `scanAll` 复用判断（mtime 差 < 1 ms 且大小相同）+ 新→旧排序 | :333–351 | :223–239 | 完全相同 | `CLISessionScanner` |
| `scanFile` 打开 + 读头 64 KB | :355–371（另读尾 8 KB） | :243–251 | 同骨架 | 留模块（`Format.scan`） |
| 头 / 尾块解析、标题、id、项目路径兜底 | :373–431 | :253–274 | 真差异 | 留模块 |
| 组记录 | :433–444 | :276–285 | 相同 | 留模块 |
| `projectName(fromPath:)` | :612–615 | :303–306 | 完全相同 | `CLISessionPaths`（两个类名下照旧能调） |
| 清理旧会话 | :186–196 + :546–569 | `CodexEnv.swift:170–192` + `AIToolsSettingsView.swift:620–641` | 逻辑完全相同（只差根目录），放的位置不同 | `CLISessionFiles.removeJSONL` + `CLISessionIndex.cleanup` |
| 审计、`~/.claude` 磁盘分布 | :161–183、:455–543、:618–653 | （Codex 的磁盘统计在 `CodexEnv.swift:151–167`，口径不同） | 真差异 | 留模块 |
| `buildMarkdown` | :572–602 | :312–329 | 真差异（格式）+ 三处无意分叉（§5.1 B2） | 留模块（`Format.markdown`） |

### 1.3 快速切换面板逐段对比

| 段 | Claude `ClaudeQuickSwitchPanel.swift` | Codex `AIToolsQuickSwitchPanel.swift` | 判定 | 去向 |
|---|---|---|---|---|
| `NSPanel` 子类（`canBecomeKey`） | :14–16 | :13–15 | 完全相同 | `QuickSwitchWindow` |
| 视图模型：`query` / `selectedIndex`、会话过滤（标题 / 项目名 / 项目路径）、取选中、`moveSelection` / `clampSelection`、`resetForShow` | :28–43、:69–73、:85–90、:111–121 | :21–56 | 相同（Claude 按模式取条数） | 逻辑进 `QuickSwitchSelection`，视图模型留模块（变薄） |
| 文件模式：类别筛选、chips 计数、⇥ / ←→ | :30–32、:46–67、:92–109 | — | Claude 独有 | 留 Claude |
| 建面板、浮动层级、透明、居中于鼠标所在屏略偏上 | :170–194 | :87–111 | 完全相同 | `QuickSwitchPanelHost.show` |
| `hide()`、本地 keyDown 监听、全局点击监听 | :197–220 | :114–137 | 完全相同 | `QuickSwitchPanelHost` |
| 按键：↑↓ ⏎ ⌘C Esc | :223–276（另有 ⇥、文件模式 ←→、⌘⏎） | :140–164 | 相同的五个键 + Claude 多三个 | 键码解码进 `QuickSwitchKey`，按键含义留各自控制器 |
| 续接 | :280–298（先找正在跑的会话所在窗口，找不到再开新窗口） | :168–173（总开新窗口，`codex resume`） | 真差异（Codex 没有找进程的能力） | 数据源 `resume` |
| 复制续接命令 | :300–305 | :175–180 | 相同骨架，命令不同 | 数据源 `resumeCommand` |
| 根视图外框（640×420、毛玻璃、圆角、描边）、50 ms 后给搜索框焦点、改查询时夹紧选中 | :338–363 | :193–212 | 相同（Claude 多 chips 与模式切换） | `QuickSwitchCard`、`QuickSwitchSearchBar` |
| 搜索栏 | :365–389（图标 / 占位随模式、分段控件 `.focusable(false)`） | :214–226 | 相同骨架 | `QuickSwitchSearchBar`（右侧附件位给 Claude 放分段控件） |
| 会话列表（空态、`ScrollViewReader`、单击选中、双击续接、选中滚动居中） | :434–468 | :228–262 | 完全相同 | `QuickSwitchSessionList` |
| 会话行 | :517–545（第二行 = 会话行方案 `SessionRowFormatStore`） | :264–292（第二行 = 项目 · 相对时间，:295–298） | 相同布局，第二行不同 | `QuickSwitchSessionRow` + 数据源 `metadataLine` |
| 文件列表、文件行、chips | :392–424、:470–515、:547–573 | — | Claude 独有 | 留 Claude |
| 底栏 + 按键提示 | :575–613 | :300–323 | 相同骨架，内容不同 | `QuickSwitchFooter`、`QuickSwitchKeyHint` |
| `onCopy` 参数 | :165 传入、:333 声明 | :83 传入、:189 声明 | 两边都**从没用过** | 删 |

### 1.4 事件文件监听逐段对比

| 段 | Claude `ClaudeLiveStatus.swift` | Codex `AIToolsNotify.swift` | 判定 | 去向 |
|---|---|---|---|---|
| 监听器类：`open(O_EVTONLY)`、`.write/.extend`、自有串行队列、cancel 时 `close` | :224–266 | :38–77 | 完全相同（Claude 多一个只写不读的 `descriptor`，:230） | `EventFileWatcher` |
| `drain()`：读到文件尾、文件变短则偏移归零、按 `\n` 切行 | :269–288 | :79–95 | 完全相同（包括 §5.2 C1 的半行问题） | `EventFileWatcher` |
| `ensureEventFile`：没有就建、超限截断保尾 | :482–500 | :360–376 | 相同（上限 5 MB / 1000 行 vs 2 MB / 500 行） | `EventFileLog.prepare` + 各自的 `Limits` |
| `readAll` | :503–508 | :379–384 | 完全相同 | `EventFileLog.readAll` |
| `start()`：后台准备 + 读全部 → 主线程回放（不发通知）→ 从读到的大小起跟随 | :318–348（另起 6 小时过期清理定时器） | :162–184 | 同骨架 | `EventFileFollower` |
| `stop()` | :350–355 | :186–189 | 相同 | `EventFileFollower.stop` |
| 一行事件的处理 | :391–428（hook 状态机 + 等确认 / 完成通知） | :272–288（只认回合完成，回放时直接跳过） | 真差异 | 留模块 |
| 设置键、通知器、notify 脚本安装 | :47–219 | :19–32、:121–157、:191–255、:328–357 | 真差异 | 留模块 |

### 1.5 调用方

| 被调 | 调用方 |
|---|---|
| `ClaudeSessionIndex.shared` | `ClaudeCodeTool.swift:17/27/34`（`activate` 刷新、`willTerminate` flush），`ClaudeCodeCenterWindow.swift:120/154/207/282/309/785`，`ClaudeCodeSettingsView.swift:32/102/634/1135/1201/1214`，`ClaudeQuickSwitchPanel.swift:35/157/284/329`，`ClaudeLiveStatus.swift:379` |
| `ClaudeSessionIndex` 的静态成员 | `projectName(fromPath:)`：`ClaudeLiveStatus.swift:41/408/414`、`ClaudeFileIndex.swift:493`、`ClaudeUsage.swift:305`、`ClaudeCodeSettingsView.swift:761`；`demungeDirName`：`ClaudeFileIndex.swift:406`、`ClaudeUsage.swift:282`；`editToolNames`：`ClaudeFileIndex.swift:410` |
| `CodexSessionIndex.shared` | `AIToolsTool.swift:19/27/110`，`AIToolsCenterWindow.swift:138/168/219/282/306`，`AIToolsSettingsView.swift:32/90/633`，`AIToolsQuickSwitchPanel.swift:25/77/187` |
| `CodexSessionIndex.projectName(fromPath:)` | `CodexUsage.swift:371`、`AIToolsNotify.swift:284` |
| `ClaudeJSONLParsing.parseDate / parseObject`（12 处） | `ClaudeSessionIndex`、`ClaudeUsage`、`ClaudeFileIndex`、`ClaudeLiveStatus` |
| `CodexJSONLParsing.parseDate / parseObject`（6 处） | `CodexSessionIndex`、`CodexUsage`、`AIToolsNotify` |
| `ClaudeLiveStatus.start / stop` | `ClaudeCodeTool.swift:26`（`activate`）、`:37`（`willTerminate`） |
| `CodexNotify.start / stop` | `AIToolsTool.swift:30/35`，`AIToolsNotify.swift:218`（装好 notify 后 `start`）、`:249`（卸载后 `stop`） |
| `ClaudeQuickSwitchController.shared` | `ClaudeCodeTool.swift:58/62/110/119`（`toggle(mode:)`、`toggle()`、`showFiles()`） |
| `AIToolsQuickSwitchController.shared` | `AIToolsTool.swift:54/97`（`toggle()`） |

### 1.6 与 issue 描述的出入

1. 103 / 165 / 82 是「两边都出现的不同行」，不是「连续相同的代码」；顺序一致的相同行更多（148 / 230 / 125），但其中会话索引与事件监听
   真正能共用的部分集中在少数几段（§1.2、§1.4），面板的相同部分最成片（一段 31 行、一段 19 行）。
2. 两个**中心窗口**（`ClaudeCodeCenterWindow.swift` 866 行 / `AIToolsCenterWindow.swift` 704 行）有 248 个相同的不同行，比面板还多，issue 没提。
   会话页是会话索引的直接消费者，本次不动，列进 §5.3（建议另开 issue）。
3. 「两个模块之间不互相依赖」（`CodexUsage.swift:4–5` 与 `DESIGN.md` §7、§9.1 都这么写）其实早就不成立：`AIToolsQuickSwitchPanel.swift:171`、
   `AIToolsCenterWindow.swift:271` 调的 `TerminalLauncher` 定义在 `ClaudeCode/ClaudeEnv.swift:376`，Codex 的续接脚本也写进了
   `Baobox/ClaudeCode/launch/`（`ClaudeEnv.swift:383`）；`Core/TerminalFocus.swift:47` 同样反向调它。`DESIGN.md` §9.1 已记为已知项。
   本次不加深、也不顺手搬（§5.3、§9 D8）。

## 2. 目标与非目标

目标：

1. 会话索引的刷新 / 复用 / 排序 / 删除 / 导出外壳 / 磁盘缓存 / 清理旧会话只有一份；两个模块只留「会话文件在哪、怎么快扫一个文件、
   怎么导出、缓存放哪」和各自独有的功能（Claude 的审计、磁盘分布）。
2. 事件文件的建 / 截断 / 回放 / 增量监听只有一份；两个模块只留「一行事件怎么处理」。
3. 快速切换面板的窗口外壳、键码、过滤与选中、会话栏视图只有一份；两边的不同集中在各自的 `QuickSwitchSessionSource`。
4. 纯逻辑进 `BaoboxTests`：`Core/CLISession/`、`Core/EventFile/` 整目录与 `Core/QuickSwitch/QuickSwitchLogic.swift`。
5. 每个重构 PR 单独可合并、能编译、用户看不出变化；模块里的类型名、单例与调用方签名不变（`ClaudeSessionIndex.shared`、
   `CodexSessionIndex.shared`、`ClaudeSessionSummary`、`ClaudeQuickSwitchController.shared.toggle(mode:)`…）。
6. 新代码不让两个模块互相依赖，也不加深 Core → 模块的反向依赖。
7. 查到的问题列清楚（§5），修不修、怎么修由你定（§9），修就单独 PR。

有意的细小差别（只有一处，在 PR2，列出来备查）：

- 事件监听的启停竞态收紧（§5.2 C3）：`start()` 立即记「已启动」，重复调用直接返回（现在要等后台读完文件才算启动，期间再调会建出第二个监听器）；
  `stop()` 之后，已经排进主线程、还没处理的新行也不再处理。现有调用时序碰不上这两种情况，用户看不出。

非目标：

- 除上面一条外不改任何用户可见行为：菜单、快捷键 id、设置键与默认值、文案、通知、导出格式、面板键位与动作先后、缓存文件名与格式。
  §5 的修复 PR 例外，且要你点头。
- 不碰用量层（#134 已完成）；不合并两边的 JSONL 解析（格式本来就不同）。
- 不做「多栏通用面板」（§3.3 第 2 条）。
- 不改中心窗口、设置页、格式化工具（`ClaudeFormat` / `AIToolsFormat`）、菜单多行标题、`TerminalLauncher` 的位置、`ClaudeFileIndex`（§5.3）。
- 不开 Swift 6 严格并发检查。

## 3. 总体设计

### 3.1 分层与目录

```
Core/CLISession/                    纯 Foundation（CLISessionIndex 另用 Combine）—— 整目录进 BaoboxTests
  CLIJSONL.swift                    parseDate / parseObject；CLISessionPaths.projectName(fromPath:)
  CLISessionFormat.swift            CLISessionSummary、CLISessionRecord、CLISessionFormat、CLISessionFile
  CLISessionFiles.swift             两种列文件的办法 + 清理旧会话
  CLISessionIndex.swift             CLISessionScanner（纯函数）+ CLISessionIndex<Format>（ObservableObject 基类）
Core/EventFile/                     纯 Foundation —— 整目录进 BaoboxTests
  EventFileWatcher.swift            EventFileWatcher、EventFileLog、EventFileFollower
Core/QuickSwitch/
  QuickSwitchLogic.swift            QuickSwitchKey、QuickSwitchSelection —— 纯 Foundation，进 BaoboxTests
  QuickSwitchPanelHost.swift        QuickSwitchWindow、QuickSwitchPanelHost（AppKit）
  QuickSwitchSessionSource.swift    会话数据源协议
  QuickSwitchViews.swift            QuickSwitchCard / SearchBar / SessionList / SessionRow / Footer / KeyHint（SwiftUI）

Modules/ClaudeCode/                 ClaudeSessionFormat + ClaudeSessionRecord + ClaudeSessionIndex（子类：shared、审计、磁盘分布）
                                    ClaudeLiveStatus 用 EventFileFollower；ClaudeQuickSwitchSource + 最近文件模式
Modules/AITools/                    CodexSessionFormat + CodexSessionRecord + CodexSessionIndex（子类：shared）
                                    CodexNotify 用 EventFileFollower；CodexQuickSwitchSource
```

### 3.2 依赖规则

1. 三个新 Core 目录不引用任何模块类型（`ClaudeEnv`、`CodexEnv`、`TerminalLauncher`…），也不调 `L()`（测试 target 里没有本地化表，
   同 `../meeting/ENGINE.md` §5.1）、`NotifyCenter`、`StorageWriteFailure`（这两个会把 App 拖进测试 target）。文案、路径、通知都由模块传进来或留在模块。
2. `Core/CLISession/`、`Core/EventFile/`、`QuickSwitchLogic.swift` 只 `import Foundation`（`CLISessionIndex.swift` 加 `Combine`），
   在 `mac/project.yml` 的 `BaoboxTests.sources` 里各加一行。
3. 两个模块之间不新增依赖：格式、记录、数据源都放在各自模块。
4. 模块里对外的名字不变：`ClaudeSessionIndex` / `CodexSessionIndex` 仍是类（子类），`shared` 仍是 `static let`；静态成员经继承照旧能用
   （`ClaudeSessionIndex.projectName(fromPath:)`、`CodexSessionIndex.projectName(fromPath:)`）。

### 3.3 三个关键取舍

1. **泛型参数是「格式」不是「摘要」，模块用非泛型子类。** 索引要的不只是摘要类型，还有缓存记录类型、怎么列文件、怎么快扫、怎么导出、缓存放哪 ——
   打包成一个只有静态成员的 `CLISessionFormat`，与 #134 的 `CLIUsageCalculator<Table: CLIUsagePricingTable>` 同一个写法。
   用子类而不是 `typealias`：Swift 不允许泛型类型里有 `static` 存储属性，`shared` 只能放在非泛型子类里；子类也正好是 Claude 审计、
   磁盘分布的家。`@Published` 全在基类、子类不加，避开早年「子类的 `@Published` 不触发 `objectWillChange`」的坑；
   scratchpad 运行期探针在 macOS 14.6 上确认：经子类实例改基类的 `@Published`，`objectWillChange` 照常触发、列表照常发布。
2. **面板抽部件 + 会话数据源协议，不抽成一个多栏通用面板。** 两个面板一个是另一个的超集：Claude 多一个「最近文件」模式（chips、类别循环、
   单击即打开、⌘⏎ 访达、加载态）。做成「一个泛型面板 + 可选第二栏」要给第二栏定义一整套协议（列表视图、chips、按键优先权、提示、计数、
   重置），而使用者只有 Claude 一个，键盘焦点这类最怕改坏的行为反而要在新框架里重写一遍。部件做法下：完全相同的东西（窗口外壳、键码、
   过滤与选中、会话栏视图）只有一份，Codex 面板缩成「数据源 + 薄控制器 + 拼起来的视图」，Claude 的文件模式原样留下、只借用外壳与会话栏。
3. **先原样搬、后单独修。** 重构 PR 只搬家，用差分测试证明「新旧逐字段一致」；修复改的是共用层（PR4）或某一个模块（PR5），各自有测试、
   可单独回退。这样每个 PR 的验证都简单：重构 PR 比「一不一样」，修复 PR 比「修没修好」。

## 4. 接口设计

签名已在 scratchpad 用 `swiftc -typecheck`（Swift 6.0.3，`-swift-version 5`，macOS 14 目标）连同模拟两个模块的桩代码核对过；
进测试 target 的那部分只带 Foundation 单独也能编；仓库里不留这些文件。下面只列签名与约定，实现照搬现有代码。

### 4.1 会话索引 `Core/CLISession/`

```swift
/// CLI 会话日志（JSONL）逐行解析的小工具。两个 ISO8601 formatter 建成静态常量复用。任意线程可调。
enum CLIJSONL {
    static func parseDate(_ string: String) -> Date?          // 先试带毫秒，再试不带
    static func parseObject(_ data: Data) -> [String: Any]?
}

enum CLISessionPaths {
    /// 路径最后一段；最后一段为空时返回原路径。
    static func projectName(fromPath path: String) -> String
}

/// 会话摘要：共用层只用到这几项（删除、导出、搜索、排序、列表行）。
protocol CLISessionSummary: Identifiable where ID == String {
    var id: String { get }
    var fileURL: URL { get }
    var projectPath: String { get }
    var projectName: String { get }
    var title: String { get }
    var lastActivity: Date { get }
}

/// 一个会话文件：列目录时顺手取到的 mtime 与大小。
struct CLISessionFile: Equatable, Sendable {
    let url: URL
    let modified: Date
    let size: Int64
}

/// 缓存记录：扫描时文件的 mtime（timeIntervalSince1970）与大小，都没变就复用。要落盘的记录靠 Codable 编码。
protocol CLISessionRecord: Codable {
    var modified: Double { get }
    var size: Int64 { get }
}

/// 一种 CLI 会话日志的「格式」。全是静态成员、不碰主线程状态，在后台线程调用。各模块实现一个。
protocol CLISessionFormat {
    associatedtype Summary: CLISessionSummary
    associatedtype Record: CLISessionRecord

    /// 列出全部会话文件；顺序就是同一时间戳时的先后（排序前的原始顺序）。
    static func sessionFiles() -> [CLISessionFile]
    /// 快扫一个文件；nil = 打不开 / 读失败，这次跳过（不进缓存，下次再试）。
    static func scan(_ file: CLISessionFile) -> Record?
    static func summary(of record: Record, fileURL: URL) -> Summary
    /// 磁盘缓存文件；nil = 只在内存里缓存。
    static var cacheFileURL: URL? { get }
    /// 清理旧会话时递归查找 .jsonl 的根目录。
    static var logRoot: URL { get }
    /// 整份会话导出成 Markdown；nil = 读失败。
    static func markdown(fileURL: URL, title: String) -> String?
}

enum CLISessionFiles {
    /// root/<子目录>/*.jsonl，只看一层子目录、不递归、跳过隐藏项（Claude Code：projects/<项目>/<会话>.jsonl）。
    static func jsonlInSubdirectories(of root: URL) -> [CLISessionFile]
    /// root 下递归找 .jsonl 普通文件、跳过隐藏项（Codex：sessions/YYYY/MM/DD/rollout-*.jsonl）。
    static func jsonlRecursively(under root: URL) -> [CLISessionFile]
    /// 递归删掉 mtime 早于 now - days 的 .jsonl；取不到 mtime 当作 now（不删）。返回（删除数，释放字节）。
    static func removeJSONL(under root: URL, olderThanDays days: Int, now: Date = Date()) -> (count: Int, bytes: Int64)
}

/// 一次刷新的纯逻辑：mtime 差 < 1 ms 且大小相同的复用缓存，其余调 scan；摘要按 lastActivity 新→旧。
enum CLISessionScanner<Format: CLISessionFormat> {
    static func isUnchanged(_ record: Format.Record, _ file: CLISessionFile) -> Bool
    static func refresh(files: [CLISessionFile], previous: [String: Format.Record],
                        scan: (CLISessionFile) -> Format.Record? = Format.scan)
        -> (summaries: [Format.Summary], cache: [String: Format.Record])
}

/// 会话索引基类。模块写一个非泛型子类放 `static let shared`。@Published 只在主线程写；重 IO 都在后台，回调在主线程。
@MainActor
class CLISessionIndex<Format: CLISessionFormat>: ObservableObject {
    @Published private(set) var sessions: [Format.Summary]     // 新→旧
    @Published private(set) var isRefreshing: Bool

    init()                                                      // 有 cacheFileURL 就同步读入缓存（与现在 Claude 的 init 相同）
    nonisolated static func projectName(fromPath path: String) -> String   // 转给 CLISessionPaths，保住两个类名下的旧调用

    func refresh()                                              // 进行中不重入；后台扫 → 主线程发布 → 安排 1 秒后落盘
    func deleteSession(_ summary: Format.Summary, completion: @escaping (Bool) -> Void)
    func exportMarkdown(_ summary: Format.Summary, completion: @escaping (String?) -> Void)
    func cleanup(olderThanDays days: Int, completion: @escaping (Int, Int64) -> Void)   // 删完先 refresh() 再回调
    func flushCache()                                           // willTerminate 调；cacheFileURL 为 nil 时什么也不做
}
```

约定（照搬现状，差分测试逐条核）：

- 复用判断 `abs(record.modified - mtime) < 0.001 && record.size == size`；`scan` 返回 nil 的文件既不进缓存也不进列表；目录里消失的文件随之出缓存。
- 列文件的顺序与现在逐字一致（同样的 `FileManager` 调用、同样的资源键与选项），排序比较器不变，所以同时间戳的先后不变。
- 磁盘缓存：`[String: Record]` 用默认 `JSONEncoder` 编码；写前建父目录（等价于现在的 `ClaudeEnv.ensureSupportDir()`）；写失败照旧静默
  （缓存是派生数据，丢了只是下次多扫，不走 `StorageWriteFailure`）。
- `cleanup` 的完成顺序与现在 Claude 的相同：先 `refresh()`，再回调。

模块这边（以 Claude 为例，Codex 同形）：

```swift
// Modules/ClaudeCode/ClaudeSessionIndex.swift
enum ClaudeJSONLParsing { static func extractText(fromContent content: Any) -> String? }   // 只剩 Claude 自己的
struct ClaudeSessionSummary: Identifiable, Equatable, CLISessionSummary { /* 字段不变 */ }
struct ClaudeSessionRecord: CLISessionRecord { /* 原 ClaudeSessionIndex.CacheRecord，字段不变 → index-cache-v2.json 照读 */ }

enum ClaudeSessionFormat: CLISessionFormat {
    static var cacheFileURL: URL? { ClaudeEnv.supportDir.appendingPathComponent("index-cache-v2.json") }
    static var logRoot: URL { ClaudeEnv.projectsDir }
    static func sessionFiles() -> [CLISessionFile] { CLISessionFiles.jsonlInSubdirectories(of: ClaudeEnv.projectsDir) }
    static func scan(_ file: CLISessionFile) -> ClaudeSessionRecord?   // 原 scanFile：头 64 KB + 尾 8 KB；mungedDir = 文件的上级目录名
    static func summary(of record: ClaudeSessionRecord, fileURL: URL) -> ClaudeSessionSummary { record.toSummary(fileURL: fileURL) }
    static func markdown(fileURL: URL, title: String) -> String?        // 原 buildMarkdown
}

@MainActor
final class ClaudeSessionIndex: CLISessionIndex<ClaudeSessionFormat> {
    static let shared = ClaudeSessionIndex()
    nonisolated static let editToolNames: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    private override init() { super.init() }

    func auditEntries(on day: Date, completion: @escaping ([ClaudeAuditProject]) -> Void)   // 原样
    func diskStats(completion: @escaping (ClaudeDiskStats) -> Void)                          // 原样
    nonisolated static func demungeDirName(_ dir: String) -> String                         // 原样
    // computeAudit / computeDiskStats / directorySize / projectsSizeAndCount 原样
}
```

Codex：`CodexSessionFormat` 的 `cacheFileURL` 为 nil、`logRoot = CodexEnv.sessionsDir`、`sessionFiles()` 用 `jsonlRecursively`；
`CodexSessionRecord` 是原 `CodexSessionIndex.CacheRecord` 加 `Codable`（不落盘，只为满足协议）；`CodexEnv.cleanupSessions` 删掉，
`AIToolsSettingsView.confirmCleanup` 改调 `CodexSessionIndex.shared.cleanup(olderThanDays:)`（不再手动 `refresh()`，共用层会刷）。

### 4.2 事件文件 `Core/EventFile/`

```swift
/// 盯一个只会追加的事件文件（hook / notify 脚本一行一个 JSON），把新写进来的行交出去。
/// 自有串行队列：打开、读取、偏移都只在这个队列上；onLines 也在这个队列上调（调用方自己切主线程）。
final class EventFileWatcher {
    init(url: URL, startOffset: UInt64, queueLabel: String, onLines: @escaping ([String]) -> Void)
    func start()      // open(O_EVTONLY) + DispatchSource(.write/.extend)；文件打不开就什么也不做（同现在）
    func stop()
}

/// 事件文件的维护。
enum EventFileLog {
    struct Limits: Equatable, Sendable { var maxBytes: Int; var keepTailLines: Int }
    /// 建父目录；没有文件就建空文件；超过 maxBytes 就只留最后 keepTailLines 行。启动时调一次。
    static func prepare(_ url: URL, limits: Limits)
    /// 全部行 + 当前大小（作为跟随的起点）。
    static func readAll(_ url: URL) -> (lines: [String], size: UInt64)
}

/// 回放 + 跟随：后台 prepare + readAll → 主线程 replay(已有行) → 从读到的大小起跟随，新行在主线程交给 follow。
@MainActor
final class EventFileFollower {
    init(url: URL, limits: EventFileLog.Limits, queueLabel: String)
    var isStarted: Bool { get }
    func start(replay: @escaping ([String]) -> Void, follow: @escaping ([String]) -> Void)   // 已启动则直接返回
    func stop()
}
```

模块这边：

```swift
// ClaudeLiveStatus
private let follower = EventFileFollower(url: ClaudeEnv.supportDir.appendingPathComponent("events.jsonl"),
                                         limits: .init(maxBytes: 5 * 1_024 * 1_024, keepTailLines: 1_000),
                                         queueLabel: "com.baobox.claudecode.eventwatcher")
func start() {
    follower.start(
        replay: { [weak self] lines in            // 初始回放不发通知（同现在）
            guard let self else { return }
            for line in lines { self.apply(line: line, notify: false) }
            self.pruneStale()
            self.startPruneTimer()
        },
        follow: { [weak self] lines in
            guard let self else { return }
            for line in lines { self.apply(line: line, notify: true) }
            self.pruneStale()
        })
}
func stop() { follower.stop(); pruneTimer?.invalidate(); pruneTimer = nil }

// CodexNotify：limits 2 MB / 500 行，queueLabel "com.baobox.aitools.eventwatcher"，replay 什么也不做（现在的 apply 在回放时本来就直接返回）
```

和现在相比只有两处时序上的变化：过期清理定时器在回放回调里起（原来在建好监听器之后，同一个主线程回合里，看不出差别）；
§2 那条启停竞态的收紧。

### 4.3 快速切换 `Core/QuickSwitch/`

```swift
// QuickSwitchLogic.swift —— 纯 Foundation，进 BaoboxTests
/// 面板认的键（Carbon 虚拟键码，与剪贴板面板同一套）。方向键不看修饰键（同现在）。
enum QuickSwitchKey: Equatable {
    case up, down, left, right, tab, escape
    case enter(command: Bool)        // Return 0x24 / 小键盘 Enter 0x4C
    case copy                        // ⌘C（0x08 + ⌘）
    init?(keyCode: UInt16, command: Bool)
}

enum QuickSwitchSelection {
    /// 空查询原样返回；否则任一字段 lowercased 包含 query.lowercased()（不 trim，同现在）。
    static func filter<T>(_ items: [T], query: String, fields: [KeyPath<T, String>]) -> [T]
    static func moved(_ index: Int, by delta: Int, count: Int) -> Int     // count 为 0 时不动
    static func clamped(_ index: Int, count: Int) -> Int                  // count 为 0 时归零
    static func cycled(_ index: Int, by delta: Int, count: Int) -> Int    // 首尾循环（Claude 的类别筛选）
    static func element<T>(_ list: [T], at index: Int) -> T?
}

// QuickSwitchPanelHost.swift —— AppKit
final class QuickSwitchWindow: NSPanel { override var canBecomeKey: Bool { true } }

/// Spotlight 式面板的窗口外壳：640×420 borderless + nonactivatingPanel、浮动层级、透明、居中于鼠标所在屏略偏上（y = midY - 140）；
/// 本地 keyDown 监听只拦本面板的事件，全局左键监听 = 点面板外收起。内容与按键含义由调用方给。
@MainActor
final class QuickSwitchPanelHost {
    static let size: NSSize
    var isVisible: Bool { get }
    /// onKey 返回 true = 已消费（不再传给搜索框）。
    func show<Content: View>(_ content: Content, onKey: @escaping (NSEvent) -> Bool)
    func hide()
}
extension QuickSwitchKey { init?(_ event: NSEvent) }

// QuickSwitchSessionSource.swift
/// 面板「会话」那一栏要的东西；Claude Code 助手、Codex 助手各实现一个（放各自模块）。两边的不同全在这里。
@MainActor
protocol QuickSwitchSessionSource {
    associatedtype Session: CLISessionSummary
    var sessions: [Session] { get }                       // 新→旧，读索引内存，零磁盘 IO
    func refresh()                                        // 面板打开时调：后台刷新索引
    func metadataLine(for session: Session) -> String     // 行的第二行；空串 = 不显示
    func resume(_ session: Session)                       // ⏎ / 双击；调用前面板已收起
    func resumeCommand(for session: Session) -> String    // ⌘C：可直接粘贴执行的续接命令
}
extension QuickSwitchSessionSource {
    func sessions(matching query: String) -> [Session]    // 标题 / 项目名 / 项目路径
}

// QuickSwitchViews.swift —— SwiftUI
struct QuickSwitchCard<Content: View>: View                    // 640×420、.ultraThinMaterial、圆角 14、描边
struct QuickSwitchSearchBar<Accessory: View>: View {           // 图标 + 输入框 + 右侧附件；自带 @FocusState 与「50 ms 后聚焦」
    init(symbol: String, placeholder: LocalizedStringKey, text: Binding<String>, @ViewBuilder accessory: () -> Accessory)
}
struct QuickSwitchSessionList<Source: QuickSwitchSessionSource>: View {
    init(source: Source, sessions: [Source.Session], selectedIndex: Binding<Int>,
         emptyText: LocalizedStringKey, onResume: @escaping (Source.Session) -> Void)
}
struct QuickSwitchSessionRow: View      // init(title:meta:selected:)
struct QuickSwitchFooter<Content: View>: View
struct QuickSwitchKeyHint: View         // init(key:label:)
```

各模块剩下的：

- **Codex**（约 120 行）：`CodexQuickSwitchSource`（第二行 = 项目 · 相对时间；续接 = `TerminalLauncher.run(codex resume …)`；命令 = `CodexResumeCommand.fullCommand`）、
  薄视图模型（`query` / `selectedIndex` 两个 `@Published`，其余调 `QuickSwitchSelection`）、控制器（`QuickSwitchPanelHost` + 五个键）、
  用部件拼的视图（视图里保留 `@ObservedObject private var index = CodexSessionIndex.shared`，会话变了要重画）。
- **Claude**（约 430 行）：`ClaudeQuickSwitchSource`（第二行 = `SessionRowFormatStore.shared.metadataLine`；续接 = 原 `resume` 的「先找正在跑的窗口，否则开新窗口」）、
  视图模型（多出模式、类别筛选、文件过滤，条数随模式）、控制器（八个键、文件动作、`toggle(mode:)`、`showFiles()`）、视图（搜索栏的附件位放分段控件，
  照旧 `.focusable(false)`；会话栏用 `QuickSwitchSessionList`；文件栏、文件行、chips 原样）。

两条照旧要守的细节：每个动作原来的「收面板」先后不变（续接：先收再续；复制：先写剪贴板再收；打开文件 / 访达：先做再收，`eb7e8db` 修过）；
Tab 只有 Claude 吃掉（Codex 现在放行，保持）。

### 4.4 两个模块各自留下的差异

| | Claude Code 助手 | Codex 助手 |
|---|---|---|
| 会话文件 | `~/.claude/projects/<项目>/*.jsonl`（两层） | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`（递归、只要普通文件） |
| 快扫 | 头 64 KB + 尾 8 KB：summary 行或首条用户输入（截 60 字）、cwd、末次时间戳、模型、上下文规模 | 头 64 KB：SessionMeta 的 id / cwd、首条用户输入（截 80 字）；最后活动 = mtime |
| 摘要独有字段 | `model`、`contextTokens`（会话行方案用） | — |
| 磁盘缓存 | `index-cache-v2.json` | 不落盘 |
| 导出 | 自己的 `markdown` | 自己的 `markdown` |
| 独有功能 | 今日改动审计、`~/.claude` 磁盘分布 | `~/.codex/sessions` 磁盘统计（`CodexEnv`） |
| 事件文件 | `events.jsonl`，5 MB / 1000 行；回放重建状态机 | `codex-events.jsonl`，2 MB / 500 行；只处理新行 |
| 面板 | 会话 + 最近文件两种模式；第二行按会话行方案；续接先找正在跑的窗口 | 只有会话；第二行 = 项目 · 相对时间；续接总开新窗口 |

## 5. 查到的问题

### 5.1 两边不一致（一边对、一边漏）

**B1. Claude 收到 hook 事件从不刷新用量（Codex 收到回合完成会刷）**

- 证据：`ClaudeUsage.swift:133` 的 `refreshThrottledFromHook()` 没有调用方（`git log -S` 只找到定义它的 `b7f51ab` 与写进 CORE_API 的 `bb6f5df`）；
  `TECH_DESIGN.md` §3.3 写的是「refresh 触发：activate 后首次 + Timer 每 5 分钟 + 收到 hook 事件时（节流 ≥ 60 s）」。
  Codex 这边 `AIToolsNotify.swift:287` 每个回合完成都调 `CodexUsageStore.shared.refreshThrottledFromEvent()`。
- 影响：Claude 的菜单「今日 $x」、额度副标题、80% 提醒最多晚 5 分钟（只靠 `ClaudeUsage.swift:115–125` 的定时器）；Codex 回合一完就更新。
- 建议：`ClaudeLiveStatus.apply` 在 `notify == true` 的 `Stop` 与 `Notification`（刚产生了用量的时刻）调它，节流不变（§9 D4）。PR5。

**B2. 导出 Markdown 三处不一致**

- (a) Claude 的小标题写死英文 `## User` / `## Assistant`（`ClaudeSessionIndex.swift:596`），不符合「用户可见文案走 `L()`」；
  Codex 用 `L("aitools.export.user" / "aitools.export.assistant")`（`CodexSessionIndex.swift:325`），中文界面导出「用户 / 助手」。
- (b) Claude 不跳过以 `<` 开头的系统注入（`<command-name>`、`<local-command-stdout>` 之类），它们会变成一段「## User」；Codex 跳过（`:322–324`）。
  两边的标题提取都跳过（Claude `:396`、Codex `:264`），只有 Claude 的导出没跟上。
- (c) Codex 把整份文件按 UTF-8 解成 `String`（`:313`），文件里任一处坏字节（比如正在写的会话末尾半个汉字）整份导出失败、弹「导出失败」；
  Claude 按字节切行（`:573–576`），坏行单独跳过。
- 建议：对齐成「本地化小标题 + 跳过系统注入 + 按行容错」。(a)(b) 改的是 Claude 导出的内容（中文界面的小标题会变），要你点头（§9 D5）。PR5。

**B3. 快速切换续接没跟上「点通知跳回终端」的修法（Claude 内部两条路径分叉）**

- `NOTIFY_JUMP.md` §1 指出快速切换「按进程猜」有两个缺口：同一目录开着几个会话会猜错；不认 Otty。于是点通知改成先用 hook 记下的终端位置
  （`ClaudeLiveStatus.swift:446–461`：先 `TerminalFocus.focus(terminal)`，没有再按进程猜）。快速切换的续接（`ClaudeQuickSwitchPanel.swift:280–298`）
  仍然只按进程猜，而 `ClaudeLiveStatus.shared.sessions[session.id]?.terminal` 里就有这个会话的位置。
- 影响：在同一目录同时开着几个 Claude 时，从面板续接可能切错窗口；Otty 里正在跑的会话，从面板续接会再开一个新窗口。
- 建议：抽一个「把正在跑的会话切到前台」的函数（位置优先 → 按进程猜 → 都不行返回 false），面板与通知共用；面板拿到 false 再开新窗口。
  Codex 没有「会话 → 终端」的对应关系，维持开新窗口（§9 D6）。PR5，只动 ClaudeCode。

**B4. 其他小分叉（搬家时自然消失，或当真差异保留）**

- `ClaudeEventWatcher.descriptor`（`ClaudeLiveStatus.swift:230/243/264`）只写不读，Codex 版没有 → PR2 后消失。
- 两个面板都把 `onCopy` 传进视图却从不用（§1.3 末行）→ PR3 后消失。
- `recentSessions(limit:)` 两边都没调用方（菜单早就不平铺最近会话）→ PR1 删除，`CORE_API.md` 同步。
- 标题截断 60 字（Claude `:428`）vs 80 字（Codex `:272`）、事件文件上限 5 MB / 1000 行 vs 2 MB / 500 行：当真差异保留，各在各的格式 / `Limits` 里。
- Claude 的磁盘缓存把已本地化的「(无标题会话)」存进 `index-cache-v2.json`，换界面语言后旧会话仍显示旧语言，直到文件变化；Codex 不落盘没这问题。影响很小，不改。

### 5.2 两边一样的潜在问题（搬进共用层后修一次）

**C1. 事件文件的「半行」会丢事件（最要紧；两边都有，Codex 更容易碰上）—— 已修（PR4）**

- 现在的读法（`ClaudeLiveStatus.swift:269–288`、`AIToolsNotify.swift:79–95`）：读到文件尾、偏移直接设成文件尾、整块按 UTF-8 解码、
  按 `\n` 切开后**连最后那截没写完的行也交出去**。
- 怎么发生：hook / notify 脚本用 `printf … >> 文件` 写一行，行长时 stdio 会按缓冲区（几 KB）分几次 `write`；监听恰好在两次 `write` 之间醒来，
  就读到半行，偏移又越过了它 —— 前半截与后半截各自解析失败，整条事件丢掉。更糟的是切点落在多字节字符中间（中文提示词、中文回复）：
  整块 `String(data:encoding: .utf8)` 返回 nil，同一批读到的**完整事件也一起丢**。Codex 的事件带整段 `last-assistant-message`，Claude 的
  `UserPromptSubmit` 带整段提示词，几 KB 很常见。启动时的 `readAll` 对最后一行同样如此。
- 复现：scratchpad 探针用与现在相同的读取逻辑、确定性地模拟「两次写入之间读一次」：一行分两次写 → 交出两截、都解析失败；
  一条完整事件 + 一行切在「成」字中间 → 这一批交出 0 行，下一批的尾巴也解析失败。
- 仓库里已经有对的写法：`ClaudeFileIndex` 只消费到最后一个 `\n`（`ClaudeFileIndex.swift:383–390`，`RECENT_FILES.md` §4.2「半行安全」），这两处没跟上。
- 修法：只消费到最后一个 `\n`、偏移停在其后，剩下的留给下次；先按字节切行再逐行解码，坏行单独丢；`readAll` 只返回完整行，大小也只算到最后一个 `\n`。PR4，单测覆盖。

**C2. 事件文件被删 / 被替换后监听永久失效 —— 已修（PR4）**

- 只监听 `.write/.extend`，盯的是打开时的那个文件节点。文件被删（用户或清理工具删了 `~/Library/Application Support/Baobox/<模块>/`）后脚本用 `>>`
  建出的是新文件，Baobox 再也收不到，要重启 App。Codex 的脚本还不 `mkdir -p`（Claude 的有，`ClaudeHooks.swift:44`），目录没了连写都写不进去。
- 修法：再监听 `.delete/.rename`，失效后建回目录与文件、偏移归零重新打开（监听父目录等它出现，不轮询）。PR4，优先级低于 C1。

**C3. 监听的启停竞态**

- 监听器要等后台读完文件才赋值（`ClaudeLiveStatus.swift:319–346`、`AIToolsNotify.swift:163–182`）：这期间再 `start()` 会建出第二个监听器（重复通知，第一个永远不停）；
  这期间 `stop()` 挡不住随后建出来的监听器；`stop()` 后已排进主线程的新行仍会被处理。现在的调用时序碰不上（Claude 只在 `activate` 调一次；
  Codex 的 `activate` 与开关通知隔得很远）。
- 处理：`EventFileFollower` 立即记「已启动」并用代次号丢弃过期回调，PR2 顺带收紧（§2 唯一一条有意差别）。

**C4. 会话索引的刷新请求会被吞，删掉的会话可能被旧扫描写回来 —— 已修（PR4）**

- `refresh()` 进行中再调直接丢弃（`ClaudeSessionIndex.swift:138`、`CodexSessionIndex.swift:122`）。清理旧会话后的刷新（Claude `:191`、Codex `AIToolsSettingsView.swift:633`）
  若撞上一次正在进行的扫描就被吞掉，而那次扫描在删除之前列的目录，发布时把刚删的会话又放回列表；`deleteSession` 同理。要时间重叠，概率低。
- 修法：进行中再请求时记一笔，本次结束后再刷一次（合并请求）。PR4。

**C5. 会话列表只在少数时刻刷新**

- 两个索引只在 `activate`、打开面板、打开中心窗口、清理之后刷新，没有定时器，菜单打开时也不刷 —— `TECH_DESIGN.md` §0 写的「只读内存缓存，同时触发后台刷新」没有实现。
- 影响：Claude 状态行没装 hooks 时的「N 个会话活跃（推断）」（`ClaudeLiveStatus.swift:378–385`）拿陈旧的 `lastActivity` 比「2 分钟内」，几乎永远显示不出来；
  Codex 状态行的会话数（`AIToolsTool.swift:110`）长时间不变。
- 修法：`submenuItems()` 里顺手 `index.refresh()`（后台跑；没变的文件只 stat 不读；进行中不重入），下一次打开菜单就是新的。不碰菜单构建本身的零磁盘 IO（§9 D7）。

**C6. `flushCache()` 名为「退出前立即落盘」，实际把写盘派到后台队列 —— 已修（PR4）**

- `ClaudeSessionIndex.swift:229–258`（`ClaudeFileIndex.swift:238–266` 同款）：`willTerminate` 返回后进程可能先退出，最后一秒内的变化没写进缓存。只影响下次启动多扫几个文件。
- 修法：flush 同步写。PR4，顺手。

### 5.3 范围外的重复（建议另开 issue，P2）

| 重复 | 量 | 说明 |
|---|---|---|
| 中心窗口 `ClaudeCodeCenterWindow.swift` / `AIToolsCenterWindow.swift` | 248 个相同的不同行，按顺序 420 行 | 会话页（搜索、列表行、续接 / 复制 / 导出 / 删除）+ 用量页。会话页在本次之后可直接用 `CLISessionSummary` 与索引的导出 / 删除 |
| `ClaudeFormat`（`ClaudeCodeCenterWindow.swift:14–64`）/ `AIToolsFormat`（`AIToolsCenterWindow.swift:13–63`） | 只差 `countdownLong` 的文案 key | 费用、token、倒计时、字节、相对时间 |
| 菜单多行标题 `multiLineTitle` | `ClaudeCodeTool.swift:172–187` / `AIToolsTool.swift:146–161` 逐行相同 | |
| 单引号转义 | `ClaudeEnv.swift:311`、`AIToolsNotify.swift:387`、`AIToolsCenterWindow.swift:83` 三份 | |
| `TerminalLauncher` 在 ClaudeCode 模块 | AITools 与 `Core/TerminalFocus.swift` 反向依赖它 | 搬进 Core 才算两模块真正解耦（§1.6 第 3 条） |
| 会话目录遍历 | Claude 模块内两层遍历写了 5 遍（会话索引、审计、`ClaudeFileIndex`、用量、调用统计），Codex 递归遍历 5 遍 | 本次之后可改用 `CLISessionFiles` |
| `ClaudeFileIndex` 的外壳 | 刷新防重入、1 秒防抖落盘、flush 与会话索引同款 | 它多一个「只读追加部分」的路径，可在 `CLISessionIndex` 稳定后再套 |
| 用量 Store 外壳（#134 之后剩下的） | `ClaudeUsage.swift` / `CodexUsage.swift` 98 个相同的不同行，连续段约 74 行 | 定时器、节流刷新、refresh 管线；算法已在 `Core/CLIUsage/` |
| 设置页 | `ClaudeCodeSettingsView.swift` / `AIToolsSettingsView.swift` 164 个相同的不同行 | 以维护节（磁盘、清理、版本检查）为主 |

## 6. 迁移步骤

每个 PR 单独可合并、能编译；重构 PR 用户看不出变化（§2 那一条除外）。搬家的 PR 用 `git diff -M --color-moved=zebra` 看，搬过去的代码应整块着色、只有改名处不同。

| PR | 一句话 | 依赖 |
|---|---|---|
| PR1 | 会话索引共用层 `Core/CLISession/`，两个索引改成子类 | 无 |
| PR2 | 事件文件共用层 `Core/EventFile/`，两边改用 `EventFileFollower` | 无（可与 PR1 并行） |
| PR3 | 快速切换部件 `Core/QuickSwitch/` + 会话数据源，两个面板改用 | PR1 |
| PR4 | Core 里的修复：半行 / UTF-8、文件被删后重开、刷新请求合并、退出同步落盘 | PR1、PR2；按 §9 D3、D7 |
| PR5 | 模块里的行为修复：Claude hook 刷用量、导出对齐、面板续接先用终端位置、菜单打开顺带刷新 | 导出要 PR1、面板要 PR3（hook 刷用量无依赖）；按 §9 D4–D7，可再拆 |

估算（行数）：PR1 后 `ClaudeSessionIndex.swift` 约 460、`CodexSessionIndex.swift` 约 210、`Core/CLISession/` 约 250；PR2 后 `ClaudeLiveStatus.swift` 约 400、
`AIToolsNotify.swift` 约 290、`Core/EventFile/` 约 150；PR3 后 Claude 面板约 430、Codex 面板约 120、`Core/QuickSwitch/` 约 280。总行数降得不多（几百行），
收益在「改一处两边一起变」和测试覆盖。

### PR1 会话索引共用层

`refactor(cli): share the session index between Claude Code and Codex (#109)`

- 新增：`Core/CLISession/CLIJSONL.swift`、`CLISessionFormat.swift`、`CLISessionFiles.swift`、`CLISessionIndex.swift`（§4.1）；
  `mac/Tests/CLISession/`（§7.1）。
- 改：
  - `Modules/ClaudeCode/ClaudeSessionIndex.swift`：`ClaudeJSONLParsing` 只留 `extractText`；`CacheRecord` 改名 `ClaudeSessionRecord`（字段不动）；
    新增 `ClaudeSessionFormat`（`scan` = 原 `scanFile` 去掉签名里的 `mungedDir`，改从文件的上级目录名取；`markdown` = 原 `buildMarkdown`）；
    `ClaudeSessionIndex` 改成子类，删 `refresh` / `deleteSession` / `exportMarkdown` / `flushCache` / 缓存持久化 / `recentSessions` / `performCleanup` / `projectName`。
  - `Modules/AITools/CodexSessionIndex.swift`：同上（`CodexSessionRecord`、`CodexSessionFormat`、子类），`uuidFromFileName` 与 `extract*` 留下。
  - `Modules/AITools/CodexEnv.swift`：删 `cleanupSessions`（`sessionsDiskStats` 不动）。
  - `Modules/AITools/AIToolsSettingsView.swift`：`confirmCleanup` 改调 `CodexSessionIndex.shared.cleanup(olderThanDays:)`。
  - `ClaudeUsage.swift`、`ClaudeFileIndex.swift`、`ClaudeLiveStatus.swift`、`CodexUsage.swift`、`AIToolsNotify.swift`：`ClaudeJSONLParsing` / `CodexJSONLParsing`
    的 `parseDate` / `parseObject` 改成 `CLIJSONL`（这五个文件 10 处，纯改名；两个索引文件里的 8 处随重写一起换）。
  - `mac/project.yml`：`BaoboxTests.sources` 加 `Sources/Core/CLISession`，注释里「目前是 Core/CLIUsage/」同步。
- 不改：所有引用 `ClaudeSessionIndex.shared`、`CodexSessionIndex.shared`、两个摘要类型的界面文件。
- 行为不变：差分测试（§7.2）逐字段一致；`index-cache-v2.json` 新旧互读。
- 文档：`Modules/ClaudeCode/CORE_API.md` §2、`docs/claude-code-assistant/TECH_DESIGN.md` §3.2 加注（同 §3.3 #134 那条的写法）、`DESIGN.md` §9.1 加一条、
  根 `CLAUDE.md` 的 Core 清单、本文状态。

- 落地（2026-11-11）：照上面做完，差分测试与单元测试结果在 PR 描述里。与 §4.1 的出入：
  - `CLISessionSummary`、`CLISessionRecord`、`CLISessionFormat` 都加了 `Sendable`：摘要与记录在后台扫出来、回主线程发布，泛型版本编译器推断不出它们可以跨线程；
    格式加 `Sendable` 是为了让后台闭包捕获泛型参数的元类型在 Xcode 26（Swift 6.2，`Sendable` 蕴含 `SendableMetatype`）下也不告警。
    两个摘要结构体与两种记录的字段全是值类型，声明遵循即可，字段一个没动。
  - `uuidFromFileName` 跟着快扫进了 `CodexSessionFormat`（没有别的调用方），Claude 的 `assistantModel` 进了 `ClaudeSessionFormat`（private）。
  - `deleteSession` 只把 `url` 与 `id` 带进后台闭包（原来捕获整个摘要），行为相同。
  - Codex 维护节清理后的两个后台任务换了先后：现在索引先发起刷新、回调里再 `reloadDisk()`（原来先 `reloadDisk()` 再 `refresh()`）。都是起后台任务，看不出差别。
  - 一次刷新改成先列完全部文件再逐个快扫（`CLISessionScanner.refresh(files:…)` 的签名本来就是这样；原来是边列边扫）。只有文件恰好在那几百毫秒里被改时，
    记下的修改时间会早一点，下次刷新照常重扫；稳定状态下结果逐字段相同。
  - 两层列目录照旧会列出项目目录里名叫 `x.jsonl` 的**目录**（快扫打不开，跳过、不进缓存），单元测试把这一现状记了下来。
  - 单元测试 30 个（估的是约 20 个）。

### PR2 事件文件共用层

`refactor(cli): share the event-file watcher between Claude Code and Codex (#109)`

- 新增：`Core/EventFile/EventFileWatcher.swift`（§4.2，`drain` / `prepare` / `readAll` 逐字搬现在的实现，包括半行问题 —— 留给 PR4）；`mac/Tests/EventFile/`。
- 改：`Modules/ClaudeCode/ClaudeLiveStatus.swift`（删 `ClaudeEventWatcher`、`ensureEventFile`、`readAll`，两个上限常量并成 `Limits`，`start` / `stop` 用 follower）；
  `Modules/AITools/AIToolsNotify.swift`（同理）；`mac/project.yml`（加 `Sources/Core/EventFile`）。
- 行为：除 §2 那条启停收紧外不变；事件文件名、上限、队列名不变。
- 文档：`TECH_DESIGN.md` §3.4 加注、`DESIGN.md` §9.1、根 `CLAUDE.md` 的 Core 清单。
- **状态（2026-11-11）：已实现**（分支 `refactor/cli-event-file`，单测 19 个，差分结果贴在 PR 描述里）。与上面的出入：
  1. `EventFileLog.prepare` 读文件大小前先清掉 URL 的 resourceValues 缓存。follower 存着同一个 URL，而后台线程读进去的缓存一直不过期
     （scratchpad 探针：追加 1000 字节后同一个 URL 实例仍报 4 字节），停了再启动会按旧大小判断要不要截断；以前每次启动都现算一个新 URL，碰不上。
     不改行为，防的是搬家带进来的回归（单测 `testPrepareSeesTheCurrentSizeWhenTheSameURLIsReused`）。
  2. `EventFileFollower` 多一个只读的 `isFollowing`（回放完、监听器建好之后为 true），测试拿它确认「后台读完之前 `stop()` 不会建出监听器」。
  3. Codex 的 `replay` 照旧逐行调 `apply(notify: false)`（它本来就直接返回），没改成空闭包，`apply` 一行没动。
  4. §5.2 C3 的实际表现（差分测出来的）：后台读完之前再 `start()`，旧代码会回放两遍，但第二个监听器赋值时第一个就被释放、不再交行，
     平时不会重复通知（只有两轮后台读之间写进来的行可能交两遍）；后台读完之前 `stop()`，旧代码随后照样建出监听器、一直跟随；
     `stop()` 时已排进主线程的行，旧代码照样处理。新代码这三种都不会。
  5. 实现时新查到、这一步没修的（建议并进 PR4）：监听器的 `stop()` 用 `[weak self]` 排一个块去 `cancel()`，调用方紧接着就放掉了最后一个引用，
     块执行时对象已经没了，`cancel()` 没调、取消回调里的 `close(fd)` 也就没跑 —— 每次 `stop()`（以及上面被替换掉的那个监听器）漏一个
     `O_EVTONLY` 文件描述符（探针：起 20 个再停掉，打开的描述符数不回落）。不影响交行（释放后不再回调），只在停止时漏，量很小。
     → 已在 PR4 修掉（§6 PR4 落地第 6 条）。

### PR3 快速切换部件 + 会话数据源

`refactor(cli): share the quick-switch panel pieces between Claude Code and Codex (#109)`

- 新增：`Core/QuickSwitch/QuickSwitchLogic.swift`、`QuickSwitchPanelHost.swift`、`QuickSwitchSessionSource.swift`、`QuickSwitchViews.swift`（§4.3）；`mac/Tests/QuickSwitch/`。
- 改：`Modules/ClaudeCode/ClaudeQuickSwitchPanel.swift`、`Modules/AITools/AIToolsQuickSwitchPanel.swift`；`mac/project.yml`（加 `Sources/Core/QuickSwitch/QuickSwitchLogic.swift` 这一个文件）。
- 不改：`ClaudeCodeTool.swift`、`AIToolsTool.swift`（两个控制器的 `shared` 与 `toggle(mode:)` / `showFiles()` / `toggle()` 签名不变）、所有本地化 key。
- 行为不变：键位、动作先后、焦点时序、面板尺寸与位置、文案逐一对照（§7.4 第 12–17 条）。
- 文档：根 `CLAUDE.md` 的 Core 清单；`RECENT_FILES.md` 里提到面板实现的地方补一句「外壳与会话栏在 Core/QuickSwitch」。
- **状态（2026-11-11）：已实现**（分支 `refactor/cli-quick-switch`）。单测 17 个（键码 5、过滤与选中 12），差分与界面对照的结果贴在 PR 描述里。
  行数：Claude 面板 614 → 475、Codex 面板 324 → 179、`Core/QuickSwitch/` 379（估的是约 430 / 120 / 280，多出来的是注释和部件的初始化器）。与 §4.3 的出入：
  1. `QuickSwitchSessionList` 多一个每次构造都不同的 `renderToken`。原来会话行写在面板的 body 里，面板每次重画都重算行的第二行；抽成独立视图后，
     参数都没变时 SwiftUI 会跳过它的 body（scratchpad 探针实测：闭包原样往下传时，子视图的 body 不再跑），而第二行依赖参数里看不出的状态 ——
     Claude 的会话行方案、相对时间。去掉 token 的对照版本在「面板开着时去设置里换会话行方案」那一步还显示旧方案（列表区 8423 个像素不同），带 token 的与改前逐像素相同。
  2. 两个视图模型的 `clampSelection` 照原来的时机写：空列表总是写 0，其余只在越界时写 —— `objectWillChange` 的次数也不变（差分逐步比了次数）。
  3. 会话列表「选中项变了滚到正中」不再判断 Claude 的模式：会话列表只在会话模式下存在，原来那个判断恒为真。
  4. Claude 文件模式的搜索（文件名 / 全路径 / 项目名）也改用 `QuickSwitchSelection.filter`（同一条规则），类别循环用 `cycled`、取选中项用 `element`；
     文件列表、文件行、chips、文件动作原样留在 Claude。
  5. 数据源是无状态的 struct，由视图模型持有（`viewModel.source`），控制器的刷新 / 续接 / 复制与视图的会话列表都经它；两个 `NSPanel` 子类并成 Core 的
     `QuickSwitchWindow`；`onCopy` 参数删了（§5.1 B4）。Codex 的 Tab 显式写在「交给搜索框」那一支里（原来落在 `default`），照旧不拦。

### PR4 Core 里的修复（按 §9 D3、D7）

`fix(cli): keep events written in pieces, reopen a replaced events file, coalesce index refreshes (#109)`

- `Core/EventFile/EventFileWatcher.swift`：C1（只消费到最后一个 `\n`、逐行解码、`readAll` 同理）、C2（`.delete/.rename` 后重开）。
- `Core/CLISession/CLISessionIndex.swift`：C4（合并刷新请求）、C6（flush 同步写）。
- 测试：半行分两次写、切在汉字中间、一次读到多行加半行、删文件后重建、重命名替换、刷新进行中删除再刷新、flush 后立即读缓存。
- 两个模块不用改。
- **状态（2026-11-11）：已实现**（分支 `fix/cli-core-events-and-index`），顺带修了 §6 PR2 第 5 条的描述符泄漏；两个模块的代码一行没改
  （只更新了 `Modules/ClaudeCode/CORE_API.md` 里 `refresh` / `flushCache` 两行说明）。与上面、§5.2 的出入：
  1. C2 只建回目录、不建文件（§5.2 C2 写的是「建回目录与文件」）：文件留给脚本的 `>>` 去建 —— `FileManager.createFile` 遇到已有的文件是整个换掉
     （scratchpad 探针：旧文件收到 `.delete`），撞上脚本刚写的第一行就会把它丢掉。目录必须建回来：Codex 的 notify 脚本不 `mkdir -p`。
     路径上没有文件时监听父目录（`.write` = 目录里有条目变了），文件一出现就改盯文件、从头读，不轮询（D3）。
  2. 读改走正在盯的那个描述符（`O_EVTONLY` 也能读，被删之后照样读得到 —— 探针确认），不再按路径另开：收到 `.delete` / `.rename` 时先把旧文件剩下的行读完再换过去，
     不会拿旧文件的偏移去读路径上的新文件。
  3. 换上来的文件一律从头读：被删后脚本重建、改名挪走（轮转）时新文件里全是新事件，从头读正好；有人把旧内容原子地重写一遍（编辑器保存）时，里面的旧事件会再交一次
     （通知重复）。比「再也收不到」好，也没有可靠的办法区分，照上面「偏移归零」。
  4. kqueue 不补发「打开之后、开始监听之前」发生的删除（探针确认，文件与目录都是）：开始监听后核对描述符与路径上的是不是同一个节点（dev + inode），
     不是就当已经被删、马上换过去。目录正被 `rm -rf` 时（先删文件、再删目录）刚建好 / 刚打开就没了，最多重来 3 次。这个竞态是实现时的一次变异测试撞出来的
     （监听器卡在已经删掉的目录上，再也不建回来）；补上之后，在 8 个空转循环占满 CPU 的情况下把改动涉及的四组测试连跑 20 轮（1000 次）没再出现。
  5. 开始监听时（包括被删后重开）先读一遍：以前开始监听之前已经写进来的行（回放读完到建好监听器之间写进来的）要等下一次写入才交出，现在马上交出。
     开始时文件不在也不再「什么也不做」，而是建回目录等它出现（follower 启动时总会先建好文件，平时碰不上）。
  6. 描述符泄漏：`stop()` 排的块强引用监听器，确定性地 `cancel()`、取消回调里 `close`；没 `stop()` 就被释放时 `deinit` 里也 `cancel()`。
     单测数本进程打开着的、路径落在测试临时目录里的描述符（`/dev/fd` + `F_GETPATH`）：起 20 个（10 个盯文件、10 个盯父目录）再停掉，回落到 0。
  7. C4：刷新进行中再请求、或删掉了会话（§5.2 C4 说的「`deleteSession` 同理」：删除撞上进行中的刷新也记一笔），这一轮结束后补扫一轮，来几次都只补一轮。
     被补掉的那一轮不发布（它可能在删除之前列的目录，发布了刚删的会话会闪回来），它扫出来的记录带进补扫复用；转圈（`isRefreshing`）补扫期间不熄。
  8. C6：`flushCache` 在调用线程上同步写；防抖的落盘与 flush 走同一个串行写盘队列，排在前面的旧快照不会盖掉 flush 写的新快照。
     `ClaudeFileIndex.flushCache()`（§5.2 C6 说的「同款」）在模块里，这一步不动，留给 §5.3「`ClaudeFileIndex` 的外壳」那条。
  9. 给测试加了 `EventFileWatcher.drainNow()`（在监听器队列上同步读一次）：确定性地造出「两次写入之间读了一次」，不靠固定等待。
  10. 单测：新增 20 个（EventFile 17、CLISession 3），翻转 PR1 / PR2 留下的 4 个钉子测试，另有 2 个测试里「flush 后转圈等缓存文件」改成 flush 返回就读；
      `BaoboxTests` 共 266 个，连跑 5 次全过。把旧行为分三组放回去（C1 + C4 + C6 / C2 / 描述符），新测试各自失败，结果贴在 PR 描述里。

### PR5 模块里的行为修复（按 §9 D4–D7）

`fix(claudecode): refresh usage on hook events; resume running sessions where the hook saw them (#109)` 与
`fix(cli): align session export between Claude Code and Codex (#109)`（建议拆成这两个）

- `ClaudeLiveStatus.swift`：B1（`Stop` / `Notification` 时调 `ClaudeUsageStore.shared.refreshThrottledFromHook()`）。
- `ClaudeEnv.swift` / `ClaudeLiveStatus.swift` / `ClaudeQuickSwitchPanel.swift`：B3（「切到正在跑的会话」共用函数，面板先用 hook 记下的位置）。
- `ClaudeSessionIndex.swift`（`ClaudeSessionFormat.markdown`）：B2 (a)(b)；`Localizable.xcstrings` 加 `claudecode.export.user` / `claudecode.export.assistant`（en + zh-Hans）。
- `CodexSessionIndex.swift`（`CodexSessionFormat.markdown`）：B2 (c)。
- `ClaudeCodeTool.swift` / `AIToolsTool.swift`：C5（`submenuItems()` 里顺手 `index.refresh()`），如果 D7 同意。

## 7. 验证

### 7.1 单元测试（BaoboxTests）

测试 target 不链接 App、不设 `TEST_HOST`（`mac/project.yml:131–147`）。用到 `@MainActor` 的测试类标 `@MainActor`，异步结果用 `XCTestExpectation` 等主线程回调；
文件类测试一律在 `FileManager.default.temporaryDirectory` 下的随机目录里做，用完删掉，不碰真实的 `~/.claude` / `~/.codex`。

- **PR1 `mac/Tests/CLISession/`**（约 20 个）
  - `CLISessionScanner`：冷启动全扫；mtime 差 0.0009 s 复用、0.001 s 重扫；大小变化重扫；`scan` 返回 nil 不进缓存、下次重试；文件消失出缓存；新→旧排序与同时间戳保持原始顺序。
    用一个假格式（静态的文件清单与扫描计数）测，不碰磁盘。
  - `CLISessionFiles`：两层遍历（忽略根目录下的文件、隐藏目录 / 文件、非 .jsonl、不进孙目录）；递归遍历（进子目录、只要普通文件、跳过隐藏项、名叫 `x.jsonl` 的目录不算）；
    `removeJSONL`（阈值两侧、嵌套目录、隐藏文件不删、返回数与字节、根目录不存在返回 (0, 0)）。
  - `CLIJSONL` / `CLISessionPaths`：带毫秒 / 不带毫秒 / 非法时间；非对象 JSON 与坏 JSON 返回 nil；末段为空的路径。
  - `CLISessionIndex`（假格式指向临时目录）：`refresh` 发布有序列表并清 `isRefreshing`；进行中再调被忽略（记录现状，PR4 改成合并时这条测试跟着改）；
    `deleteSession` 删文件、出列表、出缓存；`exportMarkdown` 把标题传给格式；`cleanup` 删完先刷新再回调；有 `cacheFileURL` 时 flush 后新实例能读回、没有时不写文件。
- **PR2 `mac/Tests/EventFile/`**（约 10 个）
  - `EventFileLog`：缺文件时建目录与空文件；没超限不动；超限只留最后 N 行（逐字节比对）；`readAll` 的行与大小。
  - `EventFileWatcher`：追加的行能收到；文件被截短后偏移归零、继续收到；`stop()` 后不再回调。
  - `EventFileFollower`：回放拿到已有行、跟随拿到之后的行、回放先于跟随；重复 `start()` 被忽略；后台读完之前 `stop()` 不会建出监听器、不会回调。
- **PR3 `mac/Tests/QuickSwitch/`**（约 10 个）
  - `QuickSwitchSelection`：空查询原样返回；不区分大小写；任一字段命中；不 trim（记录现状）；`moved` / `clamped` / `cycled` / `element` 的边界（空列表、越界、负数）。
  - `QuickSwitchKey`：每个键码的映射表；C 必须带 ⌘；⏎ 带不带 ⌘；方向键带修饰键照样识别；不认识的键返回 nil。
- **PR4**：§6 PR4 列的那些用例；PR1 里「进行中再调被忽略」那条改成「结束后补刷一次」。

### 7.2 差分测试（不进仓库，跑完贴结果进 PR 描述）

照 #134 的做法，在 scratchpad 里写临时比较程序：

- **PR1**：把 `5a6ef26` 的 `ClaudeSessionIndex.swift`、`CodexSessionIndex.swift` 用 `sed` 改名（`Old` 前缀）后，与新的 `Core/CLISession/` 和新的两个格式文件一起编，
  `ClaudeEnv` / `CodexEnv` / `L()` 用桩。两份语料：
  1. 生成的夹具：随机项目与会话，覆盖 summary 行、用户输入带 / 不带 `<…>`、头块 / 尾块里的模型与 usage、缺 cwd、文件大小落在 8 KB 与 64 KB 两侧、坏 UTF-8、空文件、
     隐藏文件、非 .jsonl、名叫 `x.jsonl` 的目录、嵌套子目录、rollout 的三种用户输入写法、SessionMeta id 有 / 无。
  2. 开发机上真实的 `~/.claude/projects` 与 `~/.codex/sessions`，**只读**：比较程序不调删除、清理、flush，只打印条数与不一致的文件名，结果不提交、不出本机。
  比较：列表顺序与每个字段（id、fileURL、projectPath、projectName、title、lastActivity、fileSize、model、contextTokens）；带上一轮缓存再扫一次（复用路径）仍一致；
  旧 `CacheRecord` 编出的 `index-cache-v2.json` 能被新 `ClaudeSessionRecord` 解出、再编码逐字节相同；每个文件新旧 `markdown` 逐字节相同；
  在两份复制出来的夹具目录上分别跑旧 `performCleanup` / `cleanupSessions` 与新 `removeJSONL`，删掉的文件集合、数量、字节数相同。
- **PR2**：同一串事件（只在行边界切块，PR2 不改切行规则）分别喂旧的 `drain` 与新的 `EventFileWatcher`，交出的行序列相同；`prepare` 的截断结果逐字节相同。
- **PR3**：旧的过滤闭包与 `QuickSwitchSelection.filter` 在随机字符串（含非 ASCII、大小写折叠）上结果相同；旧的 `moveSelection` / `clampSelection` 与新函数在随机序列上相同。

### 7.3 编译与静态检查

```bash
# 编译 + 单测（Mac 上；只编不装，不碰 /Applications —— 并行会话会互相覆盖安装）
cd mac && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Baobox -configuration Debug -derivedDataPath "$SCRATCH/DerivedData" \
  -destination 'platform=macOS' test
# 没有 mac/Vendor/ 也能编：拷 llama-server、虚拟麦克风驱动的脚本阶段会跳过

# 本地化表仍是合法 JSON（在仓库根目录跑）
python3 -c "import json;json.load(open('mac/Sources/Resources/Localizable.xcstrings'));print('valid')"

# 文案 key 与设置键前后一致（每个重构 PR 都跑，diff 必须为空；PR5 只允许多出两条导出小标题）
git grep -hoE '"(claudecode|aitools|codex)\.[A-Za-z.]+' 5a6ef26 -- mac/Sources | sort -u > "$SCRATCH/keys-before"
git grep -hoE '"(claudecode|aitools|codex)\.[A-Za-z.]+' HEAD    -- mac/Sources | sort -u > "$SCRATCH/keys-after"
diff "$SCRATCH/keys-before" "$SCRATCH/keys-after"

# 边界：新 Core 目录不引用模块类型；进测试的部分只 import Foundation / Combine
grep -rnE '\b(Claude|Codex|AITools)[A-Z][A-Za-z]*|TerminalLauncher|\bL\(' \
  mac/Sources/Core/CLISession mac/Sources/Core/EventFile mac/Sources/Core/QuickSwitch --include='*.swift' \
  | grep -v '^[^:]*:[0-9]*:[[:space:]]*//'
grep -rhn '^import' mac/Sources/Core/CLISession mac/Sources/Core/EventFile mac/Sources/Core/QuickSwitch/QuickSwitchLogic.swift | sort -u

# 搬家看着色
git diff -M --color-moved=zebra origin/main...HEAD
```

### 7.4 真机回归清单

装本地构建后跑（安装由主会话 / 用户做）。PR1 跑 1–6，PR2 跑 7–11，PR3 跑 12–17；修复 PR 跑各自列的条目。

会话索引：

1. 同一时刻对比改动前后：Codex 菜单状态行的会话数、Claude 菜单状态行一致。
2. 两个中心窗口的会话页：顺序、标题、项目名、相对时间一致；Claude 的会话行方案（模型、上下文、大小）一致；刷新按钮转圈后停。
3. 删除一个会话 → 列表少一条、文件没了；重启 App 不回来（Claude 有缓存）。
4. 导出同一个会话的 Markdown，与改动前导出的文件 `diff` 为空（两边各一个）。
5. 设置 → 维护 → 清理（拿复制出来的目录或把天数设得很大，只看结果对话框）：数字与改动前一致，列表随后刷新。
6. Claude 重启后打开面板立刻有列表（缓存命中）；刷新后约 1 秒 `index-cache-v2.json` 的修改时间更新。

事件文件：

7. Claude 开着 hooks 跑一个会话：菜单「1 运行中」→ 等确认时「1 等待确认」+ 通知 → 完成通知；点通知跳回终端。
8. Codex 开着完成通知跑一回合：「Codex 完成 · 项目」通知；点通知跳回终端；用量 60 秒内更新。
9. 关掉再打开 Codex 完成通知开关后跑一回合：只来一条通知。
10. 重启 App：已有事件不重复发通知（回放静默）。
11. 手工把事件文件撑到 6 MB / 3 MB 再启动：被截到最后 1000 / 500 行。

快速切换：

12. Claude ⌃⇧Space：打开即可打字；↑↓ 选择、选中项滚动居中；⏎ 续接（正在跑的切到前台，否则开新窗口）；⌘C 复制续接命令；Esc 与点面板外都能关。
13. Claude 面板 ⇥ 切到文件模式：chips 计数；空查询时 ←→ 切类别、有字时移动光标；鼠标点过分段控件后 ←→ 仍切类别；⏎ 打开且目标 App 到前台；⌘⏎ 访达；⌘C 复制路径；单击打开。
14. 「最近文件」菜单 / 快捷键：没开 → 文件模式打开；会话模式开着 → 切到文件；文件模式开着 → 收起。
15. Codex 面板：同 12（续接总开新窗口）；Tab 的表现与改动前一致。
16. 双显示器：面板出现在鼠标所在屏、略高于正中。
17. 在一个全屏 App 上打开面板：照常浮在上面，焦点在搜索框，原来的 App 不被切走。

修复 PR（如果做）：往 Codex 事件文件里用两次 `printf` 写一行（第二次带一个汉字的后半）→ 通知照来；删掉 `Baobox/AITools/` 后跑一回合 → 通知照来；
Claude 回合结束 60 秒内菜单「今日」更新；中文界面导出的小标题是「用户 / 助手」、没有 `<command-name>` 段；同一目录开两个 Claude 会话，从面板续接第二个 → 切到对的窗口，Otty 里同样。

## 8. 风险

| # | 风险 | 现在靠什么 | 搬坏了是什么样 | 怎么防 / 验 |
|---|---|---|---|---|
| R1 | 文件监听的打开方式、事件掩码、起点 | 自有串行队列上 `open(O_EVTONLY)`、`.write/.extend`、起点 = `readAll` 读到的大小、文件变短偏移归零 | 漏事件、重复事件、启动时把历史事件当新事件发通知 | PR2 逐字搬（`--color-moved` 核对）；7.1 / 7.2；真机 7–11 |
| R2 | 回放与跟随的先后、主线程投递 | 回放（不发通知）在建监听器之前，全部在主线程 | 历史事件轰炸通知、状态机乱序 | follower 的接口把先后写死；测试断言回放先于跟随 |
| R3 | 面板非激活又能成为 key | `NSPanel` 子类 + `.nonactivatingPanel` + `makeKeyAndOrderFront` | 搜索框打不了字，或抢走前台 App | 外壳原样搬；真机 12、15、17 |
| R4 | 面板焦点时序 | 根视图 `.task` 里等 50 ms 再聚焦（必须晚于 `makeKeyAndOrderFront`） | 打开后要先点一下才能打字 | `.task` 放在随面板一起建的 `QuickSwitchSearchBar` 上（不能放进条件分支）；真机 12 |
| R5 | 按键 | 两个控制器各自的键码 switch；只有 Claude 吃 Tab；←→ 只在文件模式且查询为空时拦 | Tab 把焦点带走、←→ 不再切类别、⌘C 失效 | `QuickSwitchKey` 映射表测试；各控制器保留自己的 case；真机 12–15 |
| R6 | 动作与收面板的先后 | 续接先收后做；复制先写后收；打开文件先做后收（`eb7e8db`） | 文件打开了但窗口留在后台 | 控制器里逐个动作照原顺序；真机 13 |
| R7 | 菜单构建零磁盘 IO | `submenuItems()` 只读 `sessions`（内存） | 打开菜单卡顿 | `sessions` 仍是内存里的 `@Published`；共用层除 `init` 读缓存外没有同步 IO —— 那次读与现在一样发生在首次取 `shared`（`activate` 里），不在菜单构建里；C5 若做也只是触发后台刷新 |
| R8 | 磁盘缓存兼容 | `index-cache-v2.json` 的键 = 记录的字段名 | 升级后首启全量重扫（不丢数据，只是慢一次） | 记录字段不动；7.2 新旧互读 |
| R9 | 列表顺序 | 列文件顺序 + 排序比较器 | 同时间戳的会话换位置 | 同样的 `FileManager` 调用与顺序；7.2 比较顺序 |
| R10 | 泛型基类上的 `ObservableObject` | — | 列表不刷新 | scratchpad 探针已验证（§3.3）；真机 2 |
| R11 | 并发 | Swift 5 模式、最小并发检查 | — | 新代码与现在同一种写法（后台算、`DispatchQueue.main.async` + `MainActor.assumeIsolated` 回写）；严格并发下的告警与现有代码同类，不在本次处理 |

## 9. 已拍板（2026-11-10）

用户的答复：「按你的建议」—— D1–D8 每一条都按「建议」执行。原问题与建议保留，供实现时对照。

1. **D1 面板怎么抽**：「部件 + 会话数据源协议」（§3.3 第 2 条），还是「一个泛型面板 + Claude 文件模式做成可选第二栏」？
   **建议前者**：完全相同的部分一样只剩一份，Claude 文件模式的键盘与焦点行为不用在新框架里重写；以后第二个工具也要文件模式时再升级成多栏。
2. **D2 修 bug 的时机**：**建议先搬后修** —— 三个重构 PR 严格行为不变（只有 §2 那条），修复集中到 PR4（Core）与 PR5（模块），各自可回退。
3. **D3 事件文件修哪些**：**建议 C1（半行 + UTF-8）必修**，已复现、影响通知；**C2（被删后重开）一起做**，用监听父目录的办法，不轮询。
4. **D4 Claude 收到 hook 事件刷新用量**：**建议补上**（文档本来就这么写，Codex 已有），挂在 `Stop` 与 `Notification`，节流 60 秒不变。
   不挂 `UserPromptSubmit`：那时还没产生用量，反而会把回合结束后的那次刷新节流掉。
5. **D5 导出 Markdown 对齐**：**建议三处都对齐** —— Claude 小标题走 `L()`、跳过 `<…>` 注入；Codex 改按字节切行。注意中文界面下 Claude 导出的小标题会从
   「User / Assistant」变成「用户 / 助手」，如果你更想要固定英文，就反过来把 Codex 也改成英文。
6. **D6 面板续接先用 hook 记下的终端位置**：**建议做**（只动 Claude），修掉 `NOTIFY_JUMP.md` 里说的两个缺口在面板里的残留；Codex 维持开新窗口。
7. **D7 会话索引的刷新**：C4（合并请求）、C6（退出同步落盘）**建议做进 PR4**；C5（打开菜单时顺带后台刷新）**建议也做** —— 成本只是 stat 一遍会话文件，
   能让「N 个会话活跃（推断）」和 Codex 会话数真正可用；单列出来是因为它让菜单打开多了一次后台扫描。
8. **D8 范围外的重复**（§5.3：中心窗口会话页、`TerminalLauncher` 进 Core、格式化工具 / 多行标题 / 单引号转义、目录遍历、`ClaudeFileIndex` 外壳、用量 Store 外壳）：
   **建议另开一个 P2 issue**，等本次三块落地后再做；其中「中心窗口会话页」与「`TerminalLauncher` 进 Core」收益最大。
