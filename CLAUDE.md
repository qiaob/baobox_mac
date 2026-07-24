# CLAUDE.md — Baobox 项目速览

给未来的 Claude / Codex 会话：**读这一页即可掌握项目，无需全量扫描**。深入某模块时再读对应源码与 `docs/`。

## 这是什么

**Baobox** —— macOS 菜单栏常驻的「效率工具集合」App（对标 CleanShot X + Paste，再加一组开发者工具）。一个 App 内置多个工具，统一入口 / 快捷键 / 设置。无 Dock 图标（`LSUIElement`），**非沙盒 + Hardened Runtime**，bundle id `com.baobox.app`。

- 技术栈：**Swift 5.9 · SwiftUI + AppKit 混合 · macOS 14+ · 零第三方依赖**（唯一例外：网络抓包模块调用系统自带 `/usr/bin/openssl` 子进程签证书）。
- 工程用 **XcodeGen** 生成（见 `project.yml`，`sources: - Sources` 全量 glob，新增 `.swift` 文件自动纳入，无需改 project.yml）。

## 构建与验证（重要）

- **本仓库在 Linux 开发环境，无法本地编译**；CI 只在 `main` 构建。改代码务必**保守**：只用项目里已出现的 API 与 Apple 稳定公开 API，不引入新框架、不用 Swift Charts / Observation 宏。
- Mac 上构建：`brew install xcodegen && xcodegen generate && open Baobox.xcodeproj`（或 `xcodebuild -scheme Baobox build`）。
- 无法编译时的自查：① 只引用真实存在的类型/方法（先 grep 确认签名）；② 每个 `L()` / `Text()` 的 key 都已入 `Localizable.xcstrings`（可跑下方脚本校验）；③ 所有 `@Published` 只在主线程写；④ `Process` / `NWConnection` / `URLSession` 不在主线程同步等待。

## 架构（框架先行，加工具 = 加模块）

```
BaoboxApp(@main, Settings scene)
└─ AppDelegate                      # Sources/App/AppDelegate.swift —— 注册所有模块 + 主菜单
   ├─ ToolRegistry                  # 模块注册表；registry.register(...) 的顺序 = 菜单顺序
   ├─ StatusItemController          # Sources/App/ —— 菜单栏 NSStatusItem，menuNeedsUpdate 重建菜单
   └─ OnboardingController          # 首启权限引导（屏幕录制 / 辅助功能）
```

核心协议 **`ToolModule`**（`Sources/Core/ToolModule.swift`）：每个工具实现 `id / name / symbolName / submenuItems() / hotkeys() / settingsTab() / activate() / willTerminate()`，向 `ToolRegistry` 注册即接入菜单栏、二级菜单、设置 Tab、全局快捷键。**框架不认识具体工具**。

共享基础设施（`Sources/Core/`）：`HotkeyCenter`（Carbon 全局快捷键，单例转发 C 回调）、`KeyCombo`、`Permissions`（屏幕录制 / 辅助功能）、`Geometry`（CG↔AK 坐标系转换，最易错点）、`ClosureMenuItem`（带 hotkeyID 的菜单项）、`TappableDisclosure`、`L10n`（本地化）、`TerminalAppPreference`。设置窗口在 `Sources/Settings/`。

## 模块清单（`Sources/Modules/<名>/`，菜单顺序 = 注册顺序）

| 模块 | id | 说明 |
|---|---|---|
| Screenshot | `screenshot` | 智能截图（窗口/区域/全屏）、标注、贴图、录屏、历史。ScreenCaptureKit |
| Clipboard | `clipboard` | 剪贴板历史、搜索、回填粘贴、收藏、隐私过滤 |
| ColorPicker | `colorpicker` | 屏幕取色（NSColorSampler）、格式化、历史色板 |
| QRCode | `qrcode` | 二维码生成（CIQRCodeGenerator，纯本地）——**新模块要生成二维码时复用其思路** |
| Caffeinate | `caffeinate` | 防休眠（IOPMAssertion），定时 |
| WindowManager | `windowmanager` | 窗口贴边/四分屏/居中/跨屏、布局快照（AX 权限，多显示器） |
| ClaudeCode | `claudecode` | Claude Code CLI 助手：会话续接、用量/额度（5h + **周窗口**）、报表、审计、hooks、配置可视化、statusline、MCP 面板。纯本地文件，`docs/claude-code-assistant/` |
| AITools | `aitools` | **Codex 助手**（Cursor 已移除）：会话续接、用量/报表（5h+周）、中心窗口、配置可视化、完成通知、维护。`docs/codex-assistant/DESIGN.md` |
| NetCapture | `netcapture` | **网络抓包**：原生 Network.framework HTTP(S) MITM 代理，Mac+手机抓包、CA 证书、代理IP/二维码、ADB 一键、本地 MCP。`docs/packet-capture/` |

## 约定（写代码前必读）

1. **并发**：UI/状态类标 `@MainActor`；重 IO 走后台再回主线程，统一用
   `DispatchQueue.global(qos:.utility).async { … DispatchQueue.main.async { MainActor.assumeIsolated { …@Published 写… } } }`。
2. **菜单构建零磁盘 IO**：`submenuItems()` / `menuNeedsUpdate` 里只读内存缓存，后台刷新由 `activate()` 启动的服务负责。
3. **本地化**：所有用户可见文案走 `L("ns.key")`（AppKit / 纯 Swift）或 SwiftUI `Text("ns.key")` key 字面量；**每个 key 必须在 `Sources/Resources/Localizable.xcstrings` 里有 en + zh-Hans 两种译文**，沿用文件里**紧凑单行 JSON** 格式，保持 JSON 合法。带参 key 形如 `ns.key %@` / `%lld`，Swift 侧用插值 `L("ns.key \(x)")`。命名空间按模块：`screenshot.* clipboard.* … claudecode.* aitools.* netcapture.*`。
4. **安全改用户文件**：读-改-写 settings.json / .claude.json / config.toml 等**只动自己的键、保留未知字段/注释**，写前备份同名 `.baobox.bak`。JSON 用 `JSONSerialization`；TOML 用行级/块级编辑（见 `CodexEnv.swift` 的 `CodexTOML`），不写通用解析器。
5. **解析全程容错**：外部文件字段缺失/类型不符只跳过或降级，**决不 crash**（无 force-unwrap、无 `try!`）。
6. **快捷键**：易冲突的组合出厂**不绑定**（`defaultCombo: nil`），由用户在快捷键页自设；纯菜单操作的模块 `hotkeys()` 返回 `[]`。
7. **未安装即降级**：依赖外部 CLI 的模块（ClaudeCode/AITools/NetCapture）在目录/二进制不存在时显示一条置灰引导，不报错、不启动后台服务。
8. **支持目录**：`~/Library/Application Support/Baobox/<模块>/`；各模块独立子目录避免串扰。

## docs/ 布局

- `docs/REQUIREMENTS.md` / `docs/TECH_DESIGN.md` —— 全局需求与 M1 技术设计（第 6 节是模块规划总表）。
- `docs/design/ui-design-v1.html` —— UI 设计稿与**设计令牌（配色）**：accent 浅 `#17A398` / 深 `#2BC4B8`，深浅两套变量。
- `docs/claude-code-assistant/` —— REQUIREMENTS + TECH_DESIGN + `WEEKLY_QUOTA.md`（周额度增量）。
- `docs/codex-assistant/DESIGN.md` —— Codex 对齐 Claude Code（取代 `docs/cursor-codex-assistant/` 的 Codex 部分）。
- `docs/packet-capture/` —— REQUIREMENTS + TECH_DESIGN（含实现顺序 §15）。

**流程惯例**：新功能先在 `docs/<feature>/` 写需求 + 技术设计，再实现；文档为准，实现照文档。

## Git

- 开发在指定 feature 分支；提交信息末尾带 `Co-Authored-By: Claude …` 与 `Claude-Session:` 尾行。
- 提交者邮箱须 `noreply@anthropic.com`（`git config user.email noreply@anthropic.com && user.name Claude`）。
- ⚠️ 本环境**无可用的 commit 签名密钥**（`ssh-keygen` 缺失、签名 key 为空文件），提交会显示 Unverified —— 这是环境限制，非代码问题，邮箱正确即可。

## 校验脚本

catalog JSON 合法性 + 静态 key 是否入表：

```bash
python3 -c "import json;json.load(open('Sources/Resources/Localizable.xcstrings'));print('valid')"
```
