# 实时翻译（Live Translate）— 需求与技术设计

> 模块 id `livetranslate`，目录 `mac/Sources/Modules/LiveTranslate/`，本地化命名空间 `livetranslate.*`。
> 仅 macOS；Windows / Linux 暂不移植。

## 1. 需求

| # | 需求 | 说明 |
|---|---|---|
| R1 | 声音取字 | 实时把语音转成文字（语音识别） |
| R2 | 音源可选 | **麦克风**（自己说话、线下会议）或**系统声音**（视频、网课、线上会议对方的声音），菜单与设置页都能切 |
| R3 | 实时翻译 | 英文 ⇄ 中文；可关闭翻译只看原文字幕 |
| R4 | 屏幕长条字幕 | 屏幕底部一条半透明长条，置顶、跨 Space、全屏 App 上也可见；可拖动，位置记忆 |
| R5 | 显示样式 | 双语 / 仅译文 / 仅原文；字号、背景不透明度可调 |
| R6 | 一键开关 | 菜单「开始 / 停止」+ 全局快捷键（出厂不绑定） |

非目标（P1 再议）：两路音源同时识别、选择具体麦克风设备、字幕导出成文件。

> 2026-11：说话语言 / 目标语言扩展到 21 种，新增「自动（A / B）」双识别器逐句判别语种；macOS 14 用离线模型翻译。
> 见 `docs/translation-engine/DESIGN.md`（§3.2 双识别器、§2 引擎）。

## 2. 技术选型

全部用系统框架，**零第三方依赖、不联网调用任何自建服务**：

| 环节 | 方案 | 备注 |
|---|---|---|
| 麦克风采集 | `AVAudioEngine.inputNode` tap | 默认输入设备；需麦克风授权（entitlement 已有） |
| 系统声音采集 | ScreenCaptureKit `SCStream`，`capturesAudio = true`，只挂 `.audio` 输出 | 复用录屏那套；需**屏幕录制**授权；`excludesCurrentProcessAudio` |
| 语音识别（macOS 26+，首选） | `Speech` 框架 `SpeechAnalyzer` + `SpeechTranscriber`（`.volatileResults`） | 本地模型、为长音频设计，一路流到底不切段 → 上下文完整、**更准**；volatile 结果出字**更快**。首次用 `AssetInventory` 自动下载语言模型；音频经 `AVAudioConverter` 转成 `bestAvailableAudioFormat`。`#if compiler(>=6.2)` 包住（需 Xcode 26 编译） |
| 语音识别（macOS 14–15 / 回退） | `Speech` 框架 `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` | locale `en-US` / `zh-CN`；设置开「优先本地识别」且 `supportsOnDeviceRecognition` 时 `requiresOnDeviceRecognition = true`（不上传音频；「自动」双语模式下只有第一路能本机，见 `docs/translation-engine/DESIGN.md` §3.3）；需**语音识别**授权 → `NSSpeechRecognitionUsageDescription` |
| 翻译 | `Translation` 框架（macOS 15+），SwiftUI `.translationTask` 拿 `TranslationSession`；每个翻译方向一个会话 | 系统本地翻译；系统不支持这对语言时（「自动」引擎）改用离线模型。**macOS 14 用离线模型 Hy-MT2**（共享层 `OfflineTranslator`，运行期间常驻），没下载时只显示原文并提示 |

`Speech` / `Translation` 是新引入的系统框架：录屏的音频、截图的 OCR（Vision）之外没有现成能力可复用，
这是这个功能的最小集合。`Translation` 全程 `#if canImport(Translation)` + `@available(macOS 15.0, *)` 包住，
旧 SDK / 旧系统都能编译、能跑。

## 3. 数据流

```
音源(mic / SCK) ──PCM──▶ AudioRouter(锁) ──▶ 当前段的 RecognitionRequest
                                               │ partial / final（任意线程）
                                               ▼
                          LiveTranslateController(@MainActor) ── lines[] ──▶ 字幕条 SwiftUI
                                               │ submit(id, text, isFinal)
                                               ▼
                          LiveTranslateTranslator ◀── translationTask(session) 挂在字幕条视图上
                                               │ targetText
                                               └──▶ lines[id].translation
```

### 3.0 引擎选择

macOS 26 且该语言被 `SpeechTranscriber` 支持 → 新引擎；不支持、模型下载失败、启动失败 → **自动回退**旧引擎。
两个引擎实现同一个 `LiveTranslateRecognizer` 协议（`onUpdate(id, text, isFinal)`），控制器不关心用的是哪个。
新引擎每个 final 结果算一句（id+1），之后的 volatile 结果是下一句的进行中文字。

**专有名词**：设置里的一张表，每行「原文 → 译名」（译名可空，最多 100 项）—— 识别时原文与译名都作提示词（新引擎走 `AnalysisContext.contextualStrings`、开始时给；旧引擎走 `request.contextualStrings`、每段现读），离线翻译按译名翻、没译名的保持原样。格式与翻译规则见 `docs/translation-engine/DESIGN.md` §2.3。

### 3.1 旧引擎分段（segment）

`SFSpeechRecognizer` 单个请求有时长上限（服务端约 1 分钟），且一句话说完前文字会一直被改写。
因此按「段」识别：每段一个 request + task，段 id 单调递增，字幕条只保留**最近 2 段**（上一句淡出 + 当前句）。

切段时机（主线程 0.5s 看门狗）：

- 当前段文字 **1.2s 没变化**（停顿 = 一句话说完）；
- 当前段已持续 **45s**（防触到时长上限）；
- 系统主动给出 `isFinal` / 出错。

切段 = 对旧 request `endAudio()`，**等它把 final 回完（最多 1.2s）再开下一段**，其间音频由
`LiveTranslateAudioGate` 攒着、新段一开按顺序补喂 —— 不丢音频。不能边等边开：系统的听写服务同一时间只服务一个
请求，新请求会把还没回 final 的旧请求掐掉（本机识别以 1110、服务器以 209 结束，实测 2026-11-05），定稿结果
（带纠错和标点）就丢了，字幕和「这句是哪种语言」都只能靠粗糙的 partial —— 这正是「识别不精准」的主因。双识别器同理，
等两路的 final 都回来再开下一段。

连续 3 段都在 1 秒内出错且没有任何文字（如系统听写被关、识别服务不可用），判定为不可恢复：停止并弹窗说明，避免死循环重启。

**字幕条快捷菜单（2026-11-05）**：顶上一行「音源 ▾」「说：… ▾」「译成：… ▾」，选了立即生效（重新开始一次，字幕条位置不变），后面跟状态（识别方式 / 翻译引擎）。菜单按深色外观画，浅色系统外观下也看得清。

### 3.2 翻译节流

**边说边翻（2026-11-05）**：长段落不再整句反复重翻 —— 每次都从头翻、越说越长，离线模型（约 55 token/s）
跟不上，看起来像要等说完才出译文。现在按 `LiveTranslateUnits` 把一句切成单元（句末标点；够长了在逗号处；
没标点又太长时中文按分词切在词边界、英文切在空格；英文缩写 / 小数不拆），说完的单元各翻一次（按定稿排队），
只有最后那截还在说的按草稿反复重翻。字幕上的译文 = 各单元译文拼起来 + 草稿；刚说完的单元先拿草稿译文顶着，
正式译文回来再换，不闪。任务 id = 句 id × 1000 + 单元序号（999 = 草稿），结果带回原文与方向，过时的丢掉。

识别 partial 每秒可达十几次。翻译器维护两个槽：

- `finals`：已定稿的段，**全部**要翻（按顺序）；
- `latest`：最新的 partial，**只保留最后一个**（新的覆盖旧的）。

`serve(session)` 循环：被唤醒（`AsyncStream<Void>`，`bufferingNewest(1)`）后先清 `finals` 再翻 `latest`，
同一时刻只有一个翻译在飞 —— 天然节流到「翻完一条再翻最新那条」。
`TranslationSession` 只在 `.translationTask` 闭包生命周期内使用，不外泄；字幕条关闭即任务取消、循环结束。

翻译失败（语言包未装、用户取消下载）只在字幕条提示一次，并引导到「系统设置 › 通用 › 语言与地区 › 翻译语言」。

**草稿就是译文（2026-11-05）**：用户反馈「译文都出来了，过几秒才有声音」—— 字幕上先出来的是草稿译文，朗读却要等这截定稿、
纠错、正式翻译。现在单元说完时，如果最近一次草稿翻的**正好就是这一整截**（去掉标点、空格、大小写后相同；草稿结果回来时记下
它对应的原文 `tailTranslationSource`），就把草稿当成这截的译文：立刻朗读；不纠错时连正式翻译也不再排（同一段原文再翻一遍没意义，
模型少排一条，后面的句子也快）；纠错照常，纠完没改字就沿用草稿，改了字才翻纠正后的（朗读不再重读）。

### 3.4 AI 纠正识别错字（2026-11-05）

起因：「实时翻译」被识别成「时事翻译」。这类错成了另一个真词的同音字，系统识别器不会按上下文回改，靠用户往专有名词里
加词也加不完。翻译模型 Hy-MT2 试过：能把「世场推广」改成「市场推广」（不成词的错字），但「时事翻译」原样放过。

- 模型：通义千问 Qwen3-1.7B（官方 Q8_0，1.83 GB），和翻译模型一样在 App 里单独下载、各起一个 llama-server 进程
  （`OfflineTranslator.corrector`）。请求带 `chat_template_kwargs.enable_thinking = false`，提示词末尾再加 `/no_think`。
- 流程：中文单元说完 → 交给纠错（上文 = 这句前面已说完的单元 + 不够时接上一句，最多 100 字）→ 结果回来换掉字幕原文里
  这一单元 → 按纠正后的文字翻译。还在说的那截照旧先出草稿译文，不等纠错；单元的正式译文晚约 1 秒。
- 防乱改（`LiveTranslateCorrector.accept`）：取第一行、去掉「改正后：」之类的前缀和引号；长度差或编辑距离超过三成就不用。
- 纠错模型还在加载（冷启动约 9 秒，比翻译模型还慢）时先不纠、直接翻，就绪后的单元才纠：第一句不用陪着等它。
- 开关：设置「AI 纠正识别错字」（`livetranslate.aiCorrection`，默认开），模型没下载、或没开翻译时不纠。纠错模型在实时翻译
  运行期间常驻，空闲 10 分钟退出；字幕条状态行显示「· AI 纠错」。

## 3.3 构建

`build-macos.yml` 用 Xcode 26（macos-15）与 Xcode 16.2（macos-14）各编一次：前者编进新引擎，后者保证旧工具链也编得过。
`release.yml` 用 Xcode 26 —— 否则发出去的包里没有新引擎。本地用 Xcode 16 编也能用，只是只有旧引擎。

## 4. 字幕条

- `NSPanel`：`.borderless + .nonactivatingPanel`，`level = .statusBar`，
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`，不抢焦点（`canBecomeKey = false`）；
  拖背景移动（`isMovableByWindowBackground`），**拖边 / 角改大小**（2026-11-05 用户要求「这个框可以自由拉」），最小 480×96。
  无边框窗口加 `.resizable` 系统也不给拖边（实测拉不动），所以自己做 `BarResizeArea`：四条边各一条 6pt 细条、四个角各一块，
  叠在 SwiftUI 内容上面（`mouseDownCanMoveWindow = false`，拖它是改大小不是挪窗口），按住拖时按拖的是哪几条边改 frame；
  右下角那块画三道斜线当可见的拖拽角。字幕条不能成为 key window，光标靠 `.activeAlways` 追踪区设置（斜向双箭头用 SF Symbol 画）。
  移动、改大小时把整个 frame 存 `livetranslate.barFrame`，下次仍在某屏内就沿用；旧版只存过原点（`barOrigin`）就用它 + 默认大小。
  `NSHostingView.sizingOptions = []`：窗口大小由用户定，SwiftUI 内容铺满，不再按内容撑窗口（否则拉不动）。
- 默认大小：屏幕可见宽度 70%（上限 1200pt）× 两句字幕的高度（按字号与显示样式算）。
- 字幕区是可滚动的**历史**：控制器保留最近 200 句，最新的在最下面，每句全文换行显示（不再截断）。内容不满一屏时贴底。
  在字幕条上改音源 / 语言 / 译成 / 朗读输出等会「停掉再重开」一次（`restartIfRunning`），这时**历史留着**、新字幕条接着显示
  （2026-11-05 用户：切换设置后历史记录就没了）：旧句子按定稿保留，识别器的句子 id 每次从头编，新句子加偏移 `lineIDBase`
  免得撞号；只有手动停止才清空。
  跟随规则：内容高度变了（来了新字、改了窗口大小）且在跟 → 滚到底；高度没变而位置变了 = 用户在翻 → 离底部超过 24pt 就不跟，
  右下角出「回到最新」按钮；翻回底部自动接着跟。判断靠字幕区内容在滚动坐标系里的 frame（PreferenceKey）。
- 顶上一行：音源 / 说 / 译成 / 朗读 快捷菜单 + **记录按钮**（点一下开 / 关，旁边小按钮打开本次记录或文件夹）+ 状态（识别方式、
  翻译引擎）+ 右上角**延迟监控**（见下）。
- 右上角一个小 ✕ = 停止。
- **模型加载中**（2026-11-05 用户：第一次翻译特别慢，没加载好就播个动画）：本次用离线模型、模型进程还没就绪
  （`OfflineTranslator.isStartingServer`）时，字幕区底部转圈 +「正在加载翻译模型，第一次要几秒…」，就绪后消失。
  实测冷启动加载：Hy-MT2 6.3 秒、Qwen3 8.7 秒（同时加载）。纠错模型还在加载时中文先不纠、直接翻（§3.4），第一句不用等它。
- 朗读菜单里的虚拟声卡列表在开始时查一次（`virtualDevices`）：字幕条每来一个字都会重画，不能每次都去系统里枚举声卡。

### 4.1 延迟监控（2026-11-05）

右上角「识别 0.8s · 翻译 0.5s」，都是最近 5 次的中位数；白 < 1.5s、黄 1.5–3s、橙 ≥ 3s。

- **识别**：停顿（≥ 0.6 秒没声音）后重新开口，到最新那句多出字的时间。开口时刻由音频路由记（`takeOnset`）：上一次开口还在等出字
  （不到 2.5 秒）就不覆盖，超过 6 秒没出字的作废（多半是咳嗽、敲键盘之类没被识别成字的声音）。
- **翻译**：一截（单元）说完、提交去纠错 / 翻译，到它的正式译文回来；开了 AI 纠错含纠错。草稿正好翻的就是这整截时算 0（见 §3.2）。
- 有一截等译文比平时久（超过「中位数 + 1 秒」且超过 1.5 秒）时，改显示它已经等了多久（带「…」），每半秒刷新：翻译卡住时数字一直涨。

## 5. 权限与降级

| 条件 | 处理 |
|---|---|
| 语音识别未授权 | 首次弹系统授权；被拒 → 弹窗引导去「隐私与安全性 › 语音识别」 |
| 麦克风音源、麦克风被拒 | 弹窗引导去「隐私与安全性 › 麦克风」 |
| 系统声音音源、无屏幕录制权限 | 触发系统登记 + 弹窗引导（授权后需重启，沿用 `Permissions` 的既有逻辑） |
| 该语言识别器不可用 | 弹窗说明（多为系统「听写」被关闭或网络不可用且无本地模型） |
| macOS 14 | 只显示原文，提示「翻译需要 macOS 15」 |

## 6. 本地记录与纪要（2026-11-05）

用户要求「内容支持本地记录，类似会议纪要」，确认「停止后自动生成纪要」。

- **托管会话（会议）不写文档**（2026-11，#107 PR3，`docs/meeting/ENGINE.md` §4.5）：会议经引擎开的会话，引擎只报「开起来 / 一句 / 结束」，
  会议的 meeting.md 由会议自己建、自己写、自己收尾；引擎只管字幕条上的「记录」按钮（跟着会议的暂停走）和「打开本次记录」（记下第一句后指向会话配置里的 `documentURL`）。
  下面说的都是自由听译自己的记录。App 退出时还在整理的纪要（会议的、自由听译的）由会议统一标「没整理完」。
- **自由听译的记录由会议库写**（2026-11，#107 PR4，`docs/meeting/ENGINE.md` §4.5.3）：记不记、什么时候记（开关、字幕条按钮、中途打开时补记已有的句子）
  仍由引擎决定；开记录时经 `FreeListeningLibrary`（Core 协议，会议库 `MeetingStore` 实现）开一份 `FreeListeningRecord`，写成什么样、写到哪、整不整理纪要
  由会议库定。写文档的类 `MeetingTranscript` 与纪要生成器 `MeetingMinutesGenerator` 都在会议模块（`Modules/Meeting/`）。「停止后整理纪要」开关在开记录、
  收尾时由引擎现读、作为参数交过去。写回 `~/Documents/Baobox 实时翻译记录/` 的旧去处已删：会议库没装上就不记录（记一条 fault，现在的启动流程里总是装上的）。

- **开关**：「保存记录」**默认关**（2026-11-05 用户要求），字幕条上的「记录」按钮一点就切（用户：菜单里操作不方便），
  设置页「记录与纪要」里也能开关，记住选择；
  正在实时翻译时**立刻生效**——开：从现在起记，字幕条上已有的几句也补进去；关：这一份就此收尾（写结束时间、整理纪要）。
- **记录**（会议模块的 `MeetingTranscript`）：开着时每次开始新建一份 Markdown，进会议库的「yyyy-MM-dd HH-mm 自由听译/meeting.md」
  （会议模块之前放 `~/Documents/Baobox 实时翻译记录/yyyy-MM-dd HH-mm-ss.md`，这些旧记录首次启动时按引用迁进会议库）。
  开头：开始 / 结束时间与时长、音源、说 / 译成；然后「## 纪要」；然后「## 记录」逐句
  `**时间** 原文` + `> 译文`（不翻的句子只有原文）。
- 什么时候记：句子**定稿**时（含被下一句顶成定稿的）；之后译文 / AI 纠正回来再更新。停止时最后那句没定稿也记上。
  内存里留整份，有变化至多 1 秒后整份重写（串行队列、原子写），中途崩溃最多丢最后 1 秒；一句都没有就不建文件。
  建目录、写文件都在后台串行队列（以前写进「文稿」时第一次会弹授权框）；写失败字幕条提示一次。
- **改设置引起的重启**（`restartIfRunning`：改音源、语言、朗读输出…）接着写同一份，记一行「改为：…」；句子 id 会从头编，
  记录里按「第几次运行 + id」区分。用户停止、出错停止才收尾。App 退出时同步写完，纪要标「没整理完」。
- **纪要**（会议模块的 `MeetingMinutesGenerator`）：停止后用 AI 纠错的 Qwen3-1.7B 在后台整理（上下文为此从 2048 调到 4096；
  2026-11 起（#86）按「设置 → AI」里「会议纪要」选的模型，Qwen3-1.7B 是默认），输出
  「### 要点 / ### 结论 / ### 待办」三节，替换「## 纪要」下的占位文字；语言跟随界面语言。记录按估算 token（中日韩一字约一个，
  其余约 3.5 字符一个）凑段，每段 ≤ 2200：一段就直接整理；多段就先逐段提要点（每段最多 10 条），再合并整理。
  没下载模型 / 内容太少（< 40 字）/ 整理失败都在这一节写明原因。整理好发系统通知（开始记录时就先申请通知权限）。
- 入口：字幕条「记录」按钮旁的小按钮（打开本次记录；还没有就打开记录文件夹）、菜单栏「打开最近一次记录」、设置页「记录与纪要」
  （开关、保存位置、打开文件夹、纪要开关）。

## 7. 设置（UserDefaults 键）

| 键 | 取值 | 默认 | 改动生效 |
|---|---|---|---|
| `livetranslate.source` | `mic` / `system` | `system` | 运行中自动重启 |
| `livetranslate.language` | `auto` 或识别 locale（`en-US` / `zh-CN` / `ja-JP`…） | `en-US` | 运行中自动重启 |
| `livetranslate.autoA` / `autoB` | 自动模式的两种语言（语言代码） | `zh-Hans` / `en` | 运行中自动重启 |
| `livetranslate.target` | 译成（语言代码）；某句本身就是它时不翻、只显示原文 | 说中文 → `en`，否则 `zh-Hans` | 运行中自动重启 |
| `livetranslate.translate` | Bool | `true` | 运行中自动重启 |
| `livetranslate.display` | `both` / `translation` / `original` | `both` | 即时 |
| `livetranslate.fontSize` | 16–40 | 24 | 即时 |
| `livetranslate.opacity` | 0.3–1.0 | 0.75 | 即时 |
| `livetranslate.onDevice` | Bool | `true` | 运行中自动重启 |
| `livetranslate.vocabulary` | 专有名词表，一行一项 `原文` 或 `原文 = 译名` | 空 | 识别下一句起；翻译下一句起（新引擎下次开始） |
| `livetranslate.barOrigin` | `NSStringFromPoint`（旧版；只在没有 `barFrame` 时用一次） | — | — |
| `livetranslate.barFrame` | `NSStringFromRect` | — | 移动 / 改大小时写 |
| `livetranslate.record.enabled` | Bool：保存记录 | `false` | 立刻（运行中开 = 从现在起记，关 = 收尾这一份） |
| `livetranslate.record.folder` | 保存位置路径；空 = 默认 | 空 | 下次开始 |
| `livetranslate.record.summary` | Bool：停止后整理纪要 | `true` | 下次停止 |

`livetranslate.language`、`livetranslate.autoA` / `autoB`、`livetranslate.vocabulary`（说话语言与专有名词表）会议、听写也在用，
键与读写定义在 `mac/Sources/Core/Translation/SpeechSettings.swift`（`SpeechSettings`；#107 从 `LiveTranslateSettings` 搬过去，键名不变）。
其余键仍在 `LiveTranslateSettings`（`LiveTranslateController.swift`）。

## 8. 文件

| 文件 | 内容 |
|---|---|
| `LiveTranslateTool.swift` | `ToolModule` 壳：菜单、快捷键、设置 Tab |
| `LiveTranslateController.swift` | 设置键、状态机、权限、引擎选择与回退、字幕行 |
| `LiveTranslateRecognition.swift` | 识别引擎协议 + SpeechAnalyzer 引擎 + SFSpeechRecognizer 分段引擎 |
| `LiveTranslateGlossaryEditor.swift` | 设置页专有名词表（原文 → 译名，回车跳格 / 新起一行） |
| `LiveTranslateAudio.swift` | `AudioRouter`（sink）、PCM 格式转换、麦克风源、系统声音源（SCK） |
| `LiveTranslateTranslator.swift` | 翻译节流队列（按方向分）+ `translationTask` 桥接 + 离线模型服务循环 |
| `LiveTranslateDualRecognizer.swift` | 双识别器：两种语言同时听、共用切段、逐句打分定语种 |
| `LiveTranslateBar.swift` | 字幕条 `NSPanel`（可拉伸、记位置大小）与 SwiftUI 视图（快捷菜单、延迟监控、可滚动历史） |
| `LiveTranslateRecordSettings.swift` | 「保存记录」「停止后整理纪要」开关与保存位置（`LiveTranslateRecordSettings`）。记录本身由会议库写：`Modules/Meeting/MeetingTranscript.swift`（Markdown，增量整份重写）、`MeetingMinutesGenerator.swift`（停止后整理纪要，分段提要点再合并），#107 PR4 从这里搬过去 |
| `LiveTranslateSettingsView.swift` | 设置页 |
