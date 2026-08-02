# 长截屏 + 菜单截图修复（issue #6）

对应 issue：[#6 截图问题](https://github.com/qiaob/baobox_mac/issues/6)

> 1、当我右键唤出菜单，然后快捷键截图，这时候我打开的菜单会自动关闭，导致我无法截取到菜单的内容
> 2、预期增加长截图功能，再订到屏幕那里，加个按钮，长截屏

两件事共用截图模块，放在同一份设计里。

---

## 1. 别的 App 的菜单被截没了

### 现状

仓库里已经有一条「含菜单整屏」链路，但**只覆盖本 App 自己的状态栏菜单**：

- `StatusItemController` 打开菜单 → `HotkeyCenter.beginMenuTrackingCapture()` 启用 CGEventTap
  （菜单跟踪期 Carbon 热键收不到事件）；
- tap 命中热键 → `onBeforeFire` → `ScreenMenuSnapshot.captureAllScreens()`（收菜单**之前**抓）
  → `onWillFireAction` 收菜单 → 执行动作；
- `CaptureController.begin` 用 `ScreenMenuSnapshot.take()` 拿到冻结底图，框选/窗口/全屏都从它裁剪。

而用户说的是**别的 App 的右键菜单**：Carbon 热键这时能正常触发（不走 tap 那条路），
但 `begin` 紧接着 `NSApp.activate(ignoringOtherApps:)` + overlay 上屏 —— 对方菜单在那一刻就收起了。
等 overlay 摆好再抓屏，菜单早已不在，于是「截不到菜单」。

### 方案

在 `begin` 里、**创建任何窗口与激活本 App 之前**补一次探测 + 抓屏：

```swift
if mode == .capture, frozenScreens.isEmpty, ScreenMenuSnapshot.hasForeignMenuOnScreen() {
    ScreenMenuSnapshot.captureAllScreens()
    frozenScreens = ScreenMenuSnapshot.take()
}
```

`hasForeignMenuOnScreen()` 用 `CGWindowListCopyWindowInfo`（只查窗口列表、不抓图，开销可忽略）判断：

- 窗口层 `kCGWindowLayer` **精确等于** `CGWindowLevelForKey(.popUpMenuWindow)`（101）——
  NSMenu 的承载窗口固定在这一层；写成 `>=` 会把拖拽层（500）、屏保层（1000）算进来，
  导致每次截图都误入冻结模式；
- `kCGWindowOwnerPID` 不是本进程（本 App 的菜单走 tap 那条路，避免重复抓图）；
- alpha > 0.01 且尺寸 ≥ 20×20，排除占位窗口。

命中才付「每屏一张整屏图」的代价，未命中时行为与之前完全一致（实时抓屏、不冻结）。

冻结模式本身的下游链路（框选裁剪 / 窗口裁剪 / 全屏直出 / 标注底图）已经存在，无需改动。

### 取舍

- 冻结模式下「点选窗口」是从整屏图里按窗口矩形裁剪，会带上压在它上面的东西 ——
  这正是要的效果（菜单就压在窗口上），且与既有状态栏菜单路径的行为一致。
- 误判（例如某些 App 的 tooltip 也放在 101 层）的后果只是「这一次截图冻结在按下快捷键的那一刻」，
  不影响正确性。

---

## 2. 长截屏（滚动拼接）

### 交互

1. 按截图快捷键，框出**可滚动区域**（不含固定的头部/侧边栏效果最好）；
2. 标注工具条上「贴图」右边新增按钮 **长截屏**（`arrow.up.and.down`，issue 里说的「订到屏幕那里加个按钮」）；
3. 点下后 overlay 退场，选区外沿显示 accent 色边框，附近浮出控制条：
   `已拼接 N pt` + 「完成」+「取消」；
4. 用户自己滚动页面，控制条上的高度实时增长；
5. 「完成」→ 拼成一张长图，走标准结果链路（复制到剪贴板 + 按设置落盘 + 记入截图历史）；
   「取消」→ 什么都不产出。

控制条与边框都是 `nonactivatingPanel`，**全程不激活本 App** —— 否则一点按钮焦点就跑了，
用户没法继续滚目标窗口。边框 `ignoresMouseEvents = true`，滚轮直接穿透到下面的页面。

菜单里在拼接期间多一条「结束长截屏」，防止控制条被拖到看不见的地方；
拼接期间再按截图快捷键 = 结束本次长截屏（否则新拉起的 overlay 会被拼进长图）。

### 抓帧

`CGWindowListCreateImage(选区, .optionOnScreenBelowWindow, 边框窗 ID, .bestResolution)`，
每 0.12s 一帧（主线程同步调用，单区域开销很小）：

- 边框窗层级 `.floating`、控制条 `.statusBar`，**层级顺序固定**，所以「抓边框窗以下的所有窗口」
  天然把自己这两个窗口排除在画面外，不需要额外的 exclude 列表；
- 上一帧还在后台拼接时跳过这一拍（`inFlight`），不积压；
- 保险丝：连续 5 分钟没点完成则自动收工。

### 拼接算法（`ScrollingCaptureStitcher`）

纯 CPU、零依赖，跑在自己的串行队列上（`compose()` 也派发到同一队列，天然排在在途 `append` 之后）。

**行特征**：每帧由 CoreGraphics 缩成 `32 × 高` 的灰度位图，于是每行压成一条 32 字节特征。
缩放本身是盒式滤波，天然抗一两像素的横向抖动。CG 位图内存自上而下，行号 0 即图像顶部。

**匹配**：设 `overlap` = 新帧顶部与已累积图像底部重合的行数，
拿已累积图像**底部 48 行**去新帧 `[overlap-48, overlap)` 处比对，
逐样本累加绝对差取平均（隔行比对省一半算力）。
`overlap` 从大到小遍历 `[48, min(帧高, 已累积高)]`，取平均绝对差最小者：

- 并列时取**最大重叠** = 尽量少认新内容，大片空白不会被误判成滚动过一段；
- 平均绝对差 > 12（0–255 量纲）视为没对上 → 丢弃该帧（滚太快跳过一屏、或内容整体换了），
  宁可少一帧也不要拼错位；
- `overlap == 帧高` → 画面没动，什么都不追加。

**追加**：只把新帧 `[overlap, 帧高)` 这一段**重绘成独立位图**存下来。
`CGImage.cropping` 是惰性视图、仍持有整帧像素，直接存会让每一帧都留在内存里
（100 帧 × 8MB 就是 800MB）；重绘一份后原帧立刻释放，内存 ≈ 最终长图大小。

**上限**：约 3000 万像素（按帧宽折算行数，再夹 40000 行），到顶自动收工。

### 已知取舍

- 页面里的固定头部/悬浮按钮会在每一屏重复出现 —— 这是所有滚动截图工具的共性，
  框选时避开它们即可；
- 滚动条浮层可能被拼进去，同上；
- 已画的标注不参与长截屏（长图内容随滚动变化，标注贴在哪一段都没意义），点长截屏即放弃它们；
- 中途换屏 / 改缩放会让帧宽变化，此时无法与旧内容对齐，该帧直接丢弃。

---

## 涉及文件

| 文件 | 改动 |
|---|---|
| `Sources/Modules/Screenshot/ScreenMenuSnapshot.swift` | 新增 `hasForeignMenuOnScreen()` |
| `Sources/Modules/Screenshot/CaptureController.swift` | `begin` 里补冻结探测；新增 `finishLongCapture`；长截屏期间的快捷键语义 |
| `Sources/Modules/Screenshot/ScrollingCaptureStitcher.swift` | **新增** —— 行特征匹配 + 拼接 |
| `Sources/Modules/Screenshot/ScrollingCaptureController.swift` | **新增** —— 抓帧节奏、边框、控制条、结果输出 |
| `Sources/Modules/Screenshot/AnnotationToolbar.swift` | 贴图右侧新增「长截屏」按钮 + delegate 方法 |
| `Sources/Modules/Screenshot/CaptureOverlayView.swift` | 实现 `toolbarLongCapture()` |
| `Sources/Modules/Screenshot/ScreenshotTool.swift` | 拼接期间的「结束长截屏」菜单项 |
| `Sources/Resources/Localizable.xcstrings` | 7 条 `annotation.longCapture` / `screenshot.longshot.*` / `screenshot.menu.finishLongCapture` |
