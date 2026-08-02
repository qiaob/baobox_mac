# 分发方式评估：App Store 还是官网直售

评估时间：2026-08。前提：**Baobox 要作为付费商业产品出售**。

## 结论

**产品的差异化功能，恰好全部落在 App Sandbox 的禁区里。**

Mac App Store 强制要求 `com.apple.security.app-sandbox`。而 Claude Code / Codex 助手、
网络抓包、hosts 管理、关键字展开这四块——也就是别家没有、最值得付费的部分——
在沙盒下**没有可行实现**，不是"申请个 entitlement 就行"，是能力本身不存在。

建议**以官网直售为主**（Developer ID + 公证），把 App Store 当作可选的引流轻量版，
而不是让它决定主版本的技术选型。理由见文末。

---

## 逐模块结论

| 模块 | 沙盒可行性 | 依据 |
|---|---|---|
| 截图 / 标注 / 贴图 / 长截屏 / 取字 | ✅ 可行 | ScreenCaptureKit 与 Vision 受 TCC 管、不受沙盒管。Snipaste 以同类能力在 MAS 上架 |
| 录屏（含系统声音 / 麦克风） | ✅ 可行 | `com.apple.security.device.audio-input` 是标准沙盒 entitlement，本项目已声明 |
| 屏幕标注画笔 | ✅ 可行 | 纯自绘透明窗口，不触碰任何受限资源 |
| 防休眠 | ✅ 可行 | IOPMAssertion 沙盒内可用；Amphetamine 即以此上架 MAS |
| 剪贴板历史 | ✅ 可行 | NSPasteboard 轮询不受沙盒限制；Paste 在 MAS 上架 |
| 截图保存到 `~/Pictures/Baobox` | ⚠️ 需改造 | 沙盒只能写容器内。需加 `com.apple.security.assets.pictures.read-write`，或改成用户手选目录 + 安全书签持久化 |
| 窗口管理 | ⚠️ 有先例，审核有变数 | AX 控制其他 App 由 TCC 授权而非沙盒禁止；Magnet / Moom 均在 MAS。但近年审核对此类越收越紧 |
| 剪贴板回填粘贴 | ⚠️ 同上 | 合成 ⌘V 需辅助功能授权；Paste 即如此实现 |
| 键盘点击（Homerow 式） | ⚠️ 风险高于窗口管理 | 同为 AX + 合成点击，但「接管全屏可点元素」比「挪个窗口」更容易被质疑 |
| **文本片段 · 关键字展开** | ❌ 不可行 | 依赖全局 `CGEventTap` 监听键盘。TextExpander 当年正因沙盒限制退出 MAS |
| **Claude Code / Codex 助手** | ❌ 不可行 | 三重违规：起子进程、读家目录任意文件、驱动终端续接 |
| **hosts 管理** | ❌ 不可行 | 写 `/etc` + 提权 + 起 `osascript`；沙盒 App 亦不能安装特权助手 |
| **网络抓包** | ❌ 不可行 | 改系统代理、装 CA 进钥匙串、起 openssl / adb 子进程 |

> ⚠️ 标记的三项技术上可行且有已上架先例，但**审核结果无法预先确认**——同类能力的通过与否
> 取决于审核员与当期政策，不是代码问题。

---

## 三条硬伤

### ① 沙盒 App 只能执行自己 bundle 内的可执行文件

仓库里现有的子进程调用点：

| 文件 | 用途 |
|---|---|
| `Sources/Modules/NetCapture/NetCaptureEnv.swift` | openssl 签证书、networksetup 改代理、adb |
| `Sources/Modules/ClaudeCode/ClaudeEnv.swift` | `claude --version`、会话续接 |
| `Sources/Modules/AITools/CodexEnv.swift` | `codex --version`、`codex resume` |
| `Sources/Modules/Hosts/HostsEnv.swift`（PR #17） | `osascript` 提权写 hosts |

沙盒下这四处全部作废。这不是权限问题——沙盒 App 无法执行 bundle 之外的任意可执行文件。

### ② 全局 event tap 上不了 MAS

| 文件 | 用途 | 失去后的后果 |
|---|---|---|
| `Sources/Core/HotkeyCenter.swift` | 状态栏菜单打开期补捉热键 | 降级：菜单打开时快捷键失灵，其余不受影响 |
| `Sources/Modules/Clipboard/SnippetExpander.swift`（PR #19） | 关键字展开 | 功能本身不存在 |

注意区分：**Carbon `RegisterEventHotKey` 的全局快捷键在沙盒下是允许的**，大量 MAS App 都在用。
不能用的只是「监听所有按键」的 event tap。

### ③ 写系统文件没有任何路径

`/etc/hosts` 在沙盒下既写不了，也不能通过特权助手绕开——MAS 不允许 App 安装
`SMJobBless` / launchd daemon 类的特权组件。hosts 模块在 MAS 上**没有可行方案**，
连可申请的 entitlement 都不存在。

---

## 沙盒下仍然完好的部分

避免只列坏消息——若真做轻量版，下面这些一行代码都不用改（除保存目录外）：

- 截图全家桶：窗口 / 区域 / 全屏、标注、贴图、历史、长截屏、屏幕取字
- 录屏（MP4 / GIF，系统声音 + 麦克风）
- 屏幕标注画笔
- 剪贴板历史、搜索、收藏、隐私过滤、落盘加密（Keychain 在沙盒内正常）
- 防休眠
- 全局快捷键、设置页、本地化、浅深色适配

这五块足以撑起一个像样的 App，但它正面对上的是免费的 Snipaste 与成熟的 Paste。

---

## 三个方案

### A. 只上 App Store

砍掉 AI 助手、hosts、抓包、关键字展开。剩下的部分要与免费产品正面竞争，
**最值得付费的东西恰好都没了**。

### B. 只做官网直售（建议）

Developer ID 签名 + 公证，Paddle / Lemon Squeezy 类平台收款（可代缴全球增值税），
Sparkle 做自动更新。功能完整，无审核，省 30% 抽成。
代价：自行处理支付、退款、License 校验与盗版。

### C. 双版本

MAS 上架轻量版引流，官网卖完整版。代价是两套构建配置、两套文案、两套支持路径。

---

## 建议：B，理由三条

1. **差异化在禁区里。** Claude Code / Codex 助手、抓包、hosts 是别家没有的东西，
   也正是沙盒全面禁止的。砍完之后在 MAS 上没有故事可讲。
2. **工程上本来就在直售那条路上。** `project.yml` 里 `DEVELOPMENT_TEAM` 已固定、
   Hardened Runtime 已开启、entitlements 声明了 apple-events 与 audio-input ——
   **这套配置本就是为 Developer ID 分发准备的**。改沙盒是往回走。
3. **目标用户是开发者。** 这群人不介意从官网下载，反而更在意功能是否被阉割。

若之后仍想要 App Store 的曝光，再按 C 补一个轻量版，但**别让它决定主版本的技术选型**。

---

## 若走 B，接下来要做的事

| 事项 | 说明 |
|---|---|
| 公证（notarization） | `xcodebuild` 出包 → `notarytool submit` → `stapler staple`。Hardened Runtime 已开，entitlements 已就绪 |
| 自动更新 | Sparkle 2，需要一个 appcast.xml 与 EdDSA 签名密钥；托管在官网同一个 Cloudflare Pages 上即可 |
| 收款与 License | Paddle / Lemon Squeezy（代缴税）或 Gumroad。License 校验建议做成「离线可用、联网校验失败不阻断」，别把用户锁在门外 |
| 试用期 | 直售产品通常给 7–14 天全功能试用，比功能阉割的免费版转化率高 |
| 官网调整 | 购买按钮改为「下载试用 + 购买 License」，并删掉「随 Apple ID 同步到每台 Mac」这类 App Store 专属措辞 |

## 若走 C，代码上怎么切

框架本身已经支持：`AppDelegate` 里按需 `registry.register(...)` 即可决定装哪些模块
（NetCapture 现在就是靠注释掉那一行来「本版不发布」的）。

真正要加的是一个编译期开关（例如 `MAS_BUILD`），控制三件事：
① 哪些模块注册；② entitlements 用哪一份；③ 设置页与文案里去掉不存在的功能。
不需要改任何模块内部代码——这正是 `ToolModule` 这套结构的价值。

---

## 本评估的边界

- 沙盒的**技术**限制（子进程、写系统文件、event tap）是确定的。
- 标 ⚠️ 的三项属于**审核政策**范畴：有已上架先例，但通过与否随审核员与当期政策浮动，
  无法预先确认。真要走 MAS，建议先用最小可用版本试一次审核，再决定投入。
- Apple 的政策会变。这份评估的结论以 2026-08 为准。
