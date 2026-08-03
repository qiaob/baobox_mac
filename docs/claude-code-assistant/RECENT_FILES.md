# Claude Code 助手 — 最近文件（增量设计）

> 版本：v1.0（2026-08-03）· 设计者：Fable 5
> 前置文档：同目录 `REQUIREMENTS.md`（需求）、`TECH_DESIGN.md`（技术方案，本文件复用其数据源与并发约定）
> 本文件是对「快速续接面板」的**增量**：面板在会话模式之外新增**文件模式**，列出各会话通过
> Write/Edit 等工具写过的文件，按类型筛选、按类别用偏好应用打开。会话模式行为不变。

## 1. 背景

用户诉求（原意）：**「Claude 每次写完文档我都不知道在哪个目录，只能再让它'用 xxx 打开'；会话
关了就找不回了。想要一个列表展示 Claude 输出过的文件，能筛 md/html/代码，点击用指定软件打开，
并且入口要简单——就在快速续接面板里展示。」**

既有的「今日改动」审计只覆盖当天、按项目聚合、入口在中心窗口，不满足「随手唤起 → 搜索/筛选 →
一键打开」的场景。故在快速续接面板内加文件模式。

## 2. 数据来源与现实约束

数据源同 TECH_DESIGN §2.2：`~/.claude/projects/<munged 路径>/<sessionId>.jsonl`，逐行 JSON、
**只追加**。`type == "assistant"` 行的 `message.content[]` 内 `tool_use` 块即工具调用：

```json
{"type":"assistant","cwd":"/Users/x/proj","sessionId":"…","timestamp":"2026-08-03T02:41:13.424Z",
 "message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/abs/path.md","content":"…"}}]}}
```

- 编辑类工具集合沿用 `ClaudeSessionIndex.editToolNames`：`Edit / Write / MultiEdit / NotebookEdit`；
  路径取 `input.file_path ?? input.notebook_path`（NotebookEdit 用后者）。
- 本机实测量级（2026-08-03）：124 个 jsonl / 共 318MB / 最大单文件 30MB / 近 7 天活跃 72 个。
  → 全量重扫不可接受，**必须增量**；且面板每次打开都刷新，活跃会话的 jsonl 在两次打开之间
  几乎必然变化 → 仅 mtime+size 复用不够，**须按字节偏移续读追加部分**。
- 扩展名分布（Write 调用实测）：md 441、py 196、yaml 192、java 174、sh 71、swift 44、html 22…
  → 类型筛选按此分组（§3.1）。
- 写入目标里 431/1313 位于 `~/.claude/` 下（plan / memory 等内部文件）→ **默认排除**，设置里
  提供「包含内部文件」开关。

## 3. 交互与 UI

### 3.1 面板双模式

快速续接面板（`ClaudeQuickSwitchPanel`）新增模式概念：**会话 / 文件**。

- 搜索栏尾部加 segmented 控件（会话 | 文件）；左侧图标随模式切换（terminal ↔ doc.on.doc），
  搜索占位文案随模式切换。
- **⇥ Tab 键切换模式**：本地键盘监听在 SwiftUI 之前消费,焦点始终留在搜索框（不触发焦点遍历、
  无提示音）。
- 文件模式在搜索栏下方多一行**类型筛选 chips**：全部 / 文档 / 网页 / 代码 / 配置 / 其他，
  各带计数（对「当前搜索词过滤后」的集合计数）；点击切换，选中态 accent 填充。
- 文件行：类型图标（按扩展名的 UTType 图标，静态字典 memoize，零磁盘 stat）+ 文件名 +
  「项目名 · 全路径」（中间截断）+ 尾部相对时间。单击选中，双击打开。
- 搜索匹配：文件名 / 全路径 / 项目名（小写子串，与会话模式同规则）。
- 键位（文件模式）：`⏎` 按类别偏好应用打开（先关面板）、`⌘⏎` 访达显示、`⌘C` 复制绝对路径、
  `esc` 关闭；`↑↓` 选择不变。footer 提示随模式切换，左侧计数为「N 个文件」。
- **模式记忆**：菜单入口显式指定（快速续接… → 会话；最近文件… → 文件）；快捷键 toggle 沿用
  上次模式（进程内记忆，重启回到会话模式）。
- 首次索引未完成时（`isRefreshing && files.isEmpty`）显示 ProgressView + 「正在索引会话…」。
- 会话模式的搜索 / ⏎ 续接 / ⌘C 复制命令 / esc 行为**逐字节不变**。

### 3.2 菜单与快捷键

- `submenuItems()` 在「快速续接…」与「浏览会话历史…」之间插入「最近文件…」
  （`ClosureMenuItem`，hotkeyID `claudecode.recentfiles`，点击 `showFiles()`）。
- `hotkeys()` 追加 `HotkeyDefinition(id: "claudecode.recentfiles", defaultCombo: nil)` ——
  出厂不绑定（易冲突组合的一贯做法），用户在快捷键页自设。
- 菜单构建仍零磁盘 IO（新项只注册闭包）。

### 3.3 设置（「会话」分节内追加）

`ClaudeMenuRowSection` 的 Form 里、终端分节之后追加「最近文件」`Section`（不新增 segmented
分节，理由：该分节已管「续接用哪个终端」这类外部 App 偏好，且分节选择器不宜从 6 涨到 7）：

- 五行类别映射：类别名 + 当前 App（图标 + 名称；未设显示「系统默认」；已卸载降级
  questionmark.app + bundle id 文本）+「选择…」（NSOpenPanel 限 `.application`，
  照抄剪贴板忽略名单的选择器模式）+ 已设时的重置按钮。
- 一行灰字说明 + 「包含 ~/.claude 下的内部文件」Toggle（默认关；切换即刷新，全部缓存命中，
  无全量重扫）。

## 4. 技术实现

新文件 `Sources/Modules/ClaudeCode/ClaudeFileIndex.swift`（不并入 `ClaudeSessionIndex.swift`，
后者已 654 行且缓存生命周期不同；解析辅助 / 工具名集合 / 路径工具直接复用其 nonisolated static）。

### 4.1 数据模型

```swift
/// 分类：发布时按扩展名计算，不入缓存（调整映射无需升缓存版本）。
enum ClaudeFileCategory: String { case doc, web, code, config, other }
// doc: md markdown mdx txt rst adoc rtf
// web: html htm xhtml（浏览器当页面打开的；css/vue/tsx 属创作产物 → code）
// config: yaml yml json toml ini conf cfg plist properties env xml xcstrings lock
// code: swift py java ts tsx js jsx vue css scss sh zsh bash sql go rs rb php c h cpp hpp cc m mm kt scala cs dart lua pl r
// other: 其余含无扩展名

struct ClaudeRecentFile: Identifiable {   // id = filePath
    let filePath: String      // 规范化绝对路径（standardizedFileURL.path，不解析符号链接）
    let projectPath: String   // 末次写入行的 cwd
    let projectName: String
    let sessionId: String     // 末次写入所在会话（归因，v1 不展示）
    let lastWritten: Date
    let writeCount: Int       // 四种编辑工具合并计数
    let category: ClaudeFileCategory
}
```

### 4.2 增量扫描（核心）

每 jsonl 一条缓存记录，Codable 持久化到 `supportDir/file-index-cache-v1.json`
（1s 防抖落盘、willTerminate flush，同会话索引）：

```swift
struct FileCacheRecord: Codable {
    var modified: Double      // mtime（容差 0.001 比较）
    var size: Int64
    var parsedOffset: Int64   // 已消费到「最后一个完整行」之后的字节位置
    var sessionId: String
    var entries: [String: EntryRecord]   // 键 = 规范化路径
    struct EntryRecord: Codable { var count: Int; var last: Double; var projectPath: String }
}
```

刷新时逐文件三分支：

1. mtime + size 都没变 → 整条复用（零 IO）；
2. size 变大（追加）→ `FileHandle.seek(parsedOffset)` 只读增量，在既有 entries 上合并；
3. size 变小或同 size 而 mtime 变（压缩/重写）→ 从 0 全量重解析。

**半行安全**：解析只到数据块内**最后一个 `\n`** 为止，`parsedOffset` 停在其后——CLI 正在写的
半行留给下次，不丢不重。行解析同 `computeAudit`：assistant 行 → tool_use ∈ editToolNames →
取路径；**相对路径用该行 `cwd` 解析**（行无 cwd 用文件内最近一次 cwd；仍无则跳过）；
`standardizedFileURL.path` 规范化（不做符号链接解析，避免数百次 lstat；`/tmp` 与 `/private/tmp`
之类别名重复属罕见外观问题，接受）。

### 4.3 发布（合并 → 过滤 → 截断 → 存在性检查）

后台完成，主线程 `MainActor.assumeIsolated` 回写 `@Published files`：

1. 全部记录按规范化路径合并：count 求和；`last` 最新者胜出并携带其 projectPath / sessionId；
2. 过滤：路径前缀为 `~/.claude/` 的默认丢弃（「包含内部文件」开启则保留）；含 `/.git/` 的
   一律丢弃；
3. 按 `lastWritten` 降序取前 **500**；
4. 对幸存者逐一 `fileExists`（≤500 次 stat，几 ms），**不存在的丢弃**——缓存仍保留其记录，
   文件恢复（如切回分支）后自动回来。

刷新触发：`activate()`（启动预热首次全量索引）、面板 `show()`、内部文件开关变更。
不加文件系统监视（与会话索引一致，按需刷新已够）。重入保护 / utility QoS / 全程容错
（无 force-unwrap、无 try!，任何 IO/JSON 失败降级为跳过）同既有约定。

### 4.4 打开偏好与打开器

- UserDefaults：`claudecode.openApp.{doc,web,code,config,other}` = bundleIdentifier
  （未设/空 = 系统默认）；`claudecode.files.includeInternal`（Bool，默认 false）。
- `ClaudeFileOpener`（@MainActor）：
  - `open(_:)`：类别 → bundleID → `urlForApplication(withBundleIdentifier:)`；命中则
    `NSWorkspace.open([url], withApplicationAt:configuration:)`（同 `TerminalLauncher.run`
    的 document 分支）；未配置 / 已卸载回退 `NSWorkspace.open(url)` 系统默认。**永不报错**。
  - `reveal(_:)` = `activateFileViewerSelecting`；`copyPath(_:)` = 写 NSPasteboard。
- 图标：`NSWorkspace.icon(for: UTType)` 按小写扩展名静态字典缓存（实际不同扩展名 ~15 个），
  无扩展名用 `.data` 泛型图标。

## 5. 本地化词条（`Localizable.xcstrings`，en / zh-Hans 双语，紧凑单行）

| key | zh-Hans | en |
|---|---|---|
| `claudecode.menu.recentFiles` | 最近文件… | Recent Files… |
| `claudecode.hotkey.recentfiles` | 最近文件面板 | Recent Files Panel |
| `claudecode.hotkey.recentfiles.subtitle` | 搜索并打开 Claude Code 最近写过的文件 | Search & open files Claude Code recently wrote |
| `claudecode.quickswitch.mode.sessions` | 会话 | Sessions |
| `claudecode.quickswitch.mode.files` | 文件 | Files |
| `claudecode.quickswitch.hint.switchMode` | 切换 | Switch |
| `claudecode.files.placeholder` | 搜索文件名、路径或项目 | Search files by name, path, or project |
| `claudecode.files.empty` | 无匹配文件 | No matching files |
| `claudecode.files.loading` | 正在索引会话… | Indexing sessions… |
| `claudecode.files.count %lld` | %lld 个文件 | %lld files |
| `claudecode.files.category.all` | 全部 | All |
| `claudecode.files.category.doc` | 文档 | Docs |
| `claudecode.files.category.web` | 网页 | Web |
| `claudecode.files.category.code` | 代码 | Code |
| `claudecode.files.category.config` | 配置 | Config |
| `claudecode.files.category.other` | 其他 | Other |
| `claudecode.files.hint.open` | 打开 | Open |
| `claudecode.files.hint.reveal` | 访达显示 | Reveal in Finder |
| `claudecode.files.hint.copyPath` | 复制路径 | Copy path |
| `claudecode.settings.files.section` | 最近文件 | Recent Files |
| `claudecode.settings.files.desc` | 最近文件面板按分类用所选应用打开文件；未设置的分类用系统默认应用。 | Files in the Recent Files panel open with the app chosen per category; unset categories use the system default. |
| `claudecode.settings.files.systemDefault` | 系统默认 | System default |
| `claudecode.settings.files.choose` | 选择… | Choose… |
| `claudecode.settings.files.choosePrompt` | 选择 | Choose |
| `claudecode.settings.files.reset` | 重置 | Reset |
| `claudecode.settings.files.includeInternal` | 包含 ~/.claude 下的内部文件 | Include internal files under ~/.claude |

## 6. 验收标准

1. 菜单「最近文件…」直接打开面板文件模式；⌃⇧Space 打开上次模式；⇥ 切换模式且焦点不离开
   搜索框（继续打字直接进搜索、无提示音）。
2. 首次打开显示「正在索引会话…」后出列表；再次打开秒开（缓存命中）；让 Claude 新写一个文件后
   重开面板，该文件出现（偏移续读生效）。
3. chips 计数正确；「文档」筛选只剩 md/txt 等；「全部」清除筛选。
4. ⏎ / 双击按类别偏好应用打开（未设走系统默认；已卸载 bundleID 兜底系统默认）；⌘⏎ 访达显示；
   ⌘C 复制绝对路径；esc / 点击面板外关闭。
5. 设置里的类别映射重启后保持；重置回「系统默认」；内部文件开关立即增减 `~/.claude/**` 条目。
6. 磁盘上删除一个已列出文件后重开面板该行消失；会话模式与改造前行为完全一致。
7. `~/.claude` 不存在时菜单仍是既有置灰引导，无崩溃。

## 7. 实现状态（as-built）

> 实现完成后补记本节（对照上文设计的落地差异），惯例同 `WEEKLY_QUOTA.md` §7。
