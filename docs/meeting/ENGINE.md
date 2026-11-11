# 会议引擎接口（MeetingEngine）· 技术设计

> issue #107「会议与实时翻译实现焊死，没有引擎接口」。状态：**已拍板（§8，2026-11-10）**，实现中：PR1–PR6 已合入（#143、#142、#148、#155、#158、#160），PR7 + PR8 见本 PR（#107 的最后一步）。
> 基线：main `50103fe`（#106 已合并）。下文路径都相对 `mac/Sources/`，行号以这个提交为准。之后 main 到 `a3cadcd` 只动了两处相关的：
> #134 加了测试 target `BaoboxTests`（§5.1）；#137 改了 `LiveTranslateSettingsView.swift` 里纪要提示的判断（`:251` 起的行号 +2，见 §1.3）。
> 相关：`TECH_DESIGN.md` §2–§3、§9（引擎改造与会议会话的落地记录），`../live-translate/DESIGN.md` §6–§7，
> `../translation-engine/DESIGN.md` §3.3、§4，`../ai-service/DESIGN.md` §3.3、§5.3–§5.4。

## 0. 一页看懂

**现在**：会议（`Modules/Meeting/`）直接驱动字幕与同传的单例 `LiveTranslateController.shared`，替它组内部配置
（`LiveTranslateSessionConfig`、`LiveTranslateTranscript.Destination`），读它的设置和混音器下标；会议的 meeting.md 和纪要都是引擎写的。
反过来，引擎要靠会议模块 `activate()` 里给可变静态 `LiveTranslateController.recordLibrary` 赋值，才知道自由听译的记录该进会议库。

**改成**：

1. `Core/MeetingEngine/` 定义 `MeetingEngine` 协议和它的值类型，只依赖 Foundation。引擎对会议**只报句子、说话人、电平、生命周期**，
   不写文件、不碰纪要。会议只认这个协议。
2. **meeting.md 与纪要归会议**（2026-11-10 拍板）：写文档的 `LiveTranslateTranscript` 和纪要生成器 `LiveTranslateMinutes` 搬进会议，
   改名 `MeetingTranscript` / `MeetingMinutesGenerator`。会议的文档由会议自己写：暂停 / 静音 / 🔖 / 速记记行、改设置续写、收尾冲刷、退出同步写完都在会议这边。
   自由听译仍由引擎决定记不记、什么时候记，写成什么样、写到哪、整理纪要交给会议库（Core 协议 `FreeListeningLibrary`）。
   「会议纪要用哪个模型、能不能整理」只在 `MeetingMinutesGenerator` 一处判断。
3. `Modules/LiveTranslate/LiveTranslateMeetingEngine.swift` 是唯一的适配器。会议专属的规则（沿用「字幕与同传」的语言与纠错、字幕关着只转录）挪到这里。
4. 装配只在 `AppDelegate` 一处：`static let meetingEngine = LiveTranslateMeetingEngine(controller:recordLibrary:)`。会议库作为构造参数交给引擎，
   `recordLibrary` 静态删掉；懒加载、建好不变，与注册 / activate 顺序无关。
5. 说话语言与专有名词表下沉到 `Core/Translation/SpeechSettings.swift`，**键名不变**。
6. 会话的决策、文档的模型与排版、纪要提示词拆成纯逻辑（`Modules/Meeting/Logic/`），在 `BaoboxTests`（已在 main）里配假引擎测。

分 8 个 PR（§6），每个单独可合并、能编译、用户看不出变化（几处有意的细小差别列在 §2）。

术语：**托管会话** = 会议经引擎开的会话（线上 / 线下会议）；**自由听译** = 引擎自己的会话（原实时翻译，入口在会议菜单里）；
**文档** = 会议库里一条记录的 meeting.md；**适配器** = `LiveTranslateMeetingEngine`；**装配点** = 唯一同时认识会议和字幕与同传的那行代码。

## 1. 现状

### 1.1 #106 之后谁是谁

- 会议（`MeetingTool`）是产品入口：线上 / 线下会议、「开始自由听译」菜单项、`livetranslate.toggle` 快捷键、嵌入的「字幕与同传」设置，
  「AI」页里字幕翻译与 AI 纠错两个功能也由它声明。
- `Modules/LiveTranslate/` 退成引擎层：识别、翻译、纠错、混音、字幕条、朗读、转录与纪要（`LiveTranslateTranscript`），以及自由听译本身
  （`followsSettings` 的会话）。
- 会议的引擎就是 `LiveTranslateController.start(config:)`（`TECH_DESIGN.md` §2.1）。会议的 meeting.md 也是引擎写的：会议给一个 `Destination`，
  引擎边识别边写、结束后整理纪要，再经 `Destination.onEvent` 报回会议库。自由听译的记录同样写进会议库（经 `recordLibrary`）。

### 1.2 会议 → 实时翻译：全部依赖

**控制调用**

| 位置 | 调用 | 用途 |
|---|---|---|
| `Modules/Meeting/MeetingSessionController.swift:123` | `LiveTranslateController.shared.toggle()` | 空闲时「开始自由听译」 |
| `:174` | `.start(config: engineConfig())` | 开始会议会话 |
| `:245`、`:253` | `.setPaused(true / false)` | 暂停 / 继续 |
| `:268` | `.addTranscriptMark(at:)` | 🔖 |
| `:276`、`:352` | `.setTranscriptNotes(_:)` | 速记；开起来后补发 |
| `:292`、`:355` | `.setBarVisible(_:translate:)` | 字幕开关；开起来后补发 |
| `:304`、`:311` | `.setLaneMuted(_:lane:)` | 单路不录 |
| `:323` | `Task { await .finish() }` | 结束（冲刷最后一句） |
| `:337` | `.terminate()` | App 退出（会议进行中） |
| `Modules/Meeting/MeetingTool.swift:74` | `.toggle()` | `livetranslate.toggle` 快捷键 |
| `MeetingTool.swift:113` | `.terminate()` | 退出时给自由听译、还在整理的纪要收尾 |

**读引擎状态**

| 位置 | 读什么 | 用途 |
|---|---|---|
| `MeetingSessionController.swift:266` | `.lines.last?.original` | 🔖 记「标记时在说什么」 |
| `:539`、`:612` | `.takeInputLevels()` → `LiveTranslateInputLevels` | 控制条两路电平点 |
| `:586–587` | `.isRunning`、`.isHostedSession` | 状态行「正在自由听译」 |
| `MeetingTool.swift:77–81` | `.isHostedSession`、`.barVisible`、`.isRunning` | 环形菜单「翻译」的标题 |
| `MeetingTool.swift:122`、`:162` | `.isRunning` | 菜单「开始 / 停止自由听译」 |

**读设置**

| 位置 | 读什么 | 用途 |
|---|---|---|
| `MeetingSessionController.swift:218–222` | `LiveTranslateSettings.speech / .target / .translateEnabled / .aiCorrection` | 组会话配置 |
| `:292`、`:355` | `LiveTranslateSettings.translateEnabled` | 字幕打开时译不译 |
| `Modules/Meeting/MeetingStore.swift:175–180` | `LiveTranslateRecordSettings.folderKey / .enabledKey / .defaultFolder` | 旧记录迁移 |
| `MeetingSettings.swift:52–53`、`MeetingText.swift:34`、`MeetingSettingsView.swift:8, 237` | `LiveTranslateMeetingStyle` | 纪要模板设置 |

**混音细节**

| 位置 | 引用 | 用途 |
|---|---|---|
| `MeetingSessionController.swift:304`、`:311` | `LiveTranslateMixerCore.microphoneLane / .systemLane`（混音器内部的下标 0 / 1） | 单路不录 |
| `MeetingDeviceTest.swift:41–42, 101, 111, 169, 253` | `LiveTranslateMixedSource`、`LiveTranslateAudioRouter`、`LiveTranslateMixer.sampleRate` | 设备自检直接用会议的混音链路 |

**引擎内部的配置、回调、转录与纪要类型（会议替引擎组装）**

| 位置 | 类型 | 说明 |
|---|---|---|
| `MeetingSessionController.swift:212–238` | `LiveTranslateSessionConfig` | `sources`（线上 `.mixed` / 线下 `.microphone`）、`usesMixer = true`、`correction: .always`、`onFinalLine`、`onLifecycle`、`onUserRequest`、`rebuild` |
| `:70`、`:410` / `:344` / `:402` | `.FinalLine` / `.Lifecycle` / `.UserRequest` | 回调参数 |
| `:68`、`:190–208` | `LiveTranslateTranscript.Destination`、`.Header` | 文件、头信息、`speakers`、`template`、`summaryFollowsSetting = false`、`notifiesMinutes = false`、`onEvent` |
| `:415`、`:473` | `LiveTranslateTranscript.Event`、`.MinutesOutcome` | 转录进度、纪要结果 |
| `:156`、`:191` | `LiveTranslateMinutesTemplate`、`LiveTranslateMeetingStyle` | 纪要模板 |
| `:444`、`:464` | `LiveTranslateMeetingMinutes.parseActionItems / .isHighlighted` | 行动项、🔖 重点 |
| `MeetingStore.swift:212, 462, 499` | `LiveTranslateMinutesTemplate.content`、`LiveTranslateTranscript.MinutesOutcome` | 状态映射、自由听译条目 |
| `MeetingReports.swift:48–51, 60, 76, 86, 177` | `LiveTranslateMinutes`（生成器、`Line`、`clip`）、`LiveTranslateMeetingMinutes`、`LiveTranslateMinutesTemplate` | 重新生成纪要、周报 |

**记录注入**

| 位置 | 内容 |
|---|---|
| `MeetingTool.swift:98` | `activate()` 里 `LiveTranslateController.recordLibrary = MeetingStore.shared` |
| `Modules/LiveTranslate/LiveTranslateController.swift:416–417` | `static var recordLibrary: LiveTranslateRecordLibrary?` |
| `LiveTranslateController.swift:1142` | 自由听译开新记录：`Self.recordLibrary?.freeListeningDestination(start:) ?? .legacy(start:)` |
| `Modules/LiveTranslate/LiveTranslateTranscript.swift:35–38` | `effectiveFolder = recordLibrary?.folderURL ?? folder`（设置页、字幕条「打开记录文件夹」） |
| `Modules/LiveTranslate/LiveTranslateSettingsView.swift:239–241, 263–271` | `writesToLibrary = recordLibrary != nil`：显示哪个目录、有没有「更改…」 |
| `MeetingStore.swift:474–515` | `extension MeetingStore: LiveTranslateRecordLibrary`（协议声明在 `LiveTranslateTranscript.swift:53–60`） |

**界面组装与功能声明**

| 位置 | 引用 |
|---|---|
| `MeetingSettingsView.swift:67` | 嵌入 `LiveTranslateSettingsSections()` |
| `MeetingTool.swift:93` | `aiFeatures()` 里的 `.liveTranslate`、`.liveCorrection`（声明在 `LiveTranslateController.swift:5–25`） |

字符串层面的共用不算类型依赖，这次不动：快捷键 id `livetranslate.toggle`（`MeetingTool.swift:69`、`MeetingSettingsView.swift:52`、
`Modules/DesktopPet/PetController.swift:951`），本地化 key `livetranslate.record.doc.*`（`MeetingReports.swift:63, 168`、`MeetingText.swift:131`、
`MeetingLibraryView.swift:380`）。

### 1.3 实时翻译 → 会议（反向）

1. **记录注入**（上表）：引擎持有会议库的引用，靠会议模块启动时赋值。
2. **用会议声明的 AI 功能**：`AIFeature.meetingMinutes` 声明在 `MeetingTool.swift:6`，引擎这边在 `LiveTranslateTranscript.swift:279`（结束时判断有没有模型）、
   `:323`（整理时本地模型常驻）、`:601`（生成器调模型）里用它；#137 之后 `LiveTranslateSettingsView.swift:253`（`a3cadcd`）的纪要提示也用它。
3. **为托管长出来的引擎能力**：`LiveTranslateSessionConfig` 整个文件就是托管接口；`LiveTranslateController.swift:398–415`（`sessionOpen`、
   `mixedSource`、`audioPaused`、`mutedLanes`、`speakerBaseline`、`barVisible`、`barGeneration`）、`:508–512`（`isHostedSession`、`showsSourceMenu`）、
   `:924–1070`（`finish`、`closeBar`、`setBarVisible`、`setPaused`、`setLaneMuted`、`takeInputLevels`、`addTranscriptMark`、`setTranscriptNotes`）、
   `:1115–1124`（说话人判定）。其中混音、暂停、静音、说话人、字幕条是引擎「能被托管」的本事，留着；和文档有关的（🔖、速记、记说明行、转录）这次搬走。
4. **会议的文档格式写在引擎里**：meeting.md 的版式（`LiveTranslateTranscript.swift:433–460`）、会议纪要的提示词（`:604–636`、`:782–886`）、
   纪要模板 / 类型 / 行动项解析（`LiveTranslateMinutesFormat.swift` 整个文件）。会议这边 `MeetingMarkdown` 按同一版式解析，
   `MeetingReports.swift:63` 按「纪要」标题找那一节替换 —— 两个模块之间有一份没写成代码的格式契约。
5. 文案：`LiveTranslateBar.swift:746` 托管时字幕条「记录」按钮的说明（`livetranslate.record.toggleHelpMeeting`）。

### 1.4 听写借用的

| 位置 | 引用 | 本次 |
|---|---|---|
| `Modules/Dictation/DictationSettings.swift:140` | `LiveTranslateSettings.speech.languages`（语言选「跟随」） | 改读 `SpeechSettings`（PR1） |
| `DictationController.swift:191` | `LiveTranslateSettings.vocabulary` | 同上 |
| `DictationSettingsView.swift:21` | `@AppStorage(LiveTranslateSettings.vocabularyKey)`（术语条数） | 同上 |
| `DictationRecognizer.swift:94, 104, 394, 469, 502, 518, 520` | `LiveTranslateAudioGate`、`LiveTranslateScoring`、`LiveTranslateAudioRouter.voicedDuration` | 引擎内部工具，P2 |

### 1.5 注册顺序依赖：是什么、坏了会怎样

- `ToolRegistry.activateAll()`（`Core/ToolRegistry.swift:12–19`）按注册顺序，逐个「注册它的快捷键 → `activate()`」。
- #106 之前，`AppDelegate` 注释写「会议在实时翻译前面：启动时先装好会议库，自由听译的新记录才写得进去」。其实 `LiveTranslateTool.activate()`
  是空的，真正的依赖不是谁先 activate，而是：**第一次写自由听译记录之前，`MeetingTool.activate()` 必须已经跑过** —— 靠的是 activate 的副作用
  给一个可变静态赋值。
- #106（`4d3fabc`）删了 `LiveTranslateTool`，`AppDelegate.swift:32` 的注释换掉了，「两个模块谁先注册」的问题跟着没了；但根子原样还在：
  `MeetingTool.swift:98` 照旧在 activate 里赋值，`MeetingTool.swift:26` 的注释还写着「注册在实时翻译前面……」。
- **坏了会怎样**（静态没装上 / 装晚了。不报错、不崩，只是悄悄写错地方）：
  1. 自由听译的新记录写回 `~/Documents/Baobox 实时翻译记录/`（`LiveTranslateController.swift:1142` 的 `.legacy`），会议库里看不到；
     第一次写「文稿」还会弹 TCC 授权框（`MeetingStore.swift:171` 的注释说的正是要避开它）。
  2. 旧记录迁移只做一次（`meeting.migratedLegacy`），之后写进旧目录的记录永远进不了会议库。
  3. 设置页「保存位置」显示旧目录并多出「更改…」，字幕条「打开记录文件夹」打开旧目录。

  会触发它的改动：调整注册或 activate 顺序；像 NetCapture 那样暂时不注册会议；将来别的模块在启动早期开自由听译；测试里想换一个会议库。
- 退出时还有一处隐式顺序（不是注册顺序）：`MeetingTool.willTerminate` 必须先 `MeetingSessionController.terminate()`（会议的转录同步写完，
  再 `MeetingStore.flush()`），再 `LiveTranslateController.terminate()`（自由听译收尾；`lastTranscript` 还在整理的纪要标「没整理完」，
  经回调同步写 meta）；之后 `AppDelegate` 才 `OfflineTranslator.shutdownAll()`。§4.5.5 把这个顺序写成显式的四步。

### 1.6 与 issue 描述不一致的地方

1. `MeetingSessionController` 的 14 个行号与当前 main 一致，但漏了 `:352`、`:355`（开起来后补发速记 / 字幕）。`LiveTranslateController.shared`
   实为 16 行；连同设置、混音下标与类型引用，这一个文件约 40 处。
2. 静态注入现在在 `MeetingTool.swift:98`（#106 在前面加了快捷键声明，`:81` 现在是环形菜单标题里的 `controller.isRunning`）；
   `recordLibrary` 声明在 `LiveTranslateController.swift:417`（`:416` 是它的注释）。
3. `AppDelegate.swift:35–36` 那条注释 #106 已删；注册顺序之间的依赖没了，activate 副作用这个根子还在（§1.5），`MeetingTool.swift:26` 留着过时注释。
4. `Core/Translation/TranslationSettings.swift` 已经存在，是翻译引擎解析（依赖 `OfflineTranslator`、`AIFeatureSettings`、`AIModelStore`、
   `LocalModels`），进不了不链接 App 的测试 target；所以共用设置另建同目录的 `SpeechSettings.swift`（已拍板，§8 第 1 条）。
5. 「共用的语音 / 词汇设置」真正的共用者是听写（读 `vocabulary`、`vocabularyKey`、`speech.languages`）。`target` / `translateEnabled` /
   `aiCorrection` 只有会议在读，适配器接手后不用下沉。
6. 协议不是 start / pause / finish / lines / mute / setNotes 这六个：转录归会议之后 `setNotes` 用不着了，要的是字幕开关、电平、退出、
   自由听译的开关与状态（#106 后菜单和快捷键在会议里）、一条事件通道（开起来 / 句子 / 结束 / 字幕条上的操作），以及改设置重启时取配置的回调。
7. 会议对实时翻译的依赖不止 `MeetingSessionController` / `MeetingTool`：`MeetingStore`、`MeetingReports`、`MeetingDeviceTest`、`MeetingSettings`、
   `MeetingText`、`MeetingSettingsView` 都有；反方向还有 `.meetingMinutes`（§1.3 第 2 条）。
8. 「会议可脱离 LiveTranslate 单独测」单靠协议做不到：`MeetingSessionController` 还直接碰 `MeetingStore`、`NotifyCenter` / `NotifyDND`、
   `AudioCaptureCoordinator`、`MeetingCalendar`、`NSAlert`、控制条 / 菜单栏项与 `Timer`，测试 target 又不链接 App ——
   要把会话的决策拆成纯逻辑（§5、PR7）。

## 2. 目标与非目标

目标：

1. 会议只认 `Core/MeetingEngine/` 里的协议与值类型。PR6 之后 `Modules/Meeting/` 里不再出现 `LiveTranslateController`、`LiveTranslateSettings`、
   `LiveTranslateSessionConfig`、`LiveTranslateTranscript`、`LiveTranslateMinutes*`、`LiveTranslateMixerCore`、`LiveTranslateRecord*`（白名单见 §3.3）；
   `Modules/LiveTranslate/` 里不再出现会议模块的类型和 `.meetingMinutes`。
2. **引擎只管「声音 → 句子」**：对托管会话只报句子、说话人、电平、生命周期。meeting.md 与纪要归会议 —— 会议的，以及自由听译写进会议库的。
3. 适配器是会议与引擎之间唯一的翻译层，会议专属的规则集中在它身上。
4. 会议库作为构造参数交给引擎，`recordLibrary` 静态删掉；装配只在 `AppDelegate` 一处，懒加载、不可变、与注册顺序无关。
5. 说话语言、专有名词表下沉到 Core，听写不再引用 `LiveTranslateSettings`；**设置键名一个都不变**。
6. 会话的决策、文档的模型与排版、纪要提示词拆成纯逻辑，能在 `BaoboxTests` 里配假引擎、假文档测。
7. 每一步单独可合并、能编译、用户看不出变化。

有意的细小差别（都在边角上，列出来备查）：

- 退出时把**所有**还在整理的纪要标「没整理完」。现在只管最近一份（`lastTranscript`）：会议结束后纪要还在整理、接着开着「保存记录」用过一次自由听译再退出，
  会议那份的纪要一节停在「正在用本地 AI 整理纪要…」，下次启动状态被修成「仅转录」。改后两份都写「纪要没整理完（Baobox 退出了）」。
- 会议里改设置重启时，「改为：…」那一行的时刻从「开始重启」挪到「重启成功」（差零点几秒）；重启失败就不记这一行（现在是记了再收尾）。自由听译不变。
- 转录 / 纪要的诊断日志 category 从 `livetranslate.transcript` 改成 `meeting.transcript`（`translation-engine/DESIGN.md` §3.3 跟着改）。
- 删掉的「写回 ~/Documents」旧路径本来就走不到，不算差别。

非目标：

- 除上面几条外不改任何用户可见行为：菜单、快捷键 id、设置键与默认值、文案、通知（含来源）、meeting.md 版式、会议库目录与 meta.json。
- 不引入第二个引擎实现（假引擎只在测试里）。
- 不改引擎的识别、翻译、纠错、混音、字幕条、朗读逻辑。`LiveTranslateController` 只动三处：托管会话不再写文档（PR3）、自由听译经协议写会议库（PR4）、
  会议库改由会话配置带进来（PR6）。
- 不挪采集链路（设备自检、听写借用的引擎工具，P2）。
- 不改本地化 key 的命名（搬到会议的代码照旧用 `livetranslate.record.doc.*`）。
- 不把 `MeetingSessionController.shared` 改成全链路构造注入（§8 第 3 条）。

## 3. 总体设计

### 3.1 分层

现在：

```
MeetingTool.activate() ─── 赋值 ──▶ LiveTranslateController.recordLibrary（可变静态）
MeetingSessionController ─ 16 处调用 ─▶ LiveTranslateController.shared（连 meeting.md、纪要一起交给引擎）
                         ─ 读设置 ────▶ LiveTranslateSettings
                         ─ 组内部配置 ─▶ LiveTranslateSessionConfig / LiveTranslateTranscript.Destination
                         ─ 用混音下标 ─▶ LiveTranslateMixerCore
MeetingStore ─── 实现 ──▶ LiveTranslateRecordLibrary（声明在 LiveTranslate）
```

改后：

```
Core/MeetingEngine/            协议 + 值类型，只依赖 Foundation
   ▲            ▲
   │            └── Modules/LiveTranslate    引擎：声音 → 句子；LiveTranslateMeetingEngine 实现协议；自由听译经 FreeListeningLibrary 写记录
   └─────────────── Modules/Meeting          会话、会议库、meeting.md 与纪要（会议的、自由听译的）；只认协议
AppDelegate.meetingEngine      装配点：建适配器、把会议库交给它；唯一同时认识两边
```

### 3.2 依赖规则

1. 箭头只指向 Core：会议不引用 `LiveTranslate*`（§3.3 白名单除外），实时翻译不引用会议模块的类型（`MeetingSessionController`、`MeetingStore`、
   `MeetingTranscript`…）和会议声明的东西（`.meetingMinutes`）；两边都可以用 Core 里的值类型。
2. 唯一同时认识两边的是装配点（`AppDelegate.meetingEngine`）。
3. `Core/MeetingEngine/` 与 `Modules/Meeting/Logic/` 只放只依赖 Foundation（外加 Combine / os）的文件：不调 `L()`、不碰 `.shared` 单例、
   不 import AppKit / SwiftUI —— 整个目录编进 `BaoboxTests`。

### 3.3 P1 之后允许保留的直接引用（白名单）

| 位置 | 引用 | 为什么留 / 什么时候清 |
|---|---|---|
| `MeetingDeviceTest.swift` | `LiveTranslateMixedSource`、`LiveTranslateAudioRouter`、`LiveTranslateMixer.sampleRate` | 自检要录的就是「识别器听到的那一路」；P2 把采集链路下沉 `Core/Audio/` |
| `MeetingSettingsView.swift` | `LiveTranslateSettingsSections(recordFolder:minutesReady:)` | 界面组装；P2 可改由引擎提供 |
| `MeetingTool.swift` | `aiFeatures()` 里的 `.liveTranslate`、`.liveCorrection` | 「AI」页分组；功能 id 跟着引擎走（`ai-service/DESIGN.md` §3.3） |

### 3.4 三个关键取舍

1. **会议不再读「字幕与同传」的任何设置**。会议只说「线上还是线下、开不开字幕、标不标说话人」；说什么语言、译成什么、纠不纠错、读不读译文，
   由引擎按自己的设置定。「会议沿用字幕与同传的语言与纠错」「字幕关着只转录」「纠错与翻译解耦（`.always`）」这些规则搬进适配器。
2. **转录与纪要这次就归会议**（拍板，§8 第 2 条）。写文档的代码只有一份（`MeetingTranscript`，两种版式），在会议里；排版与解析（`MeetingMarkdown`）
   于是在同一个模块，能配往返测试，§1.3 第 4 条那份格式契约第一次写成代码。自由听译的「记不记」仍是引擎的事（开关在字幕与同传那一页、按钮在字幕条上），
   「怎么写」交给会议库。
3. **装配用不可变的静态常量**，不用 setter（§4.6）。

## 4. 接口设计

### 4.1 协议

`Core/MeetingEngine/MeetingEngine.swift`（PR5 新增，只依赖 Foundation）：

```swift
/// 托管方（会议会话）：引擎从它取配置、向它报事件。引擎只弱引用它。
@MainActor
protocol MeetingEngineHost: AnyObject {
    /// 此刻的会话配置。开始时取一次；运行中改了引擎自己的设置（说话语言、译成、朗读…）、要重建识别链路时再取一次 ——
    /// 这时托管方会再收到一次带着新 `run` 的 `.started`。
    var engineConfig: MeetingEngineConfig { get }
    /// 引擎的事件。一律在主线程、按发生顺序报；可能在托管方调引擎方法的过程中同步报回来（§4.3）。
    func meetingEngine(didReport event: MeetingEngineEvent)
}

/// 会议记录要的「把会上的声音变成一句句文字」。只出句子，不写文件、不碰纪要。实现：LiveTranslateMeetingEngine。
@MainActor
protocol MeetingEngine: AnyObject {
    // MARK: 托管会话（线上 / 线下会议）

    /// 开一场。false = 没开：别的会话还在 / 正在开，或麦克风被听写等占着（引擎已经发过「正在 XX，先停止再开始」）。
    /// true 之后一定**异步**报 `.started` 或 `.ended`（权限被拒、识别不可用、音源打不开），不在这个调用里报。
    func start(host: MeetingEngineHost) -> Bool
    /// 暂停 / 继续：暂停 = 不往识别器送音频，会话不停（手头那句照常定稿）。开始中也收，开起来时生效；跨改设置的重启保留。
    func setPaused(_ paused: Bool)
    /// 单独不录某一路：这一路换成等长静音送进去（两路仍对齐），另一路照录，电平随之为 0。开始中也收；跨重启保留。
    func setMuted(_ muted: Bool, lane: MeetingAudioLane)
    /// 字幕条显示 / 收起；显示时译不译按引擎自己的翻译开关。没在运行时不做 —— 托管方在第一次 `.started` 时再设一次。
    func setSubtitles(_ visible: Bool)
    /// 在字幕条上显示一行提示（会议的文档写盘失败时用）。字幕条没显示就看不到，同现在。
    func showNotice(_ text: String)
    /// 屏幕上最新那句的原文（没定稿的也算）；没有为 nil。🔖 记「标记时在说什么」用。
    var currentText: String? { get }
    /// 两路电平：上次取走以来每路的最大 RMS（0…1），取一次清一次；暂停中为 0；没在托管会话里为 nil。
    func takeInputLevels() -> MeetingInputLevels?
    /// 结束：先停音频，等最后一句定稿（最多 1.5 秒）再停。不用等它返回：最后几句的 `.line` 报完才报 `.ended`（I4）。没在运行时不做。
    func finish()

    // MARK: 自由听译（引擎自己的会话；入口在会议里，#106）

    /// 此刻在跑什么：会议菜单、`livetranslate.toggle` 在环形菜单里的标题、状态行用。
    var activity: MeetingEngineActivity { get }
    /// 「开始自由听译」开关：没在跑 → 按引擎自己的设置开一次（记录经 FreeListeningLibrary 进会议库）；自由听译中 → 停；
    /// 托管会话中 → 报 `.userAction(.freeListeningTogglePressed)`，由托管方决定（会议：切字幕）。
    func toggleFreeListening()

    // MARK: 退出

    /// App 退出：停下来。托管会话剩下的 `.line` 和 `.ended` 在返回前同步报完；自由听译的记录同步写完（纪要标「没整理完」）。可以重复调用。
    func terminate()
}
```

对照 issue 列的六个：`start` → `start(host:)`；`pause` → `setPaused`；`finish` → `finish`；`lines` → `currentText` + `.line` 事件；
`mute` → `setMuted(_:lane:)`；`setNotes` → **去掉**（速记由会议直接写进自己的文档，🔖 同理）。

为什么用「托管方协议」而不是在配置里塞闭包：配置里不带闭包就能 `Equatable`，测试直接比；引擎重启时取配置、报事件走同一个对象，假引擎好写；
和 AppKit 的 delegate 一个读法。`finish()` 不做成 `async`：会议从来不等它，结果都经事件回来，测试里也不用等 `Task`。

### 4.2 数据模型

PR2 新增 `Core/MeetingEngine/MeetingEngineTypes.swift`（句子、说话人、电平、这次怎么跑的），PR5 在 `MeetingEngine.swift` 里补上配置、事件、通道：

```swift
/// 一场托管会话要什么。会议只说「线上还是线下、开不开字幕、标不标说话人」，怎么识别、译不译、纠不纠错由引擎定。
struct MeetingEngineConfig: Equatable {
    enum Capture: Equatable {
        /// 线上会议：麦克风 + 系统声音混成一路进一个识别器。
        case microphoneAndSystem
        /// 线下会议：只有麦克风（照样走混音链路：要电平、暂停也靠它）。
        case microphone
    }
    /// 占用登记（AudioCaptureCoordinator）的 owner，也是占用冲突提示的通知来源：`meeting`。
    var owner: String
    /// 占用冲突时给用户看的名字（已本地化：「会议记录」）。
    var label: String
    var capture: Capture
    /// 字幕条（+ 译文）开着。运行中用 `setSubtitles` 切，重启时按这里重组。
    var subtitles: Bool
    /// 每句判「我 / 对方」（线上会议）。
    var speakers: Bool
    /// 这场的 meeting.md：只给字幕条用 —— 记下第一句后，「记录」按钮旁的小按钮打开它。引擎不写它。
    var documentURL: URL
}

enum MeetingEngineEvent: Equatable {
    /// 开起来了；`run` = 这次怎么跑的（文档头信息、「改为：…」用）。改设置引起的重启会带着新的 `run` 再报一次。
    case started(MeetingEngineRun)
    /// 一句定稿；之后纠错 / 译文回来再报（同一 `key`，后到的覆盖先到的）。停止时没定稿的最后几句也报。
    case line(MeetingEngineLine)
    /// 会话结束（结束、识别出错停了、没开起来），每场恰好一次；这一场的 `.line` 都在它之前报完（I4）。
    case ended
    /// 用户在引擎自己的界面上点的；是什么意思由托管方定。
    case userAction(MeetingEngineUserAction)
}

enum MeetingEngineUserAction: Equatable {
    /// 字幕条右上角的 ✕（会议：收起字幕，照常记录）。
    case subtitleBarClosed
    /// 字幕条上的「记录」按钮（会议：暂停 / 继续，与控制条同步）。
    case recordButtonPressed
    /// 「开始自由听译」开关（菜单、快捷键、环形菜单）在托管会话中被按下（会议：打开 / 收起字幕）。
    case freeListeningTogglePressed
}

enum MeetingEngineActivity: Equatable {
    case idle
    /// 自由听译在跑（正在开始的不算）。
    case freeListening
    /// 托管会话正在开始或在跑；`subtitlesVisible` = 字幕条此刻真的显示着。
    case hosted(subtitlesVisible: Bool)
}

/// 一句（取代 `LiveTranslateSessionConfig.FinalLine`）。
struct MeetingEngineLine: Equatable {
    /// 本场里唯一，同一句不管报几次都是同一个键：`"\(这句是第几次运行时认出来的)-\(id)"`（#149）。
    let key: String
    /// 这句第一次出字的时刻。
    let time: Date
    /// 显示用的原文（有 AI 纠错就是纠正后的），去掉首尾空白，不会是空的。
    let original: String
    /// 空 = 没翻（字幕关着、不翻译、或这句本来就是「译成」的语言）。
    let translation: String
    /// 线上会议按两路音量判的说话人；判不准或不标说话人时为 nil。
    let speaker: MeetingSpeaker?
}

/// 这次怎么跑的（取代 `LiveTranslateTranscript.Config`）：文档开头的「音源」「说 … 译成 …」与「改为：…」那行。都已本地化。
struct MeetingEngineRun: Equatable {
    /// 「麦克风」「系统声音」「麦克风 + 系统声音」。
    var source: String
    /// 「English」「自动（简体中文 / English）」。
    var speech: String
    /// 译成什么；nil = 这次不翻译。
    var target: String?
}

/// 说话人：「我」= 麦克风，「对方」= 系统声音（取代 `LiveTranslateSpeaker`，rawValue 不变）。判法（近似）在引擎里：一句期间有人声
/// （RMS > 0.01）累计 ≥ 0.3 秒算显著，系统声音显著且 ≥ 麦克风的 35% → 对方；否则麦克风显著 → 我；都弱 → nil（TECH_DESIGN.md §9）。
enum MeetingSpeaker: String, Codable, Equatable {
    case me
    case them
}

/// 两路电平（0…1 的 RMS 峰值；取代 `LiveTranslateInputLevels`）；nil = 没有这一路（线下会议没有系统声音）。
/// 会议每 0.25 秒取一次，自己按 0.006 判亮灭（比判「有人在说话」的 0.01 低一点）。
struct MeetingInputLevels: Equatable {
    var microphone: Float?
    var system: Float?
}

enum MeetingAudioLane: Equatable, CaseIterable {
    /// 你的声音。
    case microphone
    /// 对方的声音（只有线上会议有）。
    case system
}
```

电平保持「会议来取」而不是引擎推：混音每 20 ms 一块，推事件太密；现在就是 0.25 秒取一次峰值，照旧。
纪要结果、文档进度这些类型不再过引擎，留在会议里（§4.8）。

### 4.3 线程与事件约定

| # | 约定 | 现在靠什么保证 / 为什么要 |
|---|---|---|
| I1 | 协议方法只在主线程调，事件只在主线程报 | 协议 `@MainActor`；`@Published` 只在主线程写 |
| I2 | `start` 返回 true 之后才（异步）报 `.started` 或 `.ended`；返回 false 什么都不报 | 引擎 `start(config:)` 只排一个 `Task`。会议在 `start` 返回后才挂勿扰、开控制条（`MeetingSessionController.swift:182–185`），同步报 `.ended` 会让控制条和勿扰留在那儿 |
| I3 | 一场里 `.started` 零到多次（重启会再报），`.ended` 恰好一次 | `endSession()` 有 `sessionOpen` 守门；会议只在「开始中」时进「记录中」、建文档 |
| I4 | **这一场的 `.line` 全部报完才报 `.ended`**（含停止时没定稿、强制记下的最后几句），中间不让出主线程；`.ended` 之后不再有 `.line` | `stop()` 里先 `record(line, force: true)` 再 `endSession()`；纠错 / 译文的迟到结果有 `isRunning` 守门。会议在 `.ended` 里收尾文档 —— 这条就是「收尾冲刷」在接口上的全部要求 |
| I5 | `terminate()` 返回前把剩下的 `.line` 和 `.ended` 同步报完；**转发不能隔一拍**（不能包 `Task` / `DispatchQueue.main.async`） | 会议在 `.ended` 里同步写完文档和 meta，紧接着 `flush()`；隔一拍的话 App 退出前来不及写。会议另有兜底：`terminate()` 返回后还没收到 `.ended` 就自己收尾 |
| I6 | 同一 `key` 的 `.line` 可能报多次（纠错、译文回来），后到的覆盖先到的 | 引擎每次更新都走 `record(line)` |
| I7 | `userAction` 只在托管会话运行中报 | 只有托管配置有 `onUserRequest` |
| I8 | 重入：事件可能在托管方调引擎方法的过程中同步到达（`terminate`、`toggleFreeListening`、`finish` 里的停止） | 现在就是这样，会议的处理已经容得下 |
| I9 | 改设置重启：引擎重新取 `host.engineConfig`，带新 `run` 再报 `.started`；句子键带运行次数、不撞；暂停 / 单路不录的状态保留 | 引擎 `restartIfRunning` + `sessionOpen` |
| I10 | 第一个 `.started` 之前可能已经报过 `.line`：`.started` 等音源全开好才报，这期间先开的那一路（麦克风）就可能出字定稿 | 会议先记进 `finalLines`，第一次 `.started` 建文档时按时间补写（PR3 的 `openTranscript`）；假引擎也要能这样喂 |

这些写进协议的文档注释；假引擎（§5.3）默认按它们的顺序报。

### 4.4 适配器 `LiveTranslateMeetingEngine`

`Modules/LiveTranslate/LiveTranslateMeetingEngine.swift`（PR5 新增）。不让 `LiveTranslateController` 直接实现协议：控制器还管自由听译与字幕条，
接口形状也不同（配置结构体 + 闭包）；包一层可以不动控制器的逻辑，会议专属的规则也有一个固定的家。

| `MeetingEngine` | `LiveTranslateController` |
|---|---|
| `start(host:)` | `start(config:)`（配置见下） |
| `setPaused(_:)` | `setPaused(_:)` |
| `setMuted(_:lane:)` | `setLaneMuted(_:lane:)`：`.microphone` → `LiveTranslateMixerCore.microphoneLane`，`.system` → `.systemLane` |
| `setSubtitles(_:)` | `setBarVisible(_:translate: LiveTranslateSettings.translateEnabled)` |
| `showNotice(_:)` | `showNotice(_:)`（PR3 新增：运行中才设 `notice`） |
| `currentText` | `lines.last?.original` |
| `takeInputLevels()` | `takeInputLevels()` |
| `finish()` | `Task { await finish() }` |
| `activity` | `isHostedSession` → `.hosted(subtitlesVisible: barVisible)`；否则 `isRunning` → `.freeListening`；否则 `.idle` |
| `toggleFreeListening()` | `toggle()`（PR6 起 `toggle(startingWith: .fromSettings(recordLibrary:))`） |
| `terminate()` | `terminate()` |
| `.started(run)` / `.ended` | `onLifecycle`（PR3 起 `.started` 带 `run`） |
| `.line` | `onFinalLine`（PR2 起就是 `MeetingEngineLine`） |
| `.userAction` | `onUserRequest`：`.closeBar` → `.subtitleBarClosed`，`.toggleRecording` → `.recordButtonPressed`，`.toggle` → `.freeListeningTogglePressed` |
| `host.engineConfig` | `rebuild` |

会议专属的规则从 `MeetingSessionController.swift:212–238` 原样挪过来：

```swift
private func sessionConfig(for meeting: MeetingEngineConfig, host: MeetingEngineHost?) -> LiveTranslateSessionConfig {
    var config = LiveTranslateSessionConfig(
        owner: meeting.owner, label: meeting.label,
        sources: meeting.capture == .microphoneAndSystem ? .mixed : .microphone,
        speech: SpeechSettings.speech,                                            // 沿用「字幕与同传」的说话语言
        target: LiveTranslateSettings.target,
        translate: meeting.subtitles && LiveTranslateSettings.translateEnabled,   // 字幕关着只转录
        showsBar: meeting.subtitles,
        correction: LiveTranslateSettings.aiCorrection ? .always : .off)          // 只转录时也纠错
    config.usesMixer = true                   // 线下会议也走混音链路：电平、暂停都靠它
    config.speakers = meeting.speakers
    config.documentURL = meeting.documentURL
    config.recordLibrary = recordLibrary      // PR6：字幕条「打开记录文件夹」
    config.onFinalLine = { [weak host] in host?.meetingEngine(didReport: .line($0)) }
    config.onLifecycle = { [weak host] in host?.meetingEngine(didReport: MeetingEngineEvent($0)) }   // .started(run) / .ended
    config.onUserRequest = { [weak host] in host?.meetingEngine(didReport: .userAction(MeetingEngineUserAction($0))) }
    // 改设置引起的重启：按托管方此刻的配置再翻一遍。不能落回 `.fromSettings()` —— 那样会议中途变成自由听译，
    // 托管方再也收不到事件，会议卡在「记录中」。
    config.rebuild = { [weak host] in self.sessionConfig(for: host?.engineConfig ?? meeting, host: host) }
    return config
}
```

`rebuild` 强引用适配器：适配器和控制器都是常驻单例，这个环无害。两个小的转换 init 写在适配器文件里。

### 4.5 转录与纪要归会议

#### 4.5.1 `LiveTranslateTranscript` 的职责怎么拆

| 职责 | 现在 | 挪完 |
|---|---|---|
| 文档模型：逐句（键 → 行，后到覆盖）、「改为：…」、🔖、说明行、速记 | `LiveTranslateTranscript`（`LiveTranslateTranscript.swift:67–544`） | `MeetingTranscript`（`Modules/Meeting/`）；PR7 把模型与排版拆成纯的 `MeetingTranscriptModel`（Logic） |
| 两种版式（自由听译 / 会议） | 同上 `render` / `renderMeeting` | 同上，代码原样搬，L10n key 不变，输出逐字不变 |
| 写盘：至多 1 秒整份重写、串行队列原子写、退出时同步写、写失败回调一次 | 同上 | 同上（队列名与日志 category 换成会议的） |
| 收尾与纪要决策：off / interrupted / noModel / tooShort / generating | 同上 `finish`（`:273–291`） | 同上；「有没有模型」问 `MeetingMinutesGenerator.isReady` |
| 后台整理、本地模型常驻、结果写回、自由听译的「实时翻译纪要已整理好」通知 | 同上 `generateMinutes`（`:317–357`） | 同上（通知的来源仍是 `livetranslate`、文案不变） |
| 退出时把还在整理的纪要标「没整理完」 | 引擎 `terminate()` 里 `lastTranscript?.abortMinutesIfRunning()`（只管最近一份） | `MeetingTranscript.abortAllMinutes()`：整理时自己登记、整理完注销，退出时全部标掉（§2 第一条差别） |
| 纪要生成器与提示词 | `LiveTranslateMinutes`（`:547–887`） | `MeetingMinutesGenerator`（Meeting）；PR7 把提示词与切段拆成纯的 `MeetingMinutesPrompts`（Logic） |
| 纪要模板 / 类型 / 行动项解析 | `LiveTranslateMinutesFormat.swift` | `Modules/Meeting/Logic/MeetingMinutesFormat.swift`（已是纯的） |
| 纪要结果、文档进度 | `LiveTranslateTranscript.MinutesOutcome` / `.Event` | `MeetingMinutesOutcome` / `MeetingTranscriptEvent`（Meeting/Logic），不再过引擎 |
| 「保存记录」「停止后整理纪要」两个开关 | `LiveTranslateRecordSettings`（`:5–51`） | 不动：字幕与同传那一页的开关，引擎读；「整理纪要」在开记录、收尾时作为参数交给会议库 |
| 记录写到哪 | `Destination` + 静态 `recordLibrary` | 会议：会议自己知道；自由听译：`FreeListeningLibrary`（会议库实现） |
| 什么时候记、记什么 | 引擎 `startTranscript` / `record` / `setRecording` / `finishTranscript`，托管会话也走这一套 | 托管会话：引擎不记，只报 `.started(run)` / `.line` / `.ended`；自由听译：照旧由引擎决定，经 `FreeListeningRecord` 写 |

#### 4.5.2 会议这边：每件事怎么做

会议会话（`MeetingSessionController`；PR3 起由它驱动文档，PR7 后经端口 `MeetingTranscriptWriting`）持有本场的文档对象 `transcript`：

| 行为 | 现在（在引擎里） | 挪完（在会议里） |
|---|---|---|
| 建文档 | 引擎 `startFlow` 里 `startTranscript`（权限问完、识别器开之前） | 会议收到**第一个** `.started(run)` 时建：会议版式、`speakers` 按会议类型、模板按设置、总是整理纪要、不发自由听译那条通知；开始中写的速记一并写进去。引擎没开起来（只报了 `.ended`）就始终没有文档 |
| 一句 | 引擎 `record(line)` 写，同时报 `onFinalLine` | 会议收到 `.line` 就 `transcript.update(line)`（同一 key 覆盖），照旧记进 `finalLines` 算重点 |
| 暂停 / 继续 | 引擎 `setPaused` 里记一行 | 会议 `pause()` / `resume()` 调完引擎就 `transcript.note(.paused / .resumed)`，文案同一个 key |
| 单路不录 | 引擎 `setLaneMuted` 里记一行 | 会议的两个开关同理；开始中还没文档，不记，同现在 |
| 🔖 | `engine.addTranscriptMark` → 引擎写 | 会议 `mark()` 直接 `transcript.mark(at:)` |
| 速记 | `engine.setTranscriptNotes`；开起来后补发 | 会议直接 `transcript.setNotes`；开始中先存在会话的 `notes` 里，建文档时写进去 |
| 改设置重启 | 引擎 `continueWith(config)`（重启开始时） | 引擎带新 `run` 再报 `.started`，会议 `transcript.continueWith(run, at:)`：设置真变了才记「改为：…」，还是同一份文档 |
| 收尾冲刷 | 引擎 `finish()`：停音频 → 等最后一句 ≤ 1.5 秒 → `stop()` 里强制记下没定稿的 → 收尾转录 → `.ended` | 引擎照旧，只是强制记下的那几句改成报 `.line`；会议在 `.ended` 里收尾文档，这时这场的句子已经全到了（I4） |
| `.ended` 与收尾的先后 | 跨模块：引擎先报 `.finished` 再报 `.ended`，会议靠这个顺序判断作废（`:371`） | 会议在一个函数里按顺序做：`transcript.finish` → 处理它同步回来的 `.finished`（写 meta 或作废，逻辑同 `:420–440`；没有文档 = 没开起来，直接作废，同 `:371–374`）→ 撤勿扰、停心跳、收控制条 → 复位。跨模块的顺序要求只剩 I4 |
| 退出同步写完 | 引擎 `terminating` → 同步写、纪要标没整理完 | 会议 `terminate()` 先置 `terminating`，再 `engine.terminate()`；`.ended` 同步到达 → `transcript.finish(terminating: true)`（同步写、纪要 `.interrupted`）→ meta 同步写；`terminate()` 返回后还没收到 `.ended` 就自己收尾（兜底）；最后 `flush()` |
| 写盘失败提示 | 引擎把提示放进字幕条 | 文档的 `onWriteError` 交给 `engine.showNotice(…)`：同一条文案，同样只在字幕条上 |
| 字幕条「记录」按钮、「打开本次记录」 | 跟着引擎自己的转录 | 引擎按暂停状态显示「记录」按钮；「打开本次记录」用配置里的 `documentURL`，记下第一句之后才出现，同现在 |
| 纪要 | 引擎的转录收尾时决定、后台整理，`.minutes` 经 `Destination.onEvent` 报回 | 会议的 `MeetingTranscript` 做同样的事，回调闭包里带着这场的 id（纪要好了可能已经开了下一场）；整理期间文档由它自己的任务和登记表持有 |

会议处理文档事件（`created` / `finished` / `minutes`）的逻辑（`MeetingSessionController.swift:415–456`：记有没有内容、一句没有就作废、写 meta、
解析行动项、通知）原样保留，只是事件从自己的文档来，不再经引擎。

#### 4.5.3 自由听译这边

引擎照旧决定记不记、什么时候记（「保存记录」开关、字幕条「记录」按钮、中途打开时补记字幕条上已有的句子），文档交给会议库：

```swift
// Core/MeetingEngine/FreeListeningLibrary.swift（PR4 新增）
/// 自由听译的记录进会议库（TECH_DESIGN.md §2.3）。引擎决定记不记、什么时候记；会议库决定写到哪、写成什么样、整理不整理纪要。
/// MeetingStore 实现；装配时交给引擎（PR6 起，之前经静态 recordLibrary）。
@MainActor
protocol FreeListeningLibrary: AnyObject {
    /// 会议库根目录（设置页「保存位置」、字幕条「打开记录文件夹」）。
    var folderURL: URL { get }
    /// 开一份新记录：会议库里新的一条（记下第一句才登记进索引，一句没有不留痕迹）。
    /// `summarizes` = 此刻「停止后整理纪要」开着（决定记录里先写不写纪要占位）。
    func beginFreeListeningRecord(start: Date, run: MeetingEngineRun, summarizes: Bool) -> FreeListeningRecord
}

/// 一份正在写的自由听译记录（MeetingTranscript 实现）。
@MainActor
protocol FreeListeningRecord: AnyObject {
    /// 记录文件（字幕条「打开本次记录」）。
    var fileURL: URL { get }
    /// 写盘失败时回调一次，参数是给用户看的一行提示（已本地化）。
    var onWriteError: ((String) -> Void)? { get set }
    func update(_ line: MeetingEngineLine)
    /// 改设置后的重启接着写：设置真变了才记一行「改为：…」。
    func continueWith(_ run: MeetingEngineRun, at time: Date)
    /// 收尾。`summarizes` = 此刻的「停止后整理纪要」（现在也是收尾时现读）；`terminating` = App 退出：同步写完、纪要标「没整理完」。
    func finish(at time: Date, terminating: Bool, summarizes: Bool)
}
```

- 引擎（PR4）：`transcript: LiveTranslateTranscript?` 换成 `transcript: FreeListeningRecord?`（变量名没改成 `record`：控制器已有方法 `record(_:force:)`）；
  开记录时 `beginFreeListeningRecord(start:run:summarizes: LiveTranslateRecordSettings.summary)`，
  重启 `continueWith(run)`，每句 `update(line)`，停止 `finish(…, summarizes: LiveTranslateRecordSettings.summary)`；`transcriptURL` 取 `fileURL`；
  写失败提示照旧进字幕条（那一行由 `MeetingTranscript` 组好、已本地化，引擎原样显示；会议那边同样原样交给 `showNotice`）。`lastTranscript` 删掉（PR3）。
- 会议库（PR4）：`MeetingStore` 实现 `FreeListeningLibrary` —— 分目录（「yyyy-MM-dd HH-mm 自由听译」）、建一个自由听译版式的 `MeetingTranscript`
  （`.content` 模板、不标说话人、整理完发「实时翻译纪要已整理好」），把文档事件接到原来的 `freeListening(_:id:dir:start:title:)`（第一句进索引、收尾与纪要更新 meta），
  逻辑与 `MeetingStore.swift:474–515` 相同。
- `MeetingStore` 从此不引用 LiveTranslate 的记录类型（旧记录迁移读的 `LiveTranslateRecordSettings` 两个键 PR6 换成会议自己的常量）；
  `LiveTranslateRecordLibrary`、`Destination.legacy`（写回 ~/Documents）删掉（§8 第 4 条）。

#### 4.5.4 纪要生成器与 `.meetingMinutes` 的判断

```swift
// Modules/Meeting/MeetingMinutesGenerator.swift（App 侧，PR4 由 LiveTranslateMinutes 改名搬来；PR7 把提示词与切段拆到 Logic/MeetingMinutesPrompts.swift）
@MainActor
enum MeetingMinutesGenerator {
    /// 纪要走哪个模型：「设置 → AI」里「会议纪要」选的（docs/ai-service/DESIGN.md §5.4）。整个 App 只有这里问 `.meetingMinutes`。
    static var route: AIRoute { AIService.shared.route(for: .meetingMinutes) }
    /// 此刻能不能整理：收尾时判「没有模型」、设置页的提示、会议库「重新生成」都看它。
    static var isReady: Bool { AIService.shared.isReady(route, local: .generation) }
    /// 整理一份纪要（短的一次整理；长的先逐段提要点再合并）。走本地时那个模型常驻到写完（原来在调用方做的 keep-alive 收进这里）。
    static func generate(lines: [Line], chinese: Bool, template: MeetingMinutesTemplate, notes: String) async throws -> String
}
```

- 调用方：`MeetingTranscript` 收尾时问 `isReady`（没模型 → `.noModel`），整理时调 `generate`；`MeetingMinutesRegenerator`（重新生成）问 `isReady`、调 `generate`；
  周报只借 `clip`（它的概述走 `.meetingWeekly`，不变）。
- 字幕与同传设置页「停止后用本地 AI 整理纪要」下面那行提示（#137）原来直接问 `.meetingMinutes`；PR4 起改由会议设置页传进来一个
  `minutesReady: () -> Bool`（`{ MeetingMinutesGenerator.isReady }`），实时翻译那边就不再认识 `.meetingMinutes`（原稿排在 PR6，挪到 PR4 一起做）。
- PR7 起纯逻辑的文档模型只拿「能不能整理」这个结果当参数（`ready: Bool`），决策本身可测。

#### 4.5.5 退出顺序

```swift
// MeetingTool.willTerminate()（PR5 后的样子；PR3、PR4 里引擎还是 LiveTranslateController.shared）
MeetingDetector.shared.stop(); MeetingReminder.shared.stop(); MeetingCalendar.shared.stop(); MeetingDeviceTest.shared.cancel()
let session = MeetingSessionController.shared
session.terminate()                 // 会议：引擎停 → 剩下的句子与 .ended 同步到 → meeting.md 同步写完（纪要标没整理完）→ meta 同步写
session.engine.terminate()          // 自由听译：引擎停 → 它那份记录（会议库的 MeetingTranscript）同步写完
MeetingTranscript.abortAllMinutes() // 还在整理的纪要（会议的、自由听译的）全部标「没整理完」，同步写 md 与 meta
MeetingStore.shared.flush()
// 之后 AppDelegate 才 OfflineTranslator.shutdownAll()（纪要已经全部标掉，不会写一半）
```

### 4.6 装配与 `recordLibrary` 的构造注入

**谁建谁**：

1. `AppDelegate.meetingEngine`（静态常量）第一次被用到时，用 `LiveTranslateController.shared` 和 `MeetingStore.shared`（作为 `FreeListeningLibrary`）
   建出 `LiveTranslateMeetingEngine`。
2. `MeetingSessionController.shared` 用 `AppDelegate.meetingEngine` 建出来；`MeetingTool`、`MeetingMenu` 经 `MeetingSessionController.shared.engine`
   拿引擎（快捷键、环形菜单标题、`willTerminate`、菜单标题），只有这一条路。
3. 适配器每开一个会话（托管或自由听译），都把会议库放进那份 `LiveTranslateSessionConfig`；控制器只从「当前会话配置」里读它。

```swift
// App/AppDelegate.swift
extension AppDelegate {
    /// 会议的引擎 = 字幕与同传的引擎包一层（docs/meeting/ENGINE.md）。整个 App 只有这里同时认识会议和字幕与同传；
    /// 会议库在这里作为构造参数交给引擎（取代 `LiveTranslateController.recordLibrary` 静态注入）。
    /// 第一次用到时建好、之后不变，与注册 / activate 的顺序无关。
    static let meetingEngine: any MeetingEngine =
        LiveTranslateMeetingEngine(controller: .shared, recordLibrary: MeetingStore.shared)
}

// Modules/Meeting/MeetingSessionController.swift（PR7 后挪到 App 侧的扩展里，§5.2）
static let shared = MeetingSessionController(engine: AppDelegate.meetingEngine)
```

- 为什么是静态常量而不是「注册时 setter」：`MeetingSessionController.shared` 有约 30 处调用方（8 个文件），要在注册时塞引擎只能 setter，
  那只是把「可变注入」换了个地方 —— 谁在注册前用了它就拿到空的。`static let` 第一次被用到时按需把依赖一串建好（几个 `.shared` 的 init 都很轻），
  没有可变状态，也就没有顺序。
- 模块引用 `AppDelegate` 已有先例（`MeetingTool.swift:198` 的 `AppDelegate.shared?.registry`）。

**`recordLibrary` 改成跟着会话走**（PR6）：

1. `LiveTranslateSessionConfig` 加 `recordLibrary: FreeListeningLibrary?`，`fromSettings()` 改成 `fromSettings(recordLibrary:)`；适配器建的两种配置都带上它。
2. `LiveTranslateController`：删 `static var recordLibrary`；`toggle()` 改成 `toggle(startingWith:)`（自由听译的配置由适配器给），删无参的 `start()`；
   `restartIfRunning()` 落回 `.fromSettings` 时把 `sessionConfig.recordLibrary` 带过去；开记录用 `sessionConfig.recordLibrary`；
   加 `recordFolder: URL?`（会话配置里的会议库目录）给字幕条「打开记录文件夹」用。
3. `LiveTranslateRecordSettings`：删 `folderKey`、`folder`、`defaultFolder`、`effectiveFolder`；`openFolder()` 改成 `openFolder(_ url: URL)`。
   旧记录迁移要读的 `livetranslate.record.folder` / `.enabled` 两个键改由会议自己的常量读（字面量不变，要看的旧文件夹清单不变）。
4. 设置页：`LiveTranslateSettingsSections(recordFolder: URL, minutesReady: @escaping () -> Bool)`。「记录与纪要」一节固定显示会议库目录（现在就是这样，
   因为静态总是装上的），删掉到不了的「更改…」与 `folder` 的 `@AppStorage`，以及只有它用的两条文案（`livetranslate.record.choose`、`.choosePrompt`）；
   `MeetingSettingsView` 传 `MeetingStore.shared.rootURL`。纪要提示的 `minutesReady`（`{ MeetingMinutesGenerator.isReady }`）PR4 已经加上，这一步只加 `recordFolder`。
5. `MeetingTool.activate()` 删掉赋值那一行，`MeetingTool.swift:26` 的过时注释一起改。

改完后「自由听译写到哪」只取决于开会话时谁把会议库递进来 —— 只有适配器开会话，适配器是带着会议库建出来的，没有第二条路。

### 4.7 设置下沉：`Core/Translation/SpeechSettings.swift`

PR1 新增（只依赖 Foundation 与同目录的 `TranslationLanguage`、`TranslationGlossary`；这两个文件在 `50103fe` 上用 `swiftc -typecheck` 单独编得过）：

| 键（不变） | 取值 / 默认 | 现在定义在 | 谁读 | 去向 |
|---|---|---|---|---|
| `livetranslate.language` | `auto`，或识别 locale（`en-US` / `zh-CN`…）；默认 `en-US` | `LiveTranslateSettings.languageKey` | 字幕与同传、会议（经适配器）、听写「跟随」 | `SpeechSettings.languageKey` |
| `livetranslate.autoA` | 语言代码；默认 `zh-Hans` | `.autoAKey` | 同上 | `SpeechSettings.autoAKey` |
| `livetranslate.autoB` | 语言代码；默认 `en`，与 A 相同时自动换成另一种 | `.autoBKey` | 同上 | `SpeechSettings.autoBKey` |
| `livetranslate.vocabulary` | 专有名词表文本（一行一项，`原文` 或 `原文 = 译名`）；默认空 | `.vocabularyKey` | 各识别器的提示词、翻译 / 纠错的术语、术语表编辑器、听写识别提示与设置页条数 | `SpeechSettings.vocabularyKey` |

- 跟着搬的 API：`speech`、`setSpeech(_:)`、`setAutoSpeech()`、`autoA`、`autoB`、`autoValue`、`glossary`、`vocabulary`；类型 `LiveTranslateSpeech`
  （fixed / auto、`languages`）改名 `SpeechLanguages` 一起搬。`title` 用 `L()`，留在 LiveTranslate 当扩展（显示它的地方都在那边）。
- 调用点一次改完、不留转发成员（约 35 处，编译器会找全）：LiveTranslate 的设置页、字幕条、控制器、会话配置、各识别器、翻译、纠错、术语表编辑器；
  会议 `MeetingSessionController.swift:218`（PR5 后这处随适配器走）；听写三处（§1.4）。
- 不下沉（只有字幕与同传和适配器读）：`livetranslate.source / .translate / .target / .aiCorrection / .display / .fontSize / .opacity / .onDevice /
  .barOrigin / .barFrame`、`livetranslate.voice.*`，以及「保存记录」`livetranslate.record.enabled`、「停止后整理纪要」`livetranslate.record.summary`
  （后者在开记录、收尾时作为参数交给会议库，§4.5.3）。`livetranslate.record.folder` PR6 后只有迁移读，常量挪进会议。

### 4.8 共用类型的去处

纯搬家 + 改名，`rawValue` / `storageValue` 一个不变（meta.json 的 `template`、`meeting.template` 设置存的就是它们）：

| 现在（LiveTranslate） | 改为 | 去哪 | PR |
|---|---|---|---|
| `LiveTranslateSpeaker` | `MeetingSpeaker` | `Core/MeetingEngine/MeetingEngineTypes.swift` | PR2 |
| `LiveTranslateInputLevels` | `MeetingInputLevels` | 同上 | PR2 |
| `LiveTranslateSessionConfig.FinalLine` | `MeetingEngineLine` | 同上 | PR2 |
| `LiveTranslateTranscript.Config` | `MeetingEngineRun` | 同上 | PR2 |
| （新） | `MeetingAudioLane`、`MeetingEngineConfig`、`MeetingEngineEvent` 等 | `Core/MeetingEngine/MeetingEngine.swift` | PR5 |
| （新） | `FreeListeningLibrary`、`FreeListeningRecord` | `Core/MeetingEngine/FreeListeningLibrary.swift` | PR4 |
| `LiveTranslateMinutesTemplate` / `LiveTranslateMeetingStyle` / `LiveTranslateMeetingMinutes` | `MeetingMinutesTemplate` / `MeetingMinutesStyle` / `MeetingMinutesFormat` | `Modules/Meeting/Logic/MeetingMinutesFormat.swift` | PR4 |
| `LiveTranslateTranscript.MinutesOutcome` / `.Event` | `MeetingMinutesOutcome` / `MeetingTranscriptEvent` | `Modules/Meeting/Logic/MeetingTranscriptTypes.swift` | PR4 |
| `LiveTranslateTranscript`（类） | `MeetingTranscript` | `Modules/Meeting/MeetingTranscript.swift`（App 侧：写盘、`L()`、调模型） | PR4 |
| `LiveTranslateMinutes` | `MeetingMinutesGenerator` | `Modules/Meeting/MeetingMinutesGenerator.swift`（App 侧） | PR4 |
| `LiveTranslateRecordSettings` | 不改名 | 留在 LiveTranslate，单独一个文件 | PR4 |

## 5. 可测性

### 5.1 测试 target 的约束

`BaoboxTests` 已随 #134 合进 main（`mac/project.yml`：`bundle.unit-test`，sources 是 `Tests` 与 `Sources/Core/CLIUsage`，不链接 App、不设 `TEST_HOST`，
注释写明「要测别的纯逻辑，把那个目录加进 sources（它不能引用 App / 模块类型）」）。所以被测代码和它引用的一切都得能单独编：只 import Foundation
（加 Combine / os 也行），不调 `L()`（它在 `Core/L10n.swift`），不碰任何 `.shared` 单例，不 import AppKit / SwiftUI。

### 5.2 要拆成纯逻辑的代码

PR7 把会议里要测的东西劈成「纯逻辑」与「App 外壳」两半。

**`Modules/Meeting/Logic/`**（规则同 §3.2 第 3 条，整目录进测试 target）：

- PR4 已经放进来的：`MeetingMinutesFormat`、`MeetingTranscriptTypes`。
- 搬进来、内容不动：`MeetingModels`、`MeetingLibraryFiles`、`MeetingLinkParser`、`MeetingSchedule`、`MeetingDetection`、`MeetingSeries`、`MeetingMarkdown`。
  在 `50103fe` 上把这七个和 `LiveTranslateMinutesFormat.swift`、`LiveTranslateMixing.swift` 一起 `swiftc -typecheck`，不带 App 的任何文件就编得过。
- `MeetingSessionController`：**类名不变**（约 30 处调用方不用改），挪进来，只留决策；同文件的 `MeetingLevelMeter` 跟着走。
- `MeetingTranscriptModel`：从 `MeetingTranscript` 拆出来的文档状态（逐句、「改为」、🔖、说明行、速记、纪要状态）、两种版式的排版（文案经 `Labels` 传入，
  同 `MeetingWeeklyReport.Labels` 的做法）、纪要决策 `decideMinutes(summarizes:terminating:ready:)`。
- `MeetingMinutesPrompts`：从生成器拆出来的提示词、切段（`chunk` / `fit` / `tokens` / `tidy` / `clip`）。
- `MeetingTranscriptNote`（暂停、继续、麦克风 / 系统声音的静音与恢复，文案由文档自己出）、`MeetingTranscriptSpec`（本场文档写成什么样）、
  `MeetingStatus.after(_:)`（原 `MeetingStore.status(after:)`）、`MeetingSessionPorts.swift`（三个端口）。

```swift
/// 会话要会议库做的几件事（MeetingStore 实现，前几个签名与它现在的方法一致）。
@MainActor
protocol MeetingSessionLibrary: AnyObject {
    /// 会议库根目录：会话空闲时 `engineConfig.documentURL` 的兜底（PR5 定下的，引擎这时不会来取）。
    var rootURL: URL { get }
    func createMeeting(type: MeetingType, title: String, start: Date, event: MeetingEventInfo?,
                       template: String) -> MeetingRecord
    func markdownURL(for record: MeetingRecord) -> URL
    func record(_ id: String) -> MeetingRecord?
    func update(_ id: String, sync: Bool, _ change: (inout MeetingMeta) -> Void)
    func finishWriting(_ id: String)
    func discard(_ id: String)
    func flush()
    /// 这场的 meeting.md（App 里是 MeetingTranscript，测试里是假的）：第一次开起来时建，`start` = 那一刻，`run` = 这次怎么跑的。
    func makeTranscript(_ spec: MeetingTranscriptSpec, start: Date, run: MeetingEngineRun) -> MeetingTranscriptWriting
}

/// 一场会议的 meeting.md。
@MainActor
protocol MeetingTranscriptWriting: AnyObject {
    /// 第一笔内容（created）、收尾（finished，在 `finish` 里同步回调）、纪要结果（minutes，之后异步）。
    var onEvent: ((MeetingTranscriptEvent) -> Void)? { get set }
    /// 写盘失败回调一次，参数是给用户看的一行提示（已本地化）。
    var onWriteError: ((String) -> Void)? { get set }
    func update(_ line: MeetingEngineLine)
    func mark(at time: Date)
    func note(_ note: MeetingTranscriptNote, at time: Date)
    func setNotes(_ text: String)
    func continueWith(_ run: MeetingEngineRun, at time: Date)
    func finish(at time: Date, terminating: Bool)
}

/// 会话碰到的 App 侧的东西。App 里的实现是 MeetingSessionShell。
@MainActor
protocol MeetingSessionEnvironment: AnyObject {
    func now() -> Date
    // 开始前
    func captureBusyMessage() -> String?                  // AudioCaptureCoordinator.busyMessage()
    func confirmConsent() -> Bool                         // 确认过就直接 true，否则弹合规说明（NSAlert）
    func calendarBindingCandidate() -> MeetingEventInfo?
    var defaultType: MeetingType { get }                  // MeetingSettings.defaultType
    var minutesStyle: MeetingMinutesStyle { get }         // MeetingSettings.template
    var captureLabel: String { get }                      // L("meeting.captureLabel")
    func typeName(_ type: MeetingType) -> String          // MeetingText.typeName
    // 会中 / 会后
    func setDoNotDisturb(_ on: Bool)                      // NotifyDND，令牌 meeting
    func setHeartbeat(_ running: Bool)                    // 0.25 秒一次的 Timer，回调 tick()
    func controlBar(_ change: MeetingControlBarChange)    // .show / .hide / .refreshSize / .notesExpanded(Bool)
    func refreshIndicators()                              // 菜单栏「● 32:15」
    func toast(_ toast: MeetingSessionToast)              // .alreadyRecording / .busy(String) / .overtime / .nothingRecorded（晚一拍）
    func notifySaved(_ record: MeetingRecord, outcome: MeetingMinutesOutcome)   // 晚一拍，等会议自己的勿扰撤掉
}
```

纯逻辑的会话（只列和现在不同的部分）：

```swift
// Modules/Meeting/Logic/MeetingSessionController.swift
@MainActor
final class MeetingSessionController: ObservableObject, MeetingEngineHost {
    let engine: MeetingEngine
    private let library: MeetingSessionLibrary
    private let environment: MeetingSessionEnvironment
    private var transcript: MeetingTranscriptWriting?     // 本场文档，第一次 .started 时建
    private var terminating = false

    init(engine: MeetingEngine, library: MeetingSessionLibrary, environment: MeetingSessionEnvironment)

    // @Published 状态、Phase、start / pause / mark / setNotes / setSubtitles / 静音 / finish / terminate：逻辑原样，只是
    //   LiveTranslateController.shared.x → engine.x；MeetingStore.shared.x → library.x；文档的事 → transcript?.x（§4.5.2）；
    //   勿扰 / 通知 / 控制条 / 菜单栏 / Timer / NSAlert / 日历 / MeetingSettings / L() → environment.x（调用顺序照旧）

    var engineConfig: MeetingEngineConfig { … }   // owner = "meeting"、label、capture、subtitlesOn、speakers、本场 meeting.md

    func meetingEngine(didReport event: MeetingEngineEvent) {
        switch event {
        case .started(let run): engineStarted(run)   // 开始中：进「记录中」、建文档（补速记）、补字幕、点过结束就收尾；重启：continueWith(run)
        case .line(let line):
            finalLines[line.key] = line
            transcript?.update(line)
        case .ended: ended()                         // 先 transcript.finish → 同步回来的 .finished 写 meta / 作废 → 收 UI → 复位
        case .userAction(.subtitleBarClosed): setSubtitles(false)
        case .userAction(.recordButtonPressed): togglePause()
        case .userAction(.freeListeningTogglePressed): toggleSubtitles()
        }
    }

    /// 外壳的 Timer 每 0.25 秒调一次：电平点；每秒刷新菜单栏指示、查超时。
    func tick()
}
```

**留在 App**：

- `Modules/Meeting/MeetingSessionShell.swift`：`final class MeetingSessionShell: MeetingSessionEnvironment`（控制条、菜单栏项、Timer、勿扰、宠物通知、
  合规对话框、日历候选、文案）。它的 `init` 里不能碰 `MeetingSessionController.shared`（静态常量初始化会递归）。
- `extension MeetingSessionController`：`static let shared = MeetingSessionController(engine: AppDelegate.meetingEngine, library: MeetingStore.shared,
  environment: MeetingSessionShell.shared)`；`statusLine()`（读 `phase`、`elapsed`、`engine.activity`、日历、会议库，用 `L()`）；
  `setCountdown(_:)` 转给外壳（`MeetingReminder` 不用改）。
- `MeetingTranscript`：包着 `MeetingTranscriptModel`，负责写盘队列、纪要任务、登记表与 `abortAllMinutes()`，用 `L()` 组 `Labels`；
  实现 `FreeListeningRecord`（自由听译）和 `MeetingTranscriptWriting`（会议）。
- `MeetingMinutesGenerator`：包着 `MeetingMinutesPrompts` 调 `AIService`。
- `extension MeetingStore: MeetingSessionLibrary`（`makeTranscript` 建 `MeetingTranscript`）。

### 5.3 假引擎与假文档

`mac/Tests/Meeting/FakeMeetingEngine.swift`：

```swift
@MainActor
final class FakeMeetingEngine: MeetingEngine {
    enum Call: Equatable {
        case setPaused(Bool), setMuted(Bool, MeetingAudioLane), setSubtitles(Bool), showNotice(String)
        case finish, toggleFreeListening, terminate
    }
    var acceptsStart = true
    var currentText: String?
    var levels: MeetingInputLevels?
    var activity: MeetingEngineActivity = .idle
    private(set) weak var host: MeetingEngineHost?
    private(set) var starts: [MeetingEngineConfig] = []
    private(set) var calls: [Call] = []

    func start(host: MeetingEngineHost) -> Bool {
        guard acceptsStart else { return false }
        self.host = host
        starts.append(host.engineConfig)
        return true                                       // 不同步报事件（I2）
    }
    func setPaused(_ paused: Bool) { calls.append(.setPaused(paused)) }
    // … 其余照此记一笔
    func takeInputLevels() -> MeetingInputLevels? { levels }

    // —— 测试里扮演引擎 ——
    func report(_ event: MeetingEngineEvent) { host?.meetingEngine(didReport: event) }
    /// 改设置引起的重启（I9）：再取一次配置、带新 run 再报一次 started。
    func restart(_ run: MeetingEngineRun) {
        guard let host else { return }
        starts.append(host.engineConfig)
        host.meetingEngine(didReport: .started(run))
    }
    /// 收尾（I4）：最后几句报完再报 ended。
    func end(lines: [MeetingEngineLine] = []) {
        lines.forEach { report(.line($0)) }
        report(.ended)
    }
}
```

`FakeMeetingTranscript`（实现 `MeetingTranscriptWriting`）记下每次调用；第一笔内容时报 `.created`；`finish` 里同步报 `.finished(end:minutes:terminating:)`
（纪要结果可设，默认 `.generating`）；`completeMinutes(_:)` 再报 `.minutes(…)`。`FakeMeetingLibrary` 的 `makeTranscript` 返回它，另记下
create / update / discard / finishWriting / flush；`FakeMeetingEnvironment` 合规默认确认、不占用、时钟可拨，记下 toast / 勿扰 / 控制条 / 通知。例子：

```swift
func testFinishWhileStartingFinishesRightAfterStarted() {
    let (session, engine, _, _) = makeSession()
    session.start(type: .offline)
    XCTAssertEqual(engine.starts.first?.capture, .microphone)
    session.finish()                                      // 还在开始中：记下，开起来再收尾
    XCTAssertFalse(engine.calls.contains(.finish))
    engine.report(.started(run))
    XCTAssertEqual(session.phase, .finishing)
    XCTAssertTrue(engine.calls.contains(.finish))
}

func testRestartContinuesTheSameTranscript() throws {
    let (session, engine, library, _) = makeSession()
    session.start(type: .online)
    engine.report(.started(run))
    engine.report(.line(line("1-1", "大家好")))
    engine.restart(otherRun)                              // 改了说话语言
    XCTAssertEqual(library.transcripts.count, 1)          // 还是同一份文档
    let transcript = try XCTUnwrap(library.transcripts.first)
    XCTAssertEqual(transcript.calls.last, .continueWith(otherRun))
    XCTAssertEqual(session.phase, .recording)
}

func testEndedWithoutStartedDiscardsTheMeeting() throws {
    let (session, engine, library, _) = makeSession()
    session.start(type: .online)
    let id = try XCTUnwrap(session.meetingID)
    engine.report(.ended)                                 // 没开起来：权限被拒、识别不可用
    XCTAssertTrue(library.transcripts.isEmpty)            // 从没建过文档
    XCTAssertEqual(library.discarded, [id])
    XCTAssertEqual(session.phase, .idle)
}
```

### 5.4 能覆盖的 / 覆盖不了的

能覆盖（纯逻辑 + 假引擎 + 假文档）：

- 开始：空闲才开；记录中再开只提示；占用时提示、不弹合规说明；合规取消不开；对话框期间别处开了不开；线上手动开始自动绑日历候选、线下不绑；
  标题取事件标题或类型名；引擎拒绝 → 作废这场、回到空闲、不挂勿扰不开控制条；引擎收到的配置（线上 `.microphoneAndSystem` + `speakers`、
  线下 `.microphone`、字幕默认关、`documentURL` 是本场的 meeting.md）。
- 开起来：第一次 `.started` 才建文档，头信息 / 模板 / 说话人按本场；开始中写的速记、开的字幕在这时补上；开始中点了结束 → 开起来马上收尾；
  重启再报的 `.started` 只 `continueWith`，不建第二份、不动状态。
- 会中：暂停 / 继续 / 单路不录各记一行（开始中不记）；🔖 记距开始秒数与当时那句（截 200 字）并写进文档；速记去重并写进文档；
  字幕开关的拦法（收尾中不行、相同不发）；字幕条上三种操作的含义；文档写失败 → `engine.showNotice`。
- 结束：录 / 停中 → 收尾中 + `engine.finish`；`.ended` 时先收尾文档再收 UI；有内容的留下，meta 的结束时间、状态、重点（只算当前这场）、
  行动项（只在 `.done` 时解析）；纪要还在整理时先不 `finishWriting`；一句没有 → 作废，非退出时提示；没开起来 → 作废、不提示；
  属于上一场的纪要结果不碰当前这场。
- 退出：开始中 → 作废、不碰引擎；进行中 → `engine.terminate`，文档以「退出」收尾、meta 同步写；没等到 `.ended` 也收尾；总是 `flush`。
- 心跳：暂停时电平点灰；绑了日历、超过结束 5 分钟提示一次。
- 文档模型（`MeetingTranscriptModel`）：两种版式的整份输出（固定 `Labels` 下的金样）、排版 → `MeetingMarkdown` 解析的往返（转录行、说话人、🔖、速记、纪要一节）、
  设置没变不记「改为」、速记去首尾空白、纪要决策表（关 / 退出 / 没模型 / 太短 / 整理）、喂给模型的行带「【重点】」与说话人。
- `MeetingMinutesPrompts`（切段预算、合并截断、`tidy`、`clip`）、`MeetingMinutesFormat`（行动项宽松解析、占位行、截止时间、重点窗口），
  以及搬进 `Logic/` 的七个纯文件。

覆盖不了（照旧靠编译 + 真机，§7）：适配器与 `LiveTranslateController` 的对接（真识别、真混音）、文档的写盘时机与原子写、`AIService` 的真实调用、
控制条 / 菜单栏 / 通知的样子、`MeetingStore` 的写盘（根目录写死在 Application Support，要测得另外开口子，不在本次）。

## 6. 迁移步骤

每个 PR 单独可合并、能编译、用户看不出变化（§2 的几处差别：前两条出现在 PR3，日志 category 在 PR4）；按依赖排序。行号指 `50103fe`。
搬家的 PR 用 `git diff -M --color-moved=zebra` 看，搬过去的代码应当整块着色、只有改名处不同。

| PR | 一句话 | 依赖 |
|---|---|---|
| PR1 | 说话语言、专有名词表下沉 `Core/Translation/SpeechSettings.swift` | 无 |
| PR2 | 句子、说话人、电平、「这次怎么跑的」四个值类型下沉 `Core/MeetingEngine/` | 无 |
| PR3 | 会议自己驱动 meeting.md：引擎的托管会话不再碰文档（类还在 LiveTranslate） | PR2 |
| PR4 | 写文档的类与纪要生成器搬进会议；自由听译经 `FreeListeningLibrary` 写会议库 | PR3 |
| PR5 | `MeetingEngine` 协议 + 适配器 + `AppDelegate.meetingEngine`，会议改走协议 | PR4（PR1 先合更顺） |
| PR6 | 会议库构造注入，删静态与旧路径的界面 | PR5 |
| PR7 | 会话、文档模型与排版、纪要提示词拆成纯逻辑 | PR5（建议 PR6 之后） |
| PR8 | 单元测试 | PR7 |

### PR1 共用的说话语言与专有名词表下沉 Core

`refactor(speech): move shared speech language and glossary settings to Core (#107)`

- 新增 `Core/Translation/SpeechSettings.swift`（§4.7）。
- 改：`LiveTranslateController.swift`（删 `LiveTranslateSettings` 里搬走的成员与 `LiveTranslateSpeech`，`target` 的默认值改读 `SpeechSettings.speech`，
  `title` 扩展留在这里）、`LiveTranslateSettingsView`、`LiveTranslateBar`、`LiveTranslateSessionConfig`、`LiveTranslateRecognition`、
  `LiveTranslateDualRecognizer`、`LiveTranslateSwitchingRecognizer`、`LiveTranslateTranslator`、`LiveTranslateCorrector`、`LiveTranslateGlossaryEditor`、
  `MeetingSessionController.swift:218`、`DictationSettings.swift:140`、`DictationController.swift:191`、`DictationSettingsView.swift:21`。
- 行为不变：键名字面量原样，读写逻辑整块搬。
- 验证：编译；§7.2 的设置键对比；设置页说话语言 / 自动 A、B / 术语表显示原值；听写「跟随」的标题与术语条数不变。
- 文档：`translation-engine/DESIGN.md` §4、`live-translate/DESIGN.md` §7 注明键定义在 `SpeechSettings`。

### PR2 四个共用值类型下沉 Core

`refactor(meeting): move line, speaker, level and run types to Core (#107)`

- 新增 `Core/MeetingEngine/MeetingEngineTypes.swift`：`MeetingSpeaker`、`MeetingInputLevels`、`MeetingEngineLine`、`MeetingEngineRun`（§4.2）。
- 改（只换类型名）：`LiveTranslateMixing`（说话人判定）、`LiveTranslateMixedSource`（电平）、`LiveTranslateController`（`Line.speaker`、`takeInputLevels`、
  `record` 里组的句子、`transcriptConfig`）、`LiveTranslateSessionConfig`（`onFinalLine` 的参数）、`LiveTranslateTranscript`（`Config`、说话人）；
  `MeetingSessionController`（`finalLines`、`MeetingLevelMeter`）。
- 行为不变：`MeetingSpeaker` 的 rawValue 照旧 `me` / `them`，其余是同形状的结构体换名。
- 验证：编译；开一场线上会议，说话人与电平点照常。

### PR3 会议自己驱动 meeting.md

`refactor(meeting): let Meeting drive its own transcript; hosted sessions no longer write files (#107)`

这一步改的是「谁驱动会议的文档」，写文档的类（`LiveTranslateTranscript`）先不动地方，下一步再搬。会议此时仍直接用 `LiveTranslateController.shared`（PR5 才换协议）。

- `LiveTranslateSessionConfig`：去掉 `transcript`（只有托管会话用过）；加 `speakers: Bool`、`documentURL: URL?`；`Lifecycle.started` 带 `MeetingEngineRun`。
- `LiveTranslateController`：
  - 托管会话不再建、不再写文档：`startTranscript` 对托管会话只在第一次开起来时把字幕条「记录」按钮置为在记、重启时不动（`:1129–1153`）；`record(line)` 对托管会话只报 `onFinalLine`，
    记下第一句后 `transcriptURL = documentURL`（`:1196–1208`）；`setPaused` 对托管会话只把「记录」按钮跟着暂停走、不记说明行（`:1034–1042`）；
    `setLaneMuted` 不记说明行（`:1046–1055`）；删 `addTranscriptMark`、`setTranscriptNotes`（`:1063–1070`）。
  - `settleSpeaker` 看 `sessionConfig.speakers`（`:1118`）；`setRecording` 的「不是托管会话」改看 `followsSettings`（`:1171`）。
  - `startFlow` 组好 `run` 后在最后报 `.started(run)`（`:696–700`、`:772`）；加 `showNotice(_:)`。
  - `terminate()` 不再 `lastTranscript?.abortMinutesIfRunning()`，`lastTranscript` 删掉（`:388`、`:515–520`）。自由听译这条路不动。
- `LiveTranslateTranscript`：加「正在整理纪要」的登记表与 `static func abortAllMinutes()`。
- `MeetingSessionController`（§4.5.2 整张表）：`begin` 照旧组 `Destination`，但不交给引擎；第一个 `.started(run)` 时用它建 `LiveTranslateTranscript`，
  写失败交给 `LiveTranslateController.shared.showNotice`；`.line` 写进文档；暂停 / 继续 / 静音 / 🔖 / 速记直接写；重启 `continueWith`；
  `.ended` 先 `transcript.finish` 再走原来的作废与收 UI；`terminate()` 先置 `terminating`，`engine.terminate()` 之后没等到 `.ended` 就自己收尾。
  `engineConfig` 带 `speakers`、`documentURL`。
- `MeetingTool.willTerminate`：在引擎 `terminate()` 之后加 `LiveTranslateTranscript.abortAllMinutes()`、`MeetingStore.shared.flush()`（§4.5.5）。
- 行为：除 §2 的前两条差别外不变 —— 文档对象、写法、版式、纪要都是原来那一套，只是由会议喂。
- 验证：§7.3 会议部分整张清单（1–16）。
- 文档：`TECH_DESIGN.md` §2.3、§3 指向本文；`live-translate/DESIGN.md` §6 写明托管会话不写文档。

### PR4 写文档的类与纪要生成器搬进会议

`refactor(meeting): move the transcript writer and minutes generator into Meeting (#107)`

- 新增 `Core/MeetingEngine/FreeListeningLibrary.swift`（§4.5.3）。
- 搬家 + 改名（§4.8）：`LiveTranslateTranscript` 类 → `Modules/Meeting/MeetingTranscript.swift`（`Destination` 换成会议自己的参数：文件、名字、版式、
  说话人、模板、整理与否、发不发自由听译的通知）；`LiveTranslateMinutes` → `Modules/Meeting/MeetingMinutesGenerator.swift`（加 `route` / `isReady`，
  keep-alive 收进 `generate`）；`LiveTranslateMinutesFormat.swift` → `Modules/Meeting/Logic/MeetingMinutesFormat.swift`；`MinutesOutcome` / `Event` →
  `Modules/Meeting/Logic/MeetingTranscriptTypes.swift`；`LiveTranslateRecordSettings` 留在 LiveTranslate、单独成文件。
- 改：`LiveTranslateController` 自由听译改用 `FreeListeningRecord`（§4.5.3）；静态 `recordLibrary` 的类型换成 `FreeListeningLibrary?`（PR6 删）；
  删 `LiveTranslateRecordLibrary`、`Destination.legacy` 与 `convenience init(start:config:)`（写回 ~/Documents 的路径；静态为空时不记录、记一条 fault 日志，
  到不了）。`MeetingStore` 实现 `FreeListeningLibrary`；`MeetingSessionController`、`MeetingReports`、`MeetingSettings`、`MeetingText`、`MeetingSettingsView`、
  `MeetingTool` 换成会议这边的类型名。日志 category 换成 `meeting.transcript`（`LiveTranslateLog.transcript` 删掉；引擎那条「会议库没装上」的 fault 记在
  `livetranslate.recognition`）。`LiveTranslateSettingsSections` 加 `minutesReady` 参数（§4.5.4），实时翻译目录里不再出现 `.meetingMinutes` 与会议模块的类型。
- 提交分两个：先纯搬家（`git mv` + 把原文件按类型拆成三个文件，一行不改），再改名与改引用，`git diff -M --color-moved=zebra` 各看各的。
- 行为不变：类与生成器整块搬，版式、文案、纪要逻辑一字不改；自由听译的记录照旧进会议库、照旧发「实时翻译纪要已整理好」。
- 验证：§7.3 自由听译与会议库几项（17–22）、会议 7、9；`git diff --color-moved` 核对整块搬家。
- 文档：`live-translate/DESIGN.md` §6（记录由会议库写）、§8（文件表）；`translation-engine/DESIGN.md` §3.3（日志 category）；`TECH_DESIGN.md` §2.3。

### PR5 会议改走 `MeetingEngine`

`refactor(meeting): drive the engine through a MeetingEngine protocol (#107)`

- 新增 `Core/MeetingEngine/MeetingEngine.swift`（§4.1、§4.2）、`Modules/LiveTranslate/LiveTranslateMeetingEngine.swift`（§4.4；这一步
  `toggleFreeListening` 先调 `toggle()`，还没有 `recordLibrary`）。
- `AppDelegate.swift`：`static let meetingEngine`（§4.6），改 `:32` 的注释。
- `MeetingSessionController.swift`：`init(engine:)`、`let engine`；实现 `MeetingEngineHost`（`engineConfig` 换成 `MeetingEngineConfig`，
  `meetingEngine(didReport:)` 合并原来三个回调）；剩下的 `LiveTranslateController.shared.x` 全部换成 `engine.x`，设置读取随适配器走。
- `MeetingTool.swift`：快捷键动作、环形菜单标题、`willTerminate`、`MeetingMenu` 都经 `MeetingSessionController.shared.engine`；`:93` 的功能声明照旧（白名单）。
  这一步 `activate()` 里的静态赋值还在（PR6 删）。
- 行为不变：适配器逐行对照 `MeetingSessionController.swift:212–238`；`activity` 与旧判断一一对应（菜单 `isRunning` ⇔ `.freeListening`：
  会议空闲时引擎在跑只可能是自由听译）。
- 落地时定下的两处细节：`MeetingEngineConfig.documentURL` 照本文不是可选的，会话在空闲时（引擎不会来取）的兜底是会议库根目录；
  装配链在第一次碰 `MeetingSessionController.shared` 时建好（启动时 `MeetingReminder.start()` 刷倒计时就会碰到），
  `LiveTranslateController.shared` 因此比原来（建菜单栏菜单时）早一点建出来，都在启动流程里、看不出差别。
- 验证：§7.3 会议与自由听译整张清单。
- 文档：根目录 `CLAUDE.md` 的 Core 清单加 `MeetingEngine/`、docs 布局加本文。

### PR6 会议库构造注入，删静态

`refactor(livetranslate): hand the meeting library to the engine at construction (#107)`

- 改：`LiveTranslateSessionConfig`、`LiveTranslateController`（`toggle(startingWith:)`、`restartIfRunning`、开记录、`recordFolder`）、`LiveTranslateRecordSettings`、
  `LiveTranslateSettingsView`（加 `recordFolder` 参数，`minutesReady` PR4 已有；删「更改…」）、`LiveTranslateBar`、`LiveTranslateMeetingEngine`、`AppDelegate`（传 `MeetingStore.shared`）、
  `MeetingStore`（迁移用自己的旧键常量）、`MeetingTool`（删 `:98`、改 `:26`）、`MeetingSettingsView`（传目录）、
  `Localizable.xcstrings`（删 `livetranslate.record.choose`、`.choosePrompt`）。细节见 §4.6。
- 行为不变：静态在现在的启动流程里总是装上的，「有会议库」一直是唯一走得到的分支；删掉的都是到不了的分支。
- 验证：§7.3 自由听译几项（含「启动后第一个动作就开自由听译」）；用一份有旧记录文件夹、`meeting.migratedLegacy` 为 false 的配置启动，迁移照常。
- 文档：`live-translate/DESIGN.md` §6–§7（保存位置一节）。
- 落地时定下的几处细节：
  - 迁移要读的两个旧键是 `MeetingStore` 里的私有常量（`legacyRecordEnabledKey` / `legacyRecordFolderKey`，字面量不变）；`defaultFolder` 删了以后，
    旧版的默认位置（「文稿」+ `livetranslate.record.defaultFolderName`，名字随界面语言）也在 `legacyFoldersToMigrate()` 里照原样算。要看的文件夹清单不变。
  - `toggle(startingWith:)` 收的是配置本身：适配器每次都组一份 `.fromSettings(recordLibrary:)`，结果是停止或转给托管方时就丢掉（只读设置，没有副作用）。
  - 控制器开过会话之前的占位配置是 `.fromSettings(recordLibrary: nil)`，不拿它开会话；`startTranscript` 里「配置没带会议库就不记录、记一条 fault」
    留着兜可选值，走不到。`recordFolder` 为 nil 时字幕条的文件夹按钮什么也不做（字幕条只在适配器开的会话里出现，总带着会议库）。
  - 设置页「保存位置」下的说明行（`livetranslate.record.libraryHelp`）原来看「静态装上没有」决定显不显示（实际总是显示），现在无条件显示。
  - 验证：真代码抽进探针，与 main（PR5 合入后）逐字对比会议与自由听译 38 个场景（含启动后第一个动作就按快捷键开自由听译、自由听译中途切换整理纪要、
    开着字幕改设置重启、关着保存重启后再打开保存）全部一致，字幕条文件夹按钮与设置页「保存位置」都指向会议库、没有「更改…」；
    另一个「会议模块没 activate 就开自由听译」的场景按预期不同：main 的记录进不了会议库、文件夹指向「文稿」，本 PR 照样进会议库（§1.5）。
    迁移要看的文件夹清单在八种设置组合 × 中英界面下与 main 一致。

### PR7 会话、文档模型与纪要提示词拆成纯逻辑

`refactor(meeting): split session decisions and transcript rendering from the AppKit shell (#107)`

- `git mv` 七个纯文件到 `Modules/Meeting/Logic/`；新增 `Logic/MeetingSessionPorts.swift`、`MeetingTranscriptModel`、`MeetingMinutesPrompts`、
  `MeetingTranscriptNote`、`MeetingTranscriptSpec`、`MeetingStatus.after(_:)`；`MeetingSessionController` 挪进 `Logic/` 并改用端口；
  新增 `Modules/Meeting/MeetingSessionShell.swift`；`MeetingTranscript`、`MeetingMinutesGenerator` 改成包着纯逻辑的外壳（§5.2）。
- 改：`MeetingStore`（实现 `MeetingSessionLibrary`、`status(after:)` 移走）。
- 行为不变：每个方法里的副作用按原顺序换成端口调用。例：`begin` 仍是「`engine.start` 成功 → 勿扰 → 心跳 → 控制条 → 指示器」；
  `ended` 仍是「收尾文档（→ meta 或作废）→ 撤勿扰 → 停心跳 → 收控制条 → 复位 → 指示器」。排版拆成纯函数后输出逐字不变（PR8 的金样测试钉住）。
- 建议与 PR8 一起上，拆的时候就有测试兜底。
- 验证：同 PR5 的整张清单。
- 落地时定下的几处细节：
  - `makeTranscript(_:start:run:)`：`MeetingTranscriptSpec` 在开始时组好（文件、名字、头信息、说话人、模板，同原来在 `begin` 里组的
    `Destination`），第一次 `.started` 时再带上那一刻与 `run` 建文档 —— 与原来的 `MeetingTranscript(start:config:destination:)` 一一对应。
    `MeetingTranscriptSpec` 取代了 `MeetingTranscript.Destination`（少了 `onEvent`：它成了文档上的属性，`MeetingTranscriptWriting.onEvent`），
    会议库开自由听译记录也用它。`MeetingSessionLibrary` 多一个 `rootURL`（上面的兜底要它）。
  - 说明行：会话只交 `MeetingTranscriptNote`，文案由文档的 `Labels` 出（key 仍是 `livetranslate.record.doc.*`）。原来在记下时就取好文案、
    现在排版时取；界面语言要重启才换（`L10n`），同一个进程里取到的是同一句。
  - `MeetingStatus.after(_:)`、`MeetingTranscriptNote`、`MeetingTranscriptSpec` 放在 `Logic/MeetingTranscriptTypes.swift`。
  - `MeetingMinutesPrompts` 连输入行（`contentRows` / `meetingRows`）和会议纪要的分段预算（`meetingBudget`）一起拿走，生成器只剩选模型、
    常驻、调用；`MeetingMinutesGenerator.Line` 是 `MeetingMinutesPrompts.Line` 的别名，周报直接借 `MeetingMinutesPrompts.clip`。
  - `ended()` 收录音指示改成复位之后调 `refreshIndicators()`（空闲时就是收起），与原来复位前直接 `statusItem.update(nil)` 等价。
    纪要决策的 `ready`（`MeetingMinutesGenerator.isReady`）在收尾时先取好再交给模型（它只读状态，原来短路求值，结果一样）。
  - 外壳：`MeetingSessionShell`（`init` 不碰 `shared`）+ `extension MeetingSessionController`（`static let shared`、`setCountdown(_:)`、`statusLine()`）。
    `MeetingLevelMeter` 随会话进 `Logic/`；会话 `import Combine`（`ObservableObject`）与 `os`（日志）。
  - 验证：PR6 的金样探针改成「PR6 合入后的 main 对本分支」，编真的外壳与纯逻辑，40 个场景（原 39 个 + 新加的「绑了日历事件：标题、参会人、日历、
    速记、🔖」）整份输出逐字一致；三处故意改坏（`ended` 里收控制条与撤勿扰换序、一条说明行文案、「太短」的边界）都被它查出来。

### PR8 单元测试

`test(meeting): cover the session, transcript and minutes logic (#107)`

- `mac/project.yml` 的 `BaoboxTests.sources` 加 `Sources/Core/MeetingEngine`、`Sources/Modules/Meeting/Logic`
  （可选再加 `Sources/Modules/LiveTranslate/LiveTranslateMixing.swift`，测混音与说话人判定，它本来就是纯的）。
- `mac/Tests/Meeting/`：假引擎 / 假文档 / 假会议库 / 假环境，`MeetingSessionTests`、`MeetingTranscriptModelTests`（金样 + 与 `MeetingMarkdown` 往返）、
  `MeetingMinutesPromptsTests`、`MeetingMinutesFormatTests`，以及七个纯文件的测试（§5.4）。
- 验证：`xcodebuild test`（§7.2）；CI 跑同一条。
- 落地：`mac/Tests/Meeting/` 14 个文件，163 个测试（加上原有的 34 个共 197 个）。
  - `MeetingTestSupport.swift`：§5.3 的四个假对象 + 一本按先后记副作用的账（断言 R16 的调用序列）；假文档里跑一份真的 `MeetingTranscriptModel`，
    会话测试能直接看 meeting.md；固定中文文案逐字取自 `Localizable.xcstrings`。
  - `MeetingTranscriptModelTests` 的金样（`MeetingTranscriptGoldens.swift`）是探针里旧代码（PR6）实际写到盘上的五份 meeting.md，测试照探针里那份文档
    收到的调用逐个重放；时刻按本机时区造，在哪个时区跑都一样。
  - 另加 `LiveTranslateMixing.swift` 的测试（环形缓冲、抖动缓冲与混音、节拍时钟、说话人判定）。
  - #149 没修：两个标了 `XCTExpectFailure` 的测试把现状钉住（重启失败、重启成功后结束都会让字幕条上的旧句子以新的运行次数重报一遍 ——
    探针 s06 / y08 / x05 里重启成功的场景同样重复，比 #149 写的范围大）。修 #149 时它们会「意外通过」，那时翻成正面断言。
  - 三处故意改坏（控制条先于 `engine.start` 打开、开起来时不补写之前定稿的句子、「太短」的边界）各有测试失败。

### P2 候选（另开 issue）

1. **采集链路下沉 `Core/Audio/`**：音频路由、PCM 转换、麦克风 / 系统声音源、混音（含 `LiveTranslateMixing`），以及听写借用的 `LiveTranslateAudioGate`、
   `LiveTranslateScoring`。设备自检和听写从此不引用 LiveTranslate。
2. 会议设置页的「字幕与同传」区块、「AI」页的两个功能声明改由引擎提供，清掉 §3.3 剩下两项。
3. 会议文档写盘失败时，字幕关着就看不到提示（现状，本次照旧）；要不要改走 `StorageWriteFailure`（宠物提示一次）另议。

## 7. 风险与验证

### 7.1 最容易搬坏的行为

| # | 行为 | 现在靠什么 | 搬坏了是什么样 | 怎么防 / 验 |
|---|---|---|---|---|
| R1 | 收尾冲刷（I4） | `finish()` 先停音频、等 final 最多 1.5 秒；`stop()` 先强制记下最后几句再结束会话 | 会议在点「结束」时就收尾文档（而不是等 `.ended`），或引擎先报 `.ended` 再报最后几句 → 最后半句丢 | 会议只在 `.ended` 里收尾；测试按 I4 喂；真机 7 |
| R2 | `.ended` 里的先后 | 现在跨模块靠事件顺序 | 先复位再收尾文档 → `meetingID` 已清空，`.finished` 被当成别的会议：重点丢、该作废的没作废 | `ended()` 第一步收尾文档；测试断言调用顺序；真机 7、11 |
| R3 | 暂停（含线下会议） | 混音器 `setPaused`，只有 `usesMixer` 时才有混音器；跨重启保留 | 适配器漏了 `usesMixer` → 线下会议暂停不起作用、没有电平 | 两种会议都 `usesMixer = true`；真机 2、10 |
| R4 | 「我 / 对方」与单路不录 | `.mixed` + 文档的 `speakers` + 混音器 lane | 配置漏传 `speakers` → 线上没标说话人；lane 映射反了静错路；说明行没记 | 映射表逐项核；真机 1、3 |
| R5 | 纪要触发与通知 | 会议文档：总是整理、不发自由听译的通知、`.meeting(style)`；自由听译：跟开关、发通知、`.content` | 参数串了 → 关了自由听译的纪要开关后会议也不整理、两条通知、纪要格式错 | 两处建文档的参数逐项核；真机 7、8、19 |
| R6 | App 退出同步写完（I5） | 整条链同步 + `willTerminate` 先会话后引擎 + `flush` | 会议没先置 `terminating`、事件隔拍、漏了登记表 → meta 没写结束时间、状态卡在「记录中 / 整理中」 | 转发不隔拍；`terminate` 先置标志再停引擎、有兜底；§4.5.5 四步；真机 13、14 |
| R7 | 改设置重启续写（I9） | `rebuild` 回调托管方重组；`continueWith` 续写同一份 | 每次 `.started` 都建新文档 → 一场会议两个文件；适配器漏了 `rebuild` → 会议变自由听译、卡在「记录中」 | 只在「开始中」建文档；适配器必设 `rebuild`；真机 6 |
| R8 | 开始中的补发与时序（I2） | `.started` 时补发速记与字幕；`start` 只排 `Task` | 开始中写的速记、开的字幕丢了；同步报 `.ended` 让控制条与勿扰残留 | 测试覆盖；真机 4、11 |
| R9 | 文档版式逐字不变 | 版式代码在引擎里 | 搬家或拆纯函数时改了一个字 → 会议库解析、重新生成纪要、周报读不对 | PR4 整块搬（`--color-moved` 核对）；PR8 金样 + 往返测试；真机 9、22 |
| R10 | 纪要整理期间文档的寿命 | 纪要任务强持有文档 | 会话复位时丢了引用、任务又没持有 → 纪要写不回去、meta 卡在「整理中」 | 任务与登记表持有；真机 15 |
| R11 | 写盘失败提示 | 引擎把提示放进字幕条 | 会议的写失败没人管 | `onWriteError` → `engine.showNotice`；真机 16 |
| R12 | 字幕条「记录」按钮与「打开本次记录」（会议） | 跟着引擎自己的转录 | 按钮不跟暂停走；「打开本次记录」不出现或指错文件 | 引擎按暂停状态 + `documentURL`；真机 5 |
| R13 | 自由听译的记录（PR4、PR6） | 引擎写、静态给位置 | 不进会议库；中途打开记录不补已有的句子；重启后丢了会议库 | 经 `FreeListeningLibrary`；重启带过去；真机 17–21 |
| R14 | 菜单 / 环形菜单标题 | 读 `isRunning`、`isHostedSession`、`barVisible` | 「停止 / 开始自由听译」「打开 / 收起字幕」错 | `activity` 一一对应（§4.4）；真机 12、17 |
| R15 | 设置键 | 键名字面量 | 升级后用户设置丢 | 常量原样搬；§7.2 前后对比；真机 25 |
| R16 | PR7 的副作用顺序 | 现在内联在一个方法里 | 例：控制条先于 `engine.start` 打开，start 失败后残留 | 逐方法按原顺序调端口；测试断言调用序列 |

### 7.2 编译与静态检查

```bash
# 编译（Mac 上；只编不装，不碰 /Applications —— 并行会话会互相覆盖安装）
cd mac && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Baobox -configuration Debug -derivedDataPath "$SCRATCH/DerivedData" build
# 没有 mac/Vendor/ 也能编：拷 llama-server、虚拟麦克风驱动的脚本阶段会跳过

# 单测（scheme 的 Test 动作跑 BaoboxTests，#134 起就有；PR8 起包含会议）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Baobox -derivedDataPath "$SCRATCH/DerivedData"

# 本地化表仍是合法 JSON（在仓库根目录跑）
python3 -c "import json;json.load(open('mac/Sources/Resources/Localizable.xcstrings'));print('valid')"

# 设置键前后一致（每个 PR 都跑）。这个模式也会匹配 L("livetranslate.…") 文案 key：
# 只允许少掉 PR6 删的两条文案，设置键一个都不能少
git grep -hoE '"livetranslate\.[A-Za-z.]+"' 50103fe -- mac/Sources | sort -u > "$SCRATCH/keys-before"
git grep -hoE '"livetranslate\.[A-Za-z.]+"' HEAD    -- mac/Sources | sort -u > "$SCRATCH/keys-after"
diff "$SCRATCH/keys-before" "$SCRATCH/keys-after"

# 边界（PR6 起）：会议目录里只剩 §3.3 白名单；实时翻译目录里不出现会议模块的类型与 .meetingMinutes
grep -rn 'LiveTranslate' mac/Sources/Modules/Meeting --include='*.swift' | grep -v '^[^:]*:[0-9]*:[[:space:]]*//'
grep -rnE '\bMeeting(SessionController|Store|Tool|Settings|Text|Calendar|Reminder|Detector|Transcript|MinutesGenerator)\b|\.meetingMinutes' \
  mac/Sources/Modules/LiveTranslate --include='*.swift'
```

### 7.3 真机回归清单

装本地构建后跑（安装由主会话 / 用户做）。macOS 14 上系统翻译不可用，字幕译文走离线模型；系统翻译那条路只能在 15+ 上验
（适配器对它只是原样转发 `setBarVisible`，风险低）。PR3 起每个 PR 至少跑会议部分，PR4、PR6 加跑自由听译部分。

会议（线上，戴耳机）：

1. 开始 → 控制条出现、菜单栏「● 0:00」、两路电平点会亮；说两句 → meeting.md 里有 `**时间 我**` / `**时间 对方**`。
2. 暂停 → 说话 → 继续：暂停期间的话不进记录，记录里有「暂停 / 继续」两行；状态行显示已暂停。
3. 点麦克风图标 → 说话不进记录、图标变红，记录有「麦克风静音 / 恢复」；喇叭同理。
4. 开始中（控制条还显示「正在开始」时）就展开速记写一行 → 开起来后速记一节里有它；会中 🔖 → 会后纪要的「重点」带上标记那段。
5. 打开字幕 → 字幕条 + 译文；字幕条「记录」按钮 = 暂停 / 继续，与控制条同步；说过一句后它旁边的按钮打开的是这场的 meeting.md；字幕条 ✕ → 只收字幕、会议照记。
6. 会议中在字幕条或设置里改说话语言 → 会议不断，还是同一个 meeting.md、有「改为：…」行，暂停 / 静音状态不丢，结束照常。
7. 话说到一半点结束 → 最后半句也在记录里；纪要整理完只有一条「纪要已生成」；会议库状态「已生成」，行动项解析出来。
8. 关掉「字幕与同传 → 记录与纪要 → 停止后用本地 AI 整理纪要」（先打开「保存记录」才看得到这个开关）再开一场会议 → 会议照样整理纪要。
9. 拿一份改动前生成的 meeting.md 对照新生成的：标题、头信息各行、「纪要 / 速记 / 转录」三节、转录行与说明行的写法一致。

会议（线下）：

10. 只有麦克风电平点；暂停有效（暂停期间的话不进记录）；转录行不带「我 / 对方」。

边界：

11. 开始中马上点结束 → 开起来后立即收尾；开起来后什么都没说就结束 → 不留空会议，提示「这次什么也没记下」；拒绝麦克风权限 → 弹权限说明，
    不留空会议，也不出「什么也没记下」。
12. 会议中按 `livetranslate.toggle` / 点菜单「打开字幕」/ 环形菜单「翻译」→ 切字幕，标题跟着变。
13. 会议进行中退出 Baobox → 重开后会议库里这场有转录，纪要一节写没整理完，状态仅转录。
14. 会议结束后纪要还在整理，接着开一次自由听译（开着保存）说两句停掉，在两份纪要都没整理完时退出 → 两份都写「纪要没整理完」，都不卡在「整理中」。
15. 上一场的纪要还在整理时开始下一场 → 上一场的纪要照样写完、状态更新，下一场不受影响。
16. （可选）把这场会议的目录设成只读（`chmod -w`）后打开字幕 → 字幕条上有「记录写不进去：…」，只提示一次。

自由听译：

17. 菜单「开始自由听译」→ 字幕条；✕ 停止；记录按钮开关保存；开着保存时会议库多一条「… 自由听译」，纪要好了是「实时翻译纪要已整理好」那条通知。
18. 关着保存开始、中途打开 → 字幕条上已有的几句补进新记录；中途关掉 → 这一份就此收尾。
19. 关掉「停止后整理纪要」后停止 → 记录里没有纪要一节；录到一半再打开 → 停止时按那时的开关整理。
20. 启动后第一个动作就用快捷键开自由听译（不先打开会议菜单或设置）→ 记录照样进会议库（验证装配与顺序无关）。
21. 设置页「保存位置」显示会议库路径、没有「更改…」，「打开记录文件夹」打开会议库；字幕条上还没记下句子时的文件夹按钮同样打开会议库。

会议库：

22. 会议库里「重新生成纪要」、菜单「生成本周周报」照常。

听写与互斥：

23. 听写「跟随」显示的语言、术语表条数与改动前一致；听写照常认专有名词。
24. 听写进行中开始会议 → 提示正在听写，不弹合规说明。

升级：

25. 用改动前的 UserDefaults（说话语言 = 自动、A / B、术语表、纪要模板 = 站会、保存记录开、停止后整理纪要关）启动 → 设置页显示不变。

## 8. 已拍板（2026-11-10）

1. **共用设置**：在同目录新建 `Core/Translation/SpeechSettings.swift`（不塞进做引擎解析的 `TranslationSettings.swift`）。→ §4.7、PR1。
2. **转录（meeting.md）与纪要**：这次就挪到会议，不放 P2。引擎对会议只报句子、说话人、电平、生命周期；会议的文档由会议自己写，自由听译的记录经
   `FreeListeningLibrary` 由会议库写；纪要生成器与「能不能整理」的判断都在会议。→ §3.4、§4.5、PR3、PR4。
3. **装配**：`AppDelegate` 上的不可变静态常量 `AppDelegate.meetingEngine`，`MeetingSessionController.shared` 懒加载时取它。→ §4.6、PR5。
4. **删除旧的写入路径**：写回 `~/Documents/Baobox 实时翻译记录/` 的分支（PR4）与设置页「更改…」、`folder` 设置的界面（PR6）。`livetranslate.record.folder`
   只留给旧记录迁移读。
5. **会话拆纯逻辑与单元测试算在 #107 里**：即 PR7、PR8（原稿编号 PR5、PR6）。`BaoboxTests` 已在 main，不用再等，建议两个一起上。

改的过程中没有出现必须另请你决定的新问题。§2 列的几处有意的细小差别（主要是退出时把所有还在整理的纪要都标「没整理完」）如果不想要，说一声就按现状保留。
