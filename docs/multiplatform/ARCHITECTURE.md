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
│   ├── annotation   标注图形模型、撤销重做、橡皮「点删整笔」
│   ├── stitch       长截屏重叠对齐 + RGBA 合成
│   ├── filename     模板格式化、**按平台**消毒、重名去重
│   └── history      截图历史环形存储
└── baobox-image/    RGBA → PNG、RGBA → 灰度
```

不共用的是平台层：抓屏、窗口枚举、覆盖层窗口、托盘、全局快捷键、通知、剪贴板。
这些在三个系统上的形状差异太大，强行抽象只会得到一个谁都不好用的最小公倍数，
所以 `shared/` 里**没有平台 trait** —— 只有纯函数与纯数据结构，平台层直接调用。

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
| 长截屏拼接 | ✅ Swift | ✅ 共用算法，CLI 已接 | ⬜ 算法已共用，CLI 未接 |
| 标注模型 | ✅ Swift | ✅ 模型已共用 | ✅ 模型已共用 |
| **交互式覆盖层**（悬停高亮 / 拖选 / 八向手柄 / 方向键 / 尺寸标注） | ✅ | ✅ X11 分层窗 | ✅ WS_EX_LAYERED（**未实测**） |
| 标注工具条（画笔 / 箭头 / 马赛克…） | ✅ | ⬜ 模型已共用，UI 未做 | ⬜ 同左 |
| 贴图 / OCR / 录屏 | ✅ | ⬜ | ⬜ |
| 托盘 / 全局快捷键 | ✅ | ⬜ | ⬜ |

三平台的交互规则**共用同一个状态机**（`baobox_core::selection`），所以
「单击截窗口 / 拖拽选区域 / ⏎ 全屏 / esc 取消 / 方向键 ±1、Shift ×10」在哪个系统上都一致，
差别只在怎么把它画出来：

| | 压暗与挖空 | 画法 | 文字 |
|---|---|---|---|
| Linux | 32 位 ARGB visual；没有合成器时**降级为只描边不压暗** | X11 核心绘图 | `image_text8`（不引 Xft） |
| Windows | `WS_EX_LAYERED` + `LWA_COLORKEY \| LWA_ALPHA`，选区涂 color key 即透明 | GDI `FillRect` / `FrameRect` | `TextOutW` |

不带参数直接 `capture` 就进覆盖层，这是默认用法；带 `--full` / `--region` / `--window` 则跳过覆盖层。

### 其余六个工具

尚未开始。按移植难度排序（详见 `docs/distribution/ASSESSMENT.md` 的同类分析）：

| 工具 | 难度 | 关键点 |
|---|---|---|
| Claude Code / Codex 助手 | 🟢 | 纯读本地文件，几乎无平台耦合 |
| 防休眠 | 🟢 | Windows `SetThreadExecutionState`；Linux DBus inhibit |
| 窗口管理 | 🟡 | Win32 `SetWindowPos`；Linux EWMH `_NET_WM_STATE` |
| 键盘点击 | 🟡 | Windows UI Automation；Linux AT-SPI |
| 屏幕取字 | 🟡 | Windows `Windows.Media.Ocr`；Linux 需外部 OCR |
| 剪贴板 | 🟠 | 剪贴板本身好办，但 macOS 的 `org.nspasteboard.*` 隐私标记约定**别处没有对应物**，隐私过滤要重新设计 |

## 怎么构建

```bash
# 跨平台核心（任何系统上都能跑）
cd shared/baobox-core && cargo test

# Linux
cd linux/baobox-linux && cargo build && ./target/debug/baobox-linux info

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
