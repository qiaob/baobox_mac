# 桌面宠物与通知中心（DesktopPet）设计

对应 issue #44。本工具分两层：**通知内核**（Baobox 全部模块与本机其他进程共用的通知通道）与**桌面宠物**（通知的呈现者 + 常驻陪伴形象）。用户已定优先级：四个新工具（#42 会议 / #43 专注与健康 / #45 语音听写）里第一个做，因为其余三个的提醒与回执都依赖通知层。

## 1. 需求

- 模块不再各自发系统通知，统一投递到通知内核，按级别经宠物呈现；宠物关闭时回退系统通知中心，提醒不丢失。
- 通知三级：`ambient`（气泡数秒自消）/ `bubble`（气泡+动作按钮，点击回调来源）/ `alert`（气泡+提醒动作，可选提示音）。
- 本机其他进程可经 Unix socket / CLI / URL scheme 投递通知；带动作的通知可把用户选择回传来源进程（轻量人机确认）。
  **这一条是 M2，还没实现**（2026-11-10 核实：代码里没有 `NotifyGateway`、没有 `pet.sock`，见 #113）；
  用户定了先在文档里标「计划中」，等真有外部程序要调用时再做。
- 宠物常驻桌面：待机、散步、睡觉、提醒四种基本状态；可拖放；点击唤出 Baobox 菜单；形象渲染支持 2D 精灵与 3D 模型两种后端。
- 勿扰统一判定：全屏 / 会议中 / 录屏 / 屏幕共享时非 `alert` 级通知攒批，事后一次补呈；判定逻辑与 #42、#43 共用一份。

## 2. 总体架构

```
模块 / 外部进程 ──► NotifyCore ──► PetPresenter ──► PetEngine ──► Renderer(2D | 3D)
                      │  └─ 勿扰聚合队列 ─┘                └─ 气泡 UI
                      └─ 回退：UNUserNotificationCenter（宠物关 / 未就绪 / 宠物模块没注册时；按钮转成通知操作，点了照样回调来源）
外部进程 ──Unix socket / CLI / URL──► NotifyGateway ──► NotifyCore      （M2，未实现）
```

- `NotifyCore`：通知数据模型、来源注册表、去重、勿扰聚合、动作回调用分发。与 UI 无关，可单测。
  代码不在本模块：2026-11-10（#108）起放在 `mac/Sources/Core/Notify/`（`NotifyCenter` / `NotifyDND` / `NotifySettings`），
  宠物模块只当呈现端、提供设置入口，见 `docs/notify-core/DESIGN.md`。
- **呈现端怎么接上**（#108）：通知内核不认识宠物，只认 `NotifyPresenting` 协议（`isReady` + `present`）。
  宠物模块用 `ToolModule.presentationRoles()` 交出 `PetController.shared`；框架在 `ToolRegistry.activateAll()` 里、
  任何模块 `activate()` 之前把它装进 `PresentationHub`（`mac/Sources/Core/Presentation/`），只装一次、之后只读，与注册顺序无关。
  - 投递时看呈现端：在且 `isReady`（宠物开着、窗口在屏上，或正在换形象）→ 宠物气泡；宠物关着（`isReady` 为假）→ 系统通知；
    宠物模块没注册（没有呈现端）→ 也走系统通知。
  - 启动期间先攒着：宠物要等自己的 `activate()` 里 `start()` 之后才就绪，所以 `activateAll()` 期间投递的通知先攒着
    （`NotifyCenter.holdDuringLaunch` / `releaseAfterLaunch`），全部 `activate()` 跑完再按原顺序逐条投递 ——
    排在宠物前面注册的模块发的通知，不会因为注册顺序掉到系统通知。
  - 系统通知权限：有宠物模块时照旧由宠物申请（宠物关着启动时、刚关掉宠物时），宠物开着启动不弹；
    宠物模块没注册时，框架装呈现端那一步就申请。
- `NotifyGateway`（M2，未实现）：对外协议层（socket 监听、CLI 与 URL scheme 的参数解析），只做校验与转交，不持有呈现状态。
- `PetEngine`：宠物状态机与行为（位置、移动、朝向、当前动画状态），只产出「渲染意图」（状态 + 位置 + 朝向），不关心 2D/3D。
- `PetRenderer`（协议）：消费渲染意图。两个实现：`SpriteRenderer`（2D 帧序列）、`SceneRenderer`（SceneKit 3D）。
- `PetPresenter`：气泡队列与文案排版、按钮回调接线、通知历史。

## 3. 通知模型与内部 API

```swift
struct Notice {
    var source: String            // 来源标识，如 "meeting" / "focus" / "claude-code" / 外部自报
    var level: Level              // ambient | bubble | alert
    var title: String
    var body: String?
    var actions: [Action]         // id + label，仅 bubble/alert 可带
    var dedupeKey: String?        // 同来源同 key 在窗口期内合并计数
    var ttl: TimeInterval?        // 过期自动撤下
}
NotifyCenter.shared.post(_ n: Notice,
                         onAction: ((String) -> Void)? = nil)
```

- 类型名：原名 `PetNotification`，#108 改成 `Notice`（和 Windows 版 `pet_notify.rs` 同名）。旧名留了一个版本的
  deprecated typealias，下个版本删（`docs/notify-core/DESIGN.md` §4 PR 6）。
- 内部来源在代码内注册（meeting / focus / dictation / ai-tools / livetranslate…)，免授权；外部来源走网关，须经授权名单（§5）。专注与健康（#43）的来源 id 定为 `focus`。
- 去重：同 `(source, dedupeKey)` 在 30 秒内重复投递只更新计数与最新文案，不重复弹。
- 动作回调只在进程内分发给来源模块；对外部来源经 socket 写回（§5）。

## 4. 勿扰与聚合

- 信号源（单一实现，#42/#43 共用）：前台 App 全屏、会议进行中（#42 会话状态）、屏幕录制 / 共享中、用户手动勿扰（宠物菜单「安静 1 小时 / 今天」）、专注中（#43）。
- 落地（2026-11-06，#43）：其他模块经 `NotifyDND.setSuppressed(_:token:)` 挂令牌——Baobox 录屏挂 `recording`、专注中挂 `focus`、休息画面在场挂 `break`；`reasons(ignoringTokens:)` 列出全部原因（含麦克风占用），供调用方按需挑选。麦克风占用只给专注与健康的避让用，不进 `isSuppressed`（Baobox 自己的实时翻译也占麦克风，分不清是谁）。别的 App 的录屏 / 屏幕共享用公开 API 测不准，暂不检测。
- 勿扰期间：`ambient` 直接进历史不弹；`bubble` 入队，勿扰解除后合并成一条摘要气泡（「3 条提醒：…」可展开）；`alert` 照常呈现但无声。
- 宠物在勿扰期间进入睡觉状态，形象与行为一致，不出现「睡着了还弹气泡」的割裂。

## 5. 对外协议（本机进程）—— M2 计划，尚未实现

> 2026-11-10：下面是计划中的设计，代码里还没有（#113）。实现前以这一节为准，实现后删掉这段说明。

### 5.1 Unix socket（主通道）

- 路径：`~/Library/Application Support/Baobox/pet.sock`，一行一个 JSON，UTF-8，单条上限 16KB，连接数上限 16。
- 请求：

```json
{"v":1,"source":"my-build-script","level":"bubble","title":"构建完成",
 "body":"全部测试通过","dedupe":"build","ttl":120,
 "actions":[{"id":"open","label":"打开报告"},{"id":"dismiss","label":"忽略"}]}
```

- 响应：校验失败回 `{"ok":false,"error":"..."}` 并断开；成功回 `{"ok":true}`。带 `actions` 时连接保持，用户点击后写回 `{"action":"open"}`；连接断开或 ttl 到期视为取消。无动作的通知投递后即可断开。
- CLI 封装：`baobox-pet notify --source ci --level bubble --title … [--action id=文案]…`，内部即连 socket；阻塞等回 `action` 后以退出码 / stdout 输出选择，供 shell 与 hook 直接用。

### 5.2 URL scheme（补充）

`baobox://notify?source=…&level=ambient&title=…&body=…`：仅投递，无动作回调（系统限制下不承诺回执）。

### 5.3 安全

- socket 文件权限 0600，仅同用户进程；**不开网络端口**，不经局域网。
- 来源首次投递：宠物弹一次授权气泡（允许 / 拒绝并拉黑）；授权名单存本地 JSON，设置页可撤销。
- 限流：每来源 10 条 / 分钟，超限静默丢弃并在历史里记一笔。
- 外部动作仅回传选择，**Baobox 不替外部进程执行任何命令**；title/body 做长度截断与控制字符过滤，防气泡 UI 被撑爆或伪造系统样式。

## 6. 宠物行为状态机

状态：`sleep`（勿扰/长空闲）→ `idle`（趴坐、呼吸、偶尔眨眼）→ `wander`（沿当前屏底部走动，到边缘转身）⇄ `idle`；任意状态收到通知 → `notify`（转身面向用户 + 跳一下（alert）或抬头（bubble）+ 冒气泡），气泡结束回原状态；被拖拽 → `dragged`（四肢悬空姿态），放下后回 `idle`。

- 移动：只在所在屏的工作区底部带内水平走动，避开 Dock 区域；多屏时固定在用户最后拖放的屏，不跨屏乱跑。
- 长空闲（HID idle > 5 分钟）自动 `sleep`；用户回来回 `idle`。
- 点击宠物（非拖拽）= 唤出 Baobox 主菜单；右键 = 宠物菜单（换形象、大小、安静一下、通知历史、设置）。

## 7. 渲染层

`PetRenderer` 协议只接收：当前状态、朝向、位置、提醒强度。引擎与渲染彻底解耦，换后端不触碰通知与行为逻辑。

### 7.1 2D 精灵后端（首发默认）

- 资源：每形象一目录，含 `idle / walk / sleep / notify` 四组 PNG 帧 + `pet.json`（帧率、锚点、命中轮廓）。帧动画用 `CVDisplayLink` 降级定时器驱动，睡觉 / 遮挡时停帧。
- 用户自定义：导入图片序列或 GIF 时自动切帧入组（四种状态可共用一组），落此后端。

### 7.2 3D 后端（SceneKit）

- 资源：`.usdz` 模型 + 骨骼动画片段，命名与状态机对齐（`idle` / `walk` / `notify` / `sleep`），片段间交叉淡入淡出 150ms。
- 相机与光：固定透视相机（轻微俯角）+ 单方向光 + 环境光，无阴影贴图（用模型自带 AO），背景透明（`SCNView` alpha)。
- 功耗：活动时上限 30fps；`sleep` / 被全屏遮挡 / 勿扰时暂停渲染循环（保留最后一帧静态图）；系统低电量或热压力高时自动切换 2D 后端并在设置里提示。
- 命中与气泡：3D 形象命中用模型投影包围盒近似（略小于视觉体积，避免挡操作）；气泡仍为 2D 浮层，锚在宠物头顶投影点。
- 资产现实：代码不是瓶颈，**带四段动画的低多边形猫/狗模型**才是。选型结论见 §7.3，开源现成模型足够起步，不必等采购 / 约稿；二次元 3D 形象不进首发。

### 7.3 3D 资产选型（2026-11-05 调研定）

开源现成模型以 GLB/glTF 为主，出厂前统一转 USDZ（苹果免费 Reality Converter 或 Blender 转一道，运行时零负担）。已核实可直接用的候选：

| 形象 | 来源 | 授权 | 动画（实测/官方页） | 对四状态的覆盖 |
|---|---|---|---|---|
| **狐狸（M3 原型定版）** | KhronosGroup glTF Sample Assets `Fox.glb` | 模型 CC0；骨骼/动画 CC-BY 4.0（须署名） | Survey / Walk / Run（159KB、24 关节，已下载解析实测） | 待机=Survey、走=Walk、提醒=Run 顶替；缺睡 |
| **动物包（正式内置主力）** | Quaternius Ultimate Animated Animal Pack（12 只动物）+ LowPoly Animated Animals（含哈巴狗） | CC0（官网确认，商用免署名） | 每只 12+ 段：Walk / Gallop / Jump / Kick / Death 等 | 待机/走/跳齐全；睡用 Death 躺倒帧顶替 |
| **机器人（备选吉祥物）** | three.js 官方示例 RobotExpressive | MIT（仓库标注） | Idle / Walking / Running / Jump / Dance / Wave 等 13 段 | 四状态全覆盖且提醒动作（Wave）最贴 |

- **分工**：M3 渲染管线原型直接用狐狸验证（零等待、兼容性最稳）；正式内置形象从 Quaternius 包里挑（CC0 无署名负担）；机器人作为「助手型」备选。
- **署名义务**：狐狸的骨骼/动画为 CC-BY 4.0，若正式版保留该模型，须在 App「关于 / 素材致谢」与仓库 `NOTICE` 中注明：模型 by PixelMannen (CC0)，rigging & animation by tomkranis (CC BY 4.0)，glTF conversion by @AsoboStudio & @scurest。
- **共性缺口**：「睡觉」专用片段普遍没有，一律用躺倒类片段（Death / Lie）顶替 + 闭眼靠姿态，视觉达标即可，不单独立项补动画。

## 8. 窗口与层级

- 宠物窗：borderless `NSPanel`，`canJoinAllSpaces + fullScreenAuxiliary`，`.floating` 级，高于普通窗口；`ignoresMouseEvents` 动态切换——仅命中区接收事件（2D 按 alpha、3D 按包围盒），其余穿透。
- 休息画面（#43，2026-11-06 改）：**宠物本身就是休息画面的主角**——渲染视图借给休息画面的舞台窗（`.screenSaver + 1`，暗幕在 `.screenSaver`），走到屏幕中央变大，结束后飞回、还给宠物窗。借出期间宠物窗留在原地但变空、不接鼠标，挂在它身上的气泡不受影响。见 `docs/focus-health/TECH_DESIGN.md` §5。
  - **怎么借**（#108）：休息画面不认识宠物，只认 Core 的 `BreakCompanion` 协议（`mac/Sources/Core/Presentation/BreakCompanion.swift`）。宠物模块用 `presentationRoles()` 交出 `PetController.shared` 当 `breakCompanion`，框架启动时装进 `PresentationHub`。
    宠物关着、没就绪、正在换形象时 `lend()` 返回 nil，休息画面走回退画面；宠物模块没注册时同样走回退画面，也不会顺手把 `PetController.shared` 建出来。
  - **意图与姿态**：休息画面只在阶段切换时发三种意图 —— `.walking(facingLeft:)`（飞过去 / 飞回来）、`.resting(lookAway:)`（先转过来看你 1.2 秒再躺下，护眼是侧身看远处）、`.attentive`（休息好了 / 等你确认本人）。
    `PetBreakLoan`（`PetBreakCompanion.swift`）把意图换成 `PetPose`，用自己的 1/30 秒 `.common` 定时器推给 `setLentPose`（逐行搬自原来 BreakStage 的 `pushPose`），被戳一下转给 `performLent("poke")`，`giveBack()` 停定时器、摘视图、调 `returnRenderView()`。
    `lendRenderView / setLentPose / performLent / returnRenderView` 都只在宠物模块内部用。
  - **退出保险**：`stop()` 记一个 `stopped` 标记；之后再 `returnRenderView()` 只把视图放回宠物窗，不再 `applyVisibility()`、不打招呼。今天专注与健康先于宠物 `willTerminate`，走不到；顺序反过来时，它挡住「退出时宠物重新显示、播出场、黑洞窗冒出来」那一下闪烁（`docs/notify-core/DESIGN.md` §1.2）。
- 气泡窗：独立小 `NSPanel`，不抢焦点；按钮可点但不激活 App（`nonactivatingPanel`)。

## 9. 设置（UserDefaults 键，前缀 `pet.` / `notify.`）

- 宠物（`PetSettings`，本模块）：`pet.enabled`（默认开）、`pet.character`（形象 id)、`pet.renderer`（auto / 2d / 3d)、`pet.size`、`pet.roam`（是否走动）。
- 通知内核（`NotifySettings`，`Core/Notify/`；#108 从 `PetSettings` 拆出，键名一个没改）：`notify.source.<id>`（逐来源开关，内外来源统一，默认开）、
  `notify.sound`（alert 提示音，默认关）、`notify.historyLimit`（默认 50）、`pet.quietUntil`（「安静一下」的勿扰截止，沿用老键名）。
  设置页的「通知」一组开关和「安静一下」入口仍在宠物设置页 / 宠物菜单里。
- 来源授权名单与限流状态存 `~/Library/Application Support/Baobox/Pet/sources.json`，不走 UserDefaults。

## 10. 文件

- 模块：`mac/Sources/Modules/DesktopPet/`——`DesktopPetTool.swift`（注册）、`PetEngine.swift`、`PetWindow.swift`、`BubbleWindow.swift`、`SpriteRenderer.swift`、`SceneRenderer.swift`、`PetSettingsView.swift`。
- 通知内核：`mac/Sources/Core/Notify/`（#108 从本模块搬出）——`NotifyCenter.swift`（通知模型、去重、勿扰聚合、系统通知回退）、`NotifyDND.swift`（勿扰判定）、
  `NotifySettings.swift`（通知设置）。`NotifyGateway.swift`（socket/CLI/URL，M2 未实现）落地时也放这里。
- 资源：`mac/Sources/Resources/Pets/`（内置形象目录）。
- CLI 源码：`tools/baobox-pet/`（单文件 Swift，随包分发方式从待定项里定；M2 未实现）。
- 本地化：`pet.*` / `notify.*` 键入 `Localizable.xcstrings`，中英齐全。

## 11. 迁移

- `AIToolsNotify`（Claude Code / Codex 的完成、失败、等待确认）与 LiveTranslate 纪要就绪通知改走 `NotifyCenter.post`，旧系统通知路径仅作宠物关闭时的回退，保留一个版本后删。
- #42 / #43 / #45 实现时直接依赖本模块 API，不再自建通知。
- 2026-11-06：Claude Code / Codex / 实时翻译残留的「自己申请通知权限」已删除。通知怎么展示、要不要系统通知权限，都由本模块决定（宠物关着启动或刚关掉宠物时申请），功能模块只投递内容与回调（用户确认的原则）。

## 12. 测试与验证

- 协议层：坏 JSON、超长、洪泛、无动作断开等用例走 socket 直连测试；CLI 以 shell 脚本冒烟（含 hook 场景模拟）。
- 勿扰矩阵：全屏 / 会议 / 录屏 / 专注四种信号 × 三个级别的呈现结果逐项核对。
- 功耗：3D 后端活动 / 睡觉两态各测 10 分钟 CPU 与能耗（Activity Monitor / powermetrics），睡觉态渲染必须为零帧。
- 真机验证：多屏 + Dock 自动隐藏、深色模式、气泡按钮不抢焦点、拖拽与点击区分。

## 13. 分期

- **M1 通知内核 + 2D 宠物**：内部 API、勿扰聚合、回退、精灵后端、AI 助手与 LiveTranslate 通知迁移。
- **M2 对外开放**（未开始，#113）：socket 协议、来源授权、CLI、URL scheme。
- **M3 3D 后端**：SceneKit 渲染、功耗节流、低电量降级；模型资产就绪后随版本开启。
