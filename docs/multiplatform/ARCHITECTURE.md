# 多平台架构

仓库从「一个 macOS App」调整为三平台并列。本文说明目录怎么分、什么能共用、什么不能，
以及各平台目前做到哪一步。

## 目录

```
mac/          macOS 实现（Swift + SwiftUI/AppKit）—— 原有代码整体移入，未改一行逻辑
windows/      Windows 实现（Rust + Win32/GDI）
linux/        Linux 实现（Rust + X11）
shared/       三平台共用的 Rust 库
docs/         产品文档与使用手册（面向用户，不分平台）
```

`mac/` 里是完整可用的 0.0.6；`windows/` 与 `linux/` 是新起的实现，当前只覆盖截图。

## 为什么 Windows / Linux 选 Rust

| 候选 | 否决理由 |
|---|---|
| Swift | 官方支持 Windows，但**没有 SwiftUI/AppKit** —— UI 层无论如何都要重写，能复用的只有纯逻辑，抵不上 Swift-on-Windows 生态的坑 |
| C# / .NET | Windows 上最顺，Linux 也能跑；但一套代码要同时照顾 WinUI 与 Avalonia，且团队要多维护一门语言 |
| C++ / Qt | 一套 UI 跨三平台，但 Qt 的商业授权对付费产品是负担，观感也不够原生 |
| Electron / Tauri | 与项目「原生，不是 Electron」的定位直接冲突 |

选 **Rust** 的理由：一套核心同时编译到两个平台、无运行时、体积小、
平台 API 有成熟绑定（`windows-rs` / `x11rb`），且**在 CI 与开发机上都能真正编译与测试**。

## 什么共用，什么不共用

**共用的是逻辑，不是代码行。** macOS 那边是 Swift，Windows/Linux 是 Rust ——
三份实现共享的是**同一套规格与算法**，由 `shared/` 里的 Rust 库和 `docs/` 里的设计文档共同固定。

```
shared/
├── baobox-core/     纯逻辑，零依赖，forbid(unsafe_code)
│   ├── geometry     矩形运算、八向手柄、跨屏等比映射、边界裁剪
│   ├── selection    选区状态机（悬停窗口 / 拖拽区域 / 手柄微调 / 方向键 / Esc）
│   ├── editor       标注编辑器状态机（工具切换 / 落笔 / 文字输入 / 撤销 / 四个出口）
│   ├── annotation   标注图形模型、撤销重做、橡皮「点删整笔」
│   ├── stitch       长截屏重叠对齐 + RGBA 合成
│   ├── toolbar      标注工具条的布局、调色板与命中测试
│   ├── ocr          识别结果 → 阅读顺序（分行、排序、按间距补空格）
│   ├── hotkey       快捷键组合的解析与格式化（三平台同一套文本格式）
│   ├── filename     模板格式化、**按平台**消毒、重名去重
│   ├── config       配置文件模型：行级 INI，改一个键只动那一行
│   └── history      截图历史环形存储 + 索引文件的编解码
├── baobox-app/      应用框架（只有两个 Rust 平台用；mac 那边是同构的 Swift 版）
│   ├── ToolModule   工具接入协议 + ToolRegistry（注册顺序 = 菜单顺序）
│   ├── menu         托盘菜单模型
│   └── settings     设置的**声明**（开关/下拉/输入框/数字/快捷键）
├── baobox-render/   把标注光栅化进 RGBA（三平台逐像素一致）
│   └── chrome       工具条底板、按钮底色与图标（图标也是画出来的，不用图片资源）
└── baobox-image/    RGBA → PNG / 内存 PNG、RGBA → 灰度
```

不共用的是平台层：抓屏、窗口枚举、覆盖层窗口、托盘、全局快捷键、通知、剪贴板。
这些在三个系统上的形状差异太大，强行抽象只会得到一个谁都不好用的最小公倍数，
所以 `shared/` 里**没有平台 trait** —— 只有纯函数与纯数据结构，平台层直接调用。

## App 框架：加一个工具 = 加一个模块

`shared/baobox-app` 是 macOS 侧 `Core/ToolModule.swift` + `ToolRegistry.swift` 的
Rust 对应物，Windows 与 Linux 共用。实现 `ToolModule` 并在平台的 `build_registry()`
里注册一行，**托盘菜单、全局快捷键、设置窗口的那一页就都有了** —— 框架不认识任何具体工具。

| `ToolModule` 的方法 | 框架拿它干什么 |
|---|---|
| `id` / `name` | 配置节名、菜单标题 |
| `menu_items()` | 建托盘菜单。**不许在这里读磁盘** —— 菜单每次弹出都重建 |
| `hotkeys()` | 注册全局快捷键。容易冲突的组合出厂留 `None` |
| `settings_page()` | 设置窗口里的一页 |
| `activate` / `config_changed` / `will_terminate` | 生命周期（关的时候按注册的**倒序**） |
| `perform(action)` | 执行菜单项 / 快捷键 |

### 为什么这里可以有 trait，`baobox-core` 里却不能

`ToolModule` 抽象的是「工具怎么接进 App」，不是「系统怎么干活」——
它每个方法返回的都是平台无关的数据。抓屏、剪贴板那种真正的平台能力，
形状差异太大，仍然没有 trait。

### 设置是声明出来的，界面是原生的

工具**声明**自己有哪些选项，平台层用各自的原生控件渲染：

| | 设置界面 | 快捷键录制 |
|---|---|---|
| Windows | Win32 通用控件，运行期按声明生成（不用 `.rc` 对话框资源 —— 那要编译期写死坐标） | 系统自带的 `msctls_hotkey32`。**录不了 Win 键组合**，是控件本身的限制，可在配置文件里手写 |
| Linux | GTK3 | 自己抓按键；`Esc` 取消、`Backspace` 解绑 |

于是界面是原生外观，而「有哪些设置、叫什么、默认值多少」只有一份定义。
两边都**没有「确定 / 取消」**：改完立刻生效、立刻落盘，与 mac 版一致。

### 托盘

| | 怎么实现 | 需要注意 |
|---|---|---|
| Windows | `Shell_NotifyIconW` + 运行期生成的 `HMENU` | `TrackPopupMenu` 前必须 `SetForegroundWindow`，否则菜单点向别处不消失 |
| Linux | **StatusNotifierItem + com.canonical.dbusmenu**（zbus） | 菜单由桌面渲染，所以外观原生；图标像素自己画，不依赖图标主题 |

Linux 这条路引入了 DBus 依赖（`zbus`），这是**唯一的选择** —— 老的 XEmbed systray
已被 GNOME 移除。而且即便如此，**GNOME 默认仍不显示托盘图标**，用户需要装
AppIndicator 扩展；这是 GNOME 自己的决定，任何 App 都绕不过。所以报到失败时
会明确告诉用户装什么，并说明「程序仍在运行，全局快捷键照常可用」——
不能留下一个「像是没启动」的假象。

### 线程模型

| | |
|---|---|
| Windows | **一条线程一个消息循环**。窗口、菜单、热键消息本来就绑定在创建线程上，而我们的动作是模态的 |
| Linux | 三套事件源各一条：GTK 主循环（跑注册表与设置窗口）、X11 快捷键线程、zbus 线程。之间只传动作 id 字符串 |

Linux 的快捷键线程用 `poll_for_event` + 30ms 轮询而不是阻塞等待 ——
用户在设置里改了快捷键要立刻生效，而阻塞在 `wait_for_event` 上的线程叫不醒。

## 移植时踩到的真实差异

不是「换个 API 名字」那么简单的地方，记录在此：

| 差异 | 说明 |
|---|---|
| **坐标系** | macOS 左下角原点，Windows/X11 左上角原点。`shared` 统一用左上角，mac 侧在边界转换 |
| **文件名规则** | Windows 非法字符多一批（`< > : " \| ? *`），还有 `CON` `PRN` `NUL` `COM1-9` `LPT1-9` **保留设备名**（`CON.txt` 也不行），尾部点与空格会被系统吃掉。所以 `sanitize` 按平台分规则，而不是取最严的交集 —— 否则 Linux/macOS 用户会莫名看到文件名被改 |
| **虚拟屏幕原点** | Windows 上副屏摆在主屏左边时 `SM_XVIRTUALSCREEN` 是**负数**，不能假设左上角是 (0,0) |
| **窗口边界** | Win10 起 `GetWindowRect` 包含不可见的阴影边距，直接截会多一圈背景，必须用 DWM 的 `DWMWA_EXTENDED_FRAME_BOUNDS` |
| **DPI** | Windows 进程必须先声明 Per-Monitor V2，否则在缩放屏上拿到的是被拉伸的虚拟坐标，截出来是糊的 |
| **像素方向** | GDI `GetDIBits` 默认自下而上，要逐行翻转；X11 `GetImage` 是自上而下 |
| **Alpha 不可信** | X11 深度 32 与 GDI 都可能给出 alpha=0，一律强制不透明，否则整张图在预览里透明 |
| **Wayland** | 原生 Wayland 会话下客户端**无权直接抓屏**，必须走 `xdg-desktop-portal` 的 ScreenCast（DBus + PipeWire）。当前实现只覆盖 X11 与 XWayland，并会**提前检测并明确提示**，而不是让用户拿到一张黑图 |

## 当前进度

### 截图

| 能力 | macOS | Linux | Windows |
|---|---|---|---|
| 抓全屏 / 区域 / 窗口 | ✅ | ✅ X11 | ✅ GDI（类型检查通过，**未在真机跑过**） |
| 窗口枚举与标题 | ✅ | ✅ EWMH | ✅ EnumWindows + DWM |
| 选区状态机 | ✅ Swift | ✅ 共用 `baobox-core` | ✅ 共用 `baobox-core` |
| 长截屏 | ✅ Swift | ✅ | ✅ |
| **复制到剪贴板** | ✅ | ✅ X11 selection（**未实测**） | ✅ CF_DIB（**未实测**） |
| 标注模型 + 光栅化 + 工具条布局 | ✅ Swift | ✅ 共用 `baobox-render` / `toolbar` | ✅ 同左 |
| **交互式覆盖层**（悬停高亮 / 拖选 / 八向手柄 / 方向键 / 尺寸标注） | ✅ | ✅ X11 分层窗 | ✅ WS_EX_LAYERED（**未实测**） |
| **标注编辑器窗口**（工具条 / 落笔 / 文字 / 撤销 / 四个出口） | ✅ | ✅ X11 Pixmap（**未实测**） | ✅ DIB section（**未实测**） |
| 贴图窗口 | ✅ | ✅ override-redirect（**未实测**） | ✅ `WM_NCHITTEST`（**未实测**） |
| 屏幕取字（OCR） | ✅ Vision | ✅ 外挂 tesseract | ✅ Windows.Media.Ocr（系统自带） |
| 录屏 | ✅ AVFoundation | ✅ 外挂 ffmpeg x11grab | ✅ 外挂 ffmpeg gdigrab |
| 截图历史（落盘 + 淘汰） | ✅ | ✅ `~/.local/share/baobox/` | ✅ `%APPDATA%\Baobox\` |
| **全局快捷键 + 常驻** | ✅ | ✅ X11 GrabKey（**未实测**） | ✅ RegisterHotKey + 托盘（**未实测**） |
| **托盘图标 + 动态菜单** | ✅ | ✅ SNI/dbusmenu（**未实测**） | ✅ HMENU（**未实测**） |
| **设置窗口** | ✅ SwiftUI | ✅ GTK3（**未实测**） | ✅ Win32 控件（**未实测**） |
| **配置文件** | ✅ | ✅ `~/.config/baobox/config.ini` | ✅ `%APPDATA%\Baobox\config.ini` |

三平台的交互规则**共用同一个状态机**（`baobox_core::selection`），所以
「单击截窗口 / 拖拽选区域 / ⏎ 全屏 / esc 取消 / 方向键 ±1、Shift ×10」在哪个系统上都一致，
差别只在怎么把它画出来：

| | 压暗与挖空 | 画法 | 文字 |
|---|---|---|---|
| Linux | 32 位 ARGB visual；没有合成器时**降级为只描边不压暗** | X11 核心绘图 | `image_text8`（不引 Xft） |
| Windows | `WS_EX_LAYERED` + `LWA_COLORKEY \| LWA_ALPHA`，选区涂 color key 即透明 | GDI `FillRect` / `FrameRect` | `TextOutW` |

不带参数直接 `capture` 就进覆盖层，这是默认用法；带 `--full` / `--region` / `--window` 则跳过覆盖层。

### 全局快捷键

`daemon` 子命令常驻，按快捷键即唤起覆盖层。快捷键文本格式由 `baobox_core::hotkey`
统一（`Ctrl+Shift+S`，修饰键别名 Cmd/Win/Super/Meta 与 Alt/Opt/Option 都认），
所以同一份配置在三个平台上都读得懂。**不带修饰键的组合会被拒绝** ——
那会把该键从所有 App 手里抢走（PrintScreen 例外，它本来就是系统级功能键）。

两个平台各自的坑：

- **X11**：`GrabKey` 匹配**精确的**修饰键掩码。用户开着 NumLock 时事件里多一个 Mod2，
  grab 就不匹配了 —— 表现为「快捷键有时灵有时不灵」，而用户根本想不到是 NumLock 的锅。
  必须把 CapsLock / NumLock / ScrollLock 的**全部 8 种组合**各 grab 一遍。
  另外 grab 要 `.check()` 取回执，否则「已被别的程序占用」会静默失败。
- **Windows**：`RegisterHotKey` 必须带 `MOD_NOREPEAT`，否则按住不放会连续触发；
  托盘菜单弹出前必须 `SetForegroundWindow`，否则点向别处时菜单不消失。

### 标注编辑器：一块像素，既是看到的也是保存的

截完图默认进编辑器（`--no-edit` 跳过）。交互规则全在 `baobox_core::editor`，
两个平台各写各的窗口，规则不会漂：

- 点工具条**永远不落笔**（漏了这条就会「点按钮的同时画一道」）
- 一次拖拽只压**一层**撤销（否则拖完要按几百下 Ctrl+Z）
- 原地点一下不留退化图形；空文字不占撤销栈
- Esc 的两段语义：正在打字时只丢这段文字，否则才退出编辑器
- 四个出口：复制 / 保存 / 贴图 / 取消

**渲染路径只有一条**：合成底图 → 光栅化标注 → 交给平台画文字 → 输出。
屏幕上显示与存进 PNG 走的是同一条，只是导出时不画工具条。分成两套的话，
文字位置迟早会对不上。

| | 缓冲 | 显示 | 导出 |
|---|---|---|---|
| Linux | X11 `Pixmap`，`PutImage` **必须分片**（单请求长度有上限，一整屏 4K 远超） | `CopyArea` 到窗口 | 同一条路径再走一遍，`GetImage` 读回 |
| Windows | DIB section（`biHeight` **取负** = 自上而下），像素指针我们直接持有 | `BitBlt` 到窗口 | 同一块内存直接读，不必 `GetDIBits` |

文字输入两边都能用输入法，但走的是不同的路：

| | 怎么拿到组合好的文本 |
|---|---|
| Windows | `WM_CHAR` —— 系统把按键拆成 `WM_KEYDOWN` + `WM_CHAR`，后者已经过输入法 |
| Linux | 文字工具**弹一个 GTK 输入框**，借 GTK 已有的 im-module（fcitx / ibus）支持 |

Linux 之所以不自己收键盘：X11 只给键码，中文要经过输入法组合，而输入法只跟
参与了输入法协议的应用打交道。剩下两条路是 XIM（libX11 的 C 接口，协议老旧、
**与键盘 grab 冲突**）或者借工具包 —— 而 GTK 本来就为设置窗口引进来了
（`libX11` 也因此早就链上了），借它不多一份依赖，还顺带白拿了候选窗定位、
选中、粘贴、方向键移光标。

**弹输入框前必须松开键盘 grab**：不松开的话输入法一个按键都收不到，
现象和根本没接输入法一模一样。

### 屏幕取字与录屏：系统给不给，差别很大

| | 屏幕取字 | 录屏 |
|---|---|---|
| macOS | Vision，系统自带 | AVFoundation，系统自带 |
| Windows | `Windows.Media.Ocr`，**系统自带**，语言跟随系统首选语言 | 外挂 ffmpeg `gdigrab` |
| Linux | 外挂 tesseract | 外挂 ffmpeg `x11grab` |

Linux 之所以外挂，是因为**发行版里没有系统级 OCR**，而自带识别引擎要么引入
一串 C 依赖，要么把几十 MB 模型塞进截图工具里，语言包最后还是要用户自己下 ——
绕一圈还是「让用户装东西」。录屏同理：自己编码要引 x264/libvpx（GPL 与专利各一堆）。
**没装时给一句能直接照做的安装命令**，与 macOS 侧「未安装即降级」是同一条约定。

两个刻意的细节：

- 取字**不用**各引擎自带的 `Text()` / 排好版的纯文本，而是只取「词 + 位置」，
  交给 `baobox_core::ocr::assemble` 拼 —— 否则同一张图会复制出三种排版。
  tesseract 因此要 TSV 输出而不是纯文本。
- 录屏参数里 `-video_size` 必须是**偶数**（H.264 的 4:2:0 不接受奇数宽高，
  而用户框出 801×601 是常事），`-pix_fmt yuv420p` 必须显式给（默认的 yuv444p
  很多播放器与浏览器放不了）。停止要往 stdin 写 `q` 让 ffmpeg 自己写文件尾，
  直接杀进程会留下没有 moov box 的 mp4。

### 剪贴板：两个平台是完全不同的模型

| | 模型 | 后果 |
|---|---|---|
| Windows | 数据交给系统托管（`CF_DIB`） | 复制完进程可以直接退出 |
| X11 | **数据一直留在源进程里**，你只是"所有者"，别人粘贴时向你要 | **进程退出剪贴板就空了** —— `xclip` 的 `-loops` 参数就是为这个存在的 |

所以 Linux 侧复制完会继续服务 60 秒（常驻模式下一直服务），期间可以粘贴；
到点或别的程序接管所有权就退出。这不是偷懒，是 X11 的剪贴板就长这样。

图给的是 `image/png`（GIMP / Firefox / LibreOffice / 聊天软件都认）；
Windows 给 `CF_DIB` 而不是带 alpha 的 `CF_DIBV5` —— 后者各程序对 alpha 的处理不一，
截图本来就不透明，为此冒兼容性风险不值。屏幕取字复制的是文字：
X11 侧答 `UTF8_STRING` / `TEXT` / `STRING`，Windows 侧用 `CF_UNICODETEXT`
（不用 `CF_TEXT` —— 那是 ANSI 代码页，中文在非中文系统上会变问号）。

Windows 还有一条**所有权规则**：`SetClipboardData` 成功之后内存归系统，
**绝不能再 `GlobalFree`**；只有失败时所有权还在自己手上才要还回去。

### 标注：为什么自己光栅化

标注是**截图的一部分**，同一份标注在三个平台上必须长得一样。交给各平台的绘图 API
（Core Graphics / GDI / Xlib）去画，线宽、端点、抗锯齿的差异会让结果明显不同。
`baobox-render` 自己光栅化，输出逐像素一致，并有 11 条测试固定行为
（矩形是空心的、荧光笔半透明而画笔不透明、马赛克把棋盘压成均匀灰、越界不 panic…）。

工具条的**图标**也是画出来的（`baobox_render::chrome`），不是图片资源：
换成图片要维护三套不同 DPI 的资源，换成系统图标库（SF Symbols / Segoe Fluent）
在 Linux 上根本没有对应物，而这些图标本来就全是直线、方框和椭圆。
有一条测试盯着「每个图标都画出了东西，且一个像素都没溢出按钮」。

**文字是唯一的例外**：字形栅格化要字体引擎，自带一份既臃肿又覆盖不了中文。
`render()` 把文字连同位置和颜色交回给平台层，用系统 API 画上去
（`TextOutW` / X11 核心字体 / Core Text）。X11 侧用 `poly_text8` / `poly_text16`
而不是 `image_text8` —— 后者会用背景色刷一遍文字盒子，把下面的截图盖掉。

### 其余五个工具

尚未开始（屏幕取字与录屏已随截图一起做完，不在此列）。按移植难度排序（详见 `docs/distribution/ASSESSMENT.md` 的同类分析）：

| 工具 | 难度 | 关键点 |
|---|---|---|
| Claude Code / Codex 助手 | 🟢 | 纯读本地文件，几乎无平台耦合 |
| 防休眠 | 🟢 | Windows `SetThreadExecutionState`；Linux DBus inhibit |
| 窗口管理 | 🟡 | Win32 `SetWindowPos`；Linux EWMH `_NET_WM_STATE` |
| 键盘点击 | 🟡 | Windows UI Automation；Linux AT-SPI |
| 剪贴板 | 🟠 | 剪贴板本身好办，但 macOS 的 `org.nspasteboard.*` 隐私标记约定**别处没有对应物**，隐私过滤要重新设计 |

## 怎么构建

```bash
# 跨平台核心（任何系统上都能跑）
cd shared/baobox-core && cargo test

# Linux（设置窗口用 GTK3，要装开发包）
sudo apt install libgtk-3-dev pkg-config    # Debian/Ubuntu
cd linux/baobox-linux && cargo build
./target/debug/baobox-linux                 # 常驻：托盘 + 快捷键 + 设置
./target/debug/baobox-linux info            # 环境诊断
./target/debug/baobox-linux daemon          # 常驻，按 Ctrl+Shift+S 截图
./target/debug/baobox-linux ocr             # 屏幕取字（需 tesseract）
./target/debug/baobox-linux record          # 录屏（需 ffmpeg）
./target/debug/baobox-linux history         # 最近的截图

# Windows（在 Windows 上）
cd windows/baobox-windows && cargo build --release

# Windows 代码在非 Windows 机器上做类型检查
rustup target add x86_64-pc-windows-gnu
cd windows/baobox-windows && cargo check --target x86_64-pc-windows-gnu

# macOS
cd mac && xcodegen generate && xcodebuild -scheme Baobox build
```

## 约定

1. **新逻辑先问一句：这是平台相关的吗？** 不是就放 `shared/`，让三边共用一份实现与一份测试。
2. `shared/` 里**不引入平台依赖**，也不写 `unsafe`（两个 crate 都开了 `forbid(unsafe_code)`）。
3. 平台层只做三件事：拿到像素、拿到窗口信息、把结果交出去。业务判断留在 `shared/`。
4. 行为差异**必须在文档里写明**（如上表），不能让用户自己去发现。
5. 平台模块里**只有真正碰系统 API 的部分加 `cfg(windows)`**。纯计算（ffmpeg 参数拼装、
   像素通道换算、尺寸检查）放在门外面，它们的测试才能在开发机上跑到 ——
   而那恰恰是最容易写错、又最难在真机上发现的部分。
6. 加工具：实现 `ToolModule`，在平台的 `build_registry()` 里注册一行。
   **不要动框架** —— 要动框架才能加工具，说明抽象漏了东西，那才是该改的地方。

## 构建工作流

三个平台各一条，手动触发或推到 `main` / `claude/**` 时自动跑，产物可直接下载：

| 工作流 | 跑什么 | 产物 |
|---|---|---|
| `build-macos.yml` | XcodeGen + Release 构建（ad-hoc 签名） | `Baobox-macos.zip` |
| `build-windows.yml` | `cargo test` + Release 构建 | `baobox-windows.exe` |
| `build-linux.yml` | 共享 crate 测试 + `cargo test`（`dbus-run-session` + `xvfb-run`）+ Release 构建 | `baobox-linux` |

Windows 那条最有价值：覆盖层、编辑器、托盘、设置窗口的测试都带 `cfg(windows)`，
在开发机上只能类型检查，**只有在真 Windows 上才真正跑得起来**。

警告用 `cargo rustc -- -D warnings` 卡，不用 `RUSTFLAGS` —— 后者会一并作用到
所有第三方依赖，别人代码里的一个 warning 就能把流水线弄红。
