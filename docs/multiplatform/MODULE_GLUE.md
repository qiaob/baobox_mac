# 模块胶水下沉到 baobox-app（#111）

> 状态：**已拍板（2026-11-10）**：用户同意 §7 每一条都按文中的建议做。本文只写设计，实现按迁移步骤分 PR 进行。
> 数据取自 `main@65b1186`（2026-11-10），行号都指那个提交。
> 相关：错误类型的改造见 [`ERRORS.md`](ERRORS.md)（#110），两件事的先后见 §7 Q2。

## 1. 一句话

防休眠、窗口管理、键盘点击这三个工具接进 App 的适配层（`*_module.rs`），在 Linux 和
Windows 上是两份几乎逐字相同的拷贝，真正不同的只有「怎么让系统别睡 / 怎么问窗口 /
怎么点下去」那几行。把三份适配层整份搬进 `shared/baobox-app`，平台只实现一个
2–3 个方法的小 trait；注册清单（`build_registry`）也只留一份。两边分叉时有一边没跟上的
地方（最严重的是 **Linux 没有快捷键设置页**），单独开 PR 修。

## 2. 现状

### 2.1 量化

| 文件 | Linux 行数 | Windows 行数 | 两边 `diff` 改动行 | 差在哪 | 测试（L / W） |
|---|---|---|---|---|---|
| `caffeinate_module.rs` | 373 | 380 | 35（+21 / −14） | 文件头注释；`start` / `stop` 里怎么握住「别睡」 | 11 / 11 |
| `keyboardnav_module.rs` | 235 | 234 | 19（+9 / −10） | 文件头注释；点击那 3 行 | 7 / 7 |
| `windowmanager_module.rs` | 279 | 276 | 63（+30 / −33） | 文件头注释；`apply` 里问窗口、显示器、摆放那一段 | 8 / 8 |
| `clipboard_module.rs` | 551 | 643 | 336（+214 / −122） | 监听模型、粘贴流程整段不同，Windows 还多了文本工具开关 | 8 / 9 |
| `screenshot_module.rs` | 514 | 884 | 868（+619 / −249） | Windows 后来加了快速截图（#87）与长截图、关闭贴图、历史子菜单、识别与文件名设置（#90），Linux 没跟 | 8 / 2 |

（「改动行」是两份文件 `diff` 之后用 `diffstat` 数出来的增删行数。）

除了三个模块文件，装配层也有逐字重复：

| 重复的东西 | Linux | Windows | 说明 |
|---|---|---|---|
| `build_registry()` | `app.rs:52–69` | `app.rs:37–55` | 同样 7 个工具、同样顺序；Windows 末尾多注册一个桌面宠物，要传 `owner: HWND` |
| 首启补默认值 → 落盘 → `activate_all` | `app.rs:77–84` | `app.rs:440–447` | 逐字相同 |
| `resolve_hotkeys()` | `app.rs:215–227` | `app.rs:620–632` | 逐字相同 |
| `hotkeys::Registration`（注册结果 + 提示语） | `hotkeys.rs:61–91` | `hotkeys.rs:29–59` | 逐字相同 31 行 |
| `now_seconds()` | `main.rs:653` | `main.rs:745` | 共享层 `assistant_tool.rs:45` 还有第三份 |
| 注册顺序、动作 id 的测试 | `app.rs:346–428` | `app.rs:693–807` | 两边各写一遍 |

另一个隐性成本：Windows 的三个适配层文件**整份**带 `#![cfg(windows)]`
（`caffeinate_module.rs:17`、`keyboardnav_module.rs:24`、`windowmanager_module.rs:14`），
所以它们那 26 条测试只在 Windows CI 上跑，开发机上从来不跑 —— 而这 26 条测的全是
纯逻辑（菜单、动作 id、设置项、到期判定），和 Win32 毫无关系。这违反了
`ARCHITECTURE.md` 约定 5（「只有真正碰系统 API 的部分加 `cfg(windows)`」）。

### 2.2 两个平台各自怎么拿到模块

```
Linux  app.rs   build_registry() ──► ToolRegistry ──► 托盘（tray.rs，dbusmenu）
                                                  ├─► 快捷键线程（hotkeys.rs，XGrabKey）
                                                  └─► 设置窗口（settings_window.rs，只拿 registry.settings_pages()）
Windows app.rs  build_registry(owner) ─► ToolRegistry ─► 托盘（tray.rs，弹出时现建 HMENU）
                                                     ├─► 快捷键（hotkeys.rs，RegisterHotKey）
                                                     └─► 设置窗口（前插「通用」「快捷键」，后接「关于」）
```

托盘、快捷键中心、设置窗口的**渲染**是真平台差异，不在本次范围。本次只收
「注册清单」和「三个工具的适配层」。

### 2.3 逐处对比：真平台差异、无意分叉、bug

| # | 位置 | Linux | Windows | 判定 | 迁移时以谁为准 |
|---|---|---|---|---|---|
| 1 | 防休眠：怎么握住「别睡」 | 持有 `Inhibitor`，丢掉即解除（`caffeinate_module.rs:63–64、87–89、98–101`） | 显式 `release()`，且只在开着时调（`caffeinate_module.rs:103–108`） | **真平台差异**：login1 给 fd + 屏保给 cookie，Windows 是按线程记的状态 | 收成 `AwakeBackend::{engage, release}`，两边各写约 20 行 |
| 2 | 防休眠：成功提示 | `inhibitor.describe()`，照实说哪家答应了 | 按设置给固定的一句（`:91–95`） | **真平台差异**：只有 Linux 会「只挡住一半」 | 由 `engage()` 返回这句话 |
| 3 | 键盘点击：点下去 | 开一条 X11 连接，逐个 XTEST（`keyboardnav_module.rs:107–111`） | 逐个 `SendInput`（`:108–110`） | **真平台差异** | `HintBackend::click_all`，Linux 仍只开一条连接 |
| 4 | 窗口管理：问窗口、显示器，摆放 | X11 + RandR + 自己减 strut；先 `unmaximize` 再 `place`（`windowmanager_module.rs:67–83、115–116`） | 前台窗口 + `rcWork`；`place` 里自己 `SW_RESTORE`（`:76–85、113`） | **真平台差异** | `WindowBackend::{locate, place}` |
| 5 | 窗口管理：「恢复原位」表的键 | `u32`（X11 窗口 id，`:47`） | `isize`（`HWND` 不是 `Hash`，`:55`） | **真平台差异** | 关联类型 `type Window: Copy + Eq + Hash` |
| 6 | 窗口管理：判断「窗口在哪块屏」、给屏排序用哪个矩形 | 整块显示器（`:83、100`） | 可用区域 `rcWork`（`:85、98`），因为 `work_areas()` 只收了 `rcWork` | **无意分叉**。只有任务栏贴在某块屏左边、且两块屏左边缘相差不到一条任务栏宽时，排序才可能不同 | 共享逻辑统一用 `Display.bounds`；Windows 垫片第一步先填 `bounds = rcWork`（行为不变），以后改一行换成 `rcMonitor`（§7 Q4） |
| 7 | 窗口管理：没有活动窗口时的提示 | 「…（焦点可能在桌面上）」 | 多半句「…，或者窗口是最小化的」（Windows 的 `foreground()` 滤掉了最小化窗口） | **真平台差异** | 文案留在各自垫片里 |
| 8 | 窗口管理：RandR 不可用 | 「读不到显示器布局（RandR 不可用），跨屏移动用不了」 | 无此情况 | **真平台差异** | 垫片通过 `Located::displays_unknown` 给出 |
| 9 | 整个适配层文件带 `#![cfg(windows)]` | — | 见 §2.1 | **无意分叉**（违反约定 5），后果是 26 条纯逻辑测试只在 Windows CI 上跑 | 搬进共享层后在每台机器上跑 |
| 10 | **快捷键设置页** | **没有**。`app.rs:149` 只把各工具的页交给设置窗口；Linux 侧全仓库没有一处 `Field::hotkey(` | #87 起在工具页前面插一页「快捷键」（`app.rs:332–341`，再往前是「通用」） | **bug**：Linux 19 个快捷键里 17 个出厂不绑（窗口管理 13、键盘点击 1、截整个屏幕 / 屏幕取字 / 录屏 3），用户在界面上**无处可设**，只能手改 `config.ini`；出厂绑了的 2 个（截图、剪贴板面板）撞了别的程序也没处改。GTK 的录键控件写好了、带单测（`settings_window.rs:220–237`），却永远走不到。Linux 还有两处文案指向这个不存在的页面：`app.rs:427`「设置里才看得到」、`hotkeys.rs:85`「可在设置里换一个」 | **以 Windows 为准**，页面改由共享层生成（PR 6） |
| 11 | **新建文本片段后的提示** | 「已创建片段「…」，可在设置里给它加关键字」（`clipboard_module.rs:455`），但 Linux 设置里**没有**关键字这一项（关键字展开没接，见 `ARCHITECTURE.md`「剪贴板工具」） | #90 改成「…，可在剪贴板「收藏」中使用」（`:539`） | **bug**：提示指向不存在的入口 | **以 Windows 为准**去掉「设置」那半句；Linux 面板没有「收藏」筛选（片段在列表里带「片段」标签，`clipboard_panel.rs:383–384`），措辞按 Linux 面板写（PR 6） |
| 12 | 剪贴板面板的出厂快捷键 | `Ctrl+Alt+V`（`:337`） | `Ctrl+Shift+V`（`:416`，#90 对齐 mac 的 ⌘⇧V，并在 `app.rs:288–314` 为终端粘贴临时让位） | **有意的平台差异**：Linux 终端普遍用 Ctrl+Shift+V 粘贴，X11 全局 grab 会把它从所有终端手里抢走 | 保持两边不同 |
| 13 | 剪贴板：`text_tools` 开关、文件条目粘成文件、粘回原来的窗口 | 都没有（文件条目粘成路径文字） | #90 加的 | **功能演进，Linux 没跟**，不是胶水 bug | 剪贴板不在第一阶段搬家范围（§3） |
| 14 | 菜单里的「截图设置…」「剪贴板设置…」 | 没有 | 两个工具菜单里各有一项，动作 id `screenshot.settings` / `clipboard.settings`，由 `app.rs:176–177` 截下来处理 | **框架漏了东西**：缺一个「打开设置并翻到某页」的框架动作，Windows 只好让平台层认识具体工具的动作 id，违反「框架不认识具体工具」 | 第二阶段补框架动作（PR 7） |
| 15 | 「动作 id 两边一致」的测试 | — | `app.rs:768` `the_windows_tool_declares_the_same_actions_as_the_linux_one` 拿注册表里的 id 去比 **Windows 自己的常量**，并没有和 Linux 比 | **测试空转**：两边常量各写各的，改了一边它照样绿；`windows/CLAUDE.md` 说的「有测试盯着」其实没盯住 | 常量搬进共享层，一致性由编译保证；测试改成钉死字面量（PR 1） |

另外三件**两边一样、不是分叉**，但合并时值得顺手记下：

| 问题 | 位置 | 建议 |
|---|---|---|
| 防休眠开着时改「同时不让显示器关掉」，若重开失败，会话被**静默关掉**，用户不知道 | `if self.start(remaining).is_ok()`：L `caffeinate_module.rs:180` / W `:187` | 合并后只需修一处；要有地方把失败告诉用户，依赖 #110 的错误通道 |
| 剪贴板图片文件名是 `"{秒}-{进程号}.png"`，**同一秒复制两张图会互相覆盖**，淘汰其中一条时会把另一条的图一起删掉 | L `clipboard_module.rs:155` / W `:192` | 不属于本 issue，建议单开 issue（文件名加上条目 id 的计数后缀即可） |
| 防休眠 `hotkeys()` 的注释说「与 macOS 侧一致」，但 mac 有一个出厂不绑的 `caffeinate.toggle` 快捷键（`mac/Sources/Modules/Caffeinate/CaffeinateTool.swift:66–78`） | L / W `caffeinate_module.rs` 的 `hotkeys()` | 两个 Rust 平台一起落后于 mac，§7 Q5 |

## 3. 目标与非目标

**目标**

1. 防休眠、窗口管理、键盘点击的适配层只有一份，在 `baobox-app`；`linux/`、`windows/`
   只留实现小 trait 的垫片。
2. 注册清单只有一份：**改一处，两边一起生效**（issue 验收 1）。加一个共用工具时，
   两个平台不实现垫片就编不过 —— 想漏也漏不了。
3. 两边仍各自独立编译、测试（issue 验收 2）；以前只在 Windows CI 上跑的 26 条测试，
   改到在每台机器上跑，另加一批用假后端的测试（以前测不到「真的摆了窗口」这类成功路径）。
4. `Registration`、`resolve_hotkeys`、快捷键页、`now_seconds`、动作 id 常量只留一份。
5. 两个分叉 bug（§2.3 #10、#11）用单独的 PR 修，修法以 Windows 为准。

**非目标**

- **不搬截图、剪贴板的执行流程**。覆盖层、编辑器、面板、监听模型在两个系统上形状差太远，
  `ARCHITECTURE.md` 明确不给抓屏 / 剪贴板做平台 trait；硬抽象只会得到一个谁都不好用的接口。
  这两个工具第一阶段只共享**动作 id 常量**（它们是用户配置里的键名，是跨平台契约）。
- 不追平功能差（Linux 剪贴板的文本工具开关、Windows 的快速截图等）。
- 不动托盘、快捷键中心、设置窗口的渲染。
- 不改错误类型：新 trait 先沿用 `Result<_, String>`，由 #110 统一换（见 `ERRORS.md`）。
- 不碰 mac。

## 4. 新结构

### 4.1 放在哪

```
shared/baobox-app/src/
├── lib.rs              + pub fn now_seconds()
│                       + ToolRegistry::resolved_hotkeys(&Config)
│                       + ToolRegistry::hotkey_page()          （PR 6）
├── hotkeys.rs          Registration（从两边 hotkeys.rs 原样搬来）
├── platform.rs         trait Platform + build_registry()     （唯一一份注册清单）
└── tools/
    ├── mod.rs
    ├── caffeinate.rs     CaffeinateTool<B: AwakeBackend>     （完整工具）
    ├── windowmanager.rs  WindowManagerTool<B: WindowBackend>（完整工具）
    ├── keyboardnav.rs    KeyboardNavTool<B: HintBackend>    （完整工具）
    ├── screenshot.rs     只有 id 常量                         （流程留在平台层）
    └── clipboard.rs      只有 id 常量                         （同上）
```

依赖方向不变：`baobox-app` 只依赖 `baobox-core`，不引任何平台库；仍是
`#![forbid(unsafe_code)]`。

### 4.2 三个后端 trait

下面的签名已在临时 crate 里对着当前 `shared/` 编过：`cargo +1.90.0 fmt --check`、
`cargo +1.90.0 clippy --all-targets -- -D warnings`（开着 `missing_docs`）、15 条测试全过。

```rust
// tools/caffeinate.rs
/// 「让系统别睡」在这个平台上怎么做。
pub trait AwakeBackend {
    /// 开始防休眠。`display` 为真时连显示器也不让关。
    /// 成功时返回一句「这次挡住了什么」给用户看；一家都没答应就返回错误，不许假装开好了。
    fn engage(&mut self, display: bool) -> Result<String, String>;
    /// 解除。工具保证只在开着时调用，并且总是**先解除再重开**。
    fn release(&mut self);
}
```

```rust
// tools/keyboardnav.rs
pub trait HintBackend {
    /// 扫一遍当前活动窗口里可点的元素。**必须在覆盖层出现之前调**。
    fn scan(&mut self) -> Result<Vec<Target>, String>;
    /// 显示标签、收键盘，直到会话结束；返回用户依次选中的那些。
    fn run_overlay(&mut self, session: &mut Session) -> Result<Vec<Hint>, String>;
    /// 依次在这些点上点一下。
    fn click_all(&mut self, points: &[(f64, f64)]) -> Result<(), String>;
}
```

```rust
// tools/windowmanager.rs
/// 一块显示器。
pub struct Display {
    /// 整块屏：判断窗口在哪块屏、给屏排序用
    pub bounds: Rect,
    /// 可用区域（扣掉任务栏 / strut）：算目标矩形用
    pub work: Rect,
}

/// 平台把「当前窗口 + 显示器布局」一次问齐交回来。
pub struct Located<W, P> {
    pub window: W,                        // 恢复原位表里的键
    pub visible: Rect,                    // 用户看到的矩形（含标题栏、不含阴影）
    pub displays: Vec<Display>,           // 至少一块
    pub displays_unknown: Option<String>, // 布局只是猜的时，跨屏动作要说的那句话
    pub placement: P,                     // 摆放时原样带回给平台的东西
}

pub trait WindowBackend {
    /// 窗口标识（X11 窗口 id、HWND 的数值）
    type Window: Copy + Eq + std::hash::Hash;
    /// 摆放要带回来的平台细节（Linux：X11 连接 + 边框厚度；Windows：句柄 + 阴影厚度）
    type Placement;
    fn locate(&mut self) -> Result<Located<Self::Window, Self::Placement>, String>;
    /// 把窗口摆到 `target`（用户看到的矩形）。取消最大化也是平台的事。
    fn place(&mut self, window: Self::Window, placement: Self::Placement, target: &Rect)
        -> Result<(), String>;
}
```

几处取舍：

- **防休眠用「engage / release」而不是「返回一个 guard，丢掉即解除」**。RAII guard 更像
  Rust，但在 Windows 上有个陷阱：状态是**按线程**记的，不是按 guard 记的。若写成
  `self.guard = Some(新 guard)`，旧 guard 会在新的开启**之后**才 drop，它的
  `SetThreadExecutionState(ES_CONTINUOUS)` 会把刚开的也一起关掉，而且没有任何报错。
  显式两步、由共享工具保证「先解除再重开」，再用假后端测试把调用顺序钉死
  （`["engage:false", "release", "engage:true"]`）。Linux 的 `Inhibitor` 仍是 RAII，
  藏在垫片里。
- **窗口管理一次 `locate` 问齐**，而不是拆成「活动窗口 / 显示器 / 可用区」三个方法：
  Linux 现在一个动作只开一条 X11 连接，`Placement` 关联类型让这条连接从 `locate`
  带到 `place`，行为与现在一致；Windows 的 `Placement` 就是 `(HWND, Shadow)`。
- **键盘点击 `click_all` 一次给全部点**：Linux 只开一条连接逐个点，与现在一致。
- trait **不要求 `Send`**：注册表本来就留在主线程（两边都是），X11 连接与 `HWND` 都不是 `Send`。

### 4.3 共享工具

三个工具的菜单、动作 id、设置声明、`config_changed`、`tick`、`perform` 原样从 Linux
那份搬来（两边本来逐字相同），只把平台那几行换成调后端。例如防休眠：

```rust
pub struct CaffeinateTool<B: AwakeBackend> {
    backend: B,
    settings: Settings,
    session: Option<Session>,
}

impl<B: AwakeBackend> CaffeinateTool<B> {
    pub fn new(backend: B) -> Self { … }

    fn start(&mut self, duration: Option<i64>) -> Result<String, String> {
        // 先解除再重开：顺序反过来的话，Windows 上 release 会把刚开的也一起关掉
        self.stop();
        let note = self.backend.engage(self.settings.prevent_display_sleep)?;
        self.session = Some(Session::start(crate::now_seconds(), duration));
        Ok(…) // 文案与现在相同
    }

    fn stop(&mut self) {
        if self.session.take().is_some() {
            self.backend.release();
        }
    }
}

impl<B: AwakeBackend> ToolModule for CaffeinateTool<B> { … }
```

`stop()` 只在开着时调 `release()` —— 这正是 Windows 现在的语义；Linux 上抑制器与会话
同生同灭，两种写法等价。窗口管理的 `apply` 变成「`locate` → 算目标 → 记下原位 →
`place`」，算目标那段与现在逐字相同，只是 `display_for` / `sort_displays` 统一吃
`Display.bounds`、`layout::target` / `map_across_displays` 统一吃 `Display.work`。

### 4.4 注册清单：`Platform` + `build_registry`

```rust
// platform.rs
/// 平台垫片：每个共用工具要的那一小块能力，加上仍留在平台层的工具。
pub trait Platform {
    type Awake: AwakeBackend + 'static;
    type Windows: WindowBackend + 'static;
    type Hints: HintBackend + 'static;

    fn screenshot(&self) -> Box<dyn ToolModule>;   // 流程差异太大，仍在平台层
    fn clipboard(&self) -> Box<dyn ToolModule>;    // 同上
    fn awake(&self) -> Self::Awake;
    fn windows(&self) -> Self::Windows;
    fn hints(&self) -> Self::Hints;
    fn open_terminal(&self) -> OpenTerminal;       // 两个 AI 助手开终端用
    /// 只有这个平台才有的工具（Windows 的桌面宠物），排在最后
    fn extra_tools(&self) -> Vec<Box<dyn ToolModule>> { Vec::new() }
}

/// 装配所有工具。**注册顺序 = 菜单顺序**，两个平台只有这一份。
pub fn build_registry<P: Platform>(platform: &P) -> ToolRegistry {
    let mut registry = ToolRegistry::new();
    registry.register(platform.screenshot());
    registry.register(platform.clipboard());
    registry.register(Box::new(CaffeinateTool::new(platform.awake())));
    registry.register(Box::new(WindowManagerTool::new(platform.windows())));
    registry.register(Box::new(AssistantTool::new(Flavor::ClaudeCode, platform.open_terminal())));
    registry.register(Box::new(AssistantTool::new(Flavor::Codex, platform.open_terminal())));
    registry.register(Box::new(KeyboardNavTool::new(platform.hints())));
    for tool in platform.extra_tools() {
        registry.register(tool);
    }
    registry
}
```

用关联类型而不是一个装满 `Box<dyn ToolModule>` 的结构体：后者允许平台在防休眠那一格
塞进任何工具，共享适配层就形同虚设；关联类型让「共享工具由共享层构造」成为类型上的事实。
以后加一个共用工具 = `tools/` 里加一个文件 + `Platform` 里加一个关联类型 + 清单里加一行，
两个平台不写垫片就编不过。

注册顺序测试搬到共享层，用假平台在开发机上真跑（两种情况：没有额外工具；额外工具排在最后）。

### 4.5 平台垫片留什么

| | Linux | Windows |
|---|---|---|
| 防休眠 | `caffeinate.rs` 末尾加 `LinuxAwake(Option<Inhibitor>)`：`engage` 存下抑制器并返回 `describe()`，`release` 丢掉它（约 20 行） | `caffeinate.rs` 加 `WindowsAwake`：`engage` / `release` 直接调现有两个函数，提示语按 `display` 给（约 20 行，带 `#![cfg(windows)]`） |
| 窗口管理 | `windowmanager.rs` 加 `LinuxWindows` + `X11Placement { session, root, extents }`：`locate` 就是现在 `apply` 的前半段，`place` = `unmaximize` + `place`（约 45 行） | `windowmanager.rs` 加 `WindowsWindows`：`type Window = isize`，`type Placement = (HWND, Shadow)`；第一步 `bounds = work = rcWork`（约 35 行） |
| 键盘点击 | `keyboardnav.rs` 加 `LinuxHints`：`scan` / `hint_overlay::run` / 开一条 X11 连接逐个 `click`（约 25 行） | `keyboardnav.rs` 加 `WindowsHints`（约 20 行） |
| 装配 | `app.rs`：`struct LinuxPlatform; impl Platform`（约 30 行），`build_registry()` 变一行 | `app.rs`：`struct WindowsPlatform { owner: HWND }; impl Platform`，`extra_tools` 返回桌面宠物（约 35 行） |
| 删掉 | `caffeinate_module.rs`、`keyboardnav_module.rs`、`windowmanager_module.rs`（887 行） | 同名三个文件（890 行） |

估算：删 1777 行重复，新增共享工具约 900 行 + 新测试约 250 行 + 两边垫片约 240 行，
净减约 400 行。更重要的是那 26 条重复测试变成一份，而且在每台机器上都跑。

### 4.6 与 `ARCHITECTURE.md` 的关系

`ARCHITECTURE.md:74` 写着「`shared/` 里**没有平台 trait**」。本设计在 `baobox-app`
里加了三个后端 trait，要同步改文档（PR 5），把边界写清楚：**只给「适配层九成以上相同、
平台部分不超过三个方法」的工具开后端 trait**；抓屏、剪贴板这种形状差太远的平台能力，
仍然不开（§7 Q1）。`ARCHITECTURE.md` 约定 6、`linux/CLAUDE.md` 与 `windows/CLAUDE.md`
里「加工具：在 `app.rs` 的 `build_registry()` 注册一行」与文件地图也一并更新。

## 5. 迁移步骤

每个 PR 单独可合；每步都要过 `cargo fmt --check`、`cargo clippy --all-targets -- -D warnings`
与测试（命令见 §6.1）。PR 1–5 **行为不变**；PR 6 是唯一改变行为的（只在 Linux 上），
单独审。第二阶段（PR 7–9）不在 issue 验收内，可选。

| PR | 内容 | 动哪些文件 | 行为 |
|---|---|---|---|
| **1 共享地基** | `now_seconds()`、`Registration`、`resolved_hotkeys()` 只留一份；截图、剪贴板的工具 id 与进配置的动作 id 搬进 `baobox_app::tools::{screenshot, clipboard}`，两边 `pub use`（另外三个工具的常量随 PR 2–4 一起搬）；空转的 `app.rs:768` 测试换成共享层一条钉死字面量的测试 | shared：`lib.rs`、新 `hotkeys.rs`、新 `tools/{mod,screenshot,clipboard}.rs`、`assistant_tool.rs`；两边：`app.rs`、`hotkeys.rs`、`main.rs`、`screenshot_module.rs`、`clipboard_module.rs` | 不变 |
| **2 防休眠搬家** | `CaffeinateTool<B>` + `AwakeBackend`；原 11 条测试 + 4 条假后端测试（先解除再重开、没开着不碰后端、开不成时报错且不留会话、退出时解除） | shared：新 `tools/caffeinate.rs`；两边：`caffeinate.rs` 加垫片、删 `caffeinate_module.rs`、`main.rs` 去掉 `mod`、`app.rs` 那一行注册；Windows 的 `app.rs:73` 宠物环形菜单改用共享常量 | 不变 |
| **3 键盘点击搬家** | `KeyboardNavTool<B>` + `HintBackend`；原 7 条 + 假后端测试（选中的点被点到、空窗口报「没找到」） | shared：新 `tools/keyboardnav.rs`；两边：`keyboardnav.rs` 加垫片、删 `keyboardnav_module.rs`、`main.rs`、`app.rs`（Windows 宠物菜单的 `CLICK` 常量改路径） | 不变 |
| **4 窗口管理搬家** | `WindowManagerTool<B>` + `WindowBackend`；原 8 条 + 假后端测试（半屏落在可用区、连按两次恢复不覆盖记忆、单屏跨屏给原因）—— 以前「恢复不覆盖记忆」只能靠「没有 X 服务器所以失败」间接测 | shared：新 `tools/windowmanager.rs`；两边：`windowmanager.rs` 加垫片、删 `windowmanager_module.rs`、`main.rs`、`app.rs` 测试里的路径 | 不变（Windows 垫片 `bounds = rcWork`） |
| **5 注册清单只留一份** | `Platform` + `build_registry()`；顺序测试、快捷键解析测试、「出厂只绑两个」测试搬进共享层用假平台跑；两边 `build_registry` 变一行；更新 `ARCHITECTURE.md` 与两份平台 `CLAUDE.md` | shared：新 `platform.rs`；两边 `app.rs`；`docs/multiplatform/ARCHITECTURE.md`、`linux/CLAUDE.md`、`windows/CLAUDE.md` | 不变。**issue 验收 1 在这一步达成** |
| **6 修分叉 bug** | 共享层 `ToolRegistry::hotkey_page()`（从 Windows `app.rs:332–341` 搬来）；Windows 改用它；**Linux 设置窗口最前面加「快捷键」页**；Linux 新建片段的提示改掉「在设置里加关键字」 | shared：`lib.rs`；Windows `app.rs`；Linux `app.rs`、`clipboard_module.rs`；如手册有 Linux 快捷键说明一并更新 | **Linux 变化**（修 bug）；Windows 不变 |
| 7（可选） | 框架动作「打开设置并翻到某页」：`menu::AppAction::parse`（`app.settings` / `app.settings.<节名>` / `app.about` / `app.quit`）；Windows 的 `screenshot.settings`、`clipboard.settings` 改用它，平台层不再认识工具的动作 id | shared：`menu.rs`；两边 `app.rs`；Windows 两个模块的菜单项 | 不变（这两个 id 只在菜单里，不进配置，改名安全） |
| 8（可选） | Windows 垫片的 `Display.bounds` 改用 `rcMonitor`，与 Linux 同一口径 | Windows `windowmanager.rs` | 边缘情况下屏序可能变（§2.3 #6） |
| 9（可选） | 防休眠补一个出厂不绑的 `caffeinate.toggle` 快捷键规格，对齐 mac；更正过期注释 | shared：`tools/caffeinate.rs` | 快捷键页多一行 |

## 6. 风险与验证

### 6.1 本机怎么验

当前 `main` 的基线已经量过，全绿：`baobox-app` 50 条测试过；Windows crate 交叉检查
clippy 过；Linux crate 在 Docker 里 fmt / clippy 过、166 条测试过。

```bash
# 共享层（四个 crate 各跑一遍，CI 也是这么跑的）
cd shared/baobox-app
cargo +1.90.0 fmt --check
cargo +1.90.0 clippy --all-targets -- -D warnings
cargo +1.90.0 test

# Windows：Mac 上只能类型检查（--all-targets 连测试代码一起查）
cd windows/baobox-windows
cargo +1.90.0 fmt --check
cargo +1.90.0 clippy --target x86_64-pc-windows-gnu --all-targets -- -D warnings

# Linux：依赖 GTK，在 Docker 里跑。只读挂载 + 目标目录放容器里，工作区不留任何东西
docker run --rm -v "$PWD":/work:ro -e CARGO_TARGET_DIR=/tmp/target \
  -w /work/linux/baobox-linux baobox-linux-dev:local \
  bash -c 'cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked --all-targets'
```

几个坑：

- 容器里要用 `bash -c`，**不能用 `bash -lc`**：登录 shell 会重置 `PATH`，`cargo` 直接找不到。
- 本机没有 `baobox-linux-dev:local` 时，从 `rust:1.90-bookworm` 起，
  `apt-get install -y libgtk-3-dev pkg-config` 即可（镜像里自带 clippy 与 rustfmt）。
- 托盘那条测试要会话总线，容器里会自己跳过（CI 用 `dbus-run-session -- xvfb-run` 真跑）。

Windows 的覆盖层、托盘、设置窗口测试只在 `build-windows.yml` 的真机 runner 上跑，
**每个动到 Windows 垫片的 PR 都要看那条流水线**，本地类型检查通过说明不了全部。

### 6.2 风险

| 风险 | 怎么防 |
|---|---|
| Windows 上「先开新的、再丢旧的」会把新开的一起关掉（按线程记状态） | 共享工具 `start()` 总是先 `stop()`；假后端测试钉死调用顺序 |
| 垫片带 `cfg(windows)`，Windows 行为只有 CI 能验 | 垫片只做「转调现有函数」，不含逻辑；逻辑全在共享层、在开发机上测 |
| Linux 的 X11 连接生命周期 | `X11Placement` 把 `locate` 开的连接带到 `place`，一个动作一条连接，与现在相同 |
| 守卫测试 `every_declared_setting_is_actually_read_somewhere` 用 `include_str!` 读自己的文件名 | 搬家时文件名跟着改（`include_str!("caffeinate.rs")`），否则编不过，不会静默失效 |
| PR 6 的快捷键页若被交给 `fill_defaults`，会在配置里写下 `hotkey.xxx=`（空串 = 用户主动解绑），以后出厂默认值改了也到不了用户手里 | `hotkey_page()` 不进 `settings_pages()`；加一条测试盯着「首启补默认值不碰 `[hotkey]` 节」 |
| PR 6 的 GTK 录键控件从来没被用户走到过 | 合并前在真机 X11 桌面（KDE / XFCE）手测：开设置 → 快捷键 → 给「左半屏」录一个组合 → 按下去窗口真的动了；再试 `Esc` 取消、`Backspace` 解绑（§7 Q6） |
| Windows `app.rs` 里宠物环形菜单直接引用 `caffeinate_module::{ID, STOP, TOGGLE}`、`keyboardnav_module::CLICK` | 对应 PR 里把 `use` 改到 `baobox_app::tools::*`；编译器会逐个指出来 |
| 泛型单态化让二进制变大 | 每个工具每个平台只实例化一次，可以忽略 |

## 7. 已拍板（2026-11-10）

用户的答复：「按你的建议来就行」—— 下面每一条都按「建议」那一行执行。原问题与建议保留，供实现时对照。

| # | 问题 | 建议 |
|---|---|---|
| Q1 | 接受在 `baobox-app` 里放「每个工具一个小后端 trait」吗？`ARCHITECTURE.md` 现在写着 shared 里没有平台 trait | **接受**，并把边界写进 `ARCHITECTURE.md`：只给适配层九成以上相同、平台部分不超过三个方法的工具开；抓屏 / 剪贴板继续不开 |
| Q2 | 先做 #111 还是 #110？ | **先 #111**：#110 要改 `ToolModule::perform` 的签名，三个工具合并之后只改一次，而不是两边各改一次再合并 |
| Q3 | 截图、剪贴板要不要在第二阶段也共享菜单与设置声明？ | 第一阶段**只共享 id 常量**（PR 1，零风险）。菜单与设置项要等 Windows #90 那批功能在 Linux 上追平再说，不在本 issue |
| Q4 | 窗口管理「窗口在哪块屏 / 屏的顺序」统一按整块显示器算（Linux 的口径）？ | **是**。PR 4 先保持 Windows 现状，PR 8 再改一行；只有边缘情况会不同 |
| Q5 | 防休眠要不要像 mac 一样声明一个出厂不绑的 `caffeinate.toggle` 快捷键？ | **要**（PR 9，搬家后共享层一行），同时更正「与 macOS 侧一致」那句过期注释 |
| Q6 | PR 6 要不要先在真机 Linux 上手测再合？ | **要**。那段录键代码写好以来从没被用户走到过，CI 的 Xvfb 只能证明它编得过、单测过 |

## 8. 与 issue 描述的出入

- 行数按当前 `main` 重数：三个文件现在是 373 / 380、235 / 234、279 / 276 行；
  `diff` 改动行分别是 35、19、63（issue 写的窗口管理是 65）。
- Windows `settings_window.rs` 现在 2336 行（issue 写 2327），Linux 424 行（issue 写 417）。
- issue 说两边 `settings_window.rs` 的反向差异「是设计使然」—— 渲染层确实如此；
  但 **Linux 没有快捷键页不是设计，是 #87 只改了 Windows**（§2.3 #10）。
- issue 的范围写「`linux/` 与 `windows/` 只留平台垫片」。对三个近乎重复的工具可以做到；
  截图与剪贴板的执行流程做不到（要给抓屏 / 剪贴板开大 trait，正是 `ARCHITECTURE.md`
  明确拒绝的），所以本设计分两阶段，第一阶段只共享它们的 id 常量。
