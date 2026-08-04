# CLAUDE.md — Linux 实现

给在 `linux/` 下干活的会话。**先读仓库根目录的 `CLAUDE.md`**（产品全貌与三平台约定），
再读这一页。跨平台的共享逻辑在 `../shared/`，架构取舍在 `../docs/multiplatform/ARCHITECTURE.md`。

## 这是什么

`linux/baobox-linux/` —— 一个 Rust 二进制。不带参数就是**常驻 App**（托盘 + 全局快捷键 +
设置窗口）；带子命令则是一次性的命令行工具。目前实现了**截图**、**剪贴板**、**防休眠**、**窗口管理**、
**Claude Code 助手**、**Codex 助手**六个工具。

```
baobox-linux                    常驻：托盘 + 快捷键 + 设置
baobox-linux capture [...]      截图（默认进标注编辑器）
baobox-linux ocr / record       屏幕取字 / 录屏
baobox-linux scroll / history / windows / info
```

## 构建（**要装系统开发包**）

```bash
sudo apt install libgtk-3-dev pkg-config          # Debian/Ubuntu
cargo build && cargo test
cargo rustc --release -- -D warnings              # CI 用这个卡警告
```

跑覆盖托盘的那条测试要一根真的会话总线：

```bash
dbus-run-session -- xvfb-run -a cargo test
```

没有会话总线时那条测试会**自己跳过**（不算失败，但也就白测了）。

## 文件地图

| 文件 | 干什么 |
|---|---|
| `main.rs` | 命令行入口与参数解析；`default_path` / `now_seconds` 这些被别处共用 |
| `app.rs` | **常驻 App 的装配**：注册表 + 托盘 + 快捷键 + 设置窗口。加工具改 `build_registry()` |
| `screenshot_module.rs` | 截图工具的 `ToolModule` 适配层（不含截图逻辑） |
| `x11capture.rs` | 抓屏与窗口枚举 |
| `overlay.rs` | 截图覆盖层（选区） |
| `editor.rs` | 标注编辑器窗口 |
| `text.rs` | 用 X11 核心字体把标注文字画上去 |
| `text_input.rs` | 文字工具的输入框（借 GTK 的输入法栈，中文靠它） |
| `pin.rs` | 贴图窗口 |
| `tray.rs` | StatusNotifierItem + dbusmenu |
| `settings_window.rs` | GTK3 设置窗口 |
| `hotkeys.rs` | 多快捷键中心 |
| `clipboard.rs` | X11 selection 剪贴板（写） |
| `clipboard_read.rs` | 监听剪贴板变化并读回内容（XFIXES + INCR 分片） |
| `clipboard_panel.rs` | 剪贴板面板（两层：条目 / 文本工具） |
| `clipboard_store.rs` | 剪贴板历史落盘 + Secret Service 加密 |
| `clipboard_module.rs` | 剪贴板工具的 `ToolModule` 适配层 |
| `paste.rs` | 回填粘贴（XTEST 合成 Ctrl+V） |
| `ocr.rs` / `record.rs` | 外挂 tesseract / ffmpeg |
| `caffeinate.rs` | 防休眠：login1 + 屏保两家 DBus inhibit |
| `caffeinate_module.rs` | 防休眠工具的 `ToolModule` 适配层 |
| `windowmanager.rs` | 窗口管理：EWMH（活动窗口 / strut / 摆放） |
| `windowmanager_module.rs` | 窗口管理的 `ToolModule` 适配层 |
| `assistant.rs` | AI 助手：找日志、扫目录（与 Windows 逐字相同） |
| `assistant_module.rs` | 两个助手工具的 `ToolModule` 适配层（同上） |
| `terminal.rs` | 开终端跑命令（一张候选表挨个试） |
| `store.rs` | 配置与历史的落盘位置 |

## 这个平台上最容易踩的十一个坑

1. **X11 剪贴板要本进程持续应答**。`serve` 是阻塞的 —— 常驻模式下**必须**用
   `serve_detached`，否则复制一次界面冻 60 秒。命令行下用阻塞版才对（进程本来就要退出）。
2. **`GrabKey` 匹配精确的修饰键掩码**。开着 NumLock 时事件里多一个 Mod2，
   快捷键就不匹配了。每个组合要把 CapsLock/NumLock/ScrollLock 的 **8 种组合**都 grab 一遍，
   反查时先把这些位抹掉。
3. **`PutImage` 单请求有长度上限**。一整屏 4K 图像远超 `maximum_request_length`，
   必须按行分片，否则直接被服务器拒。
4. **`image_text8` 会用背景色刷一遍文字盒子**，把下面的截图盖掉。要用
   `poly_text8` / `poly_text16`（参数得按协议手工编码）。
5. **覆盖层必须先销毁再抓屏**，而且要 `sync()` 等服务器处理完，否则把自己截进去。
6. **深度 32 的 alpha 不可信**，很多合成器留的是 0。一律强制不透明，
   否则截出来的图在预览里整张透明。
7. **弹 GTK 输入框前必须 ungrab 键盘**。编辑器抓着键盘，不松开的话输入法
   一个按键都收不到 —— 现象和根本没接输入法一模一样，极难查。
8. **合成按键时修饰键要按下去、也要抬起来**（`paste.rs`）。只按不抬的话，
   用户接下来打的每个字都带着 Ctrl，而他手上那个键本来就没按下去过，自己解不开。
9. **回填粘贴的三步顺序不能错**：先关面板（否则 Ctrl+V 打到自己身上）→
   等焦点回位（`FOCUS_SETTLE`）→ 放剪贴板 → 合成按键。
10. **摆窗口要发 `_NET_MOVERESIZE_WINDOW`，不能直接 `ConfigureWindow`**。
    直接改是绕过窗口管理器的，WM 记的位置还是旧的，它下次自己重排就把窗口弹回去。
    而且那条消息里的坐标指的是**客户区**，要减掉 `_NET_FRAME_EXTENTS`。
11. **`_NET_WORKAREA` 在多屏下不能用**。它给的是整个桌面的一块矩形（所有屏的并集），
    拿它当「这块屏的可用区域」，副屏上的窗口会被摆到主屏去。要逐屏减 strut，
    而且只减**真的压在这块屏上**的（看 `_NET_WM_STRUT_PARTIAL` 的沿边起止）。

## 线程模型

```
主线程      GTK 主循环：跑注册表、执行动作、刷新托盘、开设置窗口
快捷键线程  自己一条 X11 连接，poll + 30ms 轮询（要能被「配置变了」叫醒）
zbus 线程   zbus 自己起的，应答桌面对托盘/菜单的调用
剪贴板线程  每次复制起一条，持有 selection 直到别人接管
剪贴板监听  自己一条 X11 连接，只做「读出来 → 塞进队列」，不碰 Store
```

剪贴板监听为什么不碰 Store：Store 归主线程，跨线程共享就得为它上锁，
而上锁之后主线程画面板时会被监听线程卡住。队列里只放已经读出来的内容，
主线程每次要用 Store 之前 `drain()` 一次。

**注册表留在主线程** —— 工具不是 `Send`，而且动作本来就是模态的、一次一个。
三条线之间只传 `String` 形式的动作 id。

快捷键线程用 `poll_for_event` + 睡眠而不是阻塞等待：用户在设置里改了快捷键要立刻生效，
而阻塞在 `wait_for_event` 上的线程叫不醒。

## 桌面环境的真实差异（会决定用户看不看得到东西）

- **托盘**：KDE / XFCE / Cinnamon 开箱可用；**GNOME 默认不显示**，用户要装
  AppIndicator 扩展。这是 GNOME 自己的决定，绕不过。报到失败时必须说清楚要装什么，
  并声明「程序仍在运行，快捷键照常可用」——不能留下一个「像是没启动」的假象。
- **Wayland**：原生 Wayland 会话下客户端无权直接抓屏，只能拿到 XWayland 的内容。
  `is_wayland_session()` 提前检测并明确提示，不给用户黑图。

## 外部依赖：未安装即降级

`tesseract`（取字）与 `ffmpeg`（录屏）都是外挂的。没装时：

- 菜单里显示一条**置灰的**引导，而不是让菜单项消失（消失了用户会以为程序坏了）
- 错误信息要给**能直接照做的安装命令**，按发行版分别列出

这与 macOS 侧「未安装即降级」是同一条约定（根 `CLAUDE.md` 约定 7）。

## 目录

| | 位置 |
|---|---|
| 配置 | `$XDG_CONFIG_HOME/baobox/config.ini`，默认 `~/.config/baobox/` |
| 截图历史 | `$XDG_DATA_HOME/baobox/screenshot/`，默认 `~/.local/share/baobox/` |
| 剪贴板历史 | `$XDG_DATA_HOME/baobox/clipboard/`（`clipboard.dat` + `images/`） |
| 截图默认存放 | `~/Pictures/Baobox/`，可被设置里的「保存到」覆盖 |

配置与数据分开放，符合 XDG 的习惯 —— 配置是用户会手编、会备份的东西。

## 改代码前

1. **先问这是不是平台相关的**。不是就放 `../shared/`，让三边共用一份实现与测试。
2. 加工具：实现 `ToolModule`，在 `app.rs` 的 `build_registry()` 里注册一行。
   要动框架才能加工具，说明抽象漏了东西，那才是该改的地方。
3. 设置项**声明了就必须有人读**。有一条守卫测试盯着这件事
   （`every_declared_setting_is_actually_read_somewhere`）——
   声明了没人读的选项，用户改了什么都不会发生，比不给这个选项更糟。
4. 提交前跑 `cargo rustc --release -- -D warnings`，CI 是这么卡的。
