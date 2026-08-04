# CLAUDE.md — Windows 实现

给在 `windows/` 下干活的会话。**先读仓库根目录的 `CLAUDE.md`**（产品全貌与三平台约定），
再读这一页。跨平台的共享逻辑在 `../shared/`，架构取舍在 `../docs/multiplatform/ARCHITECTURE.md`。

## 这是什么

`windows/baobox-windows/` —— 一个 Rust 二进制。不带参数就是**常驻 App**（托盘 + 全局快捷键 +
设置窗口）；带子命令则是一次性的命令行工具。目前实现了**截图**、**剪贴板**、**防休眠**、**窗口管理**、
**Claude Code 助手**、**Codex 助手**六个工具。

```
baobox-windows                  常驻：托盘 + 快捷键 + 设置
baobox-windows capture [...]    截图（默认进标注编辑器）
baobox-windows ocr / record     屏幕取字 / 录屏
baobox-windows scroll / history / windows / info
```

## 构建

在 Windows 上：

```powershell
cargo build && cargo test
cargo rustc --release -- -D warnings     # CI 用这个卡警告
```

在**非 Windows 的开发机上**只能做类型检查（这是本仓库的常态）：

```bash
rustup target add x86_64-pc-windows-gnu
cargo check --target x86_64-pc-windows-gnu --all-targets    # --all-targets 会连测试代码一起检查
```

⚠️ **绝大多数测试在开发机上跑不到** —— 覆盖层、编辑器、托盘、设置窗口都带 `#![cfg(windows)]`。
它们只有在 `.github/workflows/build-windows.yml` 的真机 runner 上才真正执行。
所以**改完一定要看那条流水线的结果**，本地 `cargo test` 通过说明不了什么。

## 只给真正碰 Win32 的部分加 `cfg(windows)`

纯计算（ffmpeg 参数拼装、像素通道换算、尺寸检查）**放在门外面**，
它们的测试才能在开发机上跑到 —— 而那恰恰是最容易写错、又最难在真机上发现的部分
（少一个 `-pix_fmt` 要等到播放器打不开才知道）。`record.rs` 与 `ocr.rs` 就是这么分的。

## 文件地图

| 文件 | 干什么 |
|---|---|
| `main.rs` | 命令行入口与参数解析；`default_path` / `now_seconds` 被别处共用 |
| `app.rs` | **常驻 App 的装配**：注册表 + 托盘 + 快捷键 + 设置。加工具改 `build_registry()` |
| `screenshot_module.rs` | 截图工具的 `ToolModule` 适配层（不含截图逻辑） |
| `gdi.rs` | 抓屏、窗口枚举、DPI 声明 |
| `overlay.rs` | 截图覆盖层（分层窗口 + color key 挖空） |
| `editor.rs` | 标注编辑器窗口（DIB section） |
| `pin.rs` | 贴图窗口 |
| `tray.rs` | 托盘图标 + 运行期生成的 `HMENU`；也提供消息专用窗口 |
| `settings_window.rs` | Win32 通用控件的设置窗口 |
| `hotkeys.rs` | 多快捷键中心 |
| `clipboard.rs` | 写剪贴板：`CF_DIB` / `CF_UNICODETEXT` |
| `clipboard_read.rs` | 监听 `WM_CLIPBOARDUPDATE` 并读回内容；DIB → RGBA |
| `clipboard_panel.rs` | 剪贴板面板（两层：条目 / 文本工具） |
| `clipboard_store.rs` | 剪贴板历史落盘 + DPAPI 加密 |
| `clipboard_module.rs` | 剪贴板工具的 `ToolModule` 适配层 |
| `paste.rs` | 回填粘贴（`SendInput` 合成 Ctrl+V） |
| `ocr.rs` | `Windows.Media.Ocr`（系统自带，不需要用户装东西） |
| `record.rs` | 外挂 ffmpeg `gdigrab` |
| `caffeinate.rs` | 防休眠：`SetThreadExecutionState` |
| `caffeinate_module.rs` | 防休眠工具的 `ToolModule` 适配层 |
| `windowmanager.rs` | 窗口管理：前台窗口 / `rcWork` / `SetWindowPos` |
| `windowmanager_module.rs` | 窗口管理的 `ToolModule` 适配层 |
| `assistant.rs` | AI 助手：找日志、扫目录（与 Linux 逐字相同） |
| `assistant_module.rs` | 两个助手工具的 `ToolModule` 适配层（同上） |
| `terminal.rs` | 开终端跑命令（`wt.exe` → `cmd /K`） |
| `store.rs` | 配置与历史的落盘位置 |

## 这个平台上最容易踩的十个坑

1. **`SetClipboardData` 成功后所有权归系统，绝不能再 `GlobalFree`**。
   只有失败时所有权还在自己手上才要还回去。
2. **`TrackPopupMenu` 前必须 `SetForegroundWindow`**，否则菜单在鼠标点向别处时不会消失 ——
   Win32 上最经典的托盘菜单 bug。
3. **`LPARAM` 里的坐标必须按有符号解**。鼠标拖到窗口左上方时坐标是负数，
   按无符号解会得到 65535 这类天文数字，选区瞬间跑飞。
4. **DIB 的 `biHeight` 要取负**才是自上而下。忘了取负的表现是整张图上下颠倒。
   `GetDIBits` 默认给的则是自下而上，要逐行翻转。
5. **必须先声明 Per-Monitor V2 DPI 感知**（`gdi::prepare()`），且要在任何坐标 / 窗口 API
   之前。不声明的话缩放屏上拿到的是被拉伸的虚拟坐标，截出来是糊的。
6. **`GetWindowRect` 从 Win10 起包含不可见的阴影边距**，直接拿去截图会多一圈背景。
   要用 DWM 的 `DWMWA_EXTENDED_FRAME_BOUNDS`。
7. **虚拟屏幕的原点不一定是 (0,0)**：副屏摆在主屏左边时 `SM_XVIRTUALSCREEN` 是负数。
8. **`OpenClipboard` 之后一定要 `CloseClipboard`**。剪贴板是全局独占的，开着不关会让
   整个系统的复制粘贴都卡住；而且 `GetClipboardData` 的句柄不归我们，
   `CloseClipboard` 之后就作废 —— 必须在关之前把内容拷出来。
9. **`SendInput` 少发一条 `KEYEVENTF_KEYUP`**，那个修饰键就会一直卡在按下状态，
   用户还没法自己解开（他手上那个键本来就没按下去过）。
10. **摆窗口前要把阴影补回去**。第 6 条说的那圈不可见边距在这里是反方向的坑：
    直接拿算好的矩形去 `SetWindowPos`，用户看到的窗口会比预期**小一圈**，
    两个半屏窗口中间还会多一条缝。要拿 `GetWindowRect` 与
    `DWMWA_EXTENDED_FRAME_BOUNDS` 作差，把目标矩形**外扩**这么多。

## 线程模型：一条线程，一个消息循环

Win32 的窗口、菜单、热键消息都绑定在**创建它们的那条线程**上，而我们的动作
（覆盖层、编辑器、贴图）本来就是模态的、一次一个。所以整个 App 就是一条线程 ——
比 Linux 那边（GTK + X11 + DBus 三套事件源）简单得多，也少了一大类跨线程的坑。

代价是执行动作期间消息循环会停住。截图是模态操作，用户本来也不会同时去点托盘。

自定义消息一律排在 `WM_APP` 之后，并且互不撞号（有测试盯着）。

剪贴板监听也搭在这条线程上：`AddClipboardFormatListener` 把 `WM_CLIPBOARDUPDATE`
送到 `clipboard_module` 自建的消息窗口，**连模态操作期间也不会漏** ——
覆盖层、编辑器、面板跑的都是嵌套的消息循环，同一条线程上的消息照样派发。
代价是窗口过程拿不到 `&mut self`，所以读出来的内容先进一个全局队列，
主线程在用 Store 之前 `drain()` 收走。

## 键盘：`WM_KEYDOWN` 与 `WM_CHAR` 各管一段

Windows 把一次按键拆成两条消息，所以**字母键不会像 Linux 那边一样被吃掉**：
`WM_KEYDOWN` 处理命令，`WM_CHAR` 负责打字，而且 `WM_CHAR` 拿到的是
**经过输入法之后**的字符 —— 中文标注在这个平台上是白拿的。

但 `[` / `]` 例外：它们既是调线宽的命令又是能打进文字的字符，所以
`translate_key` 要看「在不在打字」，否则用户打一个 `[` 会顺手把画笔变粗。

## 设置窗口

控件是**运行期按 `SettingsPage` 声明生成**的，不是 `.rc` 对话框资源
（那要在编译期把坐标写死，而设置项会变）。两件必须记得的事：

- **必须显式 `WM_SETFONT`**，取 `SystemParametersInfoW(SPI_GETNONCLIENTMETRICS)` 里的
  `lfMessageFont`。不设的话控件会用上世纪的 System 字体，与整个系统格格不入。
- 快捷键用系统自带的 `msctls_hotkey32`。它**录不了 Win 键组合**（`HOTKEYF_*` 里没有 Win），
  这是控件本身的限制；用户可以直接在配置文件里写 `Super+…`，注册那一层是支持的。

**滚动是自己挪控件的**。三个工具的设置项加起来 700 多像素，早超过一屏
（而 768 高的笔记本扣掉任务栏根本摆不下那么高的窗口），所以窗口封顶 640 +
真的实现了 `WM_VSCROLL`：记下每个控件**设计时的 (x, y)**，滚动时逐个
`SetWindowPos`。

⚠️ `SetWindowPos` 即便带 `SWP_NOSIZE`，**位置也是两个坐标一起生效的** ——
只算 y、x 随手传 0 的话，一滚动所有控件会齐刷刷贴到窗口左边。所以 x 必须一起记。

## 目录

| | 位置 |
|---|---|
| 配置 | `%APPDATA%\Baobox\config.ini` |
| 截图历史 | `%APPDATA%\Baobox\screenshot\` |
| 剪贴板历史 | `%APPDATA%\Baobox\clipboard\`（`clipboard.dat` + `images\`） |
| 截图默认存放 | `%USERPROFILE%\Pictures\Baobox\`，可被设置里的「保存到」覆盖 |

用 `%APPDATA%` 而不是 `%LOCALAPPDATA%`：这些是用户数据，在域账号的漫游配置里跟着走是合理的。

## 改代码前

1. **先问这是不是平台相关的**。不是就放 `../shared/`。
2. 加工具：实现 `ToolModule`，在 `app.rs` 的 `build_registry()` 里注册一行。
3. **动作 id 必须与 Linux 侧逐字一致**（有测试盯着）——
   对不齐的话同一份配置里的快捷键绑定换个系统就失效。
4. 设置项**声明了就必须有人读**，有守卫测试盯着。
5. 提交前至少跑 `cargo check --target x86_64-pc-windows-gnu --all-targets`，
   然后**看 CI 的 Windows 那条**。
