# Baobox

[![macOS](https://github.com/qiaob/baobox_mac/actions/workflows/build-macos.yml/badge.svg)](https://github.com/qiaob/baobox_mac/actions/workflows/build-macos.yml)
[![Windows](https://github.com/qiaob/baobox_mac/actions/workflows/build-windows.yml/badge.svg)](https://github.com/qiaob/baobox_mac/actions/workflows/build-windows.yml)
[![Linux](https://github.com/qiaob/baobox_mac/actions/workflows/build-linux.yml/badge.svg)](https://github.com/qiaob/baobox_mac/actions/workflows/build-linux.yml)

**菜单栏常驻的 macOS 效率工具集** —— 截图、剪贴板、窗口管理、键盘点击、防休眠、
会议纪要、语音听写、桌面宠物、专注与健康提醒、划词助手，
外加 Claude Code / Codex 两个本地 AI CLI 的仪表盘。一个 App 装下它们，统一入口、
统一快捷键、统一设置。

[English](README.md) · [使用手册](docs/manual/README.md) · [快捷键总览](docs/manual/shortcuts.md)

```
macOS 14+   ·   Swift 5.9   ·   零第三方依赖   ·   数据只存本机
```

## 目录

- [这是什么](#这是什么)
- [工具一览](#工具一览)
- [安装](#安装)
- [首次启动](#首次启动)
- [快捷键](#快捷键)
- [数据与隐私](#数据与隐私)
- [从源码构建](#从源码构建)
- [项目结构](#项目结构)
- [新增一个工具](#新增一个工具)
- [文档](#文档)

## 这是什么

日常要用的小工具本来要装四五个 App：一个截图、一个剪贴板、一个窗口管理……
各自常驻后台、各有一套设置和快捷键。Baobox 把它们做成**一个原生 App 里的多个模块**：

- **原生，不是 Electron** —— Swift 5.9 + SwiftUI/AppKit 混合，**零第三方依赖**，
  常驻内存 ~50 MB 以内
- **模块化** —— App 外壳不认识任何具体工具，每个模块实现统一的 `ToolModule` 协议，
  自行注册菜单、快捷键与设置页
- **数据只在本机** —— 不上传、不收集、没有账号体系

无 Dock 图标（`LSUIElement`），所有入口都在菜单栏。

## 工具一览

| 工具 | 出厂快捷键 | 一句话 |
|---|---|---|
| [截图与录屏](docs/manual/screenshot.md) | ⌘⇧2 · ⌃⇧R | 智能截图、标注、贴图、长截屏、屏幕取字、录屏、屏幕标注画笔、历史 |
| [剪贴板](docs/manual/clipboard.md) | ⌘⇧V · ⌘⌥V | 历史、搜索、回填粘贴、收藏、格式识别与转换、文本片段、落盘加密 |
| [窗口管理](docs/manual/window-manager.md) | ⌃⌥ 系列 | 半屏 / 四分屏 / 最大化 / 居中 / 跨屏，13 个动作 + 布局快照 |
| [键盘点击](docs/manual/keyboard-nav.md) | ⌘⇧空格 | 给可点元素打字母标签，敲字母即点击；另有键盘滚动 |
| [实时翻译](docs/manual/live-translate.md) | 出厂不绑定 | 麦克风 / 系统声音实时转字幕，英中互译，屏幕底部字幕条，可存文字记录；macOS 14 用离线模型兜底 |
| [划词助手](docs/selection-translate/ASSISTANT.md) | 出厂不绑定 | 任意 App 里选中文字弹出动作条：翻译、学习、润色、改写、地道英文、解释、总结 |
| [会议](docs/meeting/REQUIREMENTS.md) | 出厂不绑定 | 下场会议倒计时、一键入会、自动检测会议、本地转录与纪要、行动项跟踪 |
| [语音听写](docs/dictation/REQUIREMENTS.md) | ⌥空格（开始 / 结束） | 按住说 / 连续听写（一句一上屏）/ 长听写，文字直接落在任意 App 的光标处，带历史 |
| [专注与健康](docs/focus-health/REQUIREMENTS.md) | 出厂不绑定 | 专注计时、喝水 / 站立 / 护眼 20-20-20 提醒、宠物陪伴式休息画面 |
| [桌面宠物](docs/desktop-pet/DESIGN.md) | 出厂不绑定 | 桌面上的宠物，同时是 Baobox 统一的通知中心 |
| [防休眠](docs/manual/caffeinate.md) | 纯菜单 | 定时阻止睡眠，可选屏幕常亮 |
| [手机互传](docs/manual/phone-transfer.md) | 出厂不绑定 | 扫码连接，Mac 与手机互传文件和文字；局域网或公网点对点直连，手机不用装 App |
| [Claude Code 助手](docs/manual/claude-code.md) | ⌃⇧空格 | 会话续接、额度用量、审计、通知、配置可视化、statusline、MCP |
| [Codex 助手](docs/manual/codex.md) | 出厂不绑定 | 会话续接、额度用量、配置可视化、完成通知、维护 |

### 框架本身

- 菜单栏常驻，无 Dock 图标；菜单是纯工具列表，每个工具一行，悬停展开二级菜单
- 全局快捷键中心（Carbon）：统一注册、**冲突检测**、自定义、持久化、恢复默认
- 统一设置窗口：通用 / 快捷键 / 每个工具一页 / 关于
- 首次启动权限引导，授权状态实时刷新
- 可选开机自启（`SMAppService`）
- 中文 / English 双语，可跟随系统

### 截图与录屏

一个快捷键自动识别意图：**悬停高亮窗口，单击即截**；**按住拖拽**（超过约 4pt 阈值）
切换为区域截图；**⏎ 全屏**；**Esc 取消**。

- 八向手柄微调、**方向键逐像素移动**（⇧ ×10）、像素放大镜实时给出坐标与色值
- 多显示器每屏独立 overlay
- **菜单也能截进去**：按下快捷键时若屏上有右键菜单或菜单栏下拉，会在本 App 激活、
  菜单收起之前先冻结整屏，截出来的图里菜单还在
- **标注**：矩形 / 椭圆 / 箭头 / 画笔 / 荧光笔 / 马赛克 / 文字 / 橡皮（点删整笔），
  撤销 ⌘Z、重做 ⇧⌘Z、复制并完成 ⏎、保存 ⌥⏎
- **贴图**：钉在所有窗口最上层，可缩放、调透明度、取字、另存；也能从剪贴板贴图
- **长截屏**：框出可滚动区域后自己滚页面，按相邻画面重叠自动对齐拼成长图，
  完成后预览窗可保存 / 复制 / 贴图 / 取字
- **屏幕取字**：系统 Vision **本地**识别（不上传），可选中英日语言组合，
  **结果可就地编辑再复制**，顺带解出画面里的二维码 / 条码
- **录屏**：复用同一套选区，MP4 或 GIF；可录系统声音与麦克风（独立第二音轨，可混为单轨）；
  录制中可暂停 / 继续 / 取消
- **屏幕标注画笔**：在实时画面上圈画，**穿透模式**下笔迹留着、底下的 App 照常操作
- **历史**：默认保留 20 张，随时复制 / 贴图 / 另存 / 删除

### 剪贴板

文本、图片、文件、链接全都记，**⌘⇧V** 唤出面板即输即搜，**⏎ 直接粘回**你刚才那个 App。

- 类型筛选（全部 / 文本 / 链接 / 图片 / 文件 / 收藏）、收藏置顶、纯文本粘贴（⌘⌥V）
- **预览区文本工具**：自动认出 JSON / JWT / XML / 时间戳 / URL / Base64 / curl，
  就地给出格式化、解码、提取、MD5 / SHA、**生成二维码**等动作，一键还原
- **大窗编辑**：等宽字体、撤销、⌘F 查找
- **文本片段**：常用文本存成片段，设关键字后在任何输入框打「前缀+关键字」就地展开
- **隐私**：密码管理器标记的内容默认不记录；临时内容始终忽略；可按 App 忽略；
  可设 1 / 7 / 30 / 90 天自动清理
- **加密**：历史落盘默认 **AES-GCM** 加密，密钥随机 256-bit 存登录钥匙串，不同步 iCloud

### 窗口管理

13 个动作全部可绑定快捷键，出厂绑在 **⌃⌥** 系列上。

> ⚠️ ⌃⌥ 系列与 Rectangle / Magnet 完全同键，两个都装的话请在设置里改掉一边。

- 完整多显示器支持：目标屏取**交集面积最大**者；按各屏**可见区域**分屏（避开菜单栏与 Dock）；
  跨屏移动等比映射并边界裁剪，不同分辨率之间不会变形溢出
- **布局快照**：存下当前所有窗口的位置与尺寸，一键还原；标题优先匹配、顺序兜底，
  未运行的 App 自动跳过；记录每屏稳定 UUID 与屏内相对位置，分辨率或排列变了也对得上
- 窗口间距可调（0 = 紧贴）

### 键盘点击

按 **⌘⇧空格**，屏幕上所有可点元素浮出两字母标签，敲字母即点击。基于辅助功能识别
**真实控件**，优先走 `AXPress`——**不移动你的真实鼠标**。

- **连续点击**：点完自动刷新标签接着点，Esc 或鼠标点击退出
- **标签范围**：仅当前屏 / 所有屏
- **键盘滚动**：j / k 滚动、空格翻页，专治 Chrome 这类不暴露滚动条的页面

### 实时翻译

选**麦克风**或**系统声音**作音源，语音实时转成字幕并**英文 ⇄ 中文**互译，显示在屏幕底部一条
可拖动的半透明字幕条上（双语 / 仅译文 / 仅原文）。识别用系统 Speech 框架（优先本地识别），
翻译用系统自带的本地翻译（macOS 15+），macOS 14 上用可下载的离线模型（Hy-MT2-1.8B）兜底，
14 也能翻译，全程不经第三方服务。会话可以存成**文字记录**，支持朗读。

实时翻译同时是「会议」里自由听译会话的引擎：在会议菜单里开始自由听译，用的就是同一条
字幕条，转录会归档进会议库。

### 划词助手

在**任意 App** 里选中文字，选区上方弹出一排小按钮：**翻译 · 学习 · 润色 · 改写 · 地道英文 · 解释 · 总结**，
还能加自己的动作（名称 + 提示词）。点了哪个才跑哪个；改写类结果在可写的输入框里能**直接替换原文**。
按住 ⌥ 用数字选、「唤出动作条」快捷键加字母纯键盘操作，每个动作也能单独绑直达快捷键。
**学习**按设置里的母语 / 在学的语言（目前中英）给词典卡（音标、美 / 英发音、释义、词形，离线 ECDICT 词典）
或整句学习（点词查义、朗读时逐词标出、跟读打分）。AI 动作走本地 Qwen3 或你配置的云端服务。
取词按可靠性分三档：辅助功能树、借剪贴板兜底、框选 OCR。翻译引擎与实时翻译共用。

### 会议

一个工具、三种会话——**线上会议、线下会议、自由听译**（自由听译就是原来的实时翻译场景）。
菜单顶部显示**下场会议倒计时**，**一键入会**直接打开日历事件里的会议链接（Zoom、腾讯会议、
钉钉、Google Meet、Teams、飞书、Webex）。Baobox 通过 EventKit 只读本机日历（数据不出本机），
还能**自己发现会议**——日历事件开始了，或某个会议 App 正在占用麦克风——就问你要不要记录。

- **会前**：会前简报（上次纪要摘要 + 未完成行动项）、会前提醒、设备自检（试录 3 秒，
  同时看麦克风与系统声音两路电平）
- **会中**：小浮条控制条（● REC + 计时 + 麦克风 / 系统声音电平点，可单独静掉一路、
  暂停、标记重点、速记，速记会后并入纪要），菜单栏常驻录音指示，记录期间专注与健康
  提醒自动顺延
- **会后**：本地转录 → 本地模型生成纪要（摘要、决议、行动项含负责人与截止日期、标记的重点段落），
  存进可搜索的**会议库**，另有跨会议的行动项视图、同系列时间线与会议周报。本地模型没下载时
  只存转录，状态标「仅转录」

会议、自由听译、听写共用一个麦克风，同一时间只能一个在录。

### 语音听写

在任何地方说话，文字直接落在**当前 App 的光标处**，不用切窗口、不用粘贴。三种模式：
**按住说话**（按住开始、松开上屏）、**连续听写**（按一下开始，每说完一句停一下就上屏，可以一直说下去；再按一下或安静 30 秒结束）、
**长听写**（一直识别到手动结束，结果先进收集面板，可编辑再整段插入 / 复制）。优先设备端识别，
默认中英自动判别（连续听写按句判，可以一句中文一句英文），术语表与实时翻译共用。

- **上屏前先整理**：语音指令（「换行」「句号」「删除上一句」）、口头禅过滤、按语言规整标点
- **插入自动降级**：辅助功能直接写入文本框 → 模拟粘贴（借剪贴板快照，**不进剪贴板历史**）→
  没处可输时（如密码框）复制到剪贴板并提示。文字绝不丢：录音条上可一键复制，听写历史里也有
- **历史**：最近的听写记录（只存文本、时间、目标 App，**不存音频**），可搜索、复制、再次插入、删除

### 桌面宠物

猫、狗、兔子或二次元形象住在桌面上，走来走去、你离开久了会趴下睡觉，同时它是 **Baobox
统一的通知中心**：各模块不再各自发系统通知，全部经由宠物以气泡呈现，带按钮可直接操作。
点 Claude Code / Codex 的通知，会直接跳到对应的终端会话。

- **形象**：内置 3 只毛绒 3D 宠物，设置里还能下载更多；支持 VRM 二次元人形，带程序化动作，
  宠物沿屏幕底部走动、可停在窗口边缘。帧图素材包（帧序列 + `pet.json`）同样支持
- **通知**：三档（轻量 / 气泡 / 提醒）、勿扰、去重与聚合。会议提醒、专注与健康提醒、
  AI 任务完成、纪要生成都走这里；宠物关闭时回退到系统通知
- **对本机其他进程开放**：本地进程可通过 Unix socket（`~/Library/Application Support/Baobox/pet.sock`，
  一行一个 JSON）发通知，另有 `baobox-pet` 命令行封装与 `baobox://notify` URL。仅同用户、
  不开网络端口、来源首次投递需你授权；Baobox 不替外部进程执行任何命令，按钮点击只把选择回传回去
- **环形菜单**：点宠物唤出 Baobox 主菜单，右键是宠物菜单（换形象、大小、安静一会儿、通知历史、
  设置），环形菜单里还有其他工具的快捷入口

### 专注与健康

专注计时（番茄钟）与健康提醒是**同一个工具**：专注管工作段，提醒与休息管间歇段。

- **专注计时**：25 / 50 / 90 分钟预置，专注中勿扰，到时宠物宣布并直接衔接休息段，轮次循环
- **提醒项**：喝水（45 分钟）、站立活动（60 分钟）、护眼 20-20-20（20 分钟）、整段休息
  （50 分钟）出厂预置，可自己增删改，按间隔或固定时刻提醒
- **休息画面**：轻松档只发宠物提醒；标准档宠物走到屏幕中央变大、陪你休息，背景变暗并拦截键鼠；
  严格档再把背景模糊掉。宠物关闭时用全屏休息卡片回退
- **懂分寸**：开会、全屏 App、录屏录音时提醒自动顺延；离开电脑够久算自然休息，不会为已经
  休息过的时段再催你；菜单栏显示倒计时

### 防休眠

基于 IOKit 电源管理断言。菜单里选 15 分钟 / 1 小时 / 2 小时 / 无限期，到点自动释放，
菜单实时显示剩余时间。可选连显示器一起防休眠。App 退出必定释放断言。

### Claude Code / Codex 助手

把本地 AI 编程 CLI 的状态收进菜单栏。**纯本地文件解析——不调用任何 AI API、不需要登录。**

- **会话续接**：最近会话一键在终端续接；Spotlight 式搜索面板
  （Claude Code 可 Tab 切到「最近文件」模式，直接打开它最近写过的文件）
- **用量与额度**：5 小时窗口 + 周窗口、今日花费、按天 / 项目 / 模型三维报表、调用统计
- **审计**（Claude Code）：按日列出改过的文件，可在访达中定位
- **通知**：任务完成 / 等待确认时通知，支持提示音与**语音朗读**；额度达 80% 提醒，
  额度重置也可提醒
- **危险命令卫士**（Claude Code）：`rm -rf /`、`sudo rm`、`git push --force`、
  `git reset --hard`、`DROP TABLE`、`mkfs`、`chmod -R 777` 等执行前拦截并把原因反馈给
  Claude；支持自定义正则规则
- **配置可视化**：权限模式 / 默认模型 / 会话保留天数 / 权限规则与预设 / 隐私开关 /
  CLAUDE.md 管理（Claude Code）；审批策略 / 沙箱模式 / 默认模型（Codex）
- **statusline 生成器**（Claude Code）：勾选段位、实时预览、一键应用，覆盖前二次确认
- **MCP**：Claude Code 可增删用户级服务器；Codex 只读列出
- **维护**：磁盘占用统计、清理旧会话、版本检查与复制升级命令

> 所有花费均为按公开定价的**估算值**，界面处处标注「估算」。
>
> **安全改用户文件**：只动自己的键、保留未知字段与注释、写前备份 `.baobox.bak`；
> 遇到无法安全编辑的值就置灰控件，宁可不做也不改坏。

## 安装

### 下载发布版本

在 [Releases](https://github.com/qiaob/baobox_mac/releases) 下载最新的 `.zip`，
解压后把 `Baobox.app` 拖进「应用程序」。首次打开若被 Gatekeeper 拦下，
在「系统设置 → 隐私与安全性」里点「仍要打开」。

### 系统要求

- macOS 14 (Sonoma) 或更新版本
- Apple 芯片与 Intel 均可

## 首次启动

会弹出权限引导，请求两项权限：

| 权限 | 用途 | 不给会怎样 |
|---|---|---|
| **屏幕录制** | 截图、录屏、屏幕取字、屏幕标注 | 这些功能不可用 |
| **辅助功能** | 剪贴板回填粘贴、窗口管理、键盘点击、关键字展开 | 剪贴板降级为仅复制；窗口管理与键盘点击不可用 |

> ⚠️ 系统限制：屏幕录制权限在系统设置里勾选后**必须重启 Baobox** 才生效。
> 引导窗与设置页都提供了一键重启。

跳过也没关系，之后在「设置 → 通用 → 权限」随时补齐。麦克风权限只在真正用到时才请求：
录屏、实时翻译、会议记录或听写。

## 快捷键

出厂已绑定：

| 快捷键 | 动作 |
|---|---|
| ⌘⇧2 | 智能截图 |
| ⌃⇧R | 开始 / 停止录屏 |
| ⌘⇧V | 剪贴板历史面板 |
| ⌘⌥V | 纯文本粘贴上一条 |
| ⌘⇧空格 | 键盘点击 |
| ⌃⇧空格 | Claude Code 快速续接 |
| ⌥空格 | 开始 / 结束听写（连续听写） |
| ⌃⌥ ← → ↑ ↓ / U I J K / ⏎ / C / ⌫ | 窗口管理 13 个动作 |
| ⌃⌥⌘ ← → | 窗口跨显示器移动 |

屏幕取字、屏幕标注、二维码、键盘滚动、Claude Code 中心、最近文件、Codex 两个面板，
会议、桌面宠物、专注与健康、划词助手的全部快捷键，以及听写的按住说话与长听写**出厂不绑定**，按需在
「设置 → 快捷键」自设。完整列表见[快捷键总览](docs/manual/shortcuts.md)。

## 数据与隐私

**所有数据只存在这台 Mac 上，不上传、不收集、没有账号。**

```
~/Library/Application Support/Baobox/<模块>/   # 各模块独立子目录
~/Pictures/Baobox/                             # 截图与录屏默认位置（可改）
```

- 剪贴板历史**默认 AES-GCM 加密**，密钥存登录钥匙串，不同步 iCloud
- 密码管理器标记的内容默认不入库；临时内容始终忽略
- Claude Code / Codex 助手**不存任何数据**，全部实时读 `~/.claude` 与 `~/.codex`
- 会议录音、转录与纪要只存在本机；听写历史只存文本，不存音频
- 桌面宠物供其他本地进程用的 socket 仅限同用户（`0600`），不开网络端口，
  Baobox 不替其他进程执行命令
- 只有你主动点「检查最新版」时才联网（查 npm 版本号）

详见[数据与隐私](docs/manual/privacy-and-data.md)。


## 仓库结构

本仓库同时容纳三个平台的实现：

```
mac/       macOS（Swift + SwiftUI/AppKit）—— 完整的 0.0.7
windows/   Windows（Rust + Win32/GDI）—— 托盘常驻：截图、剪贴板、防休眠、
           窗口管理、两个 AI 助手、键盘点击
linux/     Linux（Rust + X11）—— 托盘常驻：与 Windows 相同的六个工具
shared/    三平台共用的 Rust 核心（几何 / 选区 / 标注 / 拼接 / 文件名）
```

Windows 与 Linux 版本均为托盘常驻 App。Windows 还提供桌面宠物，从托盘的「桌面宠物」菜单开启。
可在同一菜单下载形象，或将自制的形象包放到 `%APPDATA%\Baobox\Pets`，再到设置里选择。
会议、听写、专注与健康、实时翻译与划词助手目前由 macOS 版提供。详见[多平台架构](docs/multiplatform/ARCHITECTURE.md)。

## 从源码构建

工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成，`project.yml` 里
`sources: - Sources` 是全量 glob，新增 `.swift` 文件自动纳入，不用改配置。

```bash
brew install xcodegen
git clone https://github.com/qiaob/baobox_mac.git
cd baobox_mac/mac
xcodegen generate
open Baobox.xcodeproj          # 或 xcodebuild -scheme Baobox build
```

`mac/Baobox.xcodeproj` 不入库，拉取后重新 `xcodegen generate` 即可。
非沙盒 + Hardened Runtime，bundle id `com.baobox.app`。

校验本地化目录是否合法：

```bash
python3 -c "import json;json.load(open('mac/Sources/Resources/Localizable.xcstrings'));print('valid')"
```

## 项目结构

```
mac/Sources/
├── App/                    # BaoboxApp、AppDelegate、StatusItemController
├── Core/                   # 共享基础设施
│   ├── ToolModule.swift        # 工具模块协议（框架核心）
│   ├── ToolRegistry.swift      # 注册表；注册顺序 = 菜单顺序
│   ├── HotkeyCenter.swift      # Carbon 全局快捷键
│   ├── KeyCombo / Permissions / Geometry / L10n / QRCodeGenerator / TextRecognizer …
├── Modules/                # 每个工具一个目录
│   ├── Screenshot/  Clipboard/  WindowManager/  KeyboardNav/
│   ├── Caffeinate/  ClaudeCode/  AITools/  NetCapture/  LiveTranslate/
│   ├── SelectionTranslate/  Meeting/  Dictation/  FocusHealth/  DesktopPet/
├── Settings/               # 设置窗口（通用 / 快捷键 / 各工具 / 关于）
├── Onboarding/             # 首启权限引导
└── Resources/              # Localizable.xcstrings、Assets
```

`NetCapture`（网络抓包）代码在仓库里但**暂缓**：既不编进 App，也不注册（#103）。

## 新增一个工具

框架不认识任何具体工具。加一个模块只要两步：

1. 在 `Sources/Modules/<名字>/` 实现 `ToolModule`：

```swift
@MainActor
final class MyTool: ToolModule {
    let id = "mytool"
    let name = L("mytool.name")
    let symbolName = "wand.and.stars"           // SF Symbol

    func submenuItems() -> [NSMenuItem] { … }   // 二级菜单
    func hotkeys() -> [HotkeyDefinition] { … }  // 可绑定的快捷键
    func settingsTab() -> AnyView { … }         // 设置页
    func activate() { … }                       // 启动时
    func willTerminate() { … }                  // 退出前收尾
}
```

2. 在 `AppDelegate` 里 `registry.register(MyTool())`。

菜单栏入口、二级菜单、设置 Tab、全局快捷键的注册与持久化全部自动接好。

文案一律走 `L("mytool.key")`（AppKit）或 `Text("mytool.key")`（SwiftUI），
并在 `Sources/Resources/Localizable.xcstrings` 补上 en + zh-Hans 两种译文。

详细约定见 [CLAUDE.md](CLAUDE.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [使用手册](docs/manual/README.md) | 每个工具、每项功能的完整说明（[English](docs/manual/en/README.md)） |
| [CLAUDE.md](CLAUDE.md) | 架构速览与代码约定（写代码前必读） |
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) | 全局需求 |
| [docs/TECH_DESIGN.md](docs/TECH_DESIGN.md) | 技术设计 |
| [docs/design/](docs/design/) | UI 设计稿与设计令牌 |
| `docs/<feature>/` | 各特性的需求与技术设计 |

新功能的流程：先在 `docs/<feature>/` 写需求 + 技术设计，再实现，**文档为准**。
