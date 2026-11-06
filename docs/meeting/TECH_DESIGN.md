# 会议 · 技术设计

需求见 `REQUIREMENTS.md`。代码新模块 `mac/Sources/Modules/Meeting/`，并改造 `Modules/LiveTranslate/` 成可配置的会话引擎。**实时翻译单独使用时的行为必须与改造前一致**（用户每天在用；回归是第一风险）。

## 0. 约定与踩过的坑（写代码前必读）

- 模块 id `meeting`，通知来源 `meeting`，本地化前缀 `meeting.*`，UserDefaults 前缀 `meeting.*`，数据目录 `~/Library/Application Support/Baobox/Meetings/`。
- 通知一律 `NotifyCenter.shared.post(PetNotification(...))`（宠物模块决定怎么呈现）；不碰 `UNUserNotificationCenter`。勿扰用 `NotifyDND.shared.setSuppressed(_:token:)`，记录中挂 `meeting`。
- 浮窗不抢焦点：borderless + `.nonactivatingPanel`，`hidesOnDeactivate = false`，`orderFrontRegardless()`，不 `NSApp.activate`。**不要在设置 `level` 之后设 `isFloatingPanel`**（它的 setter 会把 level 改回 `.floating`）。需要输入（速记）时面板 `canBecomeKey = true` 但仍 nonactivating。
- 往窗口里加视图时用手上那个窗口变量，别用还没赋值的可选属性（`stageWindow?.contentView` 挂空的教训）。
- 拿注册表用 `AppDelegate.shared?.registry`（`NSApp.delegate as? AppDelegate` 在 SwiftUI 入口下永远是 nil）。
- 并发：UI / `@Published` 只在主线程写；Timer 用 `Timer(timeInterval:repeats:)` + `RunLoop.main.add(_, forMode: .common)`，闭包里 `MainActor.assumeIsolated`；重 IO 走后台串行队列。解析外部文件全程容错，无 force-unwrap / `try!`。
- 新增 `L()` / `Text()` key 必须 en + zh-Hans 两条，紧凑单行 JSON 追加进 `Localizable.xcstrings`，JSON 要合法。

## 1. 麦克风占用登记（已在基线提交里实现）

`Core/AudioCaptureCoordinator.swift`：`claim(owner:label:microphone:) -> Bool`、`release(owner:)`、`current`、`isBaoboxUsingMicrophone`。实时翻译引擎每次开会话时 claim（owner = 会话的 owner：`livetranslate` / `meeting`），结束时 release；听写同理（owner `dictation`）。会议检测用 `isBaoboxUsingMicrophone` 排除自己。

## 2. 引擎改造（LiveTranslate）

### 2.1 会话配置

新增 `LiveTranslateSessionConfig`（值类型）：

| 字段 | 说明 |
|---|---|
| `owner` / `label` | 占用登记用（`livetranslate` /「实时翻译」；`meeting` /「会议记录」） |
| `sources` | `.microphone` / `.system` / `.mixed`（麦克风 + 系统声音混一路） |
| `language` | 默认取实时翻译设置；会议可覆盖 |
| `translate` | 是否翻译（会议默认 false） |
| `showsBar` | 是否显示字幕条（会议默认 false；控制条「字幕」开关运行中切换） |
| `correction` | AI 纠错（与翻译解耦：`correction && 纠错模型就绪 && 中文`） |
| `transcript` | 转录去向：`nil` = 不记 / 实时翻译旧行为；会议给定目录 + 头信息 + 是否标说话人 |
| `onFinalLine` | 回调（时间、原文、译文、说话人）—— 会议会话据此维护行动项上下文、标记等 |

- `start()` 等价于 `start(config: .fromSettings())`：读的仍是原来那些 `livetranslate.*` 设置，行为不变。
- `start(config:)` 内把直接读全局设置的地方都改成读 config。
- **字幕条可选**：`showsBar == false` 时不建字幕条；系统翻译（`TranslationSession` 挂在字幕条视图上）此时不可用 → 会议想看译文就打开字幕条（同实时翻译）。运行中 `setBarVisible(_:)` 切换。
- **结束时冲刷最后一句**：识别器 `stop()` 现在直接取消、丢掉最后一句未定稿的内容。新增 `finish() async`：先停音频 → `endAudio()` → 等最后一个 final（最多 1.5 s）→ 再停。会议结束、听写结束都走 `finish`；实时翻译的 ✕ 仍走原来的 `stop`（行为不变）。

### 2.2 混合音源与说话人

新增 `LiveTranslateMixedSource`：同时开麦克风（`AVAudioEngine`）与系统声音（`SCStream`，同现有 `LiveTranslateSystemSource` 的配置），两路各转成 16 kHz 单声道 Float32，进各自的环形缓冲；一个 20 ms 的混音节拍从两路各取等长一块（缺的补零）相加（限幅）后送进 router。两路的时钟各走各的，环形缓冲容忍 ±200 ms，超了丢旧数据。

- 每块同时记下两路 RMS；识别单元（同一个 sentence id）开始到定稿期间累计两路能量。定稿时判说话人：系统声音能量显著（> 阈值）→「对方」；否则麦克风能量显著 →「我」；都弱 → 不标。外放回声会让麦克风也收进对方声音，所以「系统声音显著」优先判「对方」。
- 设备端识别同一时间只能跑一个请求，所以两路必须混成一路进**一个**识别器，不能两路各开一个。

### 2.3 转录与纪要

- `LiveTranslateTranscript` 支持：指定目录与文件名、头信息（标题、类型、时间、参会人、日历）、每行可选说话人（`**10:32:05 我**`）、🔖 标记行、速记段。实时翻译自己（自由听译）的新记录也写进会议库（见 §4），旧目录设置保留但只用于迁移。
- `LiveTranslateMinutes.generate(lines:chinese:template:)`：模板 `.content`（自由听译：要点 / 结论 / 待办，即现状）、`.meeting(.standard / .standup / .oneOnOne / .interview)`。会议模板的输出格式固定：
  ```
  ## 摘要
  ## 决议
  ## 行动项
  - [ ] 负责人：事项（截止：…）
  ## 重点
  ```
  标记重点的段落在输入里加「【重点】」前缀加权；速记作为「会议速记」上下文附在输入前。行动项按 `- [ ] ` 行宽松解析（负责人 / 截止缺失照样收）。

## 3. 会议会话（Meeting 模块）

- `MeetingSessionController`：`start(type:event:)` → 组 config → `LiveTranslateController.shared.start(config:)`；claim 失败（听写 / 实时翻译在用）→ 宠物提示。记录中：挂 `meeting` 勿扰、菜单栏录音指示、控制条、超时检查（绑定日历事件时）。`pause/resume`（暂停 = 停喂音频，不停会话）、`mark()`、`notes`、`setSubtitles(_:)`、`finish()` → 引擎 `finish` → 写 `meta.json` → 生成纪要（后台，状态 `summarizing`）→ 完成后更新 meta + 索引 + 通知。
- **控制条** `MeetingControlBar`：nonactivating 面板，`.statusBar` 级，可拖动（记住位置），速记展开时可成为 key（输入用），收起后交还焦点。
- **合规说明**：首次开始记录弹一次（宠物常驻气泡，[我已告知][取消]）。

## 4. 会议库

- 目录：`Meetings/<yyyy>/<yyyy-MM-dd HH-mm> <标题>/meeting.md` + `meta.json`；根目录 `index.json`（摘要数组，启动时若缺失 / 损坏就扫目录重建）；`weekly/<yyyy-Www>.md`。
- `meta.json`（解析容错，字段缺失用默认）：
  ```json
  {"v":1,"id":"…","type":"online|offline|free","title":"…","start":"ISO8601","end":"ISO8601",
   "attendees":["…"],"calendar":{"eventID":"…","seriesKey":"…","calendar":"…"},
   "status":"recording|transcribed|summarizing|summarized|failed","template":"standard",
   "highlights":[{"t":123.4,"text":"…"}],
   "actionItems":[{"id":"…","text":"…","owner":"…","due":"…","done":false}],
   "legacyPath":null}
  ```
- **系列键**：重复事件用 `EKEvent.calendarItemExternalIdentifier`；非重复按「规范化标题」（去日期、编号）。
- `MeetingLibrary`（主线程模型 + 后台读写）：列表、搜索（标题 / 参会人 / 纪要全文，后台加载）、筛选、行动项勾选（写回 meta）、删除（移到废纸篓）、导出（NSSavePanel）、重新生成纪要。
- **迁移**：首次启动扫 `livetranslate.record.folder` 的 `*.md`，按引用加入索引（`type: free`、`legacyPath` 指向原文件），只做一次（`meeting.migratedLegacy`）。

## 5. 日历、提醒、检测

- `MeetingCalendar`：`EKEventStore`，macOS 14 `requestFullAccessToEvents`（首次在设置里打开日历时申请）；`project.yml` 加 `NSCalendarsFullAccessUsageDescription` 与 entitlement `com.apple.security.personal-information.calendars`（Hardened Runtime 下缺 entitlement 会直接拒）。监听 `.EKEventStoreChanged` + 60 秒刷新；缓存未来 24 小时事件（菜单构建零 IO）。
- `MeetingLinkParser`（纯函数，可单测）：从 URL / 地点 / 备注里找 Zoom（`zoom.us/j/`、`zoommtg://`）、腾讯会议（`meeting.tencent.com/dm/`、`wemeet://`）、钉钉（`dingtalk.com/…/meeting`、`dingtalk://`）、Google Meet（`meet.google.com/`）、Teams（`teams.microsoft.com/l/meetup-join`）、飞书（`vc.feishu.cn/j/`、`meetings.feishu.cn`）、Webex（`webex.com/`）。
- `MeetingReminder`：每 30 秒看下一场；到提前量发常驻气泡（同一事件只提醒一次）；暂停（1 小时 / 今天 / 直到明天）。
- `MeetingDetector`：每 5 秒：会议 App 在运行（bundle id 表：`us.zoom.xos`、`com.tencent.meeting`、`com.alibaba.DingTalkMac`、`com.microsoft.teams2`、`com.microsoft.teams`、`com.electron.lark`、`com.bytedance.feishu`、`com.cisco.webexmeetingsapp`、`com.apple.FaceTime`、`com.tencent.xinWeChat`、`com.tinyspeck.slackmacgap`）且 `NotifyDND.microphoneInUse` 且 `!AudioCaptureCoordinator.isBaoboxUsingMicrophone`，持续 ≥ 10 秒 → 问一次（同 App 同一段占用不重复问）；日历事件已开始且带链接、没在记录 → 问一次。

## 6. 界面

- 会议库窗口、行动项视图、会前简报窗、系列时间线、周报：SwiftUI，普通窗口（会 `NSApp.activate`，同设置窗口），一个 `MeetingWindowController` 管。
- 设置 Tab `meeting`：§6 需求的分组；「字幕与同传」分组直接嵌原 `LiveTranslateSettingsView`（及朗读设置）。
- 菜单栏：记录中录音指示；可选下一场倒计时（`meeting.menuBarCountdown`，默认关）。

## 7. 菜单迁移

- `LiveTranslateTool` 改名「字幕与同传」，菜单第一行「已并入「会议」」（置灰），其余不变；`livetranslate.toggle` 快捷键 id 不变，在会议菜单里显示为「开始自由听译」。
- 会议模块注册在原实时翻译的位置之前（菜单顺序 = 注册顺序）。

## 8. 验证

- 纯逻辑单测（脱离 App 编译，`swiftc` 直接跑）：链接解析、系列键、行动项解析、meta 容错解码、说话人判定（给定两路能量序列）、混音（两路不同长度 / 抖动）。
- 构建：`xcodebuild -scheme Baobox build` 无新增警告；本地化全部入表。
- 回归：实时翻译单独使用（默认设置）走 `start(config: .fromSettings())`，代码路径对比改造前；字幕条、记录开关、朗读都要能用。
- 不要在用户机器上运行 App 或弹会挡住屏幕、拦截输入的窗口；界面用离屏渲染（`cacheDisplay` 出 PNG）核对。安装与真机验证由主会话做。

## 9. 第一段落地记录（2026-11-06）

第一段 = 引擎改造 + 会议记录 + 纪要模板 + 会议库存储（§2–§4 与 §3 的控制条 / 录音指示 / 合规 / 超时）；日历、提醒、检测、会议库窗口与菜单改名在第二段。实现时定下的细节：

- **实时翻译回归**：`start()` = `start(config: .fromSettings())`；`followsSettings` 的会话在 `startFlow` 里仍在原来的时刻现读音源 / 语言（开头）与翻译 / 纠错开关（权限问完之后）。字幕条、记录按钮、✕、朗读、`toggle` 对实时翻译一律走原路；只有托管会话（`onUserRequest` 非 nil）才改道。改动的旧路径都是「多一个分支、实时翻译走 else」。
- **纠错与翻译解耦**：`Correction.always`（会议）/ `.whenTranslating`（实时翻译原样）；按单元处理的条件从「字幕条在翻译」改成 `sessionEngine != nil || correcting`，对实时翻译两者等价。不翻译时 `target(forLine:)` 一律 nil，翻译队列不会堆。
- **运行中开字幕**（会议）：不重启识别链路，只在原地起 / 停翻译（离线循环、系统翻译跟着新建的字幕条走、朗读）；收起 = 翻译一并停，已翻好的留在记录里。线上会议的混音里有对方的声音，朗读不送会议、外放时照样暂停识别防回授。
- **混音**：两路复用原来的 `LiveTranslateMicSource` / `LiveTranslateSystemAudioSource`（各接一个私有路由），转 16 kHz 后进环形缓冲；每路先攒 200 ms 抖动缓冲（麦克风一次给 100 ms 时也有余量；第一次攒够时把多攒的修掉），积压超过 200 + 200 ms 丢最早的，取空补零并重新攒；节拍按真实时间算该发几块（定时器晚了补块，最多补 200 ms）。停止时把缓冲里剩下的混完再送。线下会议也走混音链路（只有麦克风一路），为了电平。
- **说话人**：一句的期间 = 上一句定稿 → 这一句定稿（识别单元一个接一个）；「显著」= 有人声（RMS > 0.01）累计 ≥ 0.3 秒，系统声音还要 ≥ 麦克风的 35%（对方插一声「嗯」不翻转整句）。纯函数 `LiveTranslateSpeakerJudge`。
- **结束冲刷**：识别器协议加 `flush()`（默认不等）：旧引擎 / 双识别器 / 轮流识别器按切段交接的办法 endAudio、等 final、不再开新段（轮流识别器收尾时不再重认）；新引擎 `finalizeAndFinishThroughEndOfInput()` 后等结果流走完。`finish()` 限时 1.5 秒，到点 `stop()`（`stop` 也会放行 `flush`）。
- **记录**：`LiveTranslateTranscript.Destination`（文件、头信息、说话人、模板、事件回调）。自由听译的新记录进会议库 `「yyyy-MM-dd HH-mm 自由听译」/meeting.md`，版式与通知照旧，记下第一句才登记进索引；没装会议模块时写回原文件夹。会议的 meeting.md：头信息 + 纪要 + 速记 + 转录（`**10:32:05 我** 原文`、`🔖 **时间** 标记重点`、暂停 / 继续说明行）。🔖 的「重点」= 标记前 20 秒、后 5 秒内开始的句子。
- **纪要**：会议模板的提示里只给占位格式（`- [ ] 负责人：事项（截止：…）`），解析时把照抄的占位丢掉；速记最多占 400 token 预算。meta.json 的 `template` 存 `standard / standup / oneOnOne / interview / content`。
- **会议库**：`MeetingStore` 主线程模型（`records` = index.json 的内存副本）+ 后台串行写盘；启动读索引，缺失 / 损坏扫目录重建，否则与磁盘对账；上次没收尾的 `recording / summarizing` 改成 `transcribed`。一句没记下的会议直接作废（不进废纸篓）；删除进废纸篓（迁移来的旧记录连原文件）。保留时长只在启动时清理。迁移只在用过「保存记录」或改过保存位置时才去读旧文件夹（免得首次启动就弹「文稿」授权框），两种语言的默认文件夹名都看。
- **控制条**：尺寸由「新建一个不进窗口的宿主视图量当前状态」得到，状态变了下一拍重量、上边不动往下长（窗口里的宿主视图 `sizingOptions = []`）；计时按「0:00:00」占位，过一小时宽度不变。
- **勿扰下的提示**：记录中挂着 `meeting` 令牌，普通提示会被攒起来，所以会中的轻提示（已在记录、超时）用 alert 级 + toast 样式；会后的「纪要已生成」晚一拍再发（等令牌撤掉）。

文件：`Modules/LiveTranslate/` 新增 `LiveTranslateSessionConfig`、`LiveTranslateMixedSource`、`LiveTranslateMixing`（纯）、`LiveTranslateMinutesFormat`（纯）；`Modules/Meeting/`：`MeetingTool`（模块壳 + 菜单）、`MeetingSessionController`、`MeetingStore`、`MeetingModels`（纯）、`MeetingLibraryFiles`（纯）、`MeetingControlBar`、`MeetingStatusItem`、`MeetingSettings`、`MeetingSettingsView`、`MeetingText`。
