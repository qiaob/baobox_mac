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
5. 发：
   - 休息画面项取休息时长最长的一项；若有更长的休息画面项 10 分钟内到点，本项直接算完成（撞车吞并）；同跳到点的宠物提醒项并进文案；顺延超过 45 分钟的降级为卡片；
   - 宠物提醒项按同一跳合并成一张卡片。

`.warn`（休息画面项到点前 60 秒）同样过 1–4，能发就发预告卡片（与同一跳的宠物提醒卡片一起发），发不了就跳过。

回应：

- 卡片发出即 `reset`；[推迟 10 分钟] → `snooze(600)`；气泡自己消失没有回调 = 错过。
- 休息画面（标准 / 严格）：完成 → 重置全部「离开算完成」项；跳过 → 只重置本项；不能推迟。
- 轻松档的休息气泡：发出即 `rearm`（重新计时、保留本轮推迟次数）；[好的] 按完成处理；[推迟 5 分钟] → `snooze(300)`、推迟次数 +1，达到上限不再给推迟按钮；没点 = 错过。
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

模糊：暗幕里放 `NSVisualEffectView`（`.behindWindow` + `.fullScreenUI` + 深色外观 + `state = .active`，App 不在前台也保持模糊），上面再压一层 30% 黑；系统开了「减少透明度」时自动退成不透明底。暗幕 `hitTest` 一律返回自己，点在模糊层上也能「戳宠物」。

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

## 6. 通知内核与宠物的改动（DesktopPet）

- `NotifyDND` 新增 `reasons(ignoringTokens:)`：安静 / 令牌 / 前台全屏 / 麦克风占用。`isSuppressed` 语义不变（令牌、安静、全屏）。
  - 麦克风占用只进 `reasons` 给本工具避让用，不改变宠物与其他通知的现有行为（Baobox 自己的实时翻译也会占用麦克风，分不清是谁在用）。
  - 麦克风状态在后台队列读 CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`，每 5 秒刷新一次缓存，不在主线程直接调 HAL。
- 录屏：`RecordingController` 开始 / 停止录制时挂 / 摘 `recording` 令牌——录屏期间宠物气泡不出来（免得被录进视频），本工具的提醒也顺延。
- `PetController.act(clips:)`：按片段名播一串动作，不冒话（喝水 `sit_down → sit_hold_drink → stand_up`，站立 `stretch`）；形象没有这些片段返回 false。`PetModelView.performClips(_:)` 为其底层。
- 环形菜单外圈加「专注」（快捷键 id `focushealth.focus`）；宠物设置的逐来源开关加「专注与健康」（来源 id `focus`）。
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
