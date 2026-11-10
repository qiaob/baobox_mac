# CLAUDE.md — Baobox 项目速览

给未来的 Claude / Codex 会话：**读这一页即可掌握项目，无需全量扫描**。深入某模块时再读对应源码与 `docs/`。

## 这是什么

**Baobox** —— macOS 菜单栏常驻的「效率工具集合」App（对标 CleanShot X + Paste，再加一组开发者工具）。一个 App 内置多个工具，统一入口 / 快捷键 / 设置。无 Dock 图标（`LSUIElement`），**非沙盒 + Hardened Runtime**，bundle id `com.baobox.app`。

- 技术栈：**Swift 5.9 · SwiftUI + AppKit 混合 · macOS 14+ · 零第三方依赖**（例外三个：网络抓包模块调用系统自带 `/usr/bin/openssl` 子进程签证书（该模块暂缓、不编译，#103）；离线翻译把 llama.cpp 官方预编译的 `llama-server` 作为子进程打进 App 包 —— `make vendor` 按固定构建号 + SHA-256 下载、不进 git，模型文件由用户在 App 里单独下载，见 `docs/translation-engine/DESIGN.md`；朗读译文的「Baobox 同传」虚拟麦克风是 BlackHole（GPL-3.0）源码改名编译的音频驱动 —— `make vendor` 按固定版本 + SHA-256 下载源码编译、打进 App 包，用户在设置里点安装才装进系统，见 `docs/live-translate-voice/DESIGN.md`）。
- 工程用 **XcodeGen** 生成（见 `mac/project.yml`，`sources: - Sources`（相对 mac/） 全量 glob，新增 `.swift` 文件自动纳入，无需改 project.yml）。

## 构建与验证（重要）

- **本仓库在 Linux 开发环境，无法本地编译 macOS 部分**；三个平台各有一条构建工作流（`.github/workflows/build-{macos,windows,linux}.yml`），手动触发或推到 `main` / `claude/**` 时自动跑，产物可直接下载。Windows 与 Linux 的 Rust 代码在本机就能编译与测试。改代码务必**保守**：只用项目里已出现的 API 与 Apple 稳定公开 API，不引入新框架、不用 Swift Charts / Observation 宏。
- Mac 上构建：`brew install xcodegen && xcodegen generate && open Baobox.xcodeproj`（或 `xcodebuild -scheme Baobox build`）。
- Mac 有单元测试 target `BaoboxTests`：纯逻辑测试，只编 `mac/Tests/` 与被测的共用源码（目前是 `Sources/Core/CLIUsage/`），不链接、不启动 App。在 `mac/` 下 `xcodegen generate && xcodebuild -scheme Baobox test` 就能跑（或在 Xcode 里 ⌘U）；macOS 构建工作流每次也跑。
- Rust（`shared/`、`windows/`、`linux/`）：CI 卡 `cargo fmt --check` 和 `cargo clippy --all-targets -- -D warnings`，工具链固定 **1.90.0**（#115，升级时改两个工作流里的版本、顺手修掉新冒出来的警告）。
  本机：`cargo +1.90.0 fmt`、`cargo +1.90.0 clippy --all-targets`；Windows 的 crate 在 Mac 上加 `--target x86_64-pc-windows-gnu` 检查；
  Linux 的 crate 依赖 GTK，在 Mac 上用 Docker（`rust:1.90-bookworm` 里装 `libgtk-3-dev pkg-config`）。测试里的常量断言写成 `const { assert!(…) }`（clippy 不许运行期 `assert!(常量)`）。
- 无法编译时的自查：① 只引用真实存在的类型/方法（先 grep 确认签名）；② 每个 `L()` / `Text()` 的 key 都已入 `Localizable.xcstrings`（可跑下方脚本校验）；③ 所有 `@Published` 只在主线程写；④ `Process` / `NWConnection` / `URLSession` 不在主线程同步等待。

## 仓库结构（2026-08 起三平台并列）

```
mac/       macOS 实现（Swift + SwiftUI/AppKit）—— 下文说的一切都在这里
windows/   Windows 实现（Rust + Win32/GDI）—— 常驻 App：截图 + 剪贴板 + 防休眠 + 窗口管理 + AI 助手 + 键盘点击 + 桌面宠物
linux/     Linux 实现（Rust + X11）—— 常驻 App：截图 + 剪贴板 + 防休眠 + 窗口管理 + AI 助手 + 键盘点击
shared/    三平台共用的 Rust 库：baobox-core（纯逻辑）、baobox-image（PNG/灰度）
docs/      产品文档与使用手册
```

**改 macOS 代码请进 `mac/`**；跨平台的纯逻辑（几何、选区状态机、标注模型、长截屏拼接、
文件名规则、剪贴板历史、敏感内容识别、文本格式识别、窗口布局几何、AI 用量与会话日志）放 `shared/baobox-core`，三边共用一份实现与测试。详见
`docs/multiplatform/ARCHITECTURE.md`。

## 架构（框架先行，加工具 = 加模块）

```
BaoboxApp(@main, Settings scene)
└─ AppDelegate                      # Sources/App/AppDelegate.swift —— 注册所有模块 + 主菜单
   ├─ ToolRegistry                  # 模块注册表；registry.register(...) 的顺序 = 菜单顺序
   ├─ StatusItemController          # Sources/App/ —— 菜单栏 NSStatusItem，menuNeedsUpdate 重建菜单
   └─ OnboardingController          # 首启权限引导（屏幕录制 / 辅助功能）
```

核心协议 **`ToolModule`**（`mac/Sources/Core/ToolModule.swift`）：每个工具实现 `id / name / symbolName / submenuItems() / hotkeys() / settingsTab() / activate() / willTerminate()`（可选 `aiFeatures()`：用到模型的功能，进「AI」页的功能表；可选 `presentationRoles()`：替框架承担的呈现角色，目前只有桌面宠物交出通知呈现端、浮窗挂靠点（`AccessoryHost`：会议控制条经 `AccessoryDock` 挂到宠物头顶）与休息画面主角（`BreakCompanion`：专注与健康借它走到屏幕中央陪你休息，只发意图、姿态归宠物），`ToolRegistry.activateAll()` 在任何模块 `activate()` 之前装进 `Core/Presentation/` 的 `PresentationHub`、之后只读，见 `docs/notify-core/DESIGN.md` §3.3），向 `ToolRegistry` 注册即接入菜单栏、二级菜单、设置 Tab、全局快捷键。**框架不认识具体工具**。

共享基础设施（`mac/Sources/Core/`）：`HotkeyCenter`（Carbon 全局快捷键，单例转发 C 回调）、`KeyCombo`、`Permissions`（屏幕录制 / 辅助功能）、`Geometry`（CG↔AK 坐标系转换，最易错点）、`ClosureMenuItem`（带 hotkeyID 的菜单项）、`TappableDisclosure`、`L10n`（本地化）、`TerminalAppPreference`、`PasteboardBorrow`（借剪贴板取一次文字再还原，剪贴板历史据此跳过；`paste(_:)` 借剪贴板 ⌘V 插入文字）、`TextInserter`（把文字插入前台 App 的焦点：AX → 粘贴 → 复制，听写用）、`AudioCaptureCoordinator`（录音类功能互斥登记：会议 / 实时翻译 / 听写同一时刻只有一个在用语音识别）、`Notify/`（**通知内核**：所有模块投递通知（`NotifyCenter.shared.post`）、挂勿扰（`NotifyDND`）的入口；宠物开着由宠物气泡呈现，关着回退系统通知；设置在 `NotifySettings`，见 `docs/notify-core/DESIGN.md`）、`Translation/`（两个翻译模块共用：语言表 + 语种检测、引擎解析、离线模型下载与 `llama-server` 进程管理、设置区块）、`AI/`（**AI 服务层**：用到模型的地方都从 `AIService` 进；「AI」页接入多个服务商、每个服务商挂多个起了名字的模型（`AIModelStore`），每个功能单独选模型（模块用 `aiFeatures()` 声明，同 `hotkeys()` 之于快捷键页）；本地转调 `OfflineTranslator`，云端 = Claude / OpenAI 兼容，Key 在钥匙串，出错自动退回本地，见 `docs/ai-service/DESIGN.md`）。设置窗口在 `mac/Sources/Settings/`（含「AI」页）。

## 模块清单（`mac/Sources/Modules/<名>/`，菜单顺序 = 注册顺序）

| 模块 | id | 说明 |
|---|---|---|
| Screenshot | `screenshot` | 智能截图（窗口/区域/全屏）、标注、贴图、**长截屏（滚动拼接）**、**屏幕取字 OCR**、录屏、历史。ScreenCaptureKit；截图与取字每次先冻结整屏（按快捷键那一刻定格，菜单开着也截得到），见 `docs/scrolling-capture/`、`docs/screenshot-ocr/`、`docs/screen-draw/` |
| ScreenDraw | `screendraw` | **屏幕标注画笔**：直接在屏幕上圈画（绘制 / 穿透两态），讲解演示用。模块壳 `ScreenDrawTool` 在 `Modules/Screenshot/`（共用标注引擎），快捷键 id 沿用 `screenshot.draw`。`docs/screen-draw/DESIGN.md` |
| Clipboard | `clipboard` | 剪贴板历史、搜索、回填粘贴、收藏、隐私过滤（敏感内容开关）、落盘加密（AES-GCM + Keychain，见 `ClipboardCrypto`）、**预览区文本工具**（JWT/JSON/XML/时间/URL/Base64 识别 + 转换动作 + 二维码，见 `TextTools/`，`docs/clipboard-text-tools/`）、**文本片段**（= 手工创建的收藏条目 + 关键字展开，见 `SnippetExpander`，`docs/snippets/`） |
| Caffeinate | `caffeinate` | 防休眠（IOPMAssertion），定时 |
| FocusHealth | `focushealth` | **专注与健康**：专注计时（番茄钟，专注中勿扰）+ 健康提醒（喝水 / 站立 / 护眼 / 整段休息，可增删改）。提醒经桌面宠物呈现；强提醒 = 宠物走到屏幕中央变大陪你休息（轻松 / 标准 / 严格三档，标准起变暗并拦截键鼠），宠物关闭时回退全屏画面。避让开会（麦克风占用）/ 全屏 / 录屏，离开电脑算自然休息。**专注历史**（`history.jsonl` 只追加、留 400 天；设置页顶部「今天 · 本周 · 连续天数」、菜单一行「今天专注 N 分钟」，`docs/focus-health/HISTORY.md`）。`docs/focus-health/` |
| WindowManager | `windowmanager` | 窗口贴边/四分屏/居中/跨屏、布局快照（AX 权限，多显示器） |
| MenuBarManager | `menubar` | **菜单栏管理**：设置里给每个菜单栏图标选显示 / 隐藏（看不见的占位项 + 模拟 ⌘ 拖，用户不碰分隔线），隐藏的与此刻被挤掉 / 被刘海挡住的放在 Baobox 主菜单最上面一行（`ToolModule.statusMenuHeaderItems`），点一下 = 让它回到屏上再点；Baobox 图标一键挪到最右，Baobox 自己的临时图标排在它右边（`StatusItemController.makeCompanionItem`）。默认关。`docs/menubar-manager/` |
| ClaudeCode | `claudecode` | Claude Code CLI 助手：会话续接、**最近文件**（面板文件模式，会话写过的文件按类别用偏好 App 打开）、用量/额度（5h + **周窗口**）、报表、审计、hooks、配置可视化、statusline、MCP 面板。纯本地文件，`docs/claude-code-assistant/` |
| AITools | `aitools` | **Codex 助手**（Cursor 已移除）：会话续接、用量/报表（5h+周）、中心窗口、配置可视化、完成通知、维护。`docs/codex-assistant/DESIGN.md` |
| KeyboardNav | `keyboardnav` | 键盘点击：给可点元素打字母标签、连续点击、键盘滚动（AX 权限）。`docs/manual/keyboard-nav.md` |
| Meeting | `meeting` | **会议**（#42）：线上会议（麦克风 + 系统声音混成一路进一个识别器，按两路音量标「我 / 对方」）/ 线下会议（仅麦克风）/ 自由听译（= 实时翻译）；控制条（暂停、🔖 标记、速记、字幕、结束）、菜单栏录音指示 / 下一场倒计时、`meeting` 勿扰、本地纪要模板（默认 / 站会 / 1:1 / 面试）与行动项、会议库（`Application Support/Baobox/Meetings/`，旧实时翻译记录按引用迁入）。日历（EventKit，设置里打开才申请权限）、会前提醒、一键入会、会议检测（会议 App + 麦克风占用 / 日历会议已开始）、会议库窗口（搜索、行动项、会前简报、系列时间线、周报）、设备自检。引擎就是实时翻译的 `LiveTranslateController.start(config:)`。`docs/meeting/` |
| LiveTranslate | `livetranslate` | **实时翻译 / 字幕与同传**（独立入口已删，#106：不再注册成工具，菜单项「开始自由听译」、设置、`livetranslate.toggle` 快捷键都在「会议」里；这里是会议的引擎层）：麦克风 / 系统声音（SCK 只采音频）→ 识别（macOS 26 用 SpeechAnalyzer，否则 SFSpeechRecognizer 分段，自动回退）→ 翻译（macOS 15+ 系统翻译，否则 / 不支持的语言用离线模型 Hy-MT2）→ 屏幕底部字幕条。说话语言可选「自动（A / B）」：双识别器逐句判别语种；AI 纠正中文识别错字（本地 Qwen3-1.7B）；可朗读译文并送进会议（虚拟声卡 BlackHole）/ 外放。`docs/live-translate/DESIGN.md`、`docs/live-translate-voice/DESIGN.md` |
| SelectionTranslate | `selectiontranslate` | **划词助手**（#85，原划词翻译）：选中后先弹动作条（翻译 · 学习 · 润色 · 改写 · 地道英文 · 解释 · 总结 · 自定义动作），AI 动作走 `AIService`，改写类在可写输入框里可替换原文（替换前 AX 核对选区），⌥ + 数字 / 键盘模式 / 各动作直达快捷键（临时快捷键 `HotkeyCenter.registerTransient`）；「学习」= 离线 ECDICT 词典卡 + 整句点词 / 朗读高亮 / 跟读，见 `docs/selection-translate/ASSISTANT.md`。底层：全系统选中文字就地浮层翻译 + 朗读（AX 取词 / 借剪贴板兜底（App 自己的「拷贝」菜单项，终端等 AX 读不到的 App 自动弹出也能用）/ 框选 OCR；原文语种自动识别，译成可选语言；系统翻译 / 离线模型，macOS 14 也能翻）。`docs/selection-translate/` |
| Dictation | `dictation` | **语音听写**（#45）：按住说话 / 连续听写（开始·结束听写，出厂快捷键 ⌥Space：一句定稿就上屏，可以一直说，安静 30 秒自动结束）/ 长听写（收集面板，可编辑再插入）；录音条不抢焦点，Esc 取消；识别走自己的 `SFSpeechRecognizer`（taskHint 听写、优先设备端、术语表共用），默认中英自动判别（低置信度时换语言重认；连续听写与长听写按停顿切段、逐句判）；后处理：语音指令、口头禅过滤、标点规整、可选本地 AI 润色（按 App）；插入按可靠性降级：AX 写入焦点（读回校验）→ 借剪贴板 ⌘V（不进剪贴板历史）→ 复制 + 提示（密码框 / 无权限）。听写历史只存文本。`docs/dictation/` |
| PhoneTransfer | `phonetransfer` | **手机互传**：扫码连接，Mac ↔ 手机互传文件和文字，手机只用浏览器。局域网模式 = `NWListener` 极简 HTTP 服务（令牌 + Mac 端允许）；公网模式 = 隐藏 `WKWebView` 跑 WebRTC DataChannel（UDP 打洞，**不做中继**），信令 AES-GCM 加密后经公共 ntfy.sh / MQTT 中转。网页在 `Resources/PhoneTransfer/`（folder 资源，同一份由 `pages.yml` 发布到 GitHub Pages `/transfer/`）。`docs/phone-transfer/` |
| NetCapture | `netcapture` | **网络抓包（暂缓，#103）**：代码在仓库，但 `project.yml` 的 excludes 把它排除在编译之外、AppDelegate 也不注册，发布包里没有；恢复步骤写在那条 excludes 的注释里。原生 Network.framework HTTP(S) MITM 代理，Mac+手机抓包、CA 证书、代理IP/二维码、ADB 一键、本地 MCP。`docs/packet-capture/` |

## 约定（写代码前必读）

1. **并发**：UI/状态类标 `@MainActor`；重 IO 走后台再回主线程，统一用
   `DispatchQueue.global(qos:.utility).async { … DispatchQueue.main.async { MainActor.assumeIsolated { …@Published 写… } } }`。
2. **菜单构建零磁盘 IO**：`submenuItems()` / `menuNeedsUpdate` 里只读内存缓存，后台刷新由 `activate()` 启动的服务负责。
3. **本地化**：所有用户可见文案走 `L("ns.key")`（AppKit / 纯 Swift）或 SwiftUI `Text("ns.key")` key 字面量；**每个 key 必须在 `mac/Sources/Resources/Localizable.xcstrings` 里有 en + zh-Hans 两种译文**，沿用文件里**紧凑单行 JSON** 格式，保持 JSON 合法。带参 key 形如 `ns.key %@` / `%lld`，Swift 侧用插值 `L("ns.key \(x)")`。命名空间按模块：`screenshot.* clipboard.* … claudecode.* aitools.* netcapture.*`。
4. **安全改用户文件**：读-改-写 settings.json / .claude.json / config.toml 等**只动自己的键、保留未知字段/注释**，写前备份同名 `.baobox.bak`。JSON 用 `JSONSerialization`；TOML 用行级/块级编辑（见 `CodexEnv.swift` 的 `CodexTOML`），不写通用解析器。
5. **解析全程容错**：外部文件字段缺失/类型不符只跳过或降级，**决不 crash**（无 force-unwrap、无 `try!`）。
6. **快捷键**：易冲突的组合出厂**不绑定**（`defaultCombo: nil`），由用户在快捷键页自设；纯菜单操作的模块 `hotkeys()` 返回 `[]`。
7. **未安装即降级**：依赖外部 CLI 的模块（ClaudeCode/AITools/NetCapture）在目录/二进制不存在时显示一条置灰引导，不报错、不启动后台服务。
8. **支持目录**：`~/Library/Application Support/Baobox/<模块>/`；各模块独立子目录避免串扰。写盘失败别用 `try?` 吞掉：
   调 `StorageWriteFailure.report(数据名, reason:)`（`Core/StorageWriteFailure.swift`，记 fault 日志 + 同一份数据只提示一次，#101）。

## docs/ 布局

- `docs/multiplatform/ARCHITECTURE.md` —— 三平台目录划分、什么共用什么不共用、移植踩到的真实差异、各平台进度。
- `docs/manual/` —— **使用手册**：每个工具、每项功能的完整说明（面向用户，README 里的链接都指向这里）。
- `docs/REQUIREMENTS.md` / `docs/TECH_DESIGN.md` —— 全局需求与 M1 技术设计（第 6 节是模块规划总表）。
- `docs/design/ui-design-v1.html` —— UI 设计稿与**设计令牌（配色）**：accent 浅 `#17A398` / 深 `#2BC4B8`，深浅两套变量。
- `docs/claude-code-assistant/` —— REQUIREMENTS + TECH_DESIGN + `WEEKLY_QUOTA.md`（周额度增量）+ `RECENT_FILES.md`（最近文件增量）。
- `docs/codex-assistant/DESIGN.md` —— Codex 对齐 Claude Code（取代 `docs/cursor-codex-assistant/` 的 Codex 部分）。
- `docs/screen-draw/DESIGN.md` —— 屏幕标注画笔（同一套标注引擎换一块画布；绘制/穿透两态）。2026-11 起是菜单栏一级入口（`ScreenDrawTool`），代码仍在 Screenshot 目录、与截图共用标注引擎。
- `docs/desktop-pet/` —— 桌面宠物：DESIGN（总设计）、INTERACTION、PACKS（素材包）、ROAM（活动范围 / 跳窗口）、VRM（二次元人形 + 程序化动作）、ENTRANCE（黑洞出场 / 退场）、SETTLE（找个不碍事的地方待着 + 原地动作）、WAKE（系统睡眠唤醒、动画重建与看门狗，日志 category `pet`）、MOCAP（走路用开源真人动捕数据，三种走法按场景换）。
- `docs/notify-core/DESIGN.md` —— 通知内核搬出桌面宠物（#108）：`Core/Notify/`（`NotifyCenter` / `NotifyDND` / `NotifySettings`，键名不变）；宠物替别的模块做的事（通知呈现 / 会议控制条挂靠 / 休息画面主角）改成 Core 的呈现角色，由框架在启动时接上；§4 是分 PR 的迁移步骤。
- `docs/focus-health/` —— 专注与健康 REQUIREMENTS + TECH_DESIGN：计时规则（用电脑的时间 / 实际时间 / 固定时刻、自然休息）、专注—休息状态机、避让与撞车、休息画面（借宠物渲染视图放大、拦截边界、看门狗）；HISTORY（专注历史：记什么、写入点、400 天、统计口径）。
- `docs/data-export/DESIGN.md` —— 数据导出 / 导入（设置 → 通用 → 数据）：一个明文 JSON（片段、听写历史、专注与健康的提醒 / 设置 / 历史），导入只合并不覆盖；代码在 `mac/Sources/Settings/DataExport/`。
- `docs/snippets/DESIGN.md` —— 文本片段（片段 = 手工创建的收藏条目，不另开数据源）+ 关键字展开的隐私边界与事件时序。
- `docs/meeting/` —— 会议 REQUIREMENTS + TECH_DESIGN（§9 第一段落地记录：引擎配置、混音与说话人、结束冲刷、会议库；§10 第二段：日历、提醒、检测状态机、会议库窗口、周报、自检、菜单迁移）。
- `docs/dictation/` —— 语音听写 REQUIREMENTS + TECH_DESIGN：三种唤起、快捷键松开事件、识别与换段、文本后处理顺序、插入降级与「只粘贴」名单、Esc 拦截。
- `docs/live-translate/DESIGN.md` —— 实时翻译：分段识别（停顿 / 45s 切段）、翻译节流（finals 全翻 + 最新 partial）、字幕条窗口。
- `docs/ai-service/DESIGN.md` —— AI 服务层（#86）：服务商与模型（两层）、功能表（模块声明、每个功能选一个模型）、Claude 与 OpenAI 兼容客户端、钥匙串、退回与冷却、实时字幕走云端的节奏、纠错 + 翻译合一、设置页「AI」；§8 记着下一版的「一键部署本地大模型」。
- `docs/translation-engine/DESIGN.md` —— 翻译引擎共享层：系统翻译 / 离线模型（Hy-MT2-1.8B + 内置 llama-server）、文字语种检测、语音双识别器（自动识别说的是哪种语言）。
- `docs/phone-transfer/` —— 手机互传 REQUIREMENTS + TECH_DESIGN：局域网 HTTP 接口、加密信令格式、三个公共信令后端、WebRTC 建连与 NAT 诊断、DataChannel 分块协议、WKWebView 宿主桥。
- `docs/packet-capture/` —— REQUIREMENTS + TECH_DESIGN（含实现顺序 §15）。
- `docs/scrolling-capture/DESIGN.md` —— 长截屏（滚动拼接）与「别的 App 菜单被截没了」的修复（issue #6）。
- `docs/screenshot-ocr/DESIGN.md` —— 屏幕取字（Vision 本地 OCR + 二维码识别），嵌在截图模块内、不单独立 `ToolModule`；识别器下沉为 `mac/Sources/Core/TextRecognizer.swift`。
- `docs/clipboard-text-tools/` —— 剪贴板文本工具（格式识别 + 转换动作 + 二维码）REQUIREMENTS + TECH_DESIGN。独立的 QRCode 模块已随此特性移除，生成器下沉为 `mac/Sources/Core/QRCodeGenerator.swift`（NetCapture 也在用）。

> 已移除的模块：**QRCode**（并入剪贴板文本工具）、**ColorPicker 取色器**（issue #7，整体删除）。`docs/TECH_DESIGN.md` §7-A.1 仅作历史留档。

**流程惯例**：新功能先在 `docs/<feature>/` 写需求 + 技术设计，再实现；文档为准，实现照文档。

## Git

- 开发在指定 feature 分支；提交信息末尾带 `Co-Authored-By: Claude …` 与 `Claude-Session:` 尾行。
- 提交者邮箱须 `noreply@anthropic.com`（`git config user.email noreply@anthropic.com && user.name Claude`）。
- ⚠️ 本环境**无可用的 commit 签名密钥**（`ssh-keygen` 缺失、签名 key 为空文件），提交会显示 Unverified —— 这是环境限制，非代码问题，邮箱正确即可。

## 发布（Release）

三步全自动，**不需要任何 secrets**（流程 2026-08-02 起生效，v0.0.0-test 实测通过）：

1. `project.yml` 里 **只有 `MARKETING_VERSION` 一处**版本号改成新版本，`chore(release): X.Y.Z — 摘要` 直接提交 main。（`CFBundleShortVersionString` / `CFBundleVersion` 现在写的是 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`，跟着构建设置走 —— 以前写死字面量，导致工作流在命令行上覆盖版本号根本不起作用，v0.0.7 的包里仍写着上一版的号。）
2. `git tag vX.Y.Z && git push origin vX.Y.Z`。
3. `.github/workflows/release.yml` 自动：三个平台并行构建（macOS Release + **ad-hoc 签名** → zip；Linux / Windows 按标签改 Cargo.toml 版本号 → `cargo rustc --release -D warnings` → tar.gz / zip），最后 `publish` 一次性创建 GitHub Release 挂上全部产物（notes 自动生成，中文说明可事后 `gh release edit` 补，格式参照 v0.0.4；同名 Release 已存在时只补传产物，不报错）。Mac 包必须有，Linux / Windows 编不过就先不挂、不挡发版（#112）。想先验证打包：Actions 里手动跑 Release（填个试打包版本号），产物在那次运行的 Artifacts 里，不发布。

背景与取舍：

- **无付费 Apple Developer 账号** → 没有 Developer ID 证书、不能公证。带证书导入 + notarytool 的旧工作流在 git 历史里（`ce39940` 之前），将来有付费账号可恢复；在那之前**不要**给工作流加 secrets 依赖。
- ad-hoc 产物仅用于**分发**：他人首次打开需右键 →「打开」；且 ad-hoc 的 cdhash 每次构建都变，覆盖安装会作废 TCC 授权（屏幕录制/辅助功能）。
- **用户自己的 Mac 一律装本地构建**（Apple Development 证书签名，TCC 授权跨版本稳定）：`cd mac && xcodegen generate` + `xcodebuild -scheme Baobox -configuration Release build`，产物 `ditto` 到 `/Applications`（先退出运行中的 Baobox）。若 `xcode-select` 指向 CommandLineTools，命令前加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。
- tag 触发的 workflow 取自 **tag 指向的提交**里的文件 —— 对旧 tag 重跑不会用新流程。
- 历史备注：v0.0.2–v0.0.4 实为本地构建手动 `gh release create` 发布（旧工作流因 secrets 缺失从未成功过）。

## 校验脚本

catalog JSON 合法性 + 静态 key 是否入表：

```bash
python3 -c "import json;json.load(open('mac/Sources/Resources/Localizable.xcstrings'));print('valid')"
```
