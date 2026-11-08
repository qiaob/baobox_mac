# 专注与健康 · 技术设计

需求见 `REQUIREMENTS.md`。代码在 `mac/Sources/Modules/FocusHealth/`，另改桌面宠物与通知内核几处（§6）。

## 1. 文件

| 文件 | 职责 |
|---|---|
| `FocusHealthModels.swift` | 提醒项、预置、各项计时进度、专注会话、工作时间、强度（纯 Foundation，可单测） |
| `ReminderScheduler.swift` | 计时推进、到点 / 预告判定、自然休息、推迟（纯函数，可单测） |
| `FocusHealthController.swift` | 主线程编排：1 秒心跳、人在不在、睡眠唤醒、避让、发提醒、专注—休息循环、落盘 |
| `FocusHealthStore.swift` | `items.json` / `state.json` 读写（后台串行队列，退出时同步写） |
| `FocusHealthSettings.swift` | 标量设置（UserDefaults，前缀 `focus.`） |
| `BreakStage.swift` | 休息画面：暗幕窗、舞台窗、借宠物、飞行动画、拦截输入、看门狗 |
| `BreakStageViews.swift` | 休息画面里的 SwiftUI 界面（倒计时卡片、副屏小字、长按跳过） |
| `FocusStatusItem.swift` | 专注 / 休息时的菜单栏倒计时项 |
| `FocusHealthTool.swift` | ToolModule：菜单、快捷键、设置 Tab |
| `FocusHealthSettingsView.swift` | 设置页 |
| `FocusHealthText.swift` | 显示文案（本地化），与可单测的模型分开 |
| `Core/UserActivity.swift` | 键鼠空闲秒数、是否正在按键 / 按着鼠标、别的进程是否阻止屏幕休眠 |

## 2. 心跳与计时

- 主线程 `Timer` 每秒一跳（菜单栏倒计时要秒级），加进 `.common` 模式（菜单打开时也走）。每跳只做算术与一次 HID 空闲查询；dt 取与上一跳的间隔，封顶 5 秒（睡眠回来不会一口气累加几小时）。
- 在电脑前：`UserActivity.secondsSinceInput() < 120`，或 `otherProcessPreventsDisplaySleep()`（`IOPMCopyAssertionsByProcess`，排除自己的 pid，只在空闲 ≥ 120 秒时查，结果缓存 10 秒）。
- 离开段：「在电脑前」由真变假时记 `awayActive`；回来（空闲 < 5 秒）时，跨度 = 上一跳的空闲秒数 → `ReminderScheduler.applyAway`。看视频期间一直算在电脑前，不会产生离开段。
- 睡眠：`NSWorkspace.willSleep / didWake` 记起止，醒来按跨度套用 `applyAway`。
- 调度纯函数 `advance(items, runtime, input) -> [Event]`，Event 为 `.warn(id)` / `.due(id)`。预告只发一次（`warned`）；到点的项保持到点，直到调用方 `reset` / `snooze`，控制器每跳幂等处理。

## 3. 专注—休息状态机

```
idle ──开始──► focusing ⇄ paused
focusing ──到点 / 记为完成──► 轮次+1 ─┬─长──► longBreak（休息画面）─┐
                                     └─短──► shortBreak（菜单栏倒计时）┴─结束─► idle（问下一轮 / 自动下一轮）
focusing / paused ──作废──► idle
```

- 长休息条件：本次计划时长 ≥ 50 分钟，或今日轮次是 N 的倍数。
- 勿扰令牌：focusing 时挂 `focus`；休息画面在场时挂 `break`（其他模块的非重要通知攒批，结束后合并补呈）。
- 今日轮次按本地日期翻日清零。重启后：focusing / paused / shortBreak 照常恢复；longBreak（画面已随进程消失）直接结束；过点超过 10 分钟的专注只记一轮、不补休息。

## 4. 提醒分发（控制器）

每跳拿到的 `.due` 依次过闸：

1. 总开关关、本工具暂停中、今天已关 → 不推进调度（暂停期间不累加）。
2. 正在专注（focusing）、短 / 长休息中、休息画面在场或等待出场 → 记 `deferredSince`。专注结束时，专注期间顺延的项并进休息文案并重置。
3. 人不在电脑前 → 等（不算顺延，不计入 45 分钟降级）。
4. 避让（§6 的 `NotifyDND.reasons`，排除自己的 `focus` / `break` 令牌）→ 记 `deferredSince`，下一跳再看。「正在避让」缓存 5 秒（查全屏要遍历窗口列表），「没在避让」不缓存，发之前一定现查。
5. 统一节拍（§4.1，2026-11-07 起取代原来的撞车吞并）：`ReminderCoordinator.plan` 决定这一跳发不发、一起发哪几项、顺带重置哪几项。
6. 发，形式按主项（级别最高、休息最长）：
   - 休息画面：同一次的其他项并进文案（护眼不列）；顺延超过 45 分钟的降级为一张卡片，其他项也并进这张卡片；
   - 宠物提醒：合成一张卡片，站立 + 喝水合成「起来走走，喝口水」，宠物动作依次做；
   - 轻提醒：`level: .ambient`、6 秒自己消失的小气泡，宠物做动作（护眼 = VRM 的 `look_up`），发出即算做过。

### 4.1 统一节拍（`ReminderCoordinator`，纯函数，在 `ReminderScheduler.swift`）

输入：这一跳到点的项、全部项、各项计时、上次真的提醒的时刻 `lastPromptAt`（控制器内存里，重启清空）、最小间隔（`focus.minSpacing`，默认 15 分钟）。

- 级别（`ReminderItem.tier`）：
  - 3 = 休息画面 ≥ 2 分钟；
  - 2 = 宠物提醒；
  - 1 = 轻提醒，或短于 2 分钟的休息画面。
- 返回 nil（这一跳不发，到点项保持到点状态，下一跳再看）的两种情况：
  - 离 `lastPromptAt` 不到最小间隔；
  - 有更高一级的有间隔项 10 分钟内到点。
  - 到点项里有每天固定时刻的项时，这两条都不管。
- 合并：其他启用的有间隔项，级别 ≤ 到点项最高级别、距到点 ≤ min(15 分钟, 间隔 × 30%) 的加进来。
- 主项排序：级别降序，休息时长降序，原顺序。
- covered：级别低于主项、没加进来的有间隔项，重置（大的包含小的）。

验证：会话 scratchpad 里有个模拟程序，只编 `FocusHealthModels.swift` + `ReminderScheduler.swift`，5 秒一跳。用默认四项连续 3 小时，提醒依次是 20 / 50 / 75 / 105 / 130 / 160 分钟，相邻间隔 30 / 25 分钟；中途离开 6 分钟、喝水改回旧设置的情况也测过。

`.warn`（休息画面项到点前 60 秒）同样过 1–4，能发就发预告卡片（与同一跳的宠物提醒卡片一起发），发不了就跳过。

回应：

- 卡片发出即 `reset`；[推迟 10 分钟] → `snooze(600)`；气泡自己消失没有回调 = 错过。
- 休息画面（标准 / 严格）：完成 → 重置全部「离开算完成」项；跳过 → 只重置本项；不能推迟。
- 轻松档的休息气泡：发出即 `rearm`（重新计时、保留本轮推迟次数）；[好的] 按完成处理；[推迟 5 分钟] → `snooze(300)`、推迟次数 +1，达到上限不再给推迟按钮；没点 = 错过。
- 宠物关着时通知内核回退系统通知，**按钮照样带上**：`PetNotification.Action` 转成 `UNNotificationAction`（按按钮组登记 `UNNotificationCategory`，登记完再投递），用户点了经 `SystemNotificationRouter`（`UNUserNotificationCenterDelegate`）回到投稿方的回调，点通知本体 = `"open"`；同时实现 `willPresent`，Baobox 在前台（开着设置窗口点预览）也弹横幅。通知权限同样归通知内核管：宠物关着启动、或用户刚把宠物关掉时申请（`prepareSystemFallback`），功能模块不再各自申请。第一版回退通知只有标题正文、按钮全丢，且前台时不弹（2026-11-06 真机踩到）。
- 本工具自己判避让再发：勿扰期间通知内核会把通知排队、事后合成**不带按钮**的摘要（`NotifyCenter.flushIfPossible`），按钮回调就丢了。

## 5. 休息画面（BreakStage）

### 5.1 强度 → 画面样子

`BreakStageStyle`：`gentle`（不变暗、不拦截，点一下跳过）/ `locked`（变暗 + 拦截，长按 3 秒跳过）/ `lockedBlur`（同 locked，暗幕换成模糊）。

| 场合 | 轻松 | 标准 | 严格 |
|---|---|---|---|
| 休息提醒到点 | 宠物气泡（不出画面） | locked | lockedBlur |
| 专注后的长休息 | 宠物气泡 + 菜单栏倒计时 | locked | lockedBlur |
| 手动「现在休息」 | gentle | locked | lockedBlur |
| 设置页「预览效果」 | 示例气泡 | locked 10 秒 | lockedBlur 10 秒 |

模糊（严格档，有没有宠物都用）：暗幕里放 `NSVisualEffectView`（`.behindWindow` + `.fullScreenUI` + 深色外观 + `state = .active`，App 不在前台也保持模糊），上面再压一层 30% 黑；系统开了「减少透明度」时自动退成不透明底。暗幕 `hitTest` 一律返回自己，点在模糊层上也能「戳宠物」。

### 5.2 窗口

| 窗口 | 级别 | 说明 |
|---|---|---|
| 暗幕窗（每屏一张，gentle 没有） | `.screenSaver` | 无边框 nonactivating NSPanel，铺满整屏（含菜单栏），吞鼠标；点一下 = 戳宠物（「还没休息完哦」） |
| 舞台窗（一张） | `.screenSaver + 1`（gentle 为 `.statusBar`） | 装宠物渲染视图 + 倒计时卡片。locked 出场即成为 key 窗口（nonactivating，不激活 App；探针实测前台 App 不变、撤下后焦点自动回去），吞键盘；`performKeyEquivalent` 一律返回 true，⌘Q 不会把 Baobox 退出 |

- 先设 level 再 setFrame，并覆写 `constrainFrameRect`（照截图 overlay 的做法，否则盖不住菜单栏）。
- **不要设 `isFloatingPanel`**：NSPanel 的这个 setter 会把 level 改回 `.floating`（3）。第一版先设 level 再设它，舞台和暗幕都掉到 3 级，点一下暗处暗幕就盖到宠物上面——宠物被一起调暗 / 模糊、「长按跳过」按不到，暗幕也盖不住菜单栏和 Dock（2026-11-06 真机踩到；探针从 WindowServer 读层级确认修复后为 1001 / 1000）。
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`；`isReleasedWhenClosed = false`，撤下时 `orderOut` 后丢引用。
- 屏幕参数变化（插拔显示器）时重建暗幕；舞台所在的屏没了就挪到主屏中央。

### 5.3 借宠物（PetController 新增）

- `lendRenderView() -> Loan?`：把当前渲染视图（3D `PetModelView` / 2D `SpritePetView`）从宠物窗取出交给舞台。宠物窗留在原地但变空、`ignoresMouseEvents = true`，引擎站住（不溜达），姿态不再写到这个视图上；挂在宠物窗上的气泡不受影响，休息结束后照常可见。宠物关闭 / 没就绪返回 nil → 走回退画面。
- `setLentPose(_:)` / `performLent(_:)`：舞台直接驱动姿态与互动动作。
- `returnRenderView()`：放回宠物窗。借出期间的换形象请求延到归还后执行。

### 5.4 动画

- 飞行：舞台窗从宠物窗的屏幕位置与大小，60Hz 手动插值（ease-in-out，0.9 秒）到中央大尺寸（屏高 42%，上限 520pt；2D 形象上限为原尺寸 3 倍，再大就糊），期间姿态 `wander`（侧身走）；到达后窗口扩成「宠物 + 卡片」，卡片淡入，倒计时从这一刻开始。系统开了「减少动态效果」时直接出现在中央。
- 休息中：普通休息 `sleep`（躺下，片段播完 SceneKit 场景暂停，零渲染）；护眼 `idle` 侧身（看远处）。姿态 30fps 推送（2D 帧动画靠它走）。
- 结束：姿态回 `idle` 并正对用户（`PetModelView` 从睡姿回待机会自动播「起身 + 伸懒腰」），2.5 秒后飞回原位、归还视图。跳过 / 推迟直接飞回。

### 5.5 安全

- 截止看门狗：休息时长 + 飞行 + 45 秒还没撤，强制撤下（不走动画）。
- 主线程卡死看门狗：拦截键鼠期间，后台线程每 2 秒检查主线程心跳，超过 20 秒没响应 → 记日志后结束进程（窗口随进程消失），绝不留下一块撤不掉、又吞键鼠的遮罩。
- 标准 / 严格档都保留「长按 3 秒跳过」作为逃生口。
- 先用临时探针验证：nonactivating 面板成为 key 时 App 不被激活、撤下后前台 App 不变（见 §9）。

### 5.6 结束前确认本人（2026-11-08）

用户提出的问题：5 分钟的休息画面到点自动撤掉，如果人已经离开电脑，屏幕就等于解锁了。要求"必须确认是我本人到了电脑旁边"。

遮罩不能靠一直不撤来当锁用，因为 §5.5 的保护保证它永远撤得掉。所以由真正的身份验证来确认本人，由系统锁屏兜底。

只对标准、严格档生效，由 `focus.confirmIdentity` 控制，默认开。预览也走这套流程。

流程：
1. 倒计时走完，或长按跳过：不立刻撤，进入 `confirming` 阶段。
   - 卡片换成"休息结束 / 跳过休息，确认是你本人"，加 Touch ID 图标和"N 秒内没人确认就锁屏"，跳过按钮去掉。
   - 层级不动，暗幕 1000、舞台 1001。点暗处时把舞台重新放到最前、拿回焦点，嵌在卡片里的指纹验证不会被打断。
   - 第一版为了给系统对话框让位，把两层都降到 999。结果同层里谁被点谁排最前：点一下暗幕，暗幕就盖到宠物和卡片上面，指纹也不响应了（2026-11-08 用户反馈）。
2. 指纹验证嵌在卡片里：`LAAuthenticationView`（LocalAuthenticationEmbeddedUI，macOS 12+）绑一个 `LAContext`，`evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`。
   - 不弹系统对话框，Baobox 一直在前台，展示模式不断（§5.7）。
   - 2026-11-08 第一版用系统对话框（`.deviceOwnerAuthentication`）：对话框属于另一个进程，弹出时 Baobox 不在前台，展示模式失效，确认阶段还能三指滑切桌面（用户截图反馈）。
   - 先把 context 交给卡片挂好视图，0.3 秒后再开始验证。
   - 取消或失败，1 秒后再验，直到确认成功或 30 秒到点。
   - 嵌入式只支持指纹。没有 Touch ID、没录指纹、连错被系统锁住（`biometryLockout`）时直接锁屏，用密码从系统锁屏界面回来，同样算确认本人。
3. 确认成功：照常收尾，宠物飞回、撤遮罩，结果仍是完成或跳过。
4. 30 秒没人确认：收起对话框，用 `ScreenLock.lockNow()` 替用户按 ⌃⌘Q（CGEvent 发到 HID 层，要辅助功能权限，Baobox 本来就有），1.5 秒后用 `CGSessionCopyCurrentDictionary` 的 `CGSSessionScreenIsLocked` 确认锁上了，再撤遮罩。
   - 没锁上：记 error 日志，发一条"休息结束时没能锁屏"提醒，遮罩照样撤。
5. 没法用指纹验证（`canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` 失败）：按"没人确认"处理，锁屏。
6. 截止看门狗从进入确认阶段起重新计 55 秒，遮罩到点一定撤。

**所有撤遮罩的路都收口**（用户 2026-11-08："只要是全屏遮罩，都需要指纹确认才能取消"）：

| 路径 | 处理 |
|---|---|
| 外面要撤（菜单"结束休息" `endCycle`、开始专注 `startFocus`） | 只能用 `BreakStageController.end(_:)`，和到点、跳过一样先确认。`finish(_:)` 改为 private |
| 退出 App、截止看门狗（`forceTeardown`） | 不能卡着不撤（那会把电脑锁死），还没确认过的先锁屏再撤 |
| 主线程卡死看门狗 | 结束进程前，在后台线程先发 ⌃⌘Q，等 0.3 秒再 `abort()` |

用 `identitySettled` 记这一场是否已经确认过或已经锁过屏。轻松档"现在休息"的 gentle 画面不是全屏遮罩，不用确认。

2026-11-08 探针结论（会话 scratchpad 里的 `lockprobe`）：
- 系统的 Touch ID 对话框归 `coreautha` 进程，窗口层级 1000，和暗幕同层，排在它上面，但比舞台（1001）低。指纹验证本身不受遮挡影响，探针里 2 秒就通过了。这条只对第一版系统对话框方案有意义，现在指纹嵌在卡片里。
- macOS 14 已经没有 `CGSession -suspend`。
- 用户的"熄屏后多久要密码"是 14400 秒（4 小时），靠熄屏或屏保锁屏不安全。
- 从终端跑的探针没有辅助功能权限（`AXIsProcessTrusted=false`），模拟的 ⌃⌘Q 被丢掉了。锁屏这一步要在 Baobox 自己的权限下验证，见 §9。
- 不用私有的 `SACLockScreenImmediate`。

### 5.7 全屏遮罩在场时挡住切桌面（2026-11-08）

用户反馈：倒计时界面上还能三指左右滑切换桌面，会先露出别的桌面的窗口内容，然后才被倒计时盖住。

原因是遮罩虽然设成在所有桌面都显示，但切换桌面的滑动动画里系统不画它。

做法：全屏遮罩在场时（标准、严格档），Baobox 切到前台并开启展示模式 `NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]`。切桌面和调度中心归 Dock 管，Dock 被隐藏时一起被禁用。

细节：
- 展示模式只在前台生效：监听 `didResignActive`，一被切走就立刻 `activate` 并重新开启。
- 确认阶段照样抢回前台：指纹验证嵌在自己的卡片里，没有系统对话框要焦点。探针 `embedprobe` 实测，等指纹时被 ⌘Tab 或滑动切走后立刻切回，没有切换桌面，指纹照常通过，屏幕上没有出现 coreautha 窗口。
- 撤遮罩时关掉展示模式，`cleanup` 原有逻辑把焦点还给休息前的前台 App。
- 不禁强制退出（⌘⌥Esc）和关机、注销，留作逃生口。Baobox 崩溃时系统会自动解除展示模式。

探针（会话 scratchpad 的 `kioskprobe`，用户配合）：
- 对照阶段：8 秒内滑切 2 次桌面，都切成了。
- 展示模式阶段：用户反复滑动、按 ⌘Tab，14 秒内一次桌面都没切成，没有 `activeSpaceDidChange`。期间别的 App 被短暂激活又被切回，它们的窗口始终在遮罩下面。
- 第一次探针没有"被切走就切回"，激活后 0.1 秒就被滑动带离前台，展示模式随之失效。

## 6. 通知内核与宠物的改动（DesktopPet）

- `NotifyDND` 新增 `reasons(ignoringTokens:)`：安静 / 令牌 / 前台全屏 / 麦克风占用。`isSuppressed` 语义不变（令牌、安静、全屏）。
  - 麦克风占用只进 `reasons` 给本工具避让用，不改变宠物与其他通知的现有行为（Baobox 自己的实时翻译也会占用麦克风，分不清是谁在用）。
  - 麦克风状态在后台队列读 CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`，每 5 秒刷新一次缓存，不在主线程直接调 HAL。
- 录屏：`RecordingController` 开始 / 停止录制时挂 / 摘 `recording` 令牌——录屏期间宠物气泡不出来（免得被录进视频），本工具的提醒也顺延。用户刚点的操作的回执（`isUserFeedback`，如暂停专注的卡片）除外，照常出来。
- `PetController.act(clips:)`：按片段名播一串动作，不冒话（喝水 `sit_down → sit_hold_drink → stand_up`，站立 `stretch`）；形象没有这些片段返回 false。`PetModelView.performClips(_:)` 为其底层。
- 环形菜单外圈加「专注」（快捷键 id `focushealth.focus`）；宠物设置的逐来源开关加「专注与健康」（来源 id `focus`）。
  - 2026-11-08：`focushealth.focus` 带 `stateTitle`（专注中「暂停专注」、暂停中「继续专注」）。`pauseFocus` 发 bubble 级卡片 [继续][结束这一轮]，「结束」= `endFocusEarly(countAsDone: true)`；`resumeFocus`、`breakNow` 被拒（专注中 / 休息中）发 ambient 回执。这些都标 `isUserFeedback`，勿扰（含专注自己的令牌）时照常出来；提前结束算完成后的「第 N 轮专注完成」卡片同样标上（`finishFocus(byUser:)`）。
- `PetEngine` 的空闲秒数改用 `Core/UserActivity`，两处共用一份。

## 7. 菜单栏倒计时

模块自己持有一个 `NSStatusItem(variableLength)`，只在专注 / 暂停 / 休息时存在。标题 `MM:SS`（等宽数字），图标随阶段（`timer` / `pause.circle` / `cup.and.saucer`）；菜单打开时现建（委托回调照 `StatusItemController` 的写法：nonisolated + 主线程校验）。

## 8. 持久化

- `items.json`：提醒项数组。解析容错——字段缺失用默认值，枚举值不认识用默认值；整个文件坏了回落预置，并把坏文件改名 `.bad` 留底。
- `state.json`：专注会话、各项进度、暂停状态。有变化时最多 30 秒写一次，睡眠前与退出时同步写。
- 标量设置走 UserDefaults，前缀 `focus.`。

## 9. 验证

- 纯逻辑：`FocusHealthModels` / `ReminderScheduler` 不依赖 AppKit，用临时测试程序直接编译运行：累加、离开重置、看视频不算离开、固定时刻、工作时间、推迟、预告只发一次、撞车判定、专注轮次与长短休息、坏 JSON 容错。
- 探针：独立小程序验证舞台窗（nonactivating + key）不激活 App、撤下后前台 App 不变，几秒后自动退出。
- 构建：`xcodebuild -scheme Baobox build`；新增的本地化 key 全部入表（脚本核对）。
- 真机（用户）：三档强度、多屏、全屏 App 下避让、录屏避让、开会（麦克风）避让、睡眠唤醒、App 重启接着计、宠物关闭时的回退画面。

## 10. 不在本版

统计（今日 / 本周休息与专注）、语音提醒与自定义提示音、浮动间隔、逐项强度、#42 会议状态接入（届时会议模块挂 `meeting` 令牌即可，本工具不用改）。
