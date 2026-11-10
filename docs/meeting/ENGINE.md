# 会议引擎接口（MeetingEngine）· 技术设计

> issue #107「会议与实时翻译实现焊死，没有引擎接口」。状态：**设计稿，待拍板（§8）**，还没有代码改动。
> 基线：main `50103fe`（2026-11-10，#106 已合并）。下文路径都相对 `mac/Sources/`，行号以这个提交为准。
> 相关：`TECH_DESIGN.md` §2–§3、§9（引擎改造与会议会话的落地记录），`../live-translate/DESIGN.md` §6–§7，
> `../translation-engine/DESIGN.md` §4，`../ai-service/DESIGN.md` §3.3、§5.3–§5.4。

## 0. 一页看懂

**现在**：会议（`Modules/Meeting/`）直接驱动字幕与同传的单例 `LiveTranslateController.shared`，替它组内部配置
（`LiveTranslateSessionConfig`、`LiveTranslateTranscript.Destination`），读它的设置和混音器下标；反过来，引擎要靠会议模块
`activate()` 里给可变静态 `LiveTranslateController.recordLibrary` 赋值，才知道自由听译的记录该进会议库。

**改成**：

1. `Core/MeetingEngine/` 定义 `MeetingEngine` 协议和它用到的值类型（句子、说话人、电平、转录进度、纪要结果），只依赖 Foundation。会议只认它。
2. `Modules/LiveTranslate/LiveTranslateMeetingEngine.swift` 是唯一的适配器：把会议的配置翻成引擎配置、把引擎回调翻成事件。
   会议专属的规则（沿用「字幕与同传」的语言与纠错、字幕关着只转录、会议总是整理纪要……）从 `MeetingSessionController` 挪到这里。
3. 装配只在 `AppDelegate` 一处：`static let meetingEngine = LiveTranslateMeetingEngine(controller:recordLibrary:)`。
   会议库作为构造参数交给引擎，`recordLibrary` 静态删掉；懒加载、建好不变，与注册 / activate 顺序无关。
4. 说话语言与专有名词表（字幕与同传、会议、听写共用）下沉到 `Core/Translation/SpeechSettings.swift`，**键名不变**。
5. 会话的决策逻辑拆成纯逻辑（`Modules/Meeting/Logic/`），在 `BaoboxTests` 里配假引擎测。

分 6 个 PR（§6），每个单独可合并、能编译、用户看不出变化。转录（meeting.md）与纪要的归属、采集链路下沉放到 P2。

术语：**托管会话** = 会议经引擎开的会话（线上 / 线下会议）；**自由听译** = 引擎自己的会话（原实时翻译，入口在会议菜单里）；
**适配器** = `LiveTranslateMeetingEngine`；**装配点** = 唯一同时认识会议和字幕与同传的那行代码。

## 1. 现状

### 1.1 #106 之后谁是谁

- 会议（`MeetingTool`）是产品入口：线上 / 线下会议、「开始自由听译」菜单项、`livetranslate.toggle` 快捷键、嵌入的「字幕与同传」设置，
  「AI」页里字幕翻译与 AI 纠错两个功能也由它声明。
- `Modules/LiveTranslate/` 退成引擎层：识别、翻译、纠错、混音、字幕条、朗读、转录与纪要（`LiveTranslateTranscript`），以及自由听译本身
  （`followsSettings` 的会话）。
- 会议的引擎就是 `LiveTranslateController.start(config:)`（`TECH_DESIGN.md` §2.1）。会议的 meeting.md 也是引擎写的：会议给一个 `Destination`，
  引擎边识别边写、结束后整理纪要，再经 `Destination.onEvent` 报回会议库。

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

**引擎内部的配置与回调类型（会议替引擎组装）**

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
`Modules/DesktopPet/PetController.swift:951`），本地化 key `livetranslate.record.doc.minutes / .listSeparator`（`MeetingReports.swift:63, 168`、
`MeetingText.swift:131`、`MeetingLibraryView.swift:380`）。

### 1.3 实时翻译 → 会议（反向）

1. **记录注入**（上表）：引擎持有会议库的引用，靠会议模块启动时赋值。
2. **为托管长出来的引擎能力**：`LiveTranslateSessionConfig` 整个文件就是托管接口；`LiveTranslateController.swift:398–415`（`sessionOpen`、
   `mixedSource`、`audioPaused`、`mutedLanes`、`speakerBaseline`、`barVisible`、`barGeneration`）、`:508–512`（`isHostedSession`、`showsSourceMenu`）、
   `:924–1070`（`finish`、`closeBar`、`setBarVisible`、`setPaused`、`setLaneMuted`、`takeInputLevels`、`addTranscriptMark`、`setTranscriptNotes`）、
   `:1115–1124`（说话人判定）。这些是引擎「能被托管」的本事，P1 保留，只是以后只经适配器用。
3. **会议的文档格式写在引擎里**：meeting.md 的版式（`LiveTranslateTranscript.swift:433–460`）、会议纪要的提示词（`:604–636`、`:782–886`）、
   纪要模板 / 类型 / 行动项解析（`LiveTranslateMinutesFormat.swift` 整个文件）。会议这边 `MeetingMarkdown` 按同一版式解析，
   `MeetingReports.swift:63` 按「纪要」标题找那一节替换 —— 两个模块之间有一份没写成代码的格式契约。
4. 文案：`LiveTranslateBar.swift:746` 托管时字幕条「记录」按钮的说明（`livetranslate.record.toggleHelpMeeting`）。

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
  再 `MeetingStore.flush()`），再 `LiveTranslateController.terminate()`（自由听译收尾；还在整理的纪要标「没整理完」，经回调同步写 meta）；
  之后 `AppDelegate` 才 `OfflineTranslator.shutdownAll()`。P1 保持这个顺序，并写进协议注释（§4.3 I5）。

### 1.6 与 issue 描述不一致的地方

1. `MeetingSessionController` 的 14 个行号与当前 main 一致，但漏了 `:352`、`:355`（开起来后补发速记 / 字幕）。`LiveTranslateController.shared`
   实为 16 行；连同设置、混音下标与类型引用，这一个文件约 40 处。
2. 静态注入现在在 `MeetingTool.swift:98`（#106 在前面加了快捷键声明，`:81` 现在是环形菜单标题里的 `controller.isRunning`）；
   `recordLibrary` 声明在 `LiveTranslateController.swift:417`（`:416` 是它的注释）。
3. `AppDelegate.swift:35–36` 那条注释 #106 已删；注册顺序之间的依赖没了，activate 副作用这个根子还在（§1.5），`MeetingTool.swift:26` 留着过时注释。
4. `Core/Translation/TranslationSettings.swift` **已经存在**，是翻译引擎解析（`TranslationSettings.resolve`，依赖 `OfflineTranslator`、
   `AIFeatureSettings`、`AIModelStore`、`LocalModels`），进不了不链接 App 的测试 target。建议另建同目录的 `SpeechSettings.swift`（§8 第 1 条）。
5. 「共用的语音 / 词汇设置」真正的共用者是听写（读 `vocabulary`、`vocabularyKey`、`speech.languages`）。`target` / `translateEnabled` /
   `aiCorrection` 只有会议在读，适配器接手后不用下沉。
6. 协议不止 start / pause / finish / lines / mute / setNotes：还要字幕开关、🔖、电平、退出、自由听译的开关与状态（#106 后菜单和快捷键在会议里），
   一条事件通道（开起来 / 结束 / 定稿句 / 字幕条上的操作 / 转录进度），以及改设置重启时取配置的回调。
7. 会议对实时翻译的依赖不止 `MeetingSessionController` / `MeetingTool`：`MeetingStore`（记录库协议、迁移读旧设置、纪要结果类型）、
   `MeetingReports`（纪要生成器）、`MeetingDeviceTest`（混音链路）、`MeetingSettings` / `MeetingText` / `MeetingSettingsView`（纪要模板类型、
   嵌入设置区块）都有。
8. 「会议可脱离 LiveTranslate 单独测」单靠协议做不到：`MeetingSessionController` 还直接碰 `MeetingStore`、`NotifyCenter` / `NotifyDND`、
   `AudioCaptureCoordinator`、`MeetingCalendar`、`NSAlert`、控制条 / 菜单栏项与 `Timer`，测试 target 又不链接 App ——
   要把会话的决策拆成纯逻辑（§5、PR5）。

## 2. 目标与非目标

目标：

1. 会议只认 `Core/MeetingEngine/` 里的协议与值类型。PR4 之后 `Modules/Meeting/` 里不再出现 `LiveTranslateController`、`LiveTranslateSettings`、
   `LiveTranslateSessionConfig`、`LiveTranslateTranscript`、`LiveTranslateMixerCore`、`LiveTranslateRecord*`（白名单见 §3.3）。
2. 适配器是会议与引擎之间唯一的翻译层，会议专属的规则集中在它身上。
3. 会议库作为构造参数交给引擎，`recordLibrary` 静态删掉；装配只在 `AppDelegate` 一处，懒加载、不可变、与注册顺序无关。
4. 说话语言、专有名词表下沉到 Core，听写不再引用 `LiveTranslateSettings`；**设置键名一个都不变**。
5. 会话的决策逻辑拆成纯逻辑，能在 `BaoboxTests` 里配假引擎测。
6. 每一步单独可合并、能编译、行为不变。

非目标：

- 不改任何用户可见行为：菜单、快捷键 id、设置键与默认值、文案、通知、meeting.md 版式、会议库目录与 meta.json。
- 不引入第二个引擎实现（假引擎只在测试里）。
- 不改引擎内部逻辑（识别、翻译、纠错、混音、字幕条、朗读）；`LiveTranslateController` 只动「自由听译怎么拿到会议库」这一处（PR4）。
- 不挪转录（meeting.md）与纪要的归属（P2，§8 第 2 条）。
- 不挪采集链路（设备自检、听写借用的引擎工具，P2）。
- 不改本地化 key 的命名。
- 不把 `MeetingSessionController.shared` 改成全链路构造注入（§8 第 3 条）。

## 3. 总体设计

### 3.1 分层

现在：

```
MeetingTool.activate() ─── 赋值 ──▶ LiveTranslateController.recordLibrary（可变静态）
MeetingSessionController ─ 16 处调用 ─▶ LiveTranslateController.shared
                         ─ 读设置 ────▶ LiveTranslateSettings
                         ─ 组内部配置 ─▶ LiveTranslateSessionConfig / LiveTranslateTranscript.Destination
                         ─ 用混音下标 ─▶ LiveTranslateMixerCore
MeetingStore ─── 实现 ──▶ LiveTranslateRecordLibrary（声明在 LiveTranslate）
```

改后：

```
Core/MeetingEngine/            协议 + 值类型，只依赖 Foundation
   ▲            ▲
   │            └── Modules/LiveTranslate    引擎；LiveTranslateMeetingEngine 实现协议
   └─────────────── Modules/Meeting          会话、会议库、界面；只认协议
AppDelegate.meetingEngine      装配点：建适配器、把会议库交给它；唯一同时认识两边
```

### 3.2 依赖规则

1. 箭头只指向 Core：会议不引用 `LiveTranslate*`（§3.3 白名单除外），实时翻译不引用会议模块的类型（`MeetingSessionController`、`MeetingStore`…）；
   两边都可以用 Core 里 `Meeting*` 前缀的值类型。
2. 唯一同时认识两边的是装配点（`AppDelegate.meetingEngine`）。
3. `Core/MeetingEngine/` 与 `Modules/Meeting/Logic/` 只放只依赖 Foundation（外加 Combine / os）的文件：不调 `L()`、不碰 `.shared` 单例、
   不 import AppKit / SwiftUI —— 整个目录编进 `BaoboxTests`。

### 3.3 P1 之后允许保留的直接引用（白名单）

| 位置 | 引用 | 为什么留 / 什么时候清 |
|---|---|---|
| `MeetingDeviceTest.swift` | `LiveTranslateMixedSource`、`LiveTranslateAudioRouter`、`LiveTranslateMixer.sampleRate` | 自检要录的就是「识别器听到的那一路」；P2 把采集链路下沉 `Core/Audio/` |
| `MeetingSettingsView.swift` | `LiveTranslateSettingsSections(recordFolder:)` | 界面组装；P2 可改由引擎提供 |
| `MeetingTool.swift` | `aiFeatures()` 里的 `.liveTranslate`、`.liveCorrection` | 「AI」页分组；功能 id 跟着引擎走（`ai-service/DESIGN.md` §3.3） |

### 3.4 三个关键取舍

1. **会议不再读「字幕与同传」的任何设置**。会议只说「线上还是线下、开不开字幕、记到哪」；说什么语言、译成什么、纠不纠错、读不读译文，
   由引擎按自己的设置定。「会议沿用字幕与同传的语言与纠错」「字幕关着只转录」「纠错与翻译解耦（`.always`）」这些规则搬进适配器。
   协议里于是没有一个字幕与同传的概念，将来换引擎时用它自己的设置。
2. **P1 转录仍由引擎写**（所以协议照 issue 带 `setNotes` / `addMark` 和转录事件）。收尾冲刷、退出同步写完、改设置续写「改为：…」、
   写盘失败提示这些已经调好的行为原地不动；搬家放 P2（§8 第 2 条）。
3. **装配用不可变的静态常量**，不用 setter（§4.5）。

## 4. 接口设计

### 4.1 协议

`Core/MeetingEngine/MeetingEngine.swift`（PR3 新增，只依赖 Foundation）：

```swift
/// 托管方（会议会话）：引擎从它取配置、向它报事件。引擎只弱引用它。
@MainActor
protocol MeetingEngineHost: AnyObject {
    /// 此刻的会话配置。开始时取一次；运行中改了引擎自己的设置（说话语言、译成、朗读…）、要重建识别链路时再取一次 ——
    /// 这时转录接着写同一份，托管方会再收到一次 `.started`。
    var engineConfig: MeetingEngineConfig { get }
    /// 引擎的事件。一律在主线程、按发生顺序报；可能在托管方调引擎方法的过程中同步报回来（§4.3）。
    func meetingEngine(didReport event: MeetingEngineEvent)
}

/// 会议记录要的「把会上的声音变成一句句文字，写进这场的 meeting.md」。实现：LiveTranslateMeetingEngine。
@MainActor
protocol MeetingEngine: AnyObject {
    // MARK: 托管会话（线上 / 线下会议）

    /// 开一场。false = 没开：别的会话还在 / 正在开，或麦克风被听写等占着（引擎已经发过「正在 XX，先停止再开始」）。
    /// true 之后一定**异步**报 `.started` 或 `.ended`（权限被拒、识别不可用、音源打不开），不在这个调用里报。
    func start(host: MeetingEngineHost) -> Bool
    /// 暂停 / 继续：暂停 = 不往识别器送音频，会话不停（手头那句照常定稿）；转录记一行。开始中也收，开起来时生效。
    func setPaused(_ paused: Bool)
    /// 单独不录某一路：这一路换成等长静音送进去（两路仍对齐），另一路照录，电平随之为 0；转录记一行。开始中也收。
    func setMuted(_ muted: Bool, lane: MeetingAudioLane)
    /// 字幕条显示 / 收起；显示时译不译按引擎自己的翻译开关。没在运行时不做 —— 托管方在 `.started` 时再设一次。
    func setSubtitles(_ visible: Bool)
    /// 🔖：转录记一行；整理纪要时这一刻前 20 秒、后 5 秒内开始的句子加「【重点】」。
    func addMark(at time: Date)
    /// 速记（整份替换）：写进转录的「速记」一节，整理纪要时作为上下文。转录还没开始时丢掉 —— 托管方在 `.started` 时再设一次。
    func setNotes(_ notes: String)
    /// 屏幕上最新那句的原文（没定稿的也算）；没有为 nil。🔖 记「标记时在说什么」用。
    var currentText: String? { get }
    /// 两路电平：上次取走以来每路的最大 RMS（0…1），取一次清一次；暂停中为 0；没在托管会话里为 nil。
    func takeInputLevels() -> MeetingInputLevels?
    /// 结束：先停音频，等最后一句定稿（最多 1.5 秒）再停。不用等它返回：结果经事件报 ——
    /// 最后几句的 `.line` → `.transcript(.finished)` → `.ended`。没在运行时不做。
    func finish()

    // MARK: 自由听译（引擎自己的会话；入口在会议里，#106）

    /// 此刻在跑什么：会议菜单、`livetranslate.toggle` 在环形菜单里的标题、状态行用。
    var activity: MeetingEngineActivity { get }
    /// 「开始自由听译」开关：没在跑 → 按引擎自己的设置开一次（记录进会议库）；自由听译中 → 停；
    /// 托管会话中 → 报 `.userAction(.freeListeningTogglePressed)`，由托管方决定（会议：切字幕）。
    func toggleFreeListening()

    // MARK: 退出

    /// App 退出：停下来，转录同步写完（纪要标「没整理完」）；上一份还在整理的纪要也标「没整理完」。
    /// 返回前，该报的事件都已同步报完（托管方在回调里同步写 meta.json）。可以重复调用。
    func terminate()
}
```

对照 issue 列的六个：`start` → `start(host:)`；`pause` → `setPaused`；`finish` → `finish`；`lines` → `currentText` + `.line` 事件；
`mute` → `setMuted(_:lane:)`；`setNotes` → `setNotes`。多出来的几个都有现成的调用方（§1.2）。

为什么用「托管方协议」而不是在配置里塞闭包：配置里不带闭包就能 `Equatable`，测试直接比；引擎重启时取配置、报事件走同一个对象，假引擎好写；
和 AppKit 的 delegate 一个读法。`finish()` 不做成 `async`：会议从来不等它，结果都经事件回来，测试里也不用等 `Task`。

### 4.2 数据模型

`Core/MeetingEngine/MeetingEngine.swift` 与 `Core/MeetingEngine/MeetingTranscriptTypes.swift`（后者 PR2 新增）：

```swift
/// 一场托管会话要什么。会议只说「线上还是线下、开不开字幕、记到哪」，怎么识别、译不译、纠不纠错由引擎定。
struct MeetingEngineConfig: Equatable {
    enum Capture: Equatable {
        /// 线上会议：麦克风 + 系统声音混成一路进一个识别器，按两路音量判「我 / 对方」。
        case microphoneAndSystem
        /// 线下会议：只有麦克风（照样走混音链路：要电平）。
        case microphone
    }
    /// 占用登记（AudioCaptureCoordinator）的 owner，也是占用冲突提示的通知来源：`meeting`。
    var owner: String
    /// 占用冲突时给用户看的名字（已本地化：「会议记录」）。
    var label: String
    var capture: Capture
    /// 字幕条（+ 译文）开着。运行中用 `setSubtitles` 切，重启时按这里重组。
    var subtitles: Bool
    var transcript: MeetingTranscriptPlan
}

/// 这场的 meeting.md：引擎边识别边写（说完一句记一句，至多 1 秒整份重写一次），结束后整理纪要，进度经事件报回。
struct MeetingTranscriptPlan: Equatable {
    /// 会议库里这场的 id：转录事件带着它回来（纪要整理完时可能已经开了下一场）。
    var recordID: String
    var fileURL: URL
    /// 通知、日志里提到的名字（目录名）。
    var displayName: String
    var title: String
    /// 「线上会议」「线下会议」（已本地化）。
    var kind: String
    var start: Date
    var attendees: [String]
    /// 绑定的日历事件来自哪个日历。
    var calendar: String?
    /// 每句标「我 / 对方」（线上会议）。
    var speakers: Bool
    /// 纪要模板。会议总是整理纪要，「纪要已生成」由会议自己发。
    var style: MeetingMinutesStyle
}

enum MeetingEngineEvent: Equatable {
    /// 开起来了。改设置引起的重启会再报一次。
    case started
    /// 一句定稿；之后纠错 / 译文回来再报（同一 `key`，后到的覆盖先到的）。收尾时没定稿的最后一句也报。
    case line(MeetingEngineLine)
    /// 会话结束（结束、识别出错停了、没开起来），每场恰好一次。转录开过的话 `.transcript(.finished)` 一定先到。
    case ended
    /// 用户在引擎自己的界面上点的；是什么意思由托管方定。
    case userAction(MeetingEngineUserAction)
    /// 转录进度，`recordID` = `MeetingTranscriptPlan.recordID`。
    case transcript(recordID: String, MeetingTranscriptEvent)
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

/// 一句。
struct MeetingEngineLine: Equatable {
    /// 本场里唯一（改设置重启后句子 id 从头编，键里带着第几次运行）。
    let key: String
    /// 这句第一次出字的时刻。
    let time: Date
    /// 显示用的原文（有 AI 纠错就是纠正后的），去掉首尾空白，不会是空的。
    let original: String
    /// 空 = 没翻（字幕关着、不翻译、或这句本来就是「译成」的语言）。
    let translation: String
    /// 线上会议按两路音量判的说话人；判不准或不是线上会议为 nil。
    let speaker: MeetingSpeaker?
}

/// 说话人：「我」= 麦克风，「对方」= 系统声音。判法（近似）在引擎里：一句期间有人声（RMS > 0.01）累计 ≥ 0.3 秒算显著，
/// 系统声音显著且 ≥ 麦克风的 35% → 对方；否则麦克风显著 → 我；都弱 → nil（TECH_DESIGN.md §9）。
enum MeetingSpeaker: String, Codable, Equatable {
    case me
    case them
}

/// 两路电平（0…1 的 RMS 峰值）；nil = 没有这一路（线下会议没有系统声音）。会议每 0.25 秒取一次，
/// 自己按 0.006 判亮灭（比判「有人在说话」的 0.01 低一点）。
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

/// 纪要怎么样了（会议库据此更新状态）。与现在的 `LiveTranslateTranscript.MinutesOutcome` 一一对应。
enum MeetingMinutesOutcome: Equatable {
    case off
    case generating
    case done(String)
    case failed(String)
    case noModel
    case tooShort
    /// App 退出了，没整理完。
    case interrupted
}

/// 转录进度。与现在的 `LiveTranslateTranscript.Event` 一一对应。
enum MeetingTranscriptEvent: Equatable {
    /// 记下了第一句（或第一笔速记）：这场有内容了。
    case created
    /// 收尾：结束时间、纪要怎么处理；`terminating` = App 正在退出（要同步写完）。
    case finished(end: Date, minutes: MeetingMinutesOutcome, terminating: Bool)
    /// 纪要整理完 / 失败 / 没整理完（只在 `.finished` 报了 `.generating` 之后）。
    case minutes(MeetingMinutesOutcome)
}
```

电平保持「会议来取」而不是引擎推：混音每 20 ms 一块，推事件太密；现在就是 0.25 秒取一次峰值，照旧。

### 4.3 线程与事件约定

| # | 约定 | 现在靠什么保证 / 为什么要 |
|---|---|---|
| I1 | 协议方法只在主线程调，事件只在主线程报 | 协议 `@MainActor`；`@Published` 只在主线程写 |
| I2 | `start` 返回 true 之后才（异步）报 `.started` 或 `.ended`；返回 false 什么都不报 | 引擎 `start(config:)` 只排一个 `Task`。会议在 `start` 返回后才挂勿扰、开控制条（`MeetingSessionController.swift:182–185`），同步报 `.ended` 会让控制条和勿扰留在那儿 |
| I3 | 一场里 `.started` 零到多次（重启会再报），`.ended` 恰好一次 | `endSession()` 有 `sessionOpen` 守门；会议只在「开始中」时进「记录中」 |
| I4 | 收尾顺序：最后几句的 `.line`（含没定稿的）→ `.transcript(.finished)` → `.ended`，连续报完、中间不让出主线程 | `stop()` 里先 `record(line, force: true)`，再 `finishTranscript()`，再 `endSession()`。会议在 `.ended` 时看「转录收尾过没有」决定作废这场（`:371`），顺序反了就把有内容的会议当成没开起来删掉；🔖 的重点要算上最后那句 |
| I5 | `terminate()` 返回前，`.transcript(.finished(terminating: true))`、`.transcript(.minutes(.interrupted))` 都已同步报完；**转发不能隔一拍**（不能包 `Task` / `DispatchQueue.main.async`） | 会议在回调里 `MeetingStore.update(sync: true)`，紧接着 `flush()`；隔一拍的话 App 退出前 meta.json 来不及写 |
| I6 | 转录事件按 `recordID` 认人，可能在 `.ended` 之后、甚至下一场开始之后才到（纪要） | `transcriptEvent(_:meetingID:)` 带 id |
| I7 | `userAction` 只在托管会话运行中报 | 只有托管配置有 `onUserRequest` |
| I8 | 重入：事件可能在托管方调引擎方法的过程中同步到达（`terminate`、`toggleFreeListening`、`finish` 里的停止） | 现在就是这样，会议的处理已经容得下 |
| I9 | 改设置重启：引擎重新取 `host.engineConfig`，转录接着写同一份（`recordID` 不变），暂停 / 单路不录的状态保留，托管方只会再收到一次 `.started` | 引擎 `restartIfRunning` + `sessionOpen` |

这些写进协议的文档注释；假引擎（§5.3）默认按它们的顺序报。

### 4.4 适配器 `LiveTranslateMeetingEngine`

`Modules/LiveTranslate/LiveTranslateMeetingEngine.swift`（PR3 新增）。不让 `LiveTranslateController` 直接实现协议：控制器还管自由听译与字幕条，
接口形状也不同（配置结构体 + 闭包）；包一层可以一行不动控制器（自由听译的回归风险最小），会议专属的规则也有一个固定的家。

| `MeetingEngine` | `LiveTranslateController` |
|---|---|
| `start(host:)` | `start(config:)`（配置见下） |
| `setPaused(_:)` | `setPaused(_:)` |
| `setMuted(_:lane:)` | `setLaneMuted(_:lane:)`：`.microphone` → `LiveTranslateMixerCore.microphoneLane`，`.system` → `.systemLane` |
| `setSubtitles(_:)` | `setBarVisible(_:translate: LiveTranslateSettings.translateEnabled)` |
| `addMark(at:)` / `setNotes(_:)` | `addTranscriptMark(at:)` / `setTranscriptNotes(_:)` |
| `currentText` | `lines.last?.original` |
| `takeInputLevels()` | `takeInputLevels()` |
| `finish()` | `Task { await finish() }` |
| `activity` | `isHostedSession` → `.hosted(subtitlesVisible: barVisible)`；否则 `isRunning` → `.freeListening`；否则 `.idle` |
| `toggleFreeListening()` | `toggle()`（PR4 起 `toggle(startingWith: .fromSettings(recordLibrary:))`） |
| `terminate()` | `terminate()` |
| `.started` / `.ended` | `onLifecycle` |
| `.line` | `onFinalLine`（字段一一对应） |
| `.userAction` | `onUserRequest`：`.closeBar` → `.subtitleBarClosed`，`.toggleRecording` → `.recordButtonPressed`，`.toggle` → `.freeListeningTogglePressed` |
| `.transcript` | `Destination.onEvent`（PR2 后它报的就是 `MeetingTranscriptEvent`，不用翻） |
| `host.engineConfig` | `rebuild` |

会议专属的规则从 `MeetingSessionController.swift:190–238` 原样挪过来（两个小的转换 init 写在适配器文件里）：

```swift
private func sessionConfig(for meeting: MeetingEngineConfig, host: MeetingEngineHost?) -> LiveTranslateSessionConfig {
    var config = LiveTranslateSessionConfig(
        owner: meeting.owner, label: meeting.label,
        sources: meeting.capture == .microphoneAndSystem ? .mixed : .microphone,
        speech: SpeechSettings.speech,                                            // 沿用「字幕与同传」的说话语言
        target: LiveTranslateSettings.target,
        translate: meeting.subtitles && LiveTranslateSettings.translateEnabled,   // 字幕关着只转录
        showsBar: meeting.subtitles,
        correction: LiveTranslateSettings.aiCorrection ? .always : .off,          // 只转录时也纠错
        transcript: destination(for: meeting.transcript, host: host))
    config.usesMixer = true                  // 线下会议也走混音链路：电平、暂停都靠它
    config.recordLibrary = recordLibrary     // PR4：字幕条「打开记录文件夹」
    config.onFinalLine = { [weak host] line in host?.meetingEngine(didReport: .line(MeetingEngineLine(line))) }
    config.onLifecycle = { [weak host] in host?.meetingEngine(didReport: $0 == .started ? .started : .ended) }
    config.onUserRequest = { [weak host] in host?.meetingEngine(didReport: .userAction(MeetingEngineUserAction($0))) }
    // 改设置引起的重启：按托管方此刻的配置再翻一遍。不能落回 `.fromSettings()` —— 那样会议中途变成自由听译，
    // 托管方再也收不到事件，会议卡在「记录中」。
    config.rebuild = { [weak host] in self.sessionConfig(for: host?.engineConfig ?? meeting, host: host) }
    return config
}

private func destination(for plan: MeetingTranscriptPlan, host: MeetingEngineHost?) -> LiveTranslateTranscript.Destination {
    var destination = LiveTranslateTranscript.Destination(
        fileURL: plan.fileURL, displayName: plan.displayName,
        header: .init(title: plan.title, kind: plan.kind, start: plan.start,
                      attendees: plan.attendees, calendar: plan.calendar))
    destination.speakers = plan.speakers
    destination.template = .meeting(plan.style)
    destination.summaryFollowsSetting = false    // 会议总是整理纪要，不看自由听译的纪要开关
    destination.notifiesMinutes = false          // 「纪要已生成」由会议自己发
    let id = plan.recordID
    destination.onEvent = { [weak host] in host?.meetingEngine(didReport: .transcript(recordID: id, $0)) }   // 同步转发（I5）
    return destination
}
```

- `rebuild` 强引用适配器：适配器和控制器都是常驻单例，这个环无害。
- 重建时 `destination` 也跟着重建，但引擎续写的是已有的 `LiveTranslateTranscript` 对象（`startTranscript` 里 `if let transcript { continueWith }`），
  新 `Destination` 只用来读 `speakers` 这类值 —— 与现在会议每次返回同一份 `destination` 等价。

### 4.5 装配与 `recordLibrary` 的构造注入

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

// Modules/Meeting/MeetingSessionController.swift（PR5 后挪到 App 侧的扩展里，§5.2）
static let shared = MeetingSessionController(engine: AppDelegate.meetingEngine)
```

- 为什么是静态常量而不是「注册时 setter」：`MeetingSessionController.shared` 有约 30 处调用方（8 个文件），要在注册时塞引擎只能 setter，
  那只是把「可变注入」换了个地方 —— 谁在注册前用了它就拿到空的。`static let` 第一次被用到时按需把依赖一串建好（`LiveTranslateController.shared`、
  `MeetingStore.shared` 的 init 都很轻），没有可变状态，也就没有顺序。
- 去掉 `.shared`、全链路构造注入更纯，但要改约 10 个文件（提醒、检测、简报、设置页、控制条、菜单、报告…），见 §8 第 3 条。
- 模块引用 `AppDelegate` 已有先例（`MeetingTool.swift:198` 的 `AppDelegate.shared?.registry`）。

**`recordLibrary` 改成跟着会话走**（PR4）：

1. 新增 Core 协议，会议库实现它（`MeetingStore` 从此不引用任何 LiveTranslate 类型）：

   ```swift
   // Core/MeetingEngine/FreeListeningLibrary.swift
   /// 自由听译的新记录也进会议库（TECH_DESIGN.md §2.3）。MeetingStore 实现；装配时交给引擎。
   @MainActor
   protocol FreeListeningLibrary: AnyObject {
       /// 会议库根目录（设置页「保存位置」、字幕条「打开记录文件夹」）。
       var folderURL: URL { get }
       /// 开一份新的自由听译记录：会议库里新的一条（记下第一句时才登记进索引，一句没有不留痕迹）。
       func newFreeListeningRecord(start: Date) -> FreeListeningRecord
   }

   struct FreeListeningRecord {
       let fileURL: URL
       let displayName: String
       /// 记录的进度报回会议库。
       let report: @MainActor (MeetingTranscriptEvent) -> Void
   }
   ```

2. `LiveTranslateSessionConfig` 加 `recordLibrary: FreeListeningLibrary?`，`fromSettings()` 改成 `fromSettings(recordLibrary:)`；适配器建的两种配置都带上它。
3. `LiveTranslateController`：删 `static var recordLibrary`；`toggle()` 改成 `toggle(startingWith:)`（自由听译的配置由适配器给），删无参的 `start()`；
   `restartIfRunning()` 落回 `.fromSettings` 时把 `sessionConfig.recordLibrary` 带过去；`startTranscript` 用 `sessionConfig.recordLibrary` 开新记录
   （`FreeListeningRecord` → `Destination`，模板、纪要开关、通知都按自由听译原来的默认值）；加 `recordFolder: URL?`（读会话配置里的会议库目录）给字幕条用。
4. `LiveTranslateTranscript.swift`：删 `LiveTranslateRecordLibrary`、`Destination.legacy`、`convenience init(start:config:)`、`effectiveFolder`；
   `openFolder()` 改成 `openFolder(_ url: URL)`；`folderKey`、`folder`、`defaultFolder` 只剩迁移在用，挪进会议（键名字面量不变，要看的旧文件夹清单不变）。
5. 设置页：`LiveTranslateSettingsSections(recordFolder: URL)`，「记录与纪要」一节固定显示会议库目录（现在就是这样，因为静态总是装上的），
   删掉到不了的「更改…」与 `folder` 的 `@AppStorage`，以及只有它用的两条文案（`livetranslate.record.choose`、`.choosePrompt`）。
   `MeetingSettingsView` 传 `MeetingStore.shared.rootURL`。
6. 字幕条「打开记录文件夹」读 `controller.recordFolder`。
7. `MeetingTool.activate()` 删掉赋值那一行，`MeetingTool.swift:26` 的过时注释一起改。

改完后「自由听译写到哪」只取决于开会话时谁把会议库递进来 —— 只有适配器开会话，适配器是带着会议库建出来的，没有第二条路。

### 4.6 设置下沉：`Core/Translation/SpeechSettings.swift`

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
  会议 `MeetingSessionController.swift:218`（PR3 后这处随适配器走）；听写三处（§1.4）。
- 不下沉（只有字幕与同传和适配器读）：`livetranslate.source / .translate / .target / .aiCorrection / .display / .fontSize / .opacity / .onDevice /
  .barOrigin / .barFrame`、`livetranslate.record.enabled / .summary`、`livetranslate.voice.*`。`livetranslate.record.folder` 在 PR4 后只有会议的迁移读，
  常量挪进会议，字面量不变。
- 为什么不塞进 `TranslationSettings.swift`：那个文件是翻译引擎解析，依赖 App 单例，塞进去后这几个设置也进不了测试；说话语言、术语表又不只给翻译用
  （听写不翻译）。

### 4.7 共用的值类型下沉（PR2）

纯搬家 + 改名，`rawValue` / `storageValue` 一个不变（meta.json 的 `template`、`meeting.template` 设置存的就是它们）：

| 现在（LiveTranslate） | 改为（Core） | 文件 |
|---|---|---|
| `LiveTranslateSpeaker` | `MeetingSpeaker` | `Core/MeetingEngine/MeetingTranscriptTypes.swift` |
| `LiveTranslateInputLevels` | `MeetingInputLevels` | 同上 |
| `LiveTranslateTranscript.MinutesOutcome` | `MeetingMinutesOutcome` | 同上 |
| `LiveTranslateTranscript.Event` | `MeetingTranscriptEvent` | 同上 |
| `LiveTranslateMinutesTemplate` | `MeetingMinutesTemplate` | `Core/MeetingEngine/MeetingMinutesFormat.swift`（原 `LiveTranslateMinutesFormat.swift`，已是纯的） |
| `LiveTranslateMeetingStyle` | `MeetingMinutesStyle` | 同上 |
| `LiveTranslateMeetingMinutes` | `MeetingMinutesFormat` | 同上 |
| `LiveTranslateMinutes`（生成器与提示词） | `MeetingMinutesGenerator` | `Core/Minutes/MeetingMinutesGenerator.swift`（用 `AIService`、`L()`，不纯，**不放** `Core/MeetingEngine/`） |

引擎内部（混音、说话人判定、转录）直接用 Core 的类型，适配器就不用来回翻。

## 5. 可测性

### 5.1 测试 target 的约束

`refactor/usage-calculator` 分支加的 `BaoboxTests`（`bundle.unit-test`）只编 `mac/Tests/` 和点名的纯逻辑源码目录（那个分支是 `Sources/Core/CLIUsage`），
不链接 App（没有 `TEST_HOST`）。所以被测代码和它引用的一切都得能单独编：只 import Foundation（加 Combine / os 也行），不调 `L()`
（它在 `Core/L10n.swift`，不在测试 target 里），不碰任何 `.shared` 单例，不 import AppKit / SwiftUI。

### 5.2 要拆成纯逻辑的代码

`MeetingSessionController` 是会议里最该测、也最难测的：一半是决策（状态机、开始的各种拦法、开始中点结束、引擎事件、转录事件、作废与否、重点），
一半是 App 的东西（会议库读写盘、宠物通知、勿扰、合规对话框、日历、控制条、菜单栏项、`Timer`、文案）。PR5 把它劈开。

**新目录 `Modules/Meeting/Logic/`**（规则同 §3.2 第 3 条，整目录进测试 target）：

- 搬进来、内容不动：`MeetingModels`、`MeetingLibraryFiles`、`MeetingLinkParser`、`MeetingSchedule`、`MeetingDetection`、`MeetingSeries`、`MeetingMarkdown`。
  这七个已经只依赖 Foundation，彼此之外不引用别的类型（文件里提到的别的类型都在注释里）：在 `50103fe` 上把它们和 `LiveTranslateMinutesFormat.swift`、
  `LiveTranslateMixing.swift` 一起 `swiftc -typecheck`，不带 App 的任何文件就编得过。`TECH_DESIGN.md` §8 说的「swiftc 直接跑」的单测从此有正式的家。
- `MeetingSessionController`：**类名不变**（约 30 处调用方不用改），挪进来，只留决策；同文件的 `MeetingLevelMeter` 跟着走。
- `MeetingStatus.after(_:)`（原 `MeetingStore.status(after:)`）。
- `MeetingSessionPorts.swift`：两个端口。

```swift
/// 会话要会议库做的几件事（MeetingStore 实现，签名与它现在的方法一致）。
@MainActor
protocol MeetingSessionLibrary: AnyObject {
    func createMeeting(type: MeetingType, title: String, start: Date, event: MeetingEventInfo?,
                       template: String) -> MeetingRecord
    func markdownURL(for record: MeetingRecord) -> URL
    func record(_ id: String) -> MeetingRecord?
    func update(_ id: String, sync: Bool, _ change: (inout MeetingMeta) -> Void)
    func finishWriting(_ id: String)
    func discard(_ id: String)
    func flush()
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

纯逻辑的会话长这样（只列和现在不同的部分）：

```swift
// Modules/Meeting/Logic/MeetingSessionController.swift
@MainActor
final class MeetingSessionController: ObservableObject, MeetingEngineHost {
    let engine: MeetingEngine
    private let library: MeetingSessionLibrary
    private let environment: MeetingSessionEnvironment

    init(engine: MeetingEngine, library: MeetingSessionLibrary, environment: MeetingSessionEnvironment)

    // @Published 状态、Phase、start / pause / mark / setNotes / setSubtitles / 静音 / finish / terminate：逻辑原样，只是
    //   LiveTranslateController.shared.x → engine.x；MeetingStore.shared.x → library.x；
    //   勿扰 / 通知 / 控制条 / 菜单栏 / Timer / NSAlert / 日历 / MeetingSettings / L() → environment.x（调用顺序照旧）

    var engineConfig: MeetingEngineConfig { … }   // owner = "meeting"、label、capture、subtitlesOn、本场的转录计划

    func meetingEngine(didReport event: MeetingEngineEvent) {
        switch event {
        case .started: engineStarted()             // 只在「开始中」进「记录中」，补发速记 / 字幕，开始中点过结束就收尾
        case .ended: ended()
        case .line(let line): finalLines[line.key] = line
        case .userAction(.subtitleBarClosed): setSubtitles(false)
        case .userAction(.recordButtonPressed): togglePause()
        case .userAction(.freeListeningTogglePressed): toggleSubtitles()
        case .transcript(let id, let progress): transcriptEvent(progress, meetingID: id)
        }
    }

    /// 外壳的 Timer 每 0.25 秒调一次：电平点；每秒刷新菜单栏指示、查超时。
    func tick()
}
```

**留在 App**：`Modules/Meeting/MeetingSessionShell.swift`

- `final class MeetingSessionShell: MeetingSessionEnvironment`：控制条、菜单栏项、Timer、勿扰、宠物通知、合规对话框、日历候选、文案。
  它的 `init` 里不能碰 `MeetingSessionController.shared`（静态常量初始化会递归）。
- `extension MeetingSessionController`：`static let shared = MeetingSessionController(engine: AppDelegate.meetingEngine, library: MeetingStore.shared,
  environment: MeetingSessionShell.shared)`；`statusLine()`（读 `phase`、`elapsed`、`engine.activity`、日历、会议库，用 `L()`）；
  `setCountdown(_:)` 转给外壳（`MeetingReminder` 不用改）。
- `extension MeetingStore: MeetingSessionLibrary {}`（方法签名本来就对得上）。

### 5.3 假引擎

`mac/Tests/Meeting/FakeMeetingEngine.swift`：

```swift
@MainActor
final class FakeMeetingEngine: MeetingEngine {
    enum Call: Equatable {
        case setPaused(Bool), setMuted(Bool, MeetingAudioLane), setSubtitles(Bool)
        case mark(Date), notes(String), finish, toggleFreeListening, terminate
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
    /// 改设置引起的重启（I9）：再取一次配置、再报一次 started。
    func restart() {
        guard let host else { return }
        starts.append(host.engineConfig)
        host.meetingEngine(didReport: .started)
    }
    /// 收尾（I4）：最后几句 → 转录收尾 → 会话结束。
    func end(lines: [MeetingEngineLine] = [], minutes: MeetingMinutesOutcome = .generating, terminating: Bool = false) {
        guard let id = starts.last?.transcript.recordID else { return }
        lines.forEach { report(.line($0)) }
        report(.transcript(recordID: id, .finished(end: Date(), minutes: minutes, terminating: terminating)))
        report(.ended)
    }
}
```

配套 `FakeMeetingLibrary`（内存里的会议库，记下 create / update / discard / finishWriting / flush）和 `FakeMeetingEnvironment`（合规默认确认、不占用、
时钟可拨，记下 toast / 勿扰 / 控制条 / 通知）。两个例子：

```swift
func testFinishWhileStartingFinishesRightAfterStarted() {
    let (session, engine, _, _) = makeSession()
    session.start(type: .offline)
    XCTAssertEqual(session.phase, .starting)
    XCTAssertEqual(engine.starts.first?.capture, .microphone)
    session.finish()                                      // 还在开始中：记下，开起来再收尾
    XCTAssertFalse(engine.calls.contains(.finish))
    engine.report(.started)
    XCTAssertEqual(session.phase, .finishing)
    XCTAssertTrue(engine.calls.contains(.finish))
}

func testEndedWithoutTranscriptDiscardsTheMeeting() throws {
    let (session, engine, library, _) = makeSession()
    session.start(type: .online)
    let id = try XCTUnwrap(session.meetingID)
    engine.report(.ended)                                 // 没开起来：权限被拒、识别不可用
    XCTAssertEqual(library.discarded, [id])
    XCTAssertEqual(session.phase, .idle)
}
```

### 5.4 能覆盖的 / 覆盖不了的

能覆盖（纯逻辑 + 假引擎）：

- 开始：空闲才开；记录中再开只提示；占用时提示、不弹合规说明；合规取消不开；对话框期间别处开了不开；线上手动开始自动绑日历候选、线下不绑；
  标题取事件标题或类型名；引擎拒绝 → 作废这场、回到空闲、不挂勿扰不开控制条；引擎收到的配置（线上 `.microphoneAndSystem` + `speakers`、
  线下 `.microphone`、字幕默认关、模板按设置）。
- 开起来：「开始中」→「记录中」，重启再报的 `.started` 不动状态；开始中写的速记、开的字幕在开起来时补发；开始中点了结束 → 开起来马上收尾。
- 会中：暂停 / 继续只在对应状态；🔖 记距开始秒数与当时那句（截 200 字）；速记去重；字幕开关的拦法（收尾中不行、相同不发）；
  单路不录（线下没有系统声音那一路）；字幕条上三种操作的含义；重启时托管方给出的配置随字幕开关变。
- 结束与转录：录 / 停中 → 收尾中 + `engine.finish`；有内容的留下，meta 的结束时间、状态、重点（只算当前这场）、行动项（只在 `.done` 时解析）；
  纪要还在整理时先不 `finishWriting`；一句没有 → 作废，非退出时提示；属于上一场的纪要事件不碰当前这场；`.ended` 时转录没收尾的作废。
- 退出：开始中且无内容 → 作废、不碰引擎；进行中 → `engine.terminate`；总是 `flush`。
- 心跳：暂停时电平点灰；绑了日历、超过结束 5 分钟提示一次。
- 搬进 `Logic/` 的七个纯文件、`MeetingMinutesFormat`（行动项宽松解析、占位行、截止时间、重点窗口）也一起有正式单测。

覆盖不了（照旧靠编译 + 真机，§7）：适配器与 `LiveTranslateController` 的对接（真识别、真混音）、转录写盘与纪要生成（`LiveTranslateTranscript`、
`AIService`）、控制条 / 菜单栏 / 通知的样子、`MeetingStore` 的写盘（根目录写死在 Application Support，要测得另外开口子，不在本次）。

## 6. 迁移步骤

每个 PR 单独可合并、能编译、用户看不出变化；按依赖排序。行号指 `50103fe`。

### PR1 共用的说话语言与专有名词表下沉 Core

`refactor(speech): move shared speech language and glossary settings to Core (#107)`

- 新增 `Core/Translation/SpeechSettings.swift`（§4.6）。
- 改：`LiveTranslateController.swift`（删 `LiveTranslateSettings` 里搬走的成员与 `LiveTranslateSpeech`，`target` 的默认值改读 `SpeechSettings.speech`，
  `title` 扩展留在这里）、`LiveTranslateSettingsView`、`LiveTranslateBar`、`LiveTranslateSessionConfig`、`LiveTranslateRecognition`、
  `LiveTranslateDualRecognizer`、`LiveTranslateSwitchingRecognizer`、`LiveTranslateTranslator`、`LiveTranslateCorrector`、`LiveTranslateGlossaryEditor`、
  `MeetingSessionController.swift:218`、`DictationSettings.swift:140`、`DictationController.swift:191`、`DictationSettingsView.swift:21`。
- 行为不变：键名字面量原样，读写逻辑整块搬。
- 验证：编译；§7.2 的设置键对比；设置页说话语言 / 自动 A、B / 术语表显示原值；听写「跟随」的标题与术语条数不变。
- 文档：`translation-engine/DESIGN.md` §4、`live-translate/DESIGN.md` §7 注明键定义在 `SpeechSettings`。

### PR2 共用的值类型下沉 Core

`refactor(meeting): move the types Meeting and Live Translate share to Core (#107)`

- 新增 `Core/MeetingEngine/MeetingTranscriptTypes.swift`；`git mv` `LiveTranslateMinutesFormat.swift` → `Core/MeetingEngine/MeetingMinutesFormat.swift` 并改名；
  `LiveTranslateTranscript.swift` 里的 `LiveTranslateMinutes` → `Core/Minutes/MeetingMinutesGenerator.swift`。
- 改（只换类型名）：`LiveTranslateMixing`、`LiveTranslateMixedSource`、`LiveTranslateController`、`LiveTranslateSessionConfig`、`LiveTranslateTranscript`；
  `MeetingSessionController`、`MeetingStore`、`MeetingReports`、`MeetingSettings`、`MeetingText`、`MeetingSettingsView`。
- 行为不变：§4.7 的改名表，`rawValue` / `storageValue` 不变。
- 验证：编译；开一场会议出纪要；会议库里重新生成纪要；生成周报；`meeting.template` 设成站会后照样生效。

### PR3 会议改走 `MeetingEngine`

`refactor(meeting): drive the engine through a MeetingEngine protocol (#107)`

- 新增 `Core/MeetingEngine/MeetingEngine.swift`（§4.1、§4.2）、`Modules/LiveTranslate/LiveTranslateMeetingEngine.swift`（§4.4；这一步
  `toggleFreeListening` 先调 `toggle()`，还没有 `recordLibrary`）。
- `AppDelegate.swift`：`static let meetingEngine`（§4.5），改 `:32` 的注释。
- `MeetingSessionController.swift`：`init(engine:)`、`let engine`；实现 `MeetingEngineHost`（`engineConfig` 换成 `MeetingEngineConfig`，
  `meetingEngine(didReport:)` 合并原来三个回调与转录事件）；`destination` 换成 `MeetingTranscriptPlan`；§1.2 里这个文件的引用全部换成 `engine.x`。
- `MeetingTool.swift`：快捷键动作、环形菜单标题、`willTerminate`、`MeetingMenu` 都经 `MeetingSessionController.shared.engine`；`:93` 的功能声明照旧（白名单）。
  这一步 `activate()` 里的静态赋值还在（PR4 删）。
- 行为不变：适配器逐行对照 `MeetingSessionController.swift:190–238`；`activity` 与旧判断一一对应（菜单 `isRunning` ⇔ `.freeListening`：
  会议空闲时引擎在跑只可能是自由听译）。
- 验证：§7.3 会议与自由听译整张清单（这一步动的是会议的主路径）。
- 文档：`TECH_DESIGN.md` §2–§3 指向本文；根目录 `CLAUDE.md` 的 Core 清单加 `MeetingEngine/`、docs 布局加本文。

### PR4 会议库构造注入，删静态

`refactor(livetranslate): hand the meeting library to the engine at construction (#107)`

- 新增 `Core/MeetingEngine/FreeListeningLibrary.swift`。
- 改：`LiveTranslateSessionConfig`、`LiveTranslateController`（`toggle(startingWith:)`、`restartIfRunning`、`startTranscript`、`recordFolder`）、
  `LiveTranslateTranscript`、`LiveTranslateSettingsView`、`LiveTranslateBar`、`LiveTranslateMeetingEngine`、`AppDelegate`（传 `MeetingStore.shared`）、
  `MeetingStore`（实现 `FreeListeningLibrary`，迁移用自己的旧键常量）、`MeetingTool`（删 `:98`、改 `:26`）、`MeetingSettingsView`（传目录）、
  `Localizable.xcstrings`（删两条只有「更改…」用的文案）。细节见 §4.5。
- 行为不变：静态在现在的启动流程里总是装上的，「有会议库」一直是唯一走得到的分支；删掉的都是到不了的分支。
- 验证：§7.3 自由听译几项（含「启动后第一个动作就开自由听译」）；用一份有旧记录文件夹、`meeting.migratedLegacy` 为 false 的配置启动，迁移照常。
- 文档：`live-translate/DESIGN.md` §6（记录去处）、§8（文件）。

### PR5 会话的决策与 App 外壳拆开

`refactor(meeting): split the session's decisions from its AppKit shell (#107)`

- `git mv` 七个纯文件到 `Modules/Meeting/Logic/`；新增 `Logic/MeetingSessionPorts.swift`；`MeetingSessionController` 挪到 `Logic/` 并改用端口；
  新增 `Modules/Meeting/MeetingSessionShell.swift`（§5.2）。
- 改：`MeetingStore`（实现 `MeetingSessionLibrary`、`status(after:)` 移走）。
- 行为不变：每个方法里的副作用按原顺序换成端口调用。例：`begin` 仍是「`engine.start` 成功 → 勿扰 → 心跳 → 控制条 → 指示器」；
  `ended` 仍是「作废判断 → 撤勿扰 → 停心跳 → 收控制条 → 复位 → 指示器」。
- 这是机械但最大的一步，建议等 `BaoboxTests` 合并后与 PR6 一起上，拆的时候就有测试兜底（§8 第 5 条）。
- 验证：同 PR3 的整张清单。

### PR6 单元测试

`test(meeting): cover the meeting session with a fake engine (#107)`

- `mac/project.yml` 的 `BaoboxTests.sources` 加 `Sources/Core/MeetingEngine`、`Sources/Modules/Meeting/Logic`
  （可选再加 `Sources/Modules/LiveTranslate/LiveTranslateMixing.swift`，测混音与说话人判定，它本来就是纯的）。
- `mac/Tests/Meeting/`：假引擎 / 假会议库 / 假环境，`MeetingSessionTests`（§5.4 第一部分），`MeetingMinutesFormatTests`，七个纯文件的测试。
- 验证：`xcodebuild test`（§7.2）；CI 跑同一条。

### P2 候选（另开 issue）

1. **转录与纪要归会议**：meeting.md 的写入（会议版式、🔖 / 速记 / 暂停与静音说明行、纪要触发与收尾）搬进会议；引擎只报句子和「这次怎么跑的」
   （音源 / 语言 / 译成，给「改为：…」那行）；协议去掉 `addMark`、`setNotes`、`.transcript`；自由听译的记录经 `FreeListeningLibrary` 也由会议写。
   顺带把 meeting.md 的版式做成纯函数（文案经 Labels 传入，同 `MeetingWeeklyReport.Labels`），与 `MeetingMarkdown` 的解析配一条往返测试，
   钉住 §1.3 第 3 条那份格式契约。
2. **采集链路下沉 `Core/Audio/`**：音频路由、PCM 转换、麦克风 / 系统声音源、混音（含 `LiveTranslateMixing`），以及听写借用的 `LiveTranslateAudioGate`、
   `LiveTranslateScoring`。设备自检和听写从此不引用 LiveTranslate。
3. 会议设置页的「字幕与同传」区块、「AI」页的两个功能声明改由引擎提供，清掉 §3.3 剩下两项。

## 7. 风险与验证

### 7.1 最容易搬坏的行为

| # | 行为 | 现在靠什么 | 搬坏了是什么样 | 怎么防 / 验 |
|---|---|---|---|---|
| R1 | 结束冲刷与收尾顺序（I4） | `finish()` 先停音频、等 final 最多 1.5 秒；`stop()` 连续「记最后一句 → 收尾转录 → 结束会话」 | 最后半句丢；`.ended` 跑到 `.finished` 前面 → 会议把有内容的这场当成没开起来**删掉** | 适配器同步转发、不加 `Task`；测试按 I4 顺序；真机 7 |
| R2 | 暂停（含线下会议） | 混音器 `setPaused`，只有 `usesMixer` 时才有混音器；跨重启保留 | 适配器漏了 `usesMixer` → 线下会议暂停不起作用、没有电平 | 两种会议都 `usesMixer = true`；真机 2、9 |
| R3 | 「我 / 对方」与单路不录 | `.mixed` + `speakers` + 混音器 lane | 线上没标说话人；lane 映射反了静错路 | 映射表逐项核；真机 1、3 |
| R4 | 纪要触发与通知 | `summaryFollowsSetting = false`、`notifiesMinutes = false`、`.meeting(style)` | 关了自由听译的纪要开关后会议也不整理；两条通知；会议纪要变成自由听译格式 | 适配器显式设这三项；真机 7、8 |
| R5 | App 退出同步写完（I5） | 整条链同步 + `willTerminate` 先会话后引擎 + `flush` | meta.json 没写结束时间、状态卡在「记录中 / 整理中」 | 转发不隔拍；`willTerminate` 顺序不动；真机 12 |
| R6 | 改设置重启续写（I9） | `rebuild` 回调托管方重组；`sessionOpen` 保留暂停 / 静音 | 漏了 `rebuild` → 落回 `.fromSettings()`：会议中途变自由听译、再收不到事件、卡在「记录中」 | 适配器必设 `rebuild`；真机 6 |
| R7 | 开始的时序（I2） | `start` 只排 `Task` | 同步报 `.ended` → 控制条与勿扰留在屏上 | 协议注释写明；假引擎不同步报；测试覆盖 |
| R8 | 开始中的补发 | `.started` 时补发速记与字幕 | 开始中开的字幕、写的速记丢了 | 测试覆盖；真机 10 |
| R9 | 自由听译的记录去处（PR4） | 现在靠静态 | 写回 `~/Documents`、弹「文稿」授权框 | 配置带会议库、重启带过去；真机 13–16 |
| R10 | 菜单 / 环形菜单标题 | 读 `isRunning`、`isHostedSession`、`barVisible` | 「停止 / 开始自由听译」「打开 / 收起字幕」错 | `activity` 一一对应（§4.4）；真机 11、13 |
| R11 | 设置键 | 键名字面量 | 升级后用户设置丢 | 常量原样搬；§7.2 前后对比；真机 19 |
| R12 | PR5 的副作用顺序 | 现在内联在一个方法里 | 例：控制条先于 `engine.start` 打开，start 失败后残留 | 逐方法按原顺序调端口；测试断言调用序列 |

### 7.2 编译与静态检查

```bash
# 编译（Mac 上；只编不装，不碰 /Applications —— 并行会话会互相覆盖安装）
cd mac && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Baobox -configuration Debug -derivedDataPath "$SCRATCH/DerivedData" build
# 没有 mac/Vendor/ 也能编：拷 llama-server、虚拟麦克风驱动的脚本阶段会跳过

# 单测（PR6 起）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Baobox -derivedDataPath "$SCRATCH/DerivedData"

# 本地化表仍是合法 JSON（在仓库根目录跑）
python3 -c "import json;json.load(open('mac/Sources/Resources/Localizable.xcstrings'));print('valid')"

# 设置键前后一致（每个 PR 都跑）。这个模式也会匹配 L("livetranslate.…") 文案 key：
# 只允许少掉 PR4 删的两条文案，设置键一个都不能少
git grep -hoE '"livetranslate\.[A-Za-z.]+"' 50103fe -- mac/Sources | sort -u > "$SCRATCH/keys-before"
git grep -hoE '"livetranslate\.[A-Za-z.]+"' HEAD    -- mac/Sources | sort -u > "$SCRATCH/keys-after"
diff "$SCRATCH/keys-before" "$SCRATCH/keys-after"

# 边界（PR4 起）：会议目录里只剩 §3.3 白名单；实时翻译目录里不出现会议模块的类型
grep -rn 'LiveTranslate' mac/Sources/Modules/Meeting --include='*.swift' | grep -v '^[^:]*:[0-9]*:[[:space:]]*//'
grep -rnE '\bMeeting(SessionController|Store|Tool|Settings|Text|Calendar|Reminder|Detector)\b' \
  mac/Sources/Modules/LiveTranslate --include='*.swift'
```

### 7.3 真机回归清单

装本地构建后跑（安装由主会话 / 用户做）。macOS 14 上系统翻译不可用，字幕译文走离线模型；系统翻译那条路只能在 15+ 上验
（适配器对它只是原样转发 `setBarVisible`，风险低）。

会议（线上，戴耳机）：

1. 开始 → 控制条出现、菜单栏「● 0:00」、两路电平点会亮；说两句 → meeting.md 里有 `**时间 我**` / `**时间 对方**`。
2. 暂停 → 说话 → 继续：暂停期间的话不进记录，记录里有「暂停 / 继续」两行；状态行显示已暂停。
3. 点麦克风图标 → 说话不进记录、图标变红，记录有「麦克风静音 / 恢复」；喇叭同理。
4. 🔖、速记（展开输入几行）→ 会后纪要的「重点」带上标记那段，速记一节在。
5. 打开字幕 → 字幕条 + 译文；字幕条 ✕ → 只收字幕、会议照记；字幕条「记录」按钮 = 暂停 / 继续，与控制条同步。
6. 会议中在字幕条或设置里改说话语言 → 会议不断，记录接着写同一份并有「改为：…」行，暂停 / 静音状态不丢，结束照常。
7. 话说到一半点结束 → 最后半句也在记录里；纪要整理完只有一条「纪要已生成」；会议库状态「已生成」，行动项解析出来。
8. 关掉「字幕与同传 → 记录与纪要 → 停止后用本地 AI 整理纪要」（先打开「保存记录」才看得到这个开关）再开一场会议 → 会议照样整理纪要。

会议（线下）：

9. 只有麦克风电平点；暂停有效（暂停期间的话不进记录）。

边界：

10. 开始中马上点结束 → 开起来后立即收尾；什么都没说就结束 → 不留空会议，提示什么都没记下。
11. 会议中按 `livetranslate.toggle` / 点菜单「打开字幕」/ 环形菜单「翻译」→ 切字幕，标题跟着变。
12. 会议进行中退出 Baobox → 重开后会议库里这场有转录，纪要一节写没整理完，状态仅转录；纪要整理中退出 → 不会卡在「整理中」。

自由听译：

13. 菜单「开始自由听译」→ 字幕条；✕ 停止；记录按钮开关保存；开着保存时会议库多一条「… 自由听译」，纪要好了是「实时翻译纪要已整理好」那条通知。
14. 关着保存开始、中途打开 → 字幕条上已有的几句补进新记录。
15. 启动后第一个动作就用快捷键开自由听译（不先打开会议菜单或设置）→ 记录照样进会议库（验证装配与顺序无关）。
16. 设置页「保存位置」显示会议库路径、没有「更改…」，「打开记录文件夹」打开会议库；字幕条上还没记下句子时的文件夹按钮同样打开会议库。

听写与互斥：

17. 听写「跟随」显示的语言、术语表条数与改动前一致；听写照常认专有名词。
18. 听写进行中开始会议 → 提示正在听写，不弹合规说明。

升级：

19. 用改动前的 UserDefaults（说话语言 = 自动、A / B、术语表、纪要模板 = 站会）启动 → 设置页显示不变。

## 8. 待用户拍板

1. **共用设置放哪**。issue 写的是 `Core/Translation/TranslationSettings.swift`，但它已经是翻译引擎解析，依赖 App 单例。
   **建议**：同目录新建 `SpeechSettings.swift`（纯 Foundation，将来能进测试；听写也用，不只是翻译）。
2. **转录（meeting.md）与纪要这次搬不搬**。
   **建议**：P1 不搬，留在引擎（协议照 issue 带 `setNotes` / `addMark` 和转录事件）。这次就搬的话协议更干净，但收尾冲刷、退出同步写完、
   改设置续写「改为：…」、写盘失败提示这些已经调好的行为都要在会议那边重做一遍，回归面大；放 P2 单独做（§6 P2 第 1 条）。
3. **装配方式**。
   **建议**：`AppDelegate` 上的不可变静态常量 `AppDelegate.meetingEngine`，`MeetingSessionController.shared` 懒加载时取它（§4.5）。
   备选一：去掉 `.shared`、全链路构造注入（更纯，改约 10 个文件约 30 处，与仓库「单例 + `.shared`」的写法不一致）；
   备选二：注册时给单例 setter（不建议，等于把可变注入换个地方）。
4. **删不删「没有会议库就写回 ~/Documents」的旧写入路径**（`Destination.legacy`、设置页「更改…」）。
   **建议**：PR4 删。#106 之后这条路到不了，留着就是一条不报错的错误分支；`livetranslate.record.folder` 只留给迁移读。
5. **PR5（会话拆纯逻辑）与 PR6（单测）算不算 #107**。
   **建议**：算，验收第一条「会议可脱离 LiveTranslate 单独测」要的就是它们；PR5 等 `BaoboxTests` 合并后与 PR6 一起上，拆的时候就有测试兜底。
   PR1–PR4 不依赖测试 target，可以先合。
6. **白名单**：P1 之后会议里还留着的三处直接引用（设备自检的混音链路、设置页嵌入的设置区块、「AI」页两个功能声明），以及听写对引擎内部工具的引用。
   **建议**：接受，P2 再清（§6 P2 第 2、3 条）。
