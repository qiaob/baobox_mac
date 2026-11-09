# 翻译引擎（离线模型 + 自动识别语言）设计

> 共享层，目录 `mac/Sources/Core/Translation/`，本地化命名空间 `translation.*`。
> 使用方：划词翻译（`SelectionTranslate`）、实时翻译（`LiveTranslate`）。仅 macOS。

## 1. 需求

| # | 需求 | 说明 |
|---|---|---|
| R1 | 低版本也能翻译 | 系统 Translation 框架要 macOS 15；macOS 14 上要有可用的翻译 |
| R2 | 别人装上也能用 | 不依赖用户自己装 Ollama 之类的东西；模型**单独下载**，不进安装包 |
| R3 | 自动识别输入语言 | 文字：本地检测；语音：在两种语言之间逐句自动判别 |
| R4 | 翻译成指定语言 | 目标语言可选；原文已是目标语言时自动换成备选语言 |

## 2. 引擎

| 引擎 | 系统 | 数据 | 说明 |
|---|---|---|---|
| 系统翻译（`TranslationSession`） | 15+ | 本地 | 会话只能从视图的 `.translationTask` 拿，继续挂在浮层 / 字幕条上 |
| 离线模型（Hy-MT2-1.8B） | 14+ | 本地 | 内置的 `llama-server` 子进程 + 单独下载的模型文件 |
| 云端模型（「设置 → AI」接入的服务商和模型） | 14+ | **离开本机** | 经 `AIService`（`docs/ai-service/DESIGN.md`），只能手动选 |

每个翻译功能一个设置（2026-11-09 起，issue #86）：划词翻译 `ai.feature.selectiontranslate.translate`，字幕翻译
`ai.feature.livetranslate.translate`（会议的翻译也用它）。取值 `auto`（默认）/ `system` / `local`（离线模型）/
`model:<云端模型 id>`。新键没值时读旧的共用键 `translation.engine`（`offline` 当 `local`；保留不删、不再写），升级后行为不变。
在「设置 → AI」的功能表或模块设置页里选，是同一份设置。离线模型与云端的调用都从 `AIService` 进，系统翻译仍挂在视图上。

- `model:<id>`：这个云端模型配置完整就用它，出错时自动退回离线模型（有的话）；配置不完整或已删除按 `local` 处理。「自动」不会切到云端。

- `auto`：macOS 15+ 用系统翻译；系统不支持这对语言（`LanguageAvailability` 判为 unsupported）或翻译失败时，
  若离线模型已就绪则改用离线模型。macOS 14 直接用离线模型。
- 都不可用（macOS 14 且没下载模型）→ 界面给「下载离线翻译模型」入口，不报错。

### 2.1 离线模型

- 模型：腾讯混元翻译 **Hy-MT2-1.8B**（2026-05，33 种语言），`Hy-MT2-1.8B-Q4_K_M.gguf`，
  1,133,080,448 字节，SHA-256 `dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699`。
- 下载源：Hugging Face（`tencent/Hy-MT2-1.8B-GGUF`）→ 失败换 ModelScope（`Tencent-Hunyuan/Hy-MT2-1.8B-GGUF`）。
  `URLSessionDownloadTask`，失败 / 暂停时把 resumeData 落盘，下次接着下；下完先校验大小 + SHA-256 再改名生效。
- 存放：`~/Library/Application Support/Baobox/Translation/models/`。
- 提示词按模型卡的官方模板（涉及中文用中文模板，否则用英文模板），采样参数 temperature 0.7 / top_p 0.6 /
  top_k 20 / repeat_penalty 1.05。长文按段落切块（每块 ≤ 1200 字符）顺序翻译再拼回。

### 2.2 推理进程（llama.cpp）

- 用 llama.cpp 官方 macOS 预编译包（构建号固定在 `mac/Makefile` 的 `LLAMA_BUILD`，下载后校验 SHA-256），
  只取 `llama-server` 和它依赖的 10 个 dylib，构建时由 `project.yml` 的脚本阶段拷进
  `Baobox.app/Contents/Helpers/llama/` 并用 App 同一身份签名（不开 Hardened Runtime，免得 ad-hoc 构建下
  库校验失败）。文件不进 git（`mac/Vendor/` 已忽略）。
- **这是「零第三方依赖」的第二个例外**（第一个是 NetCapture 调系统 openssl）。选子进程而不是把
  llama.cpp 链进 App：Swift 代码里不混 C++；模型崩溃不带崩 Baobox；退出进程即可完整归还内存；
  升级只换一个包。
- 生命周期：第一次翻译时启动（`--host 127.0.0.1`、随机空闲端口、随机 `--api-key`、`--jinja`、
  `-ngl 99 -c 4096 -np 1`），轮询 `/health` 直到就绪；空闲 10 分钟退出；实时翻译运行期间保持常驻；
  App 退出时结束。PID 写在支持目录，下次启动先清掉残留进程（核对进程名，绝不误杀）。日志写
  `Translation/llama-server.log`，启动失败时把日志尾部带进错误提示。
- 接口：OpenAI 兼容 `POST /v1/chat/completions`（非流式）。

### 2.4 第二个本地模型：识别纠错（2026-11-05）

`OfflineModel` 从单一模型改成「每个模型一份说明」（文件名、大小、SHA-256、镜像、上下文长度），`OfflineTranslator` 每个模型
一个实例、一个推理进程：`shared` = 翻译（Hy-MT2），`corrector` = 纠错（Qwen3-1.7B，用法见 `docs/live-translate/DESIGN.md`
§3.4）。各自的 PID / 日志文件分开（翻译模型沿用 `llama-server.pid` / `.log`，纠错模型 `llama-server-corrector.*`），
采样参数按请求给（翻译用模型卡推荐值，纠错低温度、关思考）。设置页的模型下载行 `OfflineModelRow` 传实例和文案复用。

### 2.3 专有名词表（实时翻译，2026-11-05）

起因：实测「Wigmore」被随意音译成「威格莫尔」—— 原先填的专有名词只用于识别，翻译用不上。

- 格式（`livetranslate.vocabulary`，纯文本）：一行一项，`原文` 或 `原文 = 译名`（全角＝也认）；早期用逗号 / 顿号
  分隔的照读。最多 100 项生效。解析、序列化、匹配都在 `TranslationGlossary`。
- 识别：原文和译名都作为提示词（两种语言都可能被说出来），识别器每段现读，改完从下一句起生效。
- 离线翻译：每块原文里出现了的词条按模型卡的官方「术语」模板给参考译法 ——
  中文模板 `参考下面的翻译：\nX 翻译成 Y\n将以下文本翻译为…`，英文模板 `Reference the following translations:\n
  X translates to Y\n\nTranslate the following text into … Note that you must ONLY output the translated result
  without any additional explanation:`。没写译名的，拉丁字母的词（产品名、英文人名）或本身就像目标语言文字的词给「X 翻译成 X」= 保持原样，其余（如只为提高识别率填的中文词、要译成英文）交给模型照常翻；原文里出现的是译名（反方向翻译）就译回原文；
  指定的译法得像目标语言的文字（`scriptRatio ≥ 0.5`）才给，否则交给模型自己翻。每块最多 20 条。
  纯字母数字的词按整词匹配（免得「AI」命中「said」），中文等按子串匹配，都不分大小写。
- 系统翻译（macOS 15+）没有术语接口：只用于识别。

## 3. 自动识别语言

### 3.1 文字（划词翻译）

`NLLanguageRecognizer`（本地）：约束在支持的语言内；`languageHints` 偏向「目标语言 + 备选语言」
（短词最容易误判）；认不出时按文字系统兜底（假名→日文、谚文→韩文、汉字→中文、泰文、阿拉伯文、
天城文、西里尔文，其余→英文）。

目标：设置「译成」（默认取系统首选语言）+「原文已是该语言时译成」（默认 English，若「译成」本身是英文则默认中文）。
中文简繁算同一种语言。浮层方向行的目标语言可点开当场切换、重新翻译。

### 3.2 语音（实时翻译）：双识别器

`SFSpeechRecognizer` / `SpeechTranscriber` 都必须先指定语言，没有语种识别。曲线救国：

- 「说话语言」新增 **自动（A / B）**：两个 `SFSpeechRecognizer`（A、B 两种语言）同时听同一路音频，
  **共用同一套切段**（任一边文字在变就不切；两边都停 1.2s 或满 45s 切段）。
- 每段结束后等两边的 final（最多 2s），按 `平均置信度 × (0.5 + 0.5 × 文字系统吻合度)` 打分，取高分那边的文字
  作为这一句的定稿，并把这一句标成该语言。
- 进行中的 partial 显示「上一句胜出的那种语言」的结果，定稿时若换了语言，这一句的文字整体替换一次。
- 某一边连续 3 段刚开就报错且没文字 → 只剩另一边继续；两边都不行 → 按不可恢复处理。
- 代价：识别的 CPU 约翻倍；只能两种语言。要更多语言再考虑 Whisper 语种识别。

### 3.3 自愈（2026-11-05 实测问题）

实测「自动」模式跑了约 45 秒后，进程内的本地识别客户端开始刷 `kAFAssistantErrorDomain 1101`
（35 秒 60 多万条，系统把 Baobox 的日志都限流了），之后**不再出字也不回调**，字幕停住。翻译侧一直正常。
系统识别服务坏掉时不一定会回调，所以不能只靠错误回调恢复：

- 某一路任务出错 / 收尾 → 立刻不再给它喂音频；当前段的 partial 只显示还在工作的那一路
  （否则出错那一路留下的旧文字会一直挂着，看起来「卡住」）。
- **看门狗**：音频路由按 RMS 记「最近一次有人说话」的时间；**累计有人声** 6 秒却没有任何识别结果 → 判定卡死，
  收掉所有段、重建 `SFSpeechRecognizer` 对象、重新开段；连续卡死按 2 倍退避（封顶 60 秒），出字即清零。
  单语言识别器同样加了这个看门狗。
  - 计时只数有人声的时间（`LiveTranslateStallClock`：每 0.25 秒一拍，最近 0.5 秒内有人声才记这一拍；出字、开新段清零）。
    以前按「距上次出字多久」算，停顿超过 6 秒（想事情、等朗读读完——朗读暂停识别时路由不更新人声时间）后一开口，
    第一拍就被判成卡死、重启识别器，刚说的头几个字跟着被扔掉（2026-11-05 用户「选中文偶尔识别不到」，日志里每次长停顿后
    都有一次 streak 1 重启）。
- 麦克风：监听 `AVAudioEngineConfigurationChange`（换设备 / 耳机切模式），自动重新挂 tap 重启引擎。
- 诊断日志：`subsystem == "com.baobox.app"`，category `livetranslate.recognition` / `livetranslate.audio` /
  `livetranslate.transcript`。单语言识别器每段结束记一行「segment N done (pause / max length / error … / watchdog restart):
  K results, first text X.Xs, Ns」；朗读暂停识别时记「read-aloud paused recognition for X.Xs」；运行中每 10 秒一行**心跳**
  「heartbeat: audio N buffers Xs (voiced, paused for read-aloud) | recognition N updates, N new lines | corrected, translated,
  waiting (oldest) | read-aloud backlog」——「卡住了」时按它判断是哪一环停了：音频秒数为 0 = 采集断了；有人声却没有识别更新 =
  识别卡了；waiting 只增不减 = 翻译卡了；backlog 越来越多 = 朗读卡了。查看：
  `/usr/bin/log show --last 30m --style compact --predicate 'subsystem == "com.baobox.app" AND category BEGINSWITH "livetranslate"'`
  （zsh 里 `log` 是内建命令，要写全路径）。
- **只让一路走本机识别**（2026-11-05 实测）：系统的本机识别同一时间只能跑一种语言。装好英文本机模型后两路都在本机，
  英文模型一加载，中文那一路每段一开就被 `1110` 结束，连续三段后被停用（字幕条提示「简体中文识别不可用」）。
  而且**只要装了本机模型，不要求本机也会走本机**：把英文那路改成 `requiresOnDeviceRecognition = false` 后照样被挤
  （每段开头连本机识别服务的连接从 3 个变成 5 个，日志 `speechRecordingDidFail 1101` → 中文那路 `1110`）。
  实测（2026-11-05）：en-US 的各种写法（en_US、en-Latn-US、带 @rg= 等）都归一成 en-US、照样走本机；把
  `supportsOnDeviceRecognition` 设成 false 会被系统改回 true —— **装了本机模型的语言没法强制走服务器**。中途试过让另一路换成
  没有本机模型的口音（en-CA、en-GB、台湾普通话 zh-TW + 繁转简）走服务器，但**系统会在后台把用过的口音的本机模型陆续装上**
  （en-CA、zh-TW 用过一阵都变成了「有本机模型」），迟早又撞，换口音这条路已删掉。
- **现在的规则（用户决定，2026-11-05）**：
  - 固定一种语言：本机（中文大陆普通话、英文美式）。
  - 「自动」：中文本机 + 美式英文走云端，两路同时听（`LiveTranslateDualRecognizer`，只接受「最多一路有本机模型」）。前提是
    用户在 系统设置 › 键盘 › 听写 里移除英文、删掉英文本机模型（代价：固定 English 也走云端）。
    **实测这条路走不通（2026-11-05）**：用户在听写设置里删不掉英文（`Offline Dictation Status` 里 en-US 仍是 `Installed = 1`）；
    而且即使删掉，系统也会把一直在用的语言的本机模型自动装回来（用 en-CA、zh-TW 走云端时都被装上过）。这台 Mac 上两种都有
    本机模型是常态，轮流识别是「自动」的主路径；设置页说明改成「只说一种语言时直接选那种最快」，不再引导去删听写，
    「打开键盘 › 听写设置」的入口只在某种语言没有本机模型时出现。
    **实测这条路走不通（2026-11-05）**：用户在听写设置里删不掉英文（`Offline Dictation Status` 里 en-US 仍是 `Installed = 1`）；
    而且即使删掉，系统也会把一直在用的语言的本机模型自动装回来（用 en-CA、zh-TW 走云端时都被装上过）。这台 Mac 上两种都有
    本机模型是常态，轮流识别是「自动」的主路径；设置页说明改成「只说一种语言时直接选那种最快」，不再引导去删听写。
  - 两种都装了本机模型（还没删，或被系统自动装回来）：改用轮流识别（`LiveTranslateSwitchingRecognizer`）—— 一次只开当前语言的
    识别器，这一句的录音同时存一份（闸门直通时顺便录）；一句说完像不像当前语言（文字系统吻合度 < 0.3，或有置信度却 < 0.5）、
    或有声音却一直没字，就把录音交给另一种语言的识别器重认（最多 3 秒），打分高的定稿并切过去。字幕条提示「改为轮流识别」，
    设置页说明怎么切回「中文本机 + 英文云端」。
    - **字数密度（2026-11-05）**：用户说中文，切到英文后字幕只剩零星的 "You"、"I"、"Cinema"，再也切不回中文（看起来像卡死）——
      英文识别器听中文常常只吐一两个短词，置信度还挺高，「像不像英文」也像。现在按这一句录音里有人声的秒数算字数密度
      （中文按字、其余按词；以「中文每秒 1.5 字、英文每秒 1 词」为 1）：有人声 ≥ 1.5 秒而密度 < 0.6 也算「不像」→ 重认；
      重认打分再乘密度（封顶 1、保底 0.1），另一种要高出 10% 才切，差不多就留在当前语言，免得来回跳。
    - **说到一半就判（2026-11-05 用户：中英切换一次后第一句识别很慢）**：以前要等这句说完、停顿 1.2 秒、再重认才知道换了语言。
      现在这一段有人声满 2.5 秒时先看一眼 partial：文字系统对不上（≥ 3 个字符、吻合度 < 0.3）或字数密度 < 0.4，就提前切段重认
      （一段只提前一次；比说完再判更严，免得把说对了的话切断）。重认期间音频由闸门攒着，不丢字。
    - 每句一行日志「auto seg N [语言]: K units, voiced X s, density D, conf C (early / stall) -> keep / recheck」，重认一行（含耗时）
      「auto recheck seg N: zh 0.62 vs en 0.37 … -> keep / switch」（只记数字，不记内容）。
  卡死重建识别器时按这一路现用的 locale 重建。「优先本地识别」关掉也挡不住走本机，所以设置页与字幕条的状态都按「有没有本机模型」判断。
- 判语种（2026-11-05 实测英文视频）：中文识别器听到英文会直接吐英文单词（中英混说模型），原先文字系统对不上时还留 0.5 的分，
  乱码英文常常赢过英文那路，于是「原文」是乱的、译文还被译成了英文。现在：打分改为 `置信度 ×（0.15 + 0.85 × 吻合度）`；
  定稿 / partial 报语种时，文字完全不像这一路的语言（吻合度 < 0.3）而像另一路（> 0.6）就改判成另一路；partial 优先显示
  文字系统对得上的那一路。
- 字幕条顶上一行状态：「识别：简体中文 本机 · English 服务器　翻译：离线模型」，某一路被停用时显示「已停用」。
  轮流识别时没在听的那种显示「待命」。设置页「优先本地识别」下面显示「当前识别方式」：每种语言本机 / 服务器 / 轮流（两种都有
  本机模型），并给「打开键盘 › 听写设置」的入口，从系统设置回来窗口重新激活时自动刷新。

翻译方向：「译成」= T。一句的语言 L 与 T 同一种 → **不翻，只显示原文**（字幕条把原文当主字幕显示，也不朗读）；否则译成 T。
（2026-11-05 用户：「译成 English」时说英文就不该出中文。以前是「与 T 同一种 → 译成 A/B 里的另一种」，即隐式互译。）
默认 A = 中文、B = English、T = 中文：说英文出中文，说中文只显示原文。系统引擎下只给要翻的方向挂翻译会话；固定语言且与 T 相同时整场不翻，字幕条提示「说的就是 T：只显示原文」。

## 4. 设置键

| 键 | 取值 | 默认 |
|---|---|---|
| `ai.feature.selectiontranslate.translate` | `auto` / `system` / `local` / `model:<id>` | 旧键 `translation.engine` 的值，没有则 `auto` |
| `ai.feature.livetranslate.translate` | 同上 | 同上 |
| `ai.feature.livetranslate.correct` | `local` / `model:<id>` | `local` |
| `translation.engine` | 旧的共用键：只在新键没值时读一次，不再写 | — |
| `selectiontranslate.target` | 语言代码（如 `zh-Hans`） | 系统首选语言 |
| `selectiontranslate.secondaryTarget` | 语言代码 | `en`（目标是英文时为 `zh-Hans`） |
| `livetranslate.language` | `auto` 或识别 locale（`en-US`、`zh-CN`…；旧值兼容） | `en-US` |
| `livetranslate.autoA` / `livetranslate.autoB` | 语言代码 | `zh-Hans` / `en` |
| `livetranslate.target` | 语言代码 | 说的是中文 → `en`，否则 `zh-Hans` |

## 5. 文件

```
mac/Sources/Core/Translation/
  TranslationLanguage.swift     语言表、文字系统、语言检测
  TranslationSettings.swift     引擎解析（按翻译功能：resolve(AIFeature)）
  OfflineTranslator.swift       离线模型：下载 / 校验 / 推理进程 / 请求
  TranslationEngineSection.swift 设置页共用区块（这个功能的模型选择行 + 说明 + 模型状态 / 下载）
mac/Sources/Core/AI/             AI 服务层：服务商与模型、功能选择、本地 / 云端路由、云端客户端、钥匙串（docs/ai-service/DESIGN.md）
mac/Sources/Modules/LiveTranslate/LiveTranslateDualRecognizer.swift  双识别器
mac/Vendor/llama/                构建时下载（gitignore）
```
