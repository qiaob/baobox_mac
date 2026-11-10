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
| `speakers` / `documentURL` | 会议：每句判不判「我 / 对方」；字幕条「打开本次记录」打开哪个文件。#107 PR3 之前这里是 `transcript`（会议的转录去向，引擎替会议写 meeting.md），之后引擎不碰会议的文档（§2.3） |
| `onFinalLine` | 回调（时间、原文、译文、说话人）—— 会议会话据此写自己的 meeting.md、算标记重点等 |

- `start()` 等价于 `start(config: .fromSettings())`：读的仍是原来那些 `livetranslate.*` 设置，行为不变。
- `start(config:)` 内把直接读全局设置的地方都改成读 config。
- **字幕条可选**：`showsBar == false` 时不建字幕条；系统翻译（`TranslationSession` 挂在字幕条视图上）此时不可用 → 会议想看译文就打开字幕条（同实时翻译）。运行中 `setBarVisible(_:)` 切换。
- **结束时冲刷最后一句**：识别器 `stop()` 现在直接取消、丢掉最后一句未定稿的内容。新增 `finish() async`：先停音频 → `endAudio()` → 等最后一个 final（最多 1.5 s）→ 再停。会议结束、听写结束都走 `finish`；实时翻译的 ✕ 仍走原来的 `stop`（行为不变）。

### 2.2 混合音源与说话人

新增 `LiveTranslateMixedSource`：同时开麦克风（`AVAudioEngine`）与系统声音（`SCStream`，同现有 `LiveTranslateSystemSource` 的配置），两路各转成 16 kHz 单声道 Float32，进各自的环形缓冲；一个 20 ms 的混音节拍从两路各取等长一块（缺的补零）相加（限幅）后送进 router。两路的时钟各走各的，环形缓冲容忍 ±200 ms，超了丢旧数据。

- 每块同时记下两路 RMS；识别单元（同一个 sentence id）开始到定稿期间累计两路能量。定稿时判说话人：系统声音能量显著（> 阈值）→「对方」；否则麦克风能量显著 →「我」；都弱 → 不标。外放回声会让麦克风也收进对方声音，所以「系统声音显著」优先判「对方」。
- 设备端识别同一时间只能跑一个请求，所以两路必须混成一路进**一个**识别器，不能两路各开一个。

### 2.3 转录与纪要

> **谁驱动会议的 meeting.md**（2026-11，#107 PR3，详见 `ENGINE.md` §4.5）：会议会话自己驱动。引擎的托管会话只报「开起来（带这次怎么跑的 `MeetingEngineRun`）/ 一句 / 结束」，
> 不建、不写会议的文档；`MeetingSessionController` 在第一次开起来时用 `LiveTranslateTranscript` 建文档，句子、暂停 / 继续、单路静音、🔖、速记直接写，
> 改设置重启时续写同一份，`.ended` 里收尾。退出时还在整理的纪要（会议的、自由听译的）由 `LiveTranslateTranscript.abortAllMinutes()` 统一标「没整理完」。
> 写文档的类这一步还在 `Modules/LiveTranslate/`，下一步（PR4）搬进会议；下面的版式与纪要规则不变。

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
- **本场的 meeting.md 归会话**（#107 PR3，`ENGINE.md` §4.5.2、§4.5.5）：第一次 `.started` 时建（开始中写的速记、开起来之前就定稿的句子一并写进去；引擎没开起来就没有文档，这场作废）；
  暂停 / 继续、单路静音、🔖、速记调完引擎就直接写；`.ended` 里先收尾文档（它同步报回的 `.finished` 写 meta 或作废）再撤勿扰、收控制条、复位。
  App 退出：先置 `terminating` 再让引擎停，引擎在返回前把剩下的句子和 `.ended` 同步报回来；没报 `.ended`（比如正因为改设置在重启）就自己收尾。
  `MeetingTool.willTerminate` 的顺序是显式的四步：会话 `terminate()` → 引擎 `terminate()`（自由听译）→ `LiveTranslateTranscript.abortAllMinutes()` → `MeetingStore.shared.flush()`。
- **控制条** `MeetingControlBar`：nonactivating 面板，`.statusBar` 级，速记展开时可成为 key（输入用），收起后交还焦点。经 Core 的 `AccessoryDock` 找挂靠点，不认识宠物（#108）：宠物在（开着、显示着、没借给休息画面、不在出场退场途中）时挂成宠物窗的子窗口，贴在宠物头顶，跟着宠物走，自己不能拖；宠物关着、中途被关掉或借出、宠物模块没注册时回到屏幕顶部居中，可拖动（记住位置）。
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
- `MeetingDetector`：麦克风一被占用就采样（`MeetingMicListener`），有人在用时每秒、平时每 5 秒：每个会议 App（bundle id 表见 `MeetingDetectionApps`）单独判断是否正在开会 —— 它开会时才起的进程开着（`meetingProcesses`，如钉钉的 Tblive），或 `MeetingMicrophoneProbe` 按进程查出它在用麦克风；满足持续时间就问一次（同一场不重复问）；日历事件已开始且带链接、没在记录 → 问一次。详见 §10「会议检测」。

## 6. 界面

- 会议库窗口、行动项视图、会前简报窗、系列时间线、周报：SwiftUI，普通窗口（会 `NSApp.activate`，同设置窗口），一个 `MeetingWindowController` 管。
- 设置 Tab `meeting`：§6 需求的分组；「字幕与同传」分组直接嵌原 `LiveTranslateSettingsView`（及朗读设置）。
- 菜单栏：记录中录音指示；可选下一场倒计时（`meeting.menuBarCountdown`，默认关）。

## 7. 菜单迁移

- `LiveTranslateTool` 改名「字幕与同传」，菜单第一行「已并入「会议」」（置灰），其余不变；`livetranslate.toggle` 快捷键 id 不变，在会议菜单里显示为「开始自由听译」。
- 会议模块注册在原实时翻译的位置之前（菜单顺序 = 注册顺序）。
- **2026-11-10 删掉独立入口（#106）**：`LiveTranslateTool` 不再注册（文件删除），菜单里只剩会议的「开始自由听译」，
  设置只剩会议页嵌入的「字幕与同传」（`LiveTranslateSettingsSections`，独立设置页删除）。`livetranslate.toggle`
  快捷键改由 `MeetingTool.hotkeys()` 声明，id、标题、环形菜单的「翻译」都不变，已绑的键照常生效；
  退出时 `MeetingTool.willTerminate` 也调 `LiveTranslateController.terminate()`，给会议之外的自由听译收尾
  （推理进程照旧由 `AppDelegate` 的 `OfflineTranslator.shutdownAll()` 结束）。听写设置里「编辑术语表」改跳会议页。

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
- **单路静音**（2026-11-06 用户要求：有时想不录自己的声音，或只录自己）：控制条的麦克风 / 喇叭图标是开关。`LiveTranslateController.setLaneMuted(_:lane:)` → 混音器 `LiveTranslateMixerCore.setMuted`：被点掉的那一路照样按时长送一段静音进去（两路仍对齐、不算断流），电平随之为 0，「我 / 对方」按电平判也就跟着对；状态跟暂停一样存在引擎里、跨「改设置引起的重启」保留，新会话清零；记录里记一行（`livetranslate.record.doc.micMuted` 等）。只是 Baobox 不录，不碰会议软件的麦克风。
- **控制条挂在宠物头顶**（2026-11-06 真机反馈后改）：Chrome 全屏开 Google Meet，从宠物气泡点「开始记录」后控制条出在屏幕顶上，用户没看见，以为没开始 —— 控制条要出在用户刚点的地方。挂件接口原在宠物模块（`dockAccessory` / `undockAccessory` / `refreshAccessory(size:)`），#108 起控制条改调 Core 的 `AccessoryDock.dock` / `undock` / `refresh(_:size:)`，宠物实现 `AccessoryHost` 转给这组方法（docs/notify-core/DESIGN.md §3.4）。一次挂一个：贴在宠物窗高度 86% 处（同气泡尾巴）往上 4 pt，与宠物居中对齐，左右挪进屏内；头顶放不下就放到脚下。气泡排在挂件外侧（`BubbleController.accessoryClearance`）。挂上、摘下（宠物开关、借出归还）都回调，先回调再挂，控制条据此停掉拖动和记位置。会中宠物按勿扰原地打盹不溜达，挂件只在被拖、跟着窗口挪、掉下来时动；挂着时速记展开往上长（宠物按新尺寸重新贴位）。收起速记时 orderOut 会把子窗口摘下来，之后重新挂回。
- **屏幕顶部的位置要让开刘海**：全屏 App 里菜单栏收起，visibleFrame 顶到屏幕边；带刘海的屏顶上那条（`safeAreaInsets.top`，这台 32 pt）是黑的，旧位置（visibleFrame 顶下 12 pt）让黑底控制条半截落进黑带、中间被刘海挡住。现在让开「菜单栏 / safeAreaInsets / 菜单栏厚度」三者里最大的那个，记住的位置也往下拉出这条。
- **勿扰下的提示**：记录中挂着 `meeting` 令牌，普通提示会被攒起来，所以会中的轻提示（已在记录、超时）用 alert 级 + toast 样式；会后的「纪要已生成」晚一拍再发（等令牌撤掉）。

文件：`Modules/LiveTranslate/` 新增 `LiveTranslateSessionConfig`、`LiveTranslateMixedSource`、`LiveTranslateMixing`（纯）、`LiveTranslateMinutesFormat`（纯）；`Modules/Meeting/`：`MeetingTool`（模块壳 + 菜单）、`MeetingSessionController`、`MeetingStore`、`MeetingModels`（纯）、`MeetingLibraryFiles`（纯）、`MeetingControlBar`、`MeetingStatusItem`、`MeetingSettings`、`MeetingSettingsView`、`MeetingText`。

## 10. 第二段落地记录（2026-11-06）

第二段 = 日历、链接解析、会前提醒、会议检测、会议库窗口（行动项 / 会前简报 / 系列时间线 / 周报）、设备自检、完整设置与菜单、菜单迁移。#42 至此全部落地。实现时定下的细节：

- **日历**（`MeetingCalendar`）：「读取日历」默认关，打开时才 `requestFullAccessToEvents`（授权后换一个新的 `EKEventStore`，授权前建的读不到日历）；没打开不碰 EventKit。多选存的是「不读的日历」，新加的日历默认也读。查询窗口 = 现在往前 6 小时到往后 24 小时（含正在进行的长会），去掉全天事件（节假日、生日）、已取消、我已拒绝、已结束的。参会人按日历顺序取名字（没名字用邮箱 @ 前面那段），去掉我自己与会议室 / 设备；没参会人时用组织者。无标题事件显示「（无标题）」。EventKit 调用都在一条串行队列上，主线程只发布结果（没变不发布）。
- **系列键**：重复事件和改过单次的那一次（`hasRecurrenceRules || isDetached`）用 `ext:` + `calendarItemExternalIdentifier`，否则 `title:` + 规范化标题。规范化 = 小写，去「第 3 期」「2026年11月6日」「周四」「#12 / W45 / Q4 / v2」与所有数字，标点当空格。「同系列」= 系列键相同或规范化同名；两个不同的重复事件即使同名（和不同人的「1:1」）不算，没绑日历时的默认标题（「线上会议」等）不按同名归系列。纯函数 `MeetingSeries`。
- **下一场与绑定**：开始不到 15 分钟的仍算「下一场」（迟到也能一键入会，有链接的优先），否则最近一场未开始的。手动开始**线上**会议时自动绑正在进行或 5 分钟内开始的事件（有链接优先，离现在近的优先）；线下不自动绑（提醒 / 简报里点开始时才带上事件）。
- **链接解析**（`MeetingLinkParser`，纯函数）：URL → 地点 → 备注，取第一个认得的。HTML 的 `&amp;`、尖括号 / 引号 / 中文标点当边界，末尾标点与不配对的右括号去掉，没写 scheme 的会议域名补 `https://`；剥 Outlook safelinks 与 Google 跳转。不认的：Zoom 拨号页 `/u/`、Teams 会议选项、Webex 官网 / 帮助页、腾讯会议下载页、钉钉文档 / 审批、飞书文档。
- **会前提醒**（`MeetingReminder`）：15 秒心跳（提前量 1 分钟时 30 秒太粗）；窗口 = 开始前提前量到开始后 2 分钟（刚从睡眠醒来也补上），再晚交给「已开始」检测。气泡是 **alert 级 sticky**：勿扰时非 alert 会被攒起来、补发时没有按钮，等勿扰结束会议早开始了 —— 与桌面宠物的设计一致（`docs/desktop-pet/INTERACTION.md`：会议提醒 = sticky）；不想被打扰就「暂停会议提醒」。正在记这一场（提前开始、自动绑上了）不提醒；记录别的会议时主按钮换成 [加入会议]（不另开记录）。「上次有 N 项未完成」= 该系列此前会议的全部未完成行动项（与简报一致）。
- **问过的记账**（`MeetingPromptBook`，UserDefaults `meeting.prompted` / `meeting.ignoredEvents`，过期 = 事件结束后一天）：会前提醒与「已开始」检测共用（同一场只问一次，重启后也不再问）；点 [忽略] = 这一场不再问、不自动开始，进行期间 App 检测也不问。自动开始另记一笔（提醒过的那场照样可以自动开始，但只自动开始一次）。
- **暂停会议提醒**：1 小时 / 今天（到今天 24 点）/ 直到明天（到明天 24 点，后天恢复；菜单项 tooltip 写明）。暂停同时管会前提醒、检测的询问与自动开始；暂停中菜单换成「恢复会议提醒（已暂停到 …）」。存 `meeting.reminder.pausedUntil`。
- **会议检测**（`MeetingDetector`；采样节奏见下面「问得及时」）：
  - 规则 1 只在开始后 15 分钟内问（醒来时已开会半小时就不问了，交给规则 2）。
  - 规则 2 的信号（纯函数 `MeetingDetectionApps.signals`），每个会议 App 单独算：
    - **会议进程**：会议 App 开会时才起的进程开着（`meetingProcesses`：钉钉的 `Tblive.app`、`DingMeeting.app`，按 `NSWorkspace.runningApplications` 的 bundle id）—— 静音入会也算。
    - **麦克风**：`MeetingMicrophoneProbe`（后台读，下一次采样用）按进程查谁在录音 —— macOS 14 的 CoreAudio 进程对象（`kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput`，任何输入设备都算），PID → `proc_pidpath` → 所在最外层 `.app`（辅助进程归宿主 App）→ bundle id；不含 Baobox 自己。系统目录里的进程（WebKit 的 GPU 进程替网页录音、FaceTime 的 `avconferenced`）说不清是谁的，只算到前台的会议 App；系统不支持按进程查时退回「默认输入设备在用」，同样只算前台。没有会议 App 在跑时不读 CoreAudio。
    - **浏览器里的会议网站**：在录音的是浏览器（`MeetingWebSites.browsers`；说不清是谁在录时看前台是不是浏览器 —— Safari 由 WebKit 的 GPU 进程录音）就读它的窗口标题（= 各窗口当前标签页的标题；优先 `CGWindowListCopyWindowInfo` 的 `kCGWindowName`，要屏幕录制权限，读不到再用辅助功能 `kAXWindowsAttribute` / `kAXTitleAttribute`，超时 0.5 秒），按 `MeetingWebSites.site(forTitle:)` 认 Google Meet（「Meet - abc-defg-hij」「Google Meet」）、Teams、Zoom、腾讯会议、飞书会议、Webex、Jitsi；认出来的网站当作一个会议 App（key 如 `web.meet`，检测记录、忽略名单都按它），排在专门开会的 App 后面，2 秒就问；这个浏览器这一轮录音里认出过一次就一直算（`MeetingWebLatch`），松开麦克风才忘 —— 2026-11-06 真机 17:53：入会那一下认出 Meet，5 秒后同一窗口的标题就认不出了（切了标签页或标题变了），连续计时被打断，一直没问。浏览器用麦克风不一定是开会（网页录音、语音输入），所以一定要标题对得上。2026-11-06 真机：Chrome 里开 Meet，录音的是 Chrome 的音频辅助进程，约 13 秒。
    - 2026-11-06 真机：钉钉开会起 Tblive，入会后麦克风只用了 6 秒就松开（静音），旧规则「会议 App 在跑 + 默认麦克风被占用满 10 秒」问不到；Slack、微信常驻时浏览器开会又会算到它们头上 —— 所以改成按 App、按进程。
  - 规则 2 的状态机（纯函数 `MeetingDetectionMachine`），每个 App 一条记录（一场会）：会议进程连续 2 秒、专门开会的 App（含会议网站）用麦克风连续 2 秒、聊天 App 连续 10 秒（语音消息、试麦不算）才问；信号断开不超过 10 秒（会议进程；专门开会的 App / 会议网站的麦克风 —— 它们静音时也开着麦克风，要提示「你在静音中说话」，松开就是退会了，2026-11-06 真机：Zoom 退会 13 秒后进下一场，按原来的 3 分钟算成同一场没问）/ 3 分钟（聊天 App 的麦克风：钉钉等静音时会松开）还算同一场，只问一次；一次只弹一个，同时在开的算问过，之后才开的照样问。Baobox 在记录会议时正在开的都算问过（结束记录后同一场不再来问）；在用麦克风做别的（听写、字幕、自检）或在录屏时先不问，结束后再问。
  - **问得及时**（2026-11-06 用户反馈「Notion 弹得非常及时」后改，参照 Notion 桌面端：它在默认输入设备上挂 CoreAudio 属性监听，麦克风一变就查是谁在用，在用期间每秒查一次）：`MeetingMicListener` 在默认输入设备上监听 `kAudioDevicePropertyDeviceIsRunningSomewhere`（默认设备换了跟着换，HAL 调用在自己的串行队列上），钉钉的会议进程一启动（`NSWorkspace.didLaunchApplicationNotification`）也算；一变就马上采样，之后 10 秒内、以及有人在用麦克风期间每秒采样，平时 5 秒。采样在后台，读完回主线程马上判断（不再用上一拍的结果），采样进行中又要查就读完再读一次。只盯默认输入设备：用别的输入设备开会的靠定时采样兜底。改前进会到问要 10–15 秒（5 秒一拍 + 晚一拍 + 连续 5 秒），改后两三秒。
  - 候选排序：前台那个 → 专门开会的（Zoom、腾讯会议、Teams、Webex、FaceTime）→ 常驻聊天 App（钉钉、飞书、微信、Slack）。忽略名单存 bundle id → 显示名（`meeting.detect.ignored`），设置里可移除。「自动检测会议」默认开（只问不自己开始）。
  - 询问也是 alert 级：会议软件全屏时勿扰是开着的。
- **自动开始**（`meeting.autoStart`，默认关，不受「自动检测」开关影响）：规则 1 命中（带链接的日历会议开始 15 分钟内）或规则 2 命中且有进行中的日历会议 → 不问，直接开始线上会议记录（绑这场），先 toast 一句。第一次用照样先弹合规说明。
- **会议库窗口**（`MeetingWindowController` + `MeetingLibraryModel`）：一个窗口两种视图（会议 / 行动项），详情三页（纪要 / 原文 / 系列时间线）。全文搜索时把所有 meeting.md 后台读进内存缓存，按「状态 + 结束时间」判断要不要重读。纪要正文里不再列一遍行动项（下面是可勾选的列表，勾选写回 meta.json；复制、导出仍是原文）。删除前确认，记录中、整理中（含重新生成）的不能删（写完时会把目录建回来）。导出 = 整份 meeting.md（NSSavePanel）。通知「纪要已生成」的 [打开] 现在打开会议库并选中这场。
- **重新生成纪要**（`MeetingMinutesRegenerator`）：从 meeting.md 读回转录（只有时:分:秒，按开始那天算、跨午夜往后挪）、🔖 与速记，按 meta 里的模板交给本地模型；只换纪要一节（没有就加在第一个二级标题前）；会议模板重解析行动项，同一条之前勾过的保留勾选。「整理中」只在内存里，不写进 meta.json（中途退出时旧纪要还在）。一次一场；没模型时提示去下载。
- **周报**（`MeetingWeeklyReporter` + 纯函数 `MeetingWeeklyReport`）：ISO 周（周一到周日），只算线上 / 线下会议；决议取纪要「### 决议」（自由听译是「结论」）下的各条、去掉「无」；未完成行动项带来源会议。概述 = 本地模型写 2–4 句（材料截到约 2400 token），没装模型跳过这一节。同一周再生成就覆盖 `weekly/<yyyy-Www>.md`，写好用默认程序打开；本周没会议只提示一句。
- **设备自检**（`MeetingDeviceTest`）：直接用线上会议同一条混音链路 `LiveTranslateMixedSource`（录到的就是识别器听到的那一路）；系统声音开不了（多半没给屏幕录制权限）就只录麦克风并说明。回放 = 只有输出的 `AVAudioEngine` + 播放节点（`.dataPlayedBack` 回调，另有超时兜底），**不碰 voice processing**。自检期间登记占用（owner `meetingSelfTest`）。
- **菜单与菜单栏**：顺序同需求 §5；会前简报在下一场没有简报（无同系列上一场、也无未完成行动项）时置灰。录音指示与下一场倒计时共用一个菜单栏项（录音优先，`meeting.menuBarCountdown` 默认关），它的菜单也显示快捷键（`StatusItemController.showHotkeyIfTagged` 改成 internal 复用）。快捷键新增 `meeting.join`，全部出厂不绑定。
- **迁移**：`LiveTranslateTool.name` 换成 `livetranslate.mergedName`（「字幕与同传」，设置 Tab 跟着改）；`livetranslate.name` 仍是占用登记里的「实时翻译」（「正在实时翻译，先停止再开始」）。菜单第一行置灰「已并入「会议」」+ 分隔线，其余不变；设置 Tab 第一行同样说明，并带「打开会议设置」。
- 其他：`NotifyDND` 加了只读的 `hasToken(_:)`（检测看「录屏中」，不像 `reasons()` 要遍历窗口列表）；`MeetingStore` 加了批量读 Markdown、整份重写 Markdown、写周报。

文件：`Modules/Meeting/` 新增 `MeetingCalendar`（EventKit）、`MeetingLinkParser`（纯）、`MeetingSchedule`（纯：下一场 / 绑定 / 提醒时间 / 暂停 / 记账）、`MeetingDetection`（纯：检测状态机）、`MeetingSeries`（纯：系列 / 简报）、`MeetingMarkdown`（纯：meeting.md 解析 / 周报）、`MeetingReminder`、`MeetingDetector`、`MeetingReports`（重新生成纪要 / 周报）、`MeetingDeviceTest`、`MeetingWindows`（窗口控制器与视图模型）、`MeetingLibraryView`、`MeetingBriefView`。`project.yml` 加 `NSCalendarsFullAccessUsageDescription` 与 entitlement `com.apple.security.personal-information.calendars`。
