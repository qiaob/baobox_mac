# 键盘点击 技术设计

> 配套 [REQUIREMENTS.md](./REQUIREMENTS.md)。实现照本文档。

## 1. 架构

新模块 `Sources/Modules/KeyboardNav/`，实现核心协议 `ToolModule`（自动接入菜单栏、二级菜单、快捷键、设置 Tab）。命名空间 `keyboardnav.*`。

文件规划：

| 文件 | 职责 |
|---|---|
| `KeyboardNavTool.swift` | ToolModule 壳：菜单项、`hotkeys()`、`settingsTab()`、生命周期 |
| `KeyboardNavController.swift` | 协调：触发 → 扫描 → 显示 → 输入 → 点击 → 收尾（@MainActor） |
| `AXElementScanner.swift` | 用 AX 遍历前台 App，产出可点击元素（屏幕矩形 + AXUIElement 句柄） |
| `HintLabelGenerator.swift` | 生成/分配字母标签（Vimium 式最短唯一） |
| `KeyboardNavOverlayWindow.swift` / `KeyboardNavOverlayView.swift` | 透明覆盖窗口 + 标签绘制 + 键盘捕获 |
| `ClickSimulator.swift` | AXPress / CGEvent 点击 |
| `KeyboardNavEnv.swift` | 设置键、常量、忽略名单 |

## 2. Click Mode 详细流程

### 2.1 触发
`HotkeyCenter` 注册一个 hotkey（`defaultCombo: nil`）→ `KeyboardNavController.activate()`。先查 `Permissions.hasAccessibility`，无则引导（复用现有权限引导）。

### 2.2 AX 枚举（`AXElementScanner`）
- 前台 App：`NSWorkspace.shared.frontmostApplication` → `pid` → `AXUIElementCreateApplication(pid)`。
- **递归遍历** AX 树（`kAXChildrenAttribute`）；对每个元素：
  - 读 `kAXRoleAttribute`。
  - **可点击判断**：role ∈ { `AXButton`, `AXLink`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`, `AXMenuButton`, `AXMenuItem`, `AXTabButton`, `AXTextField`, `AXTextArea`, `AXComboBox`, `AXDisclosureTriangle`, `AXStepper`, 可点 `AXCell`/`AXRow`, 有 AXPress 的 `AXImage` … }，**或** `AXUIElementCopyActionNames` 含 `AXPress`。
  - 取几何：`kAXPositionAttribute`(AXValue→CGPoint) + `kAXSizeAttribute`(AXValue→CGSize) = **屏幕矩形**（AX 坐标：原点在**左上**、点单位）。
  - 过滤：size 为 0、完全在屏幕外的丢弃。
- **性能护栏**：最大深度（~40）、最大元素数（~500）、整体超时（~300ms）；超限截断并 `NSLog`。遍历在**后台线程**（AX 调用可阻塞主线程），完成回主线程显示。
- MVP 只扫前台 App 的窗口内元素；系统菜单栏 / Dock 后续。

### 2.3 标签生成（`HintLabelGenerator`）
- Vimium 式：字符集取 home-row 优先（如 `sadfjklewcmpgh`）。按元素数生成**最短、互不为前缀**的标签：N 个元素 → 1~2 字母（多则 3）。
- 元素先按屏幕位置稳定排序（上→下、左→右），标签分配稳定。

### 2.4 overlay（`KeyboardNavOverlayWindow` / `View`）
- 每屏一个透明覆盖窗口：`level = .screenSaver`、`backgroundColor = .clear`、`isOpaque = false`、可成为 key（覆写 `canBecomeKey`）、`constrainFrameRect` 返回原值——**复用截图 overlay 的成熟做法**。
- `View.draw`：每个元素矩形左上角画标签 badge（圆角底 + 字母）；已输入前缀的字母高亮，不匹配的隐藏。
- **坐标**：AX 屏幕坐标（左上原点）→ overlay AppKit 坐标（左下原点）用 `Geometry`（截图模块已有 CG↔AK 转换）。多屏：元素按所在屏分到对应 overlay。

### 2.5 键盘捕获
overlay 成为 key window，`keyDown` 累积输入缓冲：字母 → 追加并前缀过滤候选（唯一即触发点击）；`Delete` 退一字符；`Esc` 取消。捕获期间不作用到真实 App，点击时才作用于目标。

### 2.6 点击模拟（`ClickSimulator`）
- **优先** `AXUIElementPerformAction(element, kAXPressAction)` —— 可访问性点击，不移动真实鼠标、最稳。
- 元素无 AXPress / 失败：合成鼠标事件——`CGEvent(mouseEventSource:.leftMouseDown/.leftMouseUp)` 于元素中心（CG 屏幕坐标，左上原点），move + down + up。
- 点击**前**先关闭 overlay，避免 overlay 挡住合成点击。

### 2.7 收尾
overlay 关闭、缓冲清空、不主动改焦点（AXPress 一般不夺焦）。

## 3. 关键技术点与风险

- **坐标系（最易错）**：AX 与 CGEvent 用**左上原点**屏幕坐标；AppKit 用**左下原点**；多屏各有偏移。全程用 `Geometry` 并在每步注明坐标系（参考截图模块踩坑经验）。
- **AX 遍历性能**：大型 App（浏览器、Xcode）AX 树庞大，全量遍历可能数百 ms~秒级 → 护栏（深度/数量/超时）+ 后台线程；后续可按可见区域裁剪、只遍历焦点窗口。
- **可点击判断准确度**：role + AXPress 启发式会有漏判/误判 → 先覆盖常见 role，按实测迭代。
- **web app**：Chrome/Safari 网页内元素 AX 暴露有限，本期不深入。
- **无法在开发机真机验证**：AX 枚举、overlay 对齐、点击命中都需你真机测，预计多轮微调（类似截图）。

## 4. 复用的 Baobox 基础
- `HotkeyCenter`（全局快捷键；菜单打开期 CGEventTap 已支持）
- `Permissions`（辅助功能权限检查/引导）
- `Geometry`（CG↔AK 坐标转换）
- 截图 overlay 窗口模式（透明覆盖、key window、多屏、Esc）
- `L10n`、`ToolModule` 框架、`ClosureMenuItem`

## 5. 实现顺序（MVP）
1. `AXElementScanner`：枚举 + 可点击判断 + 屏幕矩形（先加一个调试动作打印元素数/位置，真机验证枚举正确性）。
2. `HintLabelGenerator`：标签算法。
3. overlay 窗口 + 标签绘制（静态显示扫描结果，验证坐标对齐）。
4. 键盘捕获 + 前缀过滤。
5. `ClickSimulator`：AXPress / CGEvent。
6. `KeyboardNavTool` 接入：菜单、快捷键、权限引导、设置 Tab、`AppDelegate` 注册。
7. 本地化 key（`keyboardnav.*`，en + zh-Hans）。

## 6. 后续
- Scroll Mode（发滚动事件到焦点滚动区）、Search、忽略应用名单、标签主题、系统菜单栏/Dock 元素。

## 7. 已确认的取舍（用户 2026-07-24）
1. **三个模式都做**（Click / Scroll / Search），但**分阶段交付**：先 Click Mode（原生 App），编译+真机测通后再 Scroll、Search。
2. **触发快捷键对齐 Homerow**：Click=⇧Space、Scroll=⇧J、Search=⇧/（做成**可配置**默认）。⚠️ 已知 ⇧Space 会与"输入框打空格"冲突——MVP 先按默认注册，后续加"文本输入焦点时不触发"的规避或由用户改键。
3. **标签字符 home-row 集**（对齐 Homerow 风格，如 `sdfghjkl…`），可配置；P1 随 macOS 输入源自动适配（AZERTY/Colemak/Dvorak）。
4. **点击优先 AXPress**（不动真鼠标），无 AXPress / 失败回退合成鼠标点击。
