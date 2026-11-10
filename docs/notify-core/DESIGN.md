# 通知内核与呈现角色搬出桌面宠物 · 技术设计

> issue #108（范围 P1）。状态：已拍板（§6），按 §4 的 PR 顺序实现。通知内核（`NotifyCenter` / `NotifyDND`）现在放在 `Modules/DesktopPet/` 里；休息画面、会议控制条、
> 专注与健康又直接调 `PetController.shared`。结果 Core 和别的模块都得认识宠物。
> 本文把通知内核搬到 Core，把「宠物替别的模块做的三件事」换成 Core 里的协议，由框架在启动时接上。
> **只改结构，产品行为不变**：宠物开着时照旧由宠物呈现，宠物关着时照旧回退（用户 2026-11-06 定的规则不动）。
> 代码基线：main @ `50103fe`，文中行号都按这个提交。

## 0. 结论

- 通知内核整体搬到 `Core/Notify/`，并从 `PetSettings` 拆出 `NotifySettings`，键名不变。类型名也不变，16 个文件里 32 处 `NotifyCenter.shared` 调用一行不用改。
- 宠物替别人做的事归成三个**呈现角色**：通知呈现端（`NotifyPresenting`，已有）、浮窗挂靠点（`AccessoryHost`，新增）、休息画面主角（`BreakCompanion`，新增）。
  宠物模块通过 `ToolModule` 新增的可选声明 `presentationRoles()` 提供这三个角色。框架在 `ToolRegistry.activateAll()` 里、**任何模块 `activate()` 之前**把它们一次装进 `PresentationHub`，之后只读。
- 休息画面不再认识 `PetPose`。它只告诉主角三种意图：「在走」「在休息」「看着你」。姿态怎么摆、30 fps 推送，都搬回宠物模块。
- 宠物关掉时的三项回退今天就有，保持不变。宠物模块整个不注册时也能用：通知走系统通知，启动时就申请权限；控制条自己摆位置；休息画面走回退画面。
- 拆成 4 个能各自合并的 PR：通知内核搬家 → 通知呈现端接线 → 挂靠点 → 专注与健康。另有 2 个可选 PR：纯逻辑单测、`PetNotification` 改名。

## 1. 现状

### 1.1 谁直接引用了 DesktopPet 的哪些类型

模块目录外引用 DesktopPet 类型的只有下面这些（`DesktopPetTool` 在 `AppDelegate.swift:37` 注册那一行除外）。

| DesktopPet 里的类型 | 引用方（`文件:行`） | 用途 |
|---|---|---|
| `NotifyCenter`、`PetNotification`（`NotifyCenter.swift:6-244`） | **Core**：`Core/StorageWriteFailure.swift:23`、`Core/AI/AIUsageMeter.swift:121`<br>**模块**：`AIToolsNotify.swift:262,314`、`CaffeinateTool.swift:112`、`ClaudeLiveStatus.swift:169,182`、`DictationController.swift:564,972`、`BreakStage.swift:477`、`FocusHealthController.swift:188,204,230,280,317,364,440,481,503,529,558,561,662`、`LiveTranslateController.swift:482`、`LiveTranslateTranscript.swift:350`、`MeetingDetector.swift:186,277,307`、`MeetingReminder.swift:167,181`、`MeetingReports.swift:213`、`MeetingSessionController.swift:491,498,516`、`MeetingTool.swift:317`、`MenuBarActions.swift:283` | 投递通知 |
| `NotifyDND`（`NotifyDND.swift`） | `RecordingController.swift:155,185`、`MeetingSessionController.swift:182,376`、`MeetingDetector.swift:243`、`MeetingMicrophoneUsage.swift:42`、`FocusHealthController.swift:71,127,192,202,223,241,274,456`、`BreakStage.swift:172,609` | 挂 / 摘勿扰令牌、查勿扰原因、查麦克风 |
| `PetController` | `MeetingControlBar.swift:27,58,80,97,118` | 会议控制条挂到宠物头顶（`dockAccessory` / `undockAccessory` / `refreshAccessory`） |
| | `BreakStage.swift:102,173,612,688,696,711` | 休息画面借渲染视图、推姿态、戳一下、归还（`Loan` / `lendRenderView` / `setLentPose` / `performLent` / `returnRenderView`） |
| | `FocusHealthController.swift:445,494,575,671`（`act(clips:)`）、`:664`（`isReady`） | 提醒时让宠物做动作；设置页预览文案按宠物在不在换 |
| `PetPose`（`PetEngine.swift:5`，带着 `PetEngine.State` / `PetGait` / `PetFlightPose`） | `BreakStage.swift:110,300` | 休息画面自己算宠物每一帧的姿态 |

通知内核自己也读宠物的设置：

- `NotifyCenter.swift:93` 读 `PetSettings.sourceEnabled`，`:134` 读 `soundEnabled`，`:208-209` 读 `historyLimit`。
- `NotifyDND.swift:39,47` 读 `PetSettings.quietUntil`。
- 这几个键其实都叫 `notify.*`，只有「安静一下」用 `pet.quietUntil`（`PetSettings.swift:36,43,44,66,85-99`）。

反方向（宠物 → 通知内核）本来就对，搬家后变成宠物 → Core：

- `PetEngine.swift:738` 读 `NotifyDND.isSuppressed` 决定睡不睡。
- `DesktopPetTool.swift:70`、`PetController.swift:593` 调 `prepareSystemFallback`。
- `PetController.swift:1153-1179` 发测试通知。

另外有两处 Core 已经反向依赖了模块目录：`Core/StorageWriteFailure.swift:23` 和 `Core/AI/AIUsageMeter.swift:121`。整个工程只有一个 target，所以不报错，但分层是倒的。

### 1.2 接线时机与注册顺序

- **启动**：`NotifyCenter.presenter` 是谁都能写的 `weak var`（`NotifyCenter.swift:72`），由 `DesktopPetTool.activate()` 赋值（`DesktopPetTool.swift:68`）。
  `activateAll()` 按注册顺序调各模块的 `activate()`（`ToolRegistry.swift:12-19`），宠物排在最后（`AppDelegate.swift:37`）。所以别的模块在 `activate()` 里同步发出的通知，一定走系统通知。
  今天没出事，只是碰巧：各模块的 `activate()` 都不直接发通知。`MeetingReminder.start()` 会同步 `tick()` 一次（`MeetingReminder.swift:87`），但那时日历事件还在后台读，列表是空的。
- **退出**：`applicationWillTerminate` 也按注册顺序调 `willTerminate()`（`AppDelegate.swift:63-66`）。
  专注与健康排在前面（`:26`）：先把休息画面拆掉、把视图还给宠物，宠物再 `stop()`。
  如果顺序反过来，宠物先 `stop()`（窗口收起、引擎停下），休息画面后还视图。`returnRenderView()` 里的 `applyVisibility()`（`PetController.swift:904`）发现宠物窗没显示，就会重新显示它、开始播出场，黑洞窗也会出来（`:573-574`）。退出时会闪一下。
- 仓库里已经有一处「在 `activate()` 里给可变静态赋值」的注入：`LiveTranslateController.recordLibrary`（`LiveTranslateController.swift:417`，在 `MeetingTool.swift:98` 赋值）。本设计不照这个写。

### 1.3 宠物关掉 / 宠物模块没注册时，各功能现在怎么表现

两种状态的意思：

- **宠物关掉**：设置里关了宠物（`pet.enabled = false`）。模块照常注册，`activate()` 照常跑。
- **宠物模块没注册**：`AppDelegate` 里没有 `register(DesktopPetTool())`。今天不会发生，这一列是按代码推演的，用来检查耦合。

| 功能 | 宠物开着 | 宠物关掉（逐行查过代码） | 宠物模块没注册（按代码推演） |
|---|---|---|---|
| 通知 | `isReady` 为真（`PetController.swift:31`）→ 宠物气泡（`:781-785`），按 toast / card / sticky 三种样式 | `isReady` 为假 → 系统通知（`NotifyCenter.swift:126-128,140-180`）。<br>有标题和正文；按钮转成 `UNNotificationAction`，点了经 `SystemNotificationRouter` 回到投稿方（`:196-201,249-268`），点通知本体算 `"open"`。<br>样式、ttl、图标不生效。<br>勿扰时照样排队、事后补一条摘要，摘要也走系统通知。<br>权限在两个时机申请：宠物关着启动时（`DesktopPetTool.swift:70`），或刚关掉宠物时（`PetController.swift:593`） | `presenter` 一直是 nil，全部走系统通知。<br>没人提前申请权限：第一次投递时才在 `postSystemNotification` 里申请（`NotifyCenter.swift:142`）。代码注释写明，这样第一条会因为弹授权框而丢掉（`:183-184`）。<br>通知设置（提示音、逐来源开关，`PetSettingsView.swift:12-16,125-130`）和「安静一下」的入口都在宠物模块里，跟着一起没了；已经存下的值照样生效 |
| 休息画面 | `lendRenderView()` 借出渲染视图，宠物飞到屏幕中央变大（`BreakStage.swift:173,243-248,292-311`）。姿态由 `pushPose` 每秒推 30 次（`:650-689`） | `lendRenderView()` 返回 nil（`PetController.swift:855`）→ 回退画面（`BreakStage.swift:198-205,249-253`）：<br>· 标准档：渐变或自选图片铺满整屏<br>· 严格档：模糊<br>· 轻松档：不变暗，只有一张居中的卡片（`.statusBar` 级，`:231`）<br>倒计时卡片都居中。「休息好啦」停 1.4 秒，有宠物时是 2.6 秒（`:353`）。点暗处照样出「还没休息完哦～」（`nudge`，`BreakStage.swift:702-713`）；里面调的 `performLent` 直接返回 nil（`PetController.swift:885`） | 同「宠物关掉」。<br>但休息画面第一次访问 `PetController.shared` 时，会把它连同引擎、气泡、环形菜单这些对象建出来。没有窗口和定时器（没人调 `start()`），`panel` 为 nil，`lendRenderView()` 返回 nil |
| 会议控制条 | `dockAccessory` 把控制条挂成宠物窗的子窗口，贴在宠物头顶、跟着宠物走，自己不能拖（`PetController.swift:700-771`，`MeetingControlBar.swift:57-73`） | `updateAccessory` 走 else 分支，立刻回调 `onChange(false)`（`PetController.swift:738-744`）→ 控制条回到上次的位置，或鼠标所在屏的顶部居中，可以拖、记住位置（`MeetingControlBar.swift:64-73,137-164`）。<br>会中开关宠物、宠物借给休息画面、出场退场途中都会再回调，自动挂上或摘下 | 同「宠物关掉」（`panel` 为 nil 也走 else 分支），同样会把 `PetController.shared` 建出来 |
| 提醒时的宠物动作 | `act(clips:)` 播喝水、伸懒腰、远眺、打哈欠（`FocusHealthController.swift:443-447,491-496,573-577,670-672`） | `act` 返回 false（`PetController.swift:836`）。调用方本来就忽略返回值 | 同「宠物关掉」（`shownModelID` 为 nil） |
| 设置页「预览效果」的文案（轻松档） | 「轻松档到点时就是这样：宠物冒个气泡提醒你。」 | 按 `PetController.shared.isReady` 换成「宠物关着，轻松档就用这样的系统通知提醒你。」（`FocusHealthController.swift:664-665`） | 同「宠物关掉」 |

**结论：验收标准里的三件事，在「宠物关掉」时今天就成立。** P1 真正要做的是类型解耦，并让「宠物模块不在」时也一样成立（顺带把通知权限提前申请）。

顺带查到回退路径上几个洞。P1 不改，列进 §6 和 §8：

- **关宠物那一刻，气泡里还没点的通知直接丢掉**，包括 sticky 和带按钮的，不转系统通知（`PetController.swift:582` → `BubbleWindow.swift:108-113`）。换形象途中排队的通知也一样。
- **标准 / 严格档休息时，alert 和操作回执被盖住**。宠物窗留在原地只是变空，`isReady` 仍为真，所以 alert 级通知和操作回执照样交给宠物气泡。
  但气泡是 `.floating` 级的子窗口（`BubbleWindow.swift:226`），被 `.screenSaver` 级的暗幕（`BreakStage.swift:853`）盖住，休息结束才看得见。8 秒的 card 可能没人看见就消失了。
- **宠物关着、系统通知权限又被拒时，回退通知不显示，代码也不知道**：`center.add` 的回调把错误忽略了（`NotifyCenter.swift:157,164,178`）。
- **`NotifyCenter.history` 一直在记（`:203-211`），macOS 上没有任何界面读它。** DESIGN.md §6 写的右键「通知历史」没做；Windows 版有。

## 2. 目标与非目标

**目标**

1. Core 不再引用 `Modules/DesktopPet/` 的任何类型。除了 `AppDelegate` 注册那一行，别的模块也不再引用（§5.2 有一条 grep 检查）。
2. 宠物把自己接上的方式是：模块声明，框架在启动时装一次，之后只读。不在运行中给可变静态赋值，也不依赖注册顺序。
3. 产品行为不变：宠物开着由宠物呈现；宠物关着走系统通知、控制条自己摆、休息画面走回退画面。UserDefaults 键名不变，用户已有的设置不丢。
4. 宠物模块不注册也能正常工作：不崩、不丢通知、启动时就申请通知权限。
5. 每一步都是能单独合并、能编译、行为不变的小 PR。不新增用户可见文案。

**非目标**

- 对外协议（Unix socket / CLI / URL scheme，#113，DESIGN.md §5）。
- 改通知的产品规则：级别、样式、勿扰判定、摘要格式，以及由谁决定出气泡还是系统通知（仍看呈现端的 `isReady`）。
- §1.3 末尾那几个洞和通知历史界面（§8 列为后续）。
- 把 FocusHealth 里的片段名（`petClips` / `restClips`，`FocusHealthText.swift:105-117`）挪走。它们只是数据，不是类型耦合。
- 拆成多个 Swift module / framework。仍是一个 target，分层靠约定加 grep 检查。
- Windows / Linux：`windows/baobox-windows/src/pet_notify.rs` 自成一套，不受影响。Rust 的 `ToolModule` trait（`shared/baobox-app/src/lib.rs:75`）本来就没有 `aiFeatures` 这类可选声明，这次也不跟着加。

## 3. 新结构

### 3.1 目录（全部 PR 合入后）

```
mac/Sources/Core/Notify/
  NotifyCenter.swift        通知内核（原样搬来）+ NotifyPresenting + SystemNotificationRouter
  NotifyDND.swift           勿扰判定（原样搬来）
  NotifySettings.swift      新：notify.* 各键 +「安静一下」（沿用老键 pet.quietUntil）
mac/Sources/Core/Presentation/
  PresentationRoles.swift   新：PresentationRoles（模块能提供的角色）+ PresentationHub（装一次，之后只读）
  AccessoryHost.swift       新：AccessoryHost 协议 + AccessoryDock 入口（没有挂靠点时的回退）
  BreakCompanion.swift      新：BreakCompanion / BreakCompanionLoan / BreakCompanionCue
mac/Sources/Modules/DesktopPet/
  PetController.swift       实现三个角色（NotifyPresenting 已有；另加 AccessoryHost）
  PetBreakCompanion.swift   新：PetBreakLoan + `extension PetController: BreakCompanion`。把意图换成 PetPose、每秒推 30 次（从 BreakStage.pushPose 搬来）
  DesktopPetTool.swift      presentationRoles() 交出三个角色
  其余文件不动
```

合入后的依赖方向：

```
各模块 ─────────────► Core/Notify          （post / setSuppressed / reasons）
MeetingControlBar ──► AccessoryDock ──────► PresentationHub.accessories?
BreakStage ─────────► BreakCompanion ─────► PresentationHub.breakCompanion?
DesktopPet ─────────► Core                 （实现协议、调 prepareSystemFallback、读 NotifyDND）
ToolRegistry.activateAll ─ 收集各模块的 presentationRoles() ─► PresentationHub.install
```

没有任何东西再指向 DesktopPet（`AppDelegate` 注册那一行除外）。

### 3.2 Core/Notify：通知内核

`NotifyCenter.swift`、`NotifyDND.swift` 用 `git mv` 原样搬过去，对外接口只做下面这些增删：

```swift
struct PetNotification { /* 字段、Level / Style / Action 原样；改不改名见 §6-1 */ }

@MainActor
protocol NotifyPresenting: AnyObject {
    var isReady: Bool { get }
    func present(_ n: PetNotification, onAction: @escaping (String) -> Void)
    /// 配合提醒做个动作（喝水、伸懒腰、远眺）；做不了返回 false。默认做不了。（PR 4 新增）
    func performGesture(_ clips: [String]) -> Bool
}
extension NotifyPresenting {
    func performGesture(_ clips: [String]) -> Bool { false }
}

@MainActor
final class NotifyCenter {
    static let shared: NotifyCenter
    func post(_ n: PetNotification, onAction: ((String) -> Void)? = nil)     // 不变
    func prepareSystemFallback(requestPermission: Bool)                       // 不变
    func handleSystemResponse(requestID: String, actionID: String)            // 不变
    private(set) var history: [HistoryEntry]                                  // 不变
    // PR 2：删掉 `weak var presenter`，deliver 改读 PresentationHub.shared.notifications；
    //       加「启动期间先攒着」，见 §3.3
    func holdDuringLaunch()
    func releaseAfterLaunch()
    // PR 4：
    /// 现在发一条会不会由呈现端（宠物气泡）呈现；false = 走系统通知。设置页预览文案用。
    var presenterIsReady: Bool { get }
    /// 转给呈现端；没有呈现端或做不了返回 false。
    @discardableResult func performGesture(_ clips: [String]) -> Bool
}

@MainActor
final class NotifyDND { /* 接口一个字不改：setSuppressed / hasToken / isSuppressed / reasons / refreshMicrophoneState / defaultInputIsRunning */ }
```

新增 `NotifySettings`，把通知内核要读的设置从 `PetSettings` 拆过来。**键名一个不改**：

```swift
/// 通知内核的设置（UserDefaults）。「安静一下」沿用老键 pet.quietUntil，用户已经设了的不丢。
enum NotifySettings {
    static let soundKey = "notify.sound"
    static let historyLimitKey = "notify.historyLimit"
    static let quietUntilKey = "pet.quietUntil"
    static var soundEnabled: Bool                          // 默认 false
    static var historyLimit: Int                           // 默认 50
    static func sourceEnabled(_ source: String) -> Bool    // notify.source.<id>，默认 true
    static var quietUntil: Date?
    static func setQuietUntil(_ date: Date?)
}
```

`PetSettings` 删掉这几项。宠物模块里的调用改读 `NotifySettings`：`DesktopPetTool.swift:33`、`PetController.swift:942,1140,1144,1148`、`PetSettingsView.swift:12`。设置页的「通知」一组开关和「安静一下」入口仍留在宠物模块（§6-3）。

「安静一下」的状态归 `NotifyDND` 读：它本来就是勿扰信号之一（DESIGN.md §4），宠物只是提供入口。

### 3.3 Core/Presentation：呈现角色与接线

```swift
/// 一个模块能替框架承担的呈现角色。都可以不提供；目前只有桌面宠物提供。
@MainActor
struct PresentationRoles {
    /// 通知呈现端。没有或没就绪 → 通知内核走系统通知。（PR 2）
    var notifications: NotifyPresenting?
    /// 浮窗挂靠点（会议控制条挂在宠物头顶）。没有或挂不上 → 浮窗自己摆。（PR 3）
    var accessories: AccessoryHost?
    /// 休息画面的主角。没有或借不到 → 休息画面走回退画面。（PR 4）
    var breakCompanion: BreakCompanion?
    init(notifications: NotifyPresenting? = nil, accessories: AccessoryHost? = nil,
         breakCompanion: BreakCompanion? = nil)
}

// ToolModule 加一个可选声明，写法同 aiFeatures() / statusMenuHeaderItems()
protocol ToolModule {
    …
    /// 这个模块替框架承担的呈现角色，默认没有。框架在调任何模块的 activate() 之前收集一次，与注册顺序无关。
    func presentationRoles() -> PresentationRoles
}
extension ToolModule {
    func presentationRoles() -> PresentationRoles { PresentationRoles() }
}

/// 装好的呈现角色：ToolRegistry.activateAll() 装一次，之后只读。
@MainActor
final class PresentationHub {
    static let shared: PresentationHub
    private(set) var notifications: NotifyPresenting?
    private(set) var accessories: AccessoryHost?
    private(set) var breakCompanion: BreakCompanion?
    /// 只给 ToolRegistry.activateAll 调。
    /// - 每个角色取第一个提供者；两个模块提供同一个角色记一条 fault 日志（配置错了），不崩。
    /// - 第二次调用忽略，记 fault。
    /// - 最后调 NotifyCenter.shared.prepareSystemFallback(requestPermission: notifications == nil)。
    func install(from tools: [any ToolModule])
}

// ToolRegistry
func activateAll() {
    NotifyCenter.shared.holdDuringLaunch()   // 先攒再装：activateAll 一开始投递的就攒住，install 前后都一样
    PresentationHub.shared.install(from: tools)
    for tool in tools { /* 注册快捷键、activate()，原样 */ }
    NotifyCenter.shared.releaseAfterLaunch()
}
```

几处细节：

- **系统通知权限**：`install` 最后一步按「有没有通知呈现端」处理。
  - 有呈现端时只装回调代理，不申请权限，和今天 `DesktopPetTool.activate` 一样。宠物关着启动时，权限仍由宠物自己的 `activate()` 申请（保留 `DesktopPetTool.swift:70`）。
  - 没有呈现端（宠物模块没注册）时启动就申请，不再丢第一条。
- **启动期间先攒着**：呈现端装在所有 `activate()` 之前，但宠物要等它自己的 `activate()` 里 `start()` 之后才就绪。
  所以 `activateAll` 期间投递的通知先攒着，全部 `activate()` 跑完再逐条走 `post`。这样排在宠物前面的模块发的通知，不会因为顺序掉到系统通知。今天没有这样的通知，实际行为不变。
- **角色用强引用**：提供者是 `PetController.shared`，本来就活到进程结束。强引用也允许将来交出一个适配对象（用弱引用的话，适配对象会立刻变 nil）。
- **晚注册不支持**：角色只在 `activateAll()` 收集一次。`activateAll()` 之后才 `register` 的模块不会被收集，这和它的 `activate()` 不会被调用一样。

宠物这边：

```swift
// DesktopPetTool
func presentationRoles() -> PresentationRoles {
    PresentationRoles(notifications: PetController.shared,
                      accessories: PetController.shared,      // PR 3 加
                      breakCompanion: PetController.shared)   // PR 4 加
}
func activate() {
    NotifyCenter.shared.prepareSystemFallback(requestPermission: !PetSettings.enabled)   // 保留
    PetController.shared.start()
    // 删掉：NotifyCenter.shared.presenter = PetController.shared
}
```

为什么这样接：

| 方案 | 问题 |
|---|---|
| 现在：`DesktopPetTool.activate()` 给 `NotifyCenter.shared.presenter` 赋值 | 谁都能随时改；宠物注册在最后，别的模块 `activate()` 期间的通知一定走系统通知 |
| 每个 Core 单例各开一个 `install`（`NotifyCenter.install(presenter:)`、`AccessoryDock.install(host:)`…），宠物在 `activate()` 里调 | 仍是在 `activate()` 里给可变静态赋值，顺序问题原样都在 |
| 在 `AppDelegate` 里手工接（`let pet = DesktopPetTool(); …install(…)`） | 框架得认识具体工具，违背 `ToolModule` 的约定 |
| 给 `activate(context:)` 传依赖 | 15 个模块的 `activate()` 都要改签名。`NotifyCenter.shared` 有 32 处调用，还有一个任意线程都能调的 `StorageWriteFailure.report`，终归还得有一个全局入口 |
| **采用：模块声明 `presentationRoles()`，`activateAll()` 一次装进 `PresentationHub`** | 和 `hotkeys()` / `aiFeatures()` 是同一个模式；只写一次、只有框架写；在所有 `activate()` 之前就装好，与顺序无关 |

`PresentationHub` 仍然是 `static let shared`。这个仓库的 Core 服务都是单例（`HotkeyCenter`、`AIService`、`AudioCaptureCoordinator`…），通知也要能在任何地方投递。所以约束是「只装一次、只有框架装、之后只读」，而不是「不许有单例」。

### 3.4 浮窗挂靠：AccessoryHost

```swift
/// 能让别的模块把小浮窗挂上去的地方（目前是宠物头顶）。一次挂一个。
@MainActor
protocol AccessoryHost: AnyObject {
    /// 挂上：能挂就挂成子窗口并贴好位置，不能挂就先不挂。挂上、摘下都回调 onChange(挂着没有)：
    /// 登记时先回调一次，之后状态变了（宠物开关、借出归还、出场退场）再回调。没挂着时，位置由浮窗自己摆。
    func dock(_ window: NSWindow, onChange: @escaping (Bool) -> Void)
    /// 摘下来、不再跟着。不回调，调用方自己收起窗口。传进来的不是当前挂件就什么也不做。
    func undock(_ window: NSWindow)
    /// 浮窗换了大小，或者自己重新排过一次（orderOut 会把子窗口摘掉）：重新挂好、贴位。
    func refresh(_ window: NSWindow, size: CGSize?)
}

/// 浮窗找挂靠点的入口，本身没有状态。没有挂靠点（宠物模块没注册）时，dock 立刻回调 false，其余什么也不做 ——
/// 浮窗照「宠物关着」的样子自己摆。
@MainActor
enum AccessoryDock {
    static func dock(_ window: NSWindow, onChange: @escaping (Bool) -> Void)
    static func undock(_ window: NSWindow)
    static func refresh(_ window: NSWindow, size: CGSize? = nil)
}
```

- 语义照搬 `PetController.dockAccessory / undockAccessory / refreshAccessory`（`PetController.swift:700-722`）。唯一的区别是 `refresh` 多带一个 `window` 参数，不是当前挂件就忽略。
- 宠物这边在 `PetController.swift` 里加 `extension PetController: AccessoryHost`，三个方法直接转给原来的方法。这个 extension 要放在同一个文件里，才读得到 `private` 的 `accessory`。
- `MeetingControlBar` 的 5 处调用（`:27,58,80,97,118`）换成 `AccessoryDock.*`。回调里的 `setDocked` 逻辑不动。

### 3.5 休息画面主角：BreakCompanion

```swift
/// 休息画面里主角此刻在做什么。休息画面只说意图；怎么摆姿势、播哪段动画，归主角自己。
enum BreakCompanionCue: Equatable {
    /// 飞到中央 / 飞回原位：侧身走。
    case walking(facingLeft: Bool)
    /// 倒计时开始：先转过来看你一眼（约 1.2 秒），再躺下。lookAway = 护眼：侧身看远处，不躺。
    case resting(lookAway: Bool)
    /// 休息好了 / 等你确认本人：站着面向你。
    case attentive
}

/// 借出来的主角（宠物的渲染视图）。休息画面把 view 装进自己的舞台窗，按需缩放、飞来飞去，结束时 giveBack()。
@MainActor
protocol BreakCompanionLoan: AnyObject {
    var view: NSView { get }
    /// 主角原来在屏幕上的位置与大小：飞出去的起点、飞回来的终点。
    var homeFrame: NSRect { get }
    /// 最多能放大到原尺寸的几倍还清晰；nil = 不限（3D 是实时渲染的）。
    var maxUpscale: CGFloat? { get }
    func cue(_ cue: BreakCompanionCue)
    /// 被戳了一下（点大宠物 / 点暗处）：做个小动作，做不了就算了。
    func poke()
    /// 还回去，只认第一次调用。调用前休息画面要先摘掉自己的勿扰令牌（§5.1-2）。
    func giveBack()
}

/// 能当休息画面主角的东西（目前是宠物）。不在场（关着、没就绪、正在换形象）就返回 nil，休息画面走回退画面。
@MainActor
protocol BreakCompanion: AnyObject {
    func lend() -> BreakCompanionLoan?
}
```

下表是 `BreakStage.swift` 在每个阶段改发什么意图，以及意图怎么还原成今天的姿态：

| 休息画面阶段（`BreakStage.Phase`） | 今天（`pushPose`，`:650-689`） | 改后：BreakStage 发的意图 | 宠物侧 `PetBreakLoan` 照搬的姿态 |
|---|---|---|---|
| `waiting` / `idle` | 不推 | 不发 | 借出后、收到第一个意图前不推，同今天 |
| `flyingIn`（`flyIn`，`:292-311`） | 先 `pose = PetPose()`；`wander`，目标在左边就朝左；每帧 `walkPhase += 9/30` | `.walking(facingLeft: target.midX < homeFrame.midX)` | 同左。新借出的 loan 自带一份新 `PetPose`，等于今天那次重置 |
| `resting`（`beginResting`，`:332-339`） | 前 1.2 秒 `idle` + `attentive`。之后护眼是 `idle`、朝右、轻微上下浮；不是护眼就 `sleep` + `lying` + `eyesClosed` | `.resting(lookAway: request.lookAway)` | 同左。1.2 秒从收到这个意图起算（今天从 `restingSince` 算，是同一时刻） |
| `celebrating`（`celebrate`，`:349-361`） | `idle` + `attentive`，上下浮 | `.attentive` | 同左 |
| `confirming`（`startConfirm`，`:381-400`） | 同 `celebrating` | `.attentive`（可能从 `resting` 直接进来，所以这里也要发） | 同左 |
| `flyingOut`（`finish`，`:527-541`） | 不重置；`facingLeft = homeFrame.midX < 当前.midX`；`wander` | `.walking(facingLeft: homeFrame.midX < current.midX)` | 同左。不重置，接着上一帧的 `time` / `walkPhase` |

`BreakStage.swift` 里其余的替换：

- `loan.frame` 换成 `homeFrame`（`:245,302,308,534,539`）。
- `is3D` 换成 `maxUpscale`：`:263` 改成 `maxSide = loan?.maxUpscale.map { (loan?.homeFrame.height ?? 104) * $0 } ?? 520`。
- `performLent("poke")` 换成 `loan?.poke()`（`:696,711`）。
- `returnRenderView()` 换成 `loan.giveBack()`（`:610-613`）。
- 删掉 `pose`、`poseTimer`、`pushPose`，以及它们的创建和失效（`:110,112,601-602,650-689,734-740`）。

宠物这边新建 `PetBreakCompanion.swift`：

```swift
@MainActor
final class PetBreakLoan: BreakCompanionLoan {
    init(_ loan: PetController.Loan, owner: PetController)
    // view = loan.view；homeFrame = loan.frame；maxUpscale = loan.is3D ? nil : 3
    // 自己持有一个 1/30 秒、.common 模式的 Timer：借出时开，giveBack 时停。节奏和今天 BreakStage 的 poseTimer 一样。
    // 不复用宠物引擎的帧定时器：引擎会随系统睡眠 suspend（PetEngine.swift:347），复用的话行为会变。
    // tick：按当前意图算出 PetPose（逐行照搬 pushPose，见上表），再 owner.setLentPose(pose)。
    // poke → owner.performLent("poke")
    // giveBack → 停定时器、view.removeFromSuperview()、owner.returnRenderView()
}
extension PetController: BreakCompanion {
    func lend() -> BreakCompanionLoan? { lendRenderView().map { PetBreakLoan($0, owner: self) } }
}
```

`PetController.Loan`、`lendRenderView`、`setLentPose`、`performLent`、`returnRenderView` 都留着，只是变成宠物模块内部用。

顺手加一道保险，不改今天的行为：`PetController.stop()` 记一个 `stopped` 标记；`stopped` 之后再调 `returnRenderView()`，只把视图放回去，不再 `applyVisibility()`、不打招呼。这样退出时不管谁先 `willTerminate`，都不会把宠物重新放出来（§1.2）。

### 3.6 提醒时的动作与「宠物在不在」

- `FocusHealthController` 的 4 处 `PetController.shared.act(clips:)`（`:445,494,575,671`）换成 `NotifyCenter.shared.performGesture(clips)`。原来那几个 0.6 秒、1.0 秒的 `asyncAfter` 延时留在原处，时序不变。`PetController.performGesture` 的实现就是调 `act(clips:)`。
- `:664` 的 `PetController.shared.isReady` 换成 `NotifyCenter.shared.presenterIsReady`。
- 动作挂在呈现端上，因为它是「宠物配合这条提醒演一下」，只有呈现端知道自己能不能演。
  更干净的做法是把动作并进通知模型（加一个 `gesture` 字段，由宠物自己挑时机演）。但那样会改时序，留到后续（§8）。

### 3.7 宠物模块里留什么

宠物模块保留：

- 引擎、渲染（2D / 3D / VRM）、气泡（`BubbleController`）、环形菜单、出场退场、找空地、素材包。
- 宠物设置页（含「通知」一组开关）、宠物菜单（含「安静一下」「发送测试通知」）。
- 三个角色的实现：`PetController` 和 `PetBreakLoan`。

宠物模块可以随便用 Core；Core 和别的模块不再用宠物。

### 3.8 回退一览（合入后）

| | 宠物开着 | 宠物关掉 | 宠物模块没注册 |
|---|---|---|---|
| 通知 | 宠物气泡 | 系统通知（带按钮），同今天 | 系统通知（带按钮）；**启动时就申请权限**（改进） |
| 提醒时的动作 | 宠物演 | 不演，同今天 | 不演 |
| 会议控制条 | 挂在宠物头顶 | 屏幕顶部居中、可拖、记住位置，同今天 | 同「宠物关掉」（`AccessoryDock` 直接回调 false） |
| 休息画面 | 宠物飞到中央 | 回退画面（渐变 / 图片 / 模糊 + 卡片），同今天 | 同「宠物关掉」（`breakCompanion` 为 nil）；**不再顺手把 `PetController.shared` 建出来**（改进） |

### 3.9 为什么拆成两个协议

issue 写的是「`lendRenderView` / `dockAccessory` 换成 Core 的 `AccessoryHost` 协议」。但这两件事方向相反：

- **挂靠**：别人的窗口挂到宠物身上，宠物管位置。挂件常驻整场会议，需要回调「挂没挂上」。
- **借主角**：宠物的视图交给别人，别人管位置和意图。只借一场休息，需要推意图、最后归还。

合成一个协议的话，会议控制条就得认识「借视图」，休息画面也得认识「挂没挂上」的回调。所以挂靠沿用 issue 的名字 `AccessoryHost`，借主角另起名叫 `BreakCompanion`（§6-2）。

## 4. 迁移步骤

按顺序合，每一步单独一个 PR、能编译、行为不变。PR 1–3 都不碰 FocusHealth，FocusHealth 的改动集中在 PR 4（见 §6-6）。
PR 2–4 依赖前一个 PR 引入的类型，必须按顺序合。

### PR 1 · 通知内核搬到 Core（纯搬家 + 拆设置）

PR 内分两个提交：第一个只做 `git mv`，第二个再改引用。这样 `git log --follow` 和 blame 都能跟上。

- 搬家：
  - `git mv mac/Sources/Modules/DesktopPet/NotifyCenter.swift mac/Sources/Core/Notify/NotifyCenter.swift`
  - `git mv mac/Sources/Modules/DesktopPet/NotifyDND.swift mac/Sources/Core/Notify/NotifyDND.swift`
- 新建 `Core/Notify/NotifySettings.swift`（§3.2），`NotifyCenter.swift:93,134,208-209` 和 `NotifyDND.swift:39,47` 改读它。
- `DesktopPet/PetSettings.swift`：删掉 `soundKey / historyLimitKey / quietUntilKey / soundEnabled / historyLimit / sourceEnabled / quietUntil / setQuietUntil`，类型注释从「桌面宠物 / 通知中心设置」改成「桌面宠物设置」。
- 宠物模块里改读 `NotifySettings` 的地方：`DesktopPetTool.swift:33`、`PetController.swift:942,1140,1144,1148`、`PetSettingsView.swift:12`。
- 文档：
  - `docs/desktop-pet/DESIGN.md` 的 §2、§9、§10，改文件位置；
  - 根目录 `CLAUDE.md`：Core 共享基础设施里补 `Notify/`（所有模块投递通知、挂勿扰的入口），docs 布局里补 `docs/notify-core/`。
- 为什么行为不变：同一个 target、类型名不变，32 处调用点不用改；键名一个没变。
- 自查：`grep -rn "PetSettings" mac/Sources/Core` 为空；编译通过。

### PR 2 · 通知呈现端改由框架接线

- 新建 `Core/Presentation/PresentationRoles.swift`：`PresentationRoles`（这一步只有 `notifications`）和 `PresentationHub`。
- `Core/ToolModule.swift`：加 `presentationRoles()` 及默认实现。
- `Core/ToolRegistry.swift`：`activateAll()` 开头先 `holdDuringLaunch`、再 `install`（都在任何 `activate()` 之前），全部 `activate()` 跑完 `releaseAfterLaunch`。
- `Core/Notify/NotifyCenter.swift`：删 `weak var presenter`，`deliver` 改读 `PresentationHub.shared.notifications`；加启动期间先攒着的逻辑。
- `DesktopPet/DesktopPetTool.swift`：实现 `presentationRoles()`；`activate()` 删掉给 `presenter` 赋值那一行。
- 文档：
  - `docs/desktop-pet/DESIGN.md` §2，写清呈现端怎么接上；
  - 根目录 `CLAUDE.md` 架构一节：`ToolModule` 的可选声明里补 `presentationRoles()`。
- 为什么行为不变：
  - 呈现端还是 `PetController.shared`，只是装得更早（在所有 `activate()` 之前）。
  - 回调代理还是启动时装；有宠物模块时，申请权限的时机不变。
  - 启动期间攒着的那段，今天没有通知会进去。
- 自查：`grep -rn "\.presenter\b" mac/Sources` 为空；启动日志里没有 presentation 的 fault。

### PR 3 · 会议控制条改走 AccessoryDock

- 新建 `Core/Presentation/AccessoryHost.swift`（§3.4）；`PresentationRoles` 加 `accessories`。
- `DesktopPet/PetController.swift`：同一个文件里加 `extension PetController: AccessoryHost`。`DesktopPetTool.presentationRoles()` 交出 `accessories`。
- `Meeting/MeetingControlBar.swift:27,58,80,97,118` 换成 `AccessoryDock.*`。
- 文档：`docs/desktop-pet/INTERACTION.md` §1、`docs/meeting/TECH_DESIGN.md` 第 64、128 行。
- 为什么行为不变：转发的是同一组方法；`refresh` 多出的窗口判断，在只有一个挂件时恒为真。

### PR 4 · 专注与健康不再认识宠物

- 新建 `Core/Presentation/BreakCompanion.swift`（§3.5）；`PresentationRoles` 加 `breakCompanion`。
- `Core/Notify/NotifyCenter.swift`：`NotifyPresenting.performGesture` 及默认实现；加 `presenterIsReady`、`performGesture(_:)`。
- 新建 `DesktopPet/PetBreakCompanion.swift`：`PetBreakLoan` + `extension PetController: BreakCompanion`。
  `lendRenderView` 是 internal，所以这个 extension 可以放在新文件里。`pushPose` 的映射逐行搬过来。
- `DesktopPet/PetController.swift`：
  - 实现 `performGesture`（就是调 `act(clips:)`）；
  - `stop()` / `returnRenderView()` 加 `stopped` 保险。
- `DesktopPet/DesktopPetTool.swift`：`presentationRoles()` 交出 `breakCompanion`。
- `FocusHealth/BreakStage.swift`：按 §3.5 的表替换。`cleanup` 里「先摘 break 令牌、再 giveBack」的顺序和那行注释都保留（`:608-613`）。
- `FocusHealth/FocusHealthController.swift`：`:445,494,575,671` 换成 `NotifyCenter.shared.performGesture`，`:664` 换成 `presenterIsReady`。
- 文档：
  - `docs/desktop-pet/DESIGN.md` §8；
  - `docs/focus-health/TECH_DESIGN.md`：§1 文件表里 BreakStage 一行、§5.3（借宠物 → 借主角 + 意图表）、§6 里 `PetController.act(clips:)` 那条。
- 为什么行为不变：
  - 姿态逻辑原样搬过去，推送节奏还是 30 fps、`.common` 模式；
  - 意图在原来的阶段切换点发出；
  - 动作的延时留在原处；
  - `stopped` 保险在今天的注册顺序下不会触发。
- **这是最容易搬坏的一步**：按 §5.2 的休息画面矩阵在真机上过一遍再合。

### PR 5（可选）· 通知内核纯逻辑单测

前提：`BaoboxTests` 先合进 main。`refactor/usage-calculator` 分支正在加这个 target，它只编 `mac/Tests/` 和指定的纯逻辑目录。

- 新建 `Core/Notify/Model/`，里面只依赖 Foundation：
  - 通知模型，从 `NotifyCenter.swift` 移过来；
  - `NotifyLedger`：负责去重（30 秒）、同标题合并计数、逐来源开关、勿扰时攒不攒、alert 和操作回执绕过勿扰、摘要取前 3 个标题、历史条数上限。时间和设置都由参数传入。
- `NotifyCenter` 改为调 `NotifyLedger`。窗口、声音、系统通知、定时器、`L()` 仍留在 `NotifyCenter`。
- `mac/project.yml`：`BaoboxTests.sources` 加 `Sources/Core/Notify/Model`。
- 新增 `mac/Tests/Notify/NotifyLedgerTests.swift`，覆盖：
  - 去重边界：29.9 秒和 30.1 秒；
  - 同标题合并计数；
  - 来源关掉时直接丢；
  - 勿扰时 bubble 入队，alert 和回执照常出；
  - 摘要的条数和标题；
  - 历史裁剪。
- 测试按现状写，不顺手改语义。比如「同一个去重 key、标题不同」：第二条直接丢，历史也不加计数，今天就是这样。

### PR 6（可选，待拍板）· `PetNotification` 改名 `Notice`

- 纯改名：16 个文件里的 35 行，加上宠物模块内部的引用。
- `NotifyCenter.swift` 里保留一个版本的 `@available(*, deprecated, renamed: "Notice") typealias PetNotification = Notice`，给在途分支缓冲，下个版本删。
  macOS 构建不把警告当错误；2026-11-10 用 swiftc 在临时文件里核对过，旧名只报 deprecated 警告。
- 放在最后：改名碰的文件最多，等在途分支都合完再做，冲突最少。

## 5. 风险与验证

### 5.1 最容易搬坏的地方

1. **休息画面的姿态（PR 4）**。`pushPose` 搬进宠物模块后最可能出的错：
   - 飞行中不迈步（`walkPhase` 没累加）；
   - 朝向反了；
   - 到中央没先转过来看你一眼；
   - 护眼时躺下了；
   - 确认本人阶段还躺着（`startConfirm` 漏发 `.attentive`）；
   - 开了减弱动态效果，停在走路姿势（`.walking` 后紧接 `.resting`，两个都得发）。

   对策：逐行照搬，PR 描述里贴新旧映射对照，再按 §5.2 的矩阵过一遍。
2. **先摘勿扰再还宠物**（`BreakStage.swift:608-609`）。顺序反了的话，引擎还按勿扰让宠物睡着，还回去会先躺下再爬起来。`giveBack()` 的文档注释和 `cleanup` 里都要写明。
3. **接线时机提前了（PR 2）**。`install` 在所有 `activate()` 之前，这时宠物还没 `start()`。要确认两件事：宠物开着启动时不多弹一次权限框；宠物关着启动时照样弹（由宠物的 `activate()` 申请）。
4. **设置键兼容（PR 1）**。`notify.sound`、`notify.historyLimit`、`notify.source.*`、`pet.quietUntil` 必须原样不动。
   核对方法：PR 前后各跑一次 `defaults read com.baobox.app | grep -E 'notify\.|quietUntil'`，结果应该一致；设了「安静 1 小时」再升级，应该仍在安静中。
5. **挂件的 `refresh` 带窗口参数（PR 3）**。`MeetingControlBar` 传进去的必须是同一个 `panel`。要专门验证收起速记以后 `orderOut` 再挂回去的那条路（`:93-98`）。
6. **搬家要保留历史（PR 1）**。先单独 `git mv`、后改内容（见 PR 1）。`NotifyCenter` 的去重、摘要逻辑在 PR 1 里一行都不动。
7. **在途分支冲突**。
   - `feat/focus-history-export`（#104）改了 `FocusHealthController.swift` 和 `docs/focus-health/TECH_DESIGN.md`。代码上和 PR 4 改的行不重叠，文档会冲突。
   - PR 5 依赖 `refactor/usage-calculator` 加的测试 target。
   - PR 6 改名几乎和所有在途分支冲突，所以放最后。
8. **`ToolModule` 的形状变了（PR 2）**。Rust 的 `ToolModule` trait 不跟着改（§2），在 PR 2 的描述里写一句。

### 5.2 验证方法

**编译**（每个 PR 都跑）：

```bash
cd mac && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Baobox -configuration Debug -derivedDataPath <scratchpad>/dd build
```

新增的 `.swift` 文件自动纳入（`project.yml` 是全量 glob），只有 PR 5 要改 `project.yml`。没有 `Vendor/` 也能编，脚本阶段只告警。

**静态检查**（PR 4 合入后应该输出为空）：

```bash
cd mac/Sources
grep -rnwE "PetController|PetPose|PetSettings|PetEngine|BubbleController|DesktopPetTool" --include='*.swift' . \
  | grep -v "Modules/DesktopPet/" | grep -v "App/AppDelegate.swift"
```

本设计不新增用户可见文案，`Localizable.xcstrings` 不用动；照例跑一遍 JSON 校验。

**真机矩阵**：装本地构建（根目录 `CLAUDE.md`「发布」一节）。

| 场景 | 宠物开着 | 宠物关掉 |
|---|---|---|
| 测试通知（宠物菜单 → 发送测试通知，三种样式） | 出三种气泡；点 sticky 的按钮，宠物会说话 | 三条系统通知；sticky 那条的按钮能点 |
| 勿扰摘要：在全屏 App 里触发一条 bubble 级通知，再退出全屏 | 5 秒内出摘要气泡 | 出一条摘要系统通知 |
| 专注：开始 / 暂停（出卡片 [继续][结束这一轮]）/ 继续 | 出回执气泡，勿扰时也出 | 出回执系统通知 |
| 健康提醒：喝水 + 站立（设置里把间隔调短）、护眼 | 卡片 + 宠物坐下喝水 / 伸懒腰 / 远眺 | 系统通知，宠物不演 |
| 设置页「预览效果」，轻松 / 标准 / 严格三档，2D、3D 形象各一次 | 轻松：气泡 + 打哈欠。标准 / 严格：宠物飞到中央变大、躺下，到点起身，Touch ID 确认后飞回 | 轻松：系统通知（文案是系统通知的说法）。标准：渐变卡片。严格：模糊 |
| 护眼的休息画面（`lookAway`） | 侧身看远处，不躺下 | 回退画面 |
| 系统设置里开「减弱动态效果」后预览 | 直接出现在中央，结束时直接回去 | — |
| 休息画面中途长按跳过 | 进入确认本人阶段时，宠物站起来面向你 | 卡片换成确认 |
| 会议：开始记录 | 控制条挂在宠物头顶；展开速记往上长；收起后仍然挂着 | 屏幕顶部居中，可以拖，下次记得位置 |
| 会议中关掉 / 打开宠物 | 关：控制条回到顶部。开：宠物出场落地后挂回去 | — |
| 会议中点「现在休息」 | 控制条先摘下来，休息结束后挂回去 | — |
| 休息画面在场时退出 Baobox | 宠物不会闪出来；下次启动宠物还在原位 | — |

**宠物模块没注册**（只在本地临时验证，不提交）：注释掉 `AppDelegate.swift:37`，编一个本地包，确认：

- 启动就弹通知权限框（以前没授权过的话）；
- 通知走系统通知，按钮能点；
- 休息画面走回退画面；
- 会议控制条在屏幕顶部，可以拖；
- 日志里没有 fault。

**日志**：`/usr/bin/log stream --predicate 'subsystem == "com.baobox.app"'`（zsh 里裸写 `log` 是内建命令）。

- 每场休息画面有一行 `break shown: …, pet true/false`（`BreakStage.swift:188`），PR 4 之后应该照旧。
- `PresentationHub` 的 fault 只在配置错时出现。

**单测**：PR 5 合入后跑 `xcodebuild test -scheme Baobox`。

## 6. 已拍板（2026-11-10）

用户同意按下面的建议做：

1. **`PetNotification` 改名 `Notice`**（和 Windows 版 `pet_notify.rs` 同名）：单独一个纯改名 PR，放在最后（PR 6），保留一个版本的 deprecated typealias。
2. **拆成两个协议**：挂浮窗叫 `AccessoryHost`，借主角叫 `BreakCompanion`（理由见 §3.9）。
3. **「宠物模块没注册」只保证不崩、不丢通知、功能能用**，不为它另做入口。通知开关、提示音、「安静一下」仍留在宠物设置页和宠物菜单里。
4. **回退路径上的两个洞另开 issue**（#144），P1 不动（P1 的前提是行为不变）。
5. **「系统通知权限被拒 + 宠物关着」的提示**以后在宠物设置页「启用宠物」下面加一行小字，不放在 P1。
6. **排期**：PR 1–3 按顺序合；PR 4（专注与健康）的前置 #104 已合入；PR 5 的前置 `BaoboxTests` 已合入（#134）；PR 6 按第 1 条做。

## 7. 与 issue 描述不一致的地方

- **行号漏了几处**。按 `50103fe` 核对，issue 列的行号都对得上，但漏了：
  - `MeetingControlBar.swift:27`：`show()` 里的 `refreshAccessory`；
  - `FocusHealthController.swift:664`：读 `PetController.shared.isReady`；
  - `BreakStage.swift:102`：用了 `PetController.Loan` 类型；
  - `BreakStage.swift:110,300`：用了 `PetPose`，连带宠物引擎内部的 `PetEngine.State` / `PetGait` / `PetFlightPose`。
- **「`NotifyPresenting` 已存在，只需搬家」不完全成立**。`NotifyCenter` 读 `PetSettings.sourceEnabled / soundEnabled / historyLimit`，`NotifyDND` 读 `PetSettings.quietUntil`，搬之前得先拆出 `NotifySettings`。另外模型类型还叫 `PetNotification`。
- **「宠物关闭时回退到独立窗口」今天已经有了**：
  - 控制条：`MeetingControlBar.swift:64-73`；
  - 休息画面的回退画面：`BreakStage.swift:198-205,249-253`（#49 / #50）；
  - 通知回退系统通知：`NotifyCenter.swift:126-128`。

  验收标准里的三件事，在「宠物关掉」时今天就成立。P1 实际要做的是类型解耦，并让「宠物模块不在」时也成立。
- **`lendRenderView` 和 `dockAccessory` 不是同一类能力**，建议拆成两个协议（§3.9）。
- **issue 没提的两点**：
  - Core 已经反向依赖宠物模块（`Core/StorageWriteFailure.swift:23`、`Core/AI/AIUsageMeter.swift:121`），PR 1 顺带消掉；
  - 启动和退出各有一处注册顺序依赖（§1.2）。

## 8. 后续（不在 P1）

- §6-4、§6-5 里那几个洞。
- 把提醒动作并进通知模型（`gesture` 字段），由宠物自己挑时机演。今天是 FocusHealth 用 0.6 / 1.0 秒的延时估的。
- 通知历史界面。数据已经在 `NotifyCenter.history` 里。
- 对外协议（#113）落地时，`NotifyGateway` 直接放进 `Core/Notify/`。
- `AIUsageMeter.openSettings` 和宠物环形菜单都读 `AppDelegate.shared?.registry`，也就是 Core 和模块依赖了 App 层。另议。
