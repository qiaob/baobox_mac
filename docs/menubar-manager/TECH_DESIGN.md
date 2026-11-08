# 菜单栏管理 · 技术设计

需求见 `REQUIREMENTS.md`，效果图 https://claude.ai/artifact/A7ftJyNNzRJeyCmkQnoiXh 。macOS 14+，零第三方依赖。
Ice（开源，GPL-3.0）只作参考思路，不拷代码。

## 1. 模块划分

`mac/Sources/Modules/MenuBarManager/`，模块 id `menubar`，文案命名空间 `menubar.*`。

| 文件 | 职责 |
|---|---|
| `MenuBarManagerTool` | 模块壳（子菜单、设置 Tab、快捷键）+ `MenuBarManager`（启停、定时扫描、Baobox 自身可见的保险） |
| `MenuBarSettings` | 两个开关的键与默认值 |
| `MenuBarItemScanner` | 找别的 App 的菜单栏图标、认出是哪个 App 的哪一项、判断显示 / 隐藏 / 被挤掉、抓图标图像（每个只抓一次、存盘） |
| `MenuBarSpacer` | 看不见的占位状态项：撑到 10_000 宽，把排在它左边的图标推出屏幕 |
| `MenuBarItemMover` | 单独挪一个图标（屏外的也行，§8c） |
| `MenuBarActions` | 设置里的显示 / 隐藏、顶部图标行的点开：先单独挪，不灵退回「缩短占位项 + ⌘ 拖」（§8b） |
| `MenuBarIconRow` | Baobox 菜单顶部那一行（`NSMenuItem.view`，AppKit） |
| `MenuBarSettingsView` | 设置页（图标列表、显示 / 隐藏） |

框架改动（`Core/` 与 `App/`）：

- `ToolModule` 加可选方法 `statusMenuHeaderItems() -> [NSMenuItem]`，协议扩展里默认返回空；
  `StatusItemController.rebuild()` 把各模块的头部项放在最前面（再接分隔线）。框架照旧不认识具体工具。
  Rust 侧的 `ToolModule` trait 不跟：Windows / Linux 没有菜单栏管理。
- `StatusItemController` 暴露 `showMenu(atMouse:)`，给「打开 Baobox 菜单」快捷键用。

## 2. 找图标：MenuBarItemScanner

- `CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)`，取窗口层 = `CGWindowLevelForKey(.statusWindow)`（25）的窗口，
  去掉 Baobox 自己的 pid。2026-11-08 探针（终端里跑、没有屏幕录制权限）在用户机器上列出了全部 13 个图标的进程、位置、大小。
- 14.6 上**每个图标有两个同位置的窗口**（探针里每个图标两条记录、frame 相同）。按 (pid, frame) 合并，取真正画着图标的那个（§8 探针 1）。
- 认是哪一项：App 用 bundle id；同一个 App 有多项（控制中心的 Wi-Fi、电池…）时，用辅助功能读该 App 的
  `kAXExtrasMenuBarAttribute` 子项，按位置对上，取它的描述 / 标识作区分。设置按「bundle id + 这一项的标识」记。
- 看不看得见（按图标所在屏）：
  - 有刘海的屏：在 `NSScreen.auxiliaryTopRightArea`（刘海右边那块）里、且 `kCGWindowIsOnscreen` 为真 → 看得见；
    落在刘海范围、屏幕左边以外、被占位项推出屏外、不在屏上 → 看不见。
  - 没刘海的屏（`auxiliaryTopRightArea` 为 nil）：在屏内且 onscreen → 看得见。
- **菜单构建零 IO**（仓库约定）：后台队列刷新缓存，`menuNeedsUpdate` 只读缓存。刷新时机：前台 App 切换
  （`NSWorkspace.didActivateApplicationNotification`，菜单宽度跟着变）、App 启动 / 退出、挪完图标之后、工具开着时每 3 秒一次。
- 图标图像：`CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution])`，
  透明底、只有图标本身。随缓存一起刷新。屏外、刘海后面的窗口能不能抓到，见 §8 探针 1。
- 屏幕录制权限缺失时：窗口列表仍能拿到位置，但抓不到图 → 图标行与设置列表改用 `NSRunningApplication.icon` + App 名。

## 3. 隐藏的办法：看不见的占位项 + 自动挪图标

用户不碰分隔线，也不 ⌘ 拖（2026-11-08 用户：「不需要分割线」）。内部仍用 Hidden Bar / Ice 的老办法，只是全程自动、看不见：

- **占位项（MenuBarSpacer）**：一个 `NSStatusItem`，`autosaveName = "baobox.menubar.spacer"`，**不放图像、不可点**，
  `length = 10_000`：排在它左边的状态项全部被推出屏幕。它自己伸出屏外，用户看不到它。
- **位置**：状态项的位置存在各自 App 偏好的 `NSStatusItem Preferred Position <autosaveName>` 里，实测是「数值越大越靠左」的
  排序键（用户机器上 Rectangle 735 在 Wi-Fi 619 左边，往右依次是聚焦 549、Tailscale 383、输入法 295、电池 215）。
  占位项第一次创建前写它自己的键，放在**所有图标的最左边**（值比现有最大的再大一点）：这时谁都不隐藏。只写 Baobox 自己的偏好。
- **挪图标**（最终做法见 §8c；下面是最早的 ⌘ 拖版本，现为退路）：设置里某项改成「隐藏」→ 把它挪到占位项左边；改回「显示」→ 挪回右边。
  做法是模拟 ⌘ 拖（§8 第 4 条验证过）：先把占位项临时缩到约 8 宽，让隐藏的图标回到屏上；再往 `.cghidEventTap` 发
  「按住 ⌘ 的鼠标按下 → 分段拖动 → 抬起」，起点是图标中心，终点是占位项的左边（或右边）；最后占位项恢复 10_000。
  需要辅助功能权限。挪的那零点几秒里菜单栏会闪一下，只在改设置时发生。位置不够（图标缩回来后仍不在屏上）时，
  临时把 Baobox 切到前台腾出位置再挪。
- **记得住**：⌘ 拖完系统会把新位置写回那个 App 自己的 `Preferred Position`，App 重开、Mac 重启后还在占位项左边，
  一般不用 Baobox 再动。Baobox 启动时、App 启动时对一遍设置，位置不对再挪（比如 App 自己重置了位置）。
- 关掉工具：移除占位项，隐藏的图标全部回到菜单栏（它们的位置键仍在左边，排在最左而已）。

## 4. Baobox 图标挪到最右

- 主状态项现在没设 `autosaveName`（系统默认叫 `Item-0`），也从没存过位置，所以排在最左。
- 「放到最右边」：写 `NSStatusItem Preferred Position Item-0` 为一个比右边第三方图标都小、又比系统图标大的值，
  再移除并重建状态项，让系统按新位置摆。具体取值见 §8 探针 3。
- **Baobox 自己必须一直看得见**（2026-11-08 用户：「一定要保证自身百分之百可见，不然自己也隐藏掉了……就死循环了」）：
  - 主状态项 `autosaveName` 写死 `Item-0`：系统默认按创建顺序起名，占位项在各模块 activate 时先建出来，主图标成了 Item-1、
    找不到记过的位置，被当新图标排到最左、落进隐藏区（实测踩到，Baobox 图标「没了」）。
  - 用户在设置里打开菜单栏管理时，顺手挪到最右边（`farRightPosition`：电池 / 控制中心图标的值 + 3，且比占位项的值小 40 以上）。
  - 每次扫描完 `MenuBarManager.ensureBaoboxVisible()`：落进占位项左边、或菜单栏露着却不在屏上 → 挪回最右边（改自己的位置值、
    重建状态项，不用模拟拖）。Baobox 菜单开着、正在挪图标时不动；10 秒内最多一次；已在最右边仍被挤掉就不再折腾，靠快捷键兜底。
  - 设置列表不列 Baobox 自己的状态项（扫描时排除本进程）。
- Baobox 自己的临时状态项（专注倒计时、会议录音指示）原先不指定位置，系统会排到最左 = 隐藏区。
  `StatusItemController.makeCompanionItem` 给它们固定 autosaveName，**每次出现**都按主图标当前的值写成「− 1 / − 2」，排在主图标右边。
- 快捷键 `menubar.openMenu`（出厂不绑）：图标看得见就 `button.performClick`；看不见就在鼠标位置
  `menu.popUp(positioning:at:in: nil)`。

## 5. 点被藏的图标：MenuBarItemClicker

- 先单独挪到 Baobox 图标左边再点（§8c）；下面几条是挪不成时的退路。
- **隐藏的图标**：占位项缩短 → 它回到屏上 → 在它的位置发一次普通的鼠标按下 / 抬起（`.cghidEventTap`）→ 它的菜单或面板打开。
  等它关掉（那个进程新出现的屏上窗口都消失，最长 60 秒）再把占位项撑回去。
- **被挤掉的图标**：位置本来就不够；临时把 Baobox 切到前台（菜单栏换成 Baobox 自己很短的菜单，腾出位置），图标回到屏上再点；
  用完把原来的前台 App 切回来。隐藏的图标缩回来仍不在屏上时同样这么办。
- 都不行（还是不在屏上）：宠物提示「菜单栏放不下了」，不乱点。
- 合成的按下 / 抬起要把单击次数（`mouseEventClickState`）标成 1：默认是 0，Electron 做的菜单栏图标只认 `clickCount == 1`，
  Slack 在屏上被点了两下也没反应（2026-11-08 日志）。第一下 1 秒内没弹出东西就按住久一点再点一次；两次都没反应，宠物提示。
- 图标图像每个只抓一次、存盘（`~/Library/Application Support/Baobox/MenuBar/Icons/`）：抓屏会让菜单栏亮起紫色的录屏指示，
  第一版每 3 秒抓一遍，指示常亮（用户截图问「为什么多了一个这个」）。
- 点之前先收起 Baobox 自己的菜单（顶部图标行就在这个菜单里），点完把鼠标放回原处。

## 6. 设置与持久化

- `UserDefaults`：`menubar.enabled`（默认关）、`menubar.showSqueezed`（被挤掉的也放进顶部图标行，默认开）。
- **隐藏了哪些不另外存**：排在占位项左边的就是隐藏的，位置由系统记在各 App 自己的偏好里（§3）。
  副作用：第一次出现、没记过位置的状态项系统排到最左 → 落进隐藏区（设置页说明里写明，想显示就改）。
- 设置页列表只来自扫描缓存（没在运行的 App 不列）。
- 设置页显示两项权限的状态，缺了给按钮（复用 `Permissions`）。

## 7. 菜单顶部图标行：MenuBarIconRow

- `statusMenuHeaderItems()` 返回一个自定义视图的 `NSMenuItem`（SwiftUI `NSHostingView`，只在主线程建 ——
  `StatusItemController` 已经处理了 AX 巡检在后台线程「模拟打开」菜单的情况）+ 一条分隔线。
- 数据只读扫描缓存：先「隐藏」项（按设置列表的顺序），再一道细竖线、此刻看不见的「显示」项（`showSqueezed` 开时）。
- 按钮带 `accessibilityLabel`（App 名），悬停 `toolTip` 显示 App 名。

## 8. 探针结果（2026-11-08，用户机器 macOS 14.6，Debug 构建里跑，四轮）

终端没有屏幕录制和辅助功能权限，探针做成 Debug 构建里的一次性检查（`make dev`，不动 `/Applications` 那份）；
Debug 构建与正式版同一开发证书签名，**两项授权直接沿用**。

1. **认图标**：辅助功能读各 App 的 `kAXExtrasMenuBarAttribute` 子项，位置、大小都准；系统项带标识（`com.apple.menuextra.wifi`
   / `.battery` / `.clock` / `.controlcenter`）和描述（「电池」「时钟」），第三方项一般只有位置。窗口列表里每项有一对同位置窗口，
   控制中心还有几个隐藏模块的窗口叠在别的图标上 → **以辅助功能的列表为准**，按位置对上屏上那个窗口。
2. **抓图标图像**：菜单栏露着时，`CGWindowListCreateImage(frame, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution])`
   和 ScreenCaptureKit 单窗口都能拿到透明底的图标；`CGImage(windowListFromArrayScreenBounds:…)` 一律 nil。
   **全屏 App 里菜单栏收着时、图标被推到屏外后都抓不到** → 看得见的时候抓、按项缓存，隐藏后用缓存。
3. **位置键**：「数值越大越靠左」确认（预设 200 落在电池和控制中心之间、1 落在时钟左边、100000 落在最左）。
   ⌘ 拖完系统会把新值写回那个 App 自己的偏好（Rectangle 476 → 574，复原后回到 476）。
4. **模拟 ⌘ 拖**（`.cghidEventTap`，按住 ⌘ 的按下 → 分段拖动 → 抬起，起止点都在屏上）：可靠。占位项撑到 10_000 后，
   它左边的图标被推到 x = -4080，从菜单栏消失；缩回后又回到屏上。
5. **给屏外的图标发事件**：`postToPid`、会话事件流加窗口字段，点击和拖动都不起作用。Ice 能做到，靠的是一套专门的转发
   （先给目标进程发空事件、用按进程的事件拦截把真事件同时送进会话流和目标进程、全程隐藏鼠标、逐步等位置变化），复杂且跟系统版本走。
   → **不碰屏外的图标**：要点一个隐藏的图标时，先把占位项缩短让它回到屏上，再在屏上正常点它（§5）。

## 8c. 单独挪一个图标（屏外的也行）—— 最终做法

8b 的「缩短占位项」只能让目标露在看得见那段最左边，夹在它和占位项之间的隐藏图标都会一起露出来；目标排在隐藏区最左边时
（比如新出现的钉钉、最早隐藏的 Slack）等于整个隐藏区都出来了，用户：「不对，还是都出来了」。于是照 Ice 的思路
（只看原理，代码自己写，`MenuBarItemMover`）直接挪屏外的图标：

- 按下（带 ⌘）放在所有屏幕之外 (20000, 20000)，窗口字段（`mouseEventWindowUnderMousePointer`、`…ThatCanHandleThisEvent`、
  自定义字段 0x33）指向要挪的图标；抬起放在目标图标的边上，窗口字段指向目标。两个事件的目标进程都是要挪的图标所属的 App，
  带唯一的 `eventSourceUserData`，不发拖动事件。
- 每个事件「转一手」：给那个 App 发一个空事件 → 挂在那个 App 上的拦截（`tapCreateForPid`）收到后把真事件发进会话事件流 →
  会话流上只听的拦截看到真事件，再把它直接发给那个 App。§8 第 5 条单发哪一边都不起作用，两边都收到才行。
- 每步等图标位置变化，不变就补一个抬起、按住 ⌘ 在它中心按一下「叫醒」再重试，最多 5 次；全程隐藏鼠标指针，做完放回。
- 取屏外窗口的位置要用 `CGWindowListCreateDescriptionFromArray`（数组里放窗口号本身）：`CGWindowListCopyWindowInfo(.optionIncludingWindow, id)`
  对屏外窗口返回空，第一版因此一上来就判失败、退回了 8b。
- 2026-11-08 用户机器实测：隐藏的 Tailscale / 钉钉从 x≈-4000 挪到 Baobox 左边、再挪回占位项左边，各一次成功（约 30 毫秒）；
  用户从 Baobox 菜单点 Slack、微信、1Password 都走这条路打开（1Password 第 3 次才挪成）。

用法：
- 点开隐藏 / 被挤掉的图标：单独挪到 **Baobox 图标左边**（最右侧，不会被挤）→ 普通点一下 → 等它的菜单关掉 → 挪回去
  （隐藏的回到占位项左边；被挤掉的回到它原来左邻的右边）。
- 设置里的隐藏 / 显示：单独挪到占位项左边 / 右边。
- 单独挪失败时退回 8b 的老办法。

## 8b. 早先的做法（现在是 8c 的退路）

**只让要碰的那一个图标回到屏上**。第一版把占位项缩到 8 宽，所有隐藏的图标一起回来；菜单栏本来就放不下时，
排在最左的（比如 Slack）照样被挤到刘海后面，点不到，整排图标还一起闪（2026-11-08 用户指出）。现在：

- 隐藏区的图标挨个排在占位项左边，缩放占位项时整体平移、彼此距离不变。按目标图标离占位项左边的距离，
  把占位项的左边放到「目标刚好落在看得见那段最左边」的位置（`revealOnly`）：夹在它和占位项之间的会一起露出来，
  更左边的仍在屏外。看得见那段的左边 = 刘海右边；菜单栏属主 App 的菜单越过刘海时，取它菜单的右边缘（辅助功能读 `kAXMenuBarAttribute`）。
- 占位项窗口比长度多 16 左右的留白：先按 16 设长度，读回实际左边再修一次。
- 点隐藏的图标：`revealOnly` → 普通点一下 → 等它的菜单关掉 → 占位项撑回去。被挤掉的图标：本来就在占位项右边，只是位置不够。
- 隐藏：占位项左边只露进看得见那段 40（`exposeSpacerEdge`）→ 把图标 ⌘ 拖到它左边；最挨着占位项的那个隐藏图标会短暂露一下。
- 显示：`revealOnly` → ⌘ 拖到占位项右边。
- 位置不够（夹在中间的太多、看得见那段太窄、前台 App 菜单太长）→ 临时把 Baobox 切到前台（菜单栏换成 Baobox 自己很短的菜单）再算一次；
  还不够就提示「菜单栏放不下」。用完切回原来的 App。
- 拖之前记下鼠标位置，做完用 `CGWarpMouseCursorPosition` 放回；点击把鼠标留在图标上（菜单开在它下面）。

## 9. 风险

- 挪图标、点图标都是在屏上发普通的合成鼠标事件（等同用户自己 ⌘ 拖、点一下），比 Ice 那套转发稳；
  但「⌘ 拖能重排菜单栏」本身是系统行为，将来的系统可能变。挪完按位置核对，挪不动时提示用户自己 ⌘ 拖。
- 挪、点的那一下会动鼠标、菜单栏会闪；拖动途中用户正好在动鼠标会拖歪 —— 开始前等鼠标静止 0.1 秒，挪完核对位置。
- `CGWindowListCreateImage` 在 macOS 14 已弃用（截图的冻结底图也在用），以后的系统上可能要换成 ScreenCaptureKit。
- macOS 26 系统自带菜单栏图标管理，可能和占位项的办法打架，到时再评估。

## 10. 实现顺序

1. 探针（§8），结果回写本文。
2. 扫描 + 菜单顶部图标行（先只显示被挤掉的，不点）。
3. 点击转发。
4. 占位项 + 自动挪图标 + 设置页的显示 / 隐藏列表。
5. Baobox 图标挪到最右 + 「打开 Baobox 菜单」快捷键。
6. 文案（en + zh-Hans）、使用手册 `docs/manual/menubar.md`。
