# 实时翻译 · 语音输出（朗读译文）设计

> 已按此实现（2026-11-05，用户确认「原声默认不进会议」）。模块：`mac/Sources/Modules/LiveTranslate/`，本地化命名空间
> `livetranslate.voice.*`。仅 macOS。

## 1. 需求

| # | 需求 | 说明 |
|---|---|---|
| R1 | 把实时翻译的译文读出来 | 系统 TTS 朗读 |
| R2 | 能送进会议（Google Meet 等） | 会议另一头的人当成「我的麦克风」听到 |
| R3 | 能同时从音响 / 耳机播放 | 自己也听得到；或者只给自己听 |
| R4 | 音色可选 | 中文、英文各选一个 |

## 2. 两种典型用法

| 场景 | 音源 | 谁在说 | 读出来送到哪 |
|---|---|---|---|
| 我开会说中文，让对方听英文 | 麦克风 | 我 | 会议（虚拟麦克风）；可选同时从耳机监听 |
| 听别人说英文（会议 / 视频），自己听中文 | 系统声音 | 别人 | 音响 / 耳机（**不送会议**，否则对方听到中文） |

实现上强制：只有音源是麦克风时才送会议（音源是系统声音时，即使选了会议设备也只外放）。
**不送会议时总是外放**：「同时从音响 / 耳机播放」「我的原声也送进会议」两个开关只在真的送会议时才出现（2026-11-05 实测：会议设备「不送」、外放开关又关着 → 两路都没开，朗读没声音）。

只读译文：本来就是「译成」那种语言的句子不翻，也不读。所以在会议里直接说目标语言时，对方要靠「我的原声也送进会议」才听得到。

## 3. 送进会议：虚拟麦克风

macOS 没有让 App 直接「当麦克风」的公开接口，只能借虚拟声卡：Baobox 把语音播到虚拟声卡的输出端，
会议软件把同一个设备的输入端选作麦克风。这台 Mac 已装 **BlackHole 2ch**（免费开源）。

- 设置里选「送到会议」用的设备：列出所有既能输入又能输出的虚拟设备（BlackHole、Loopback……），
  并提示「在 Google Meet 的麦克风里选同名设备」。
- **自带「Baobox 同传」虚拟麦克风**（2026-11-05 用户要求设备名是 Baobox 的，而不是 BlackHole）：macOS 不让 App 自己当麦克风，
  会议软件能选的必须是系统里的音频设备，所以只能装驱动（音频服务插件）。用 BlackHole v0.7.1（GPL-3.0）源码改名编译：
  `make vendor` 下载源码（校验 SHA-256），在 `BlackHole.c` 最前面预先定义 `kDriver_Name "BaoboxInterpreter"`、
  `kPlugIn_BundleID "com.baobox.audio.interpreter"`、`kHas_Driver_Name_Format false`、`kDevice_Name "Baobox 同传"`、
  `kManufacturer_Name "Baobox"`（这些常量都由 `#ifndef` 包着），写死的容器名「BlackHole Box」用 sed 换成「Baobox Box」，
  `xcodebuild` 编出 `BaoboxInterpreter.driver`（arm64 + x86_64）。构建时拷进 `Baobox.app/Contents/Library/Audio/` 并用 App 同一身份签名。
- 安装：设置「朗读译文」里点「安装」→ 系统管理员密码框（`osascript … with administrator privileges`）→ 拷进
  `/Library/Audio/Plug-Ins/HAL/`、`chown root:wheel`、`killall -9 coreaudiod` 重启音频服务（所有声音断 1～2 秒）→
  等设备 `BaoboxInterpreter_UID` 出现（最多 10 秒）后自动选中。装好了但设备没出现（系统不认签名等）就提示先用 BlackHole。可卸载。
- 别的虚拟声卡（BlackHole 等）照样列出来可选。
- 选了虚拟麦克风后，会议里**只听得到 Baobox 送进去的声音**。可选「我的原声也送进会议」：麦克风原声和译文语音混在一起，
  读译文时原声自动压低。

## 4. 读什么、怎么跟上

- 读每个单元的**正式译文**（开了 AI 纠错就是纠错后的），按顺序排队读。例外（2026-11-05 用户：译文都出来了，过几秒才有声音）：
  这截说完时，如果草稿译文翻的正好就是这一整截（不计标点空格），就当场读草稿，不再等纠错和正式翻译
  （见 docs/live-translate/DESIGN.md §3.2「草稿就是译文」）。
- 每次开始后的第一句，系统 TTS 要先花约 1.3 秒加载音色，之后出声只要 0.02 秒（实测）：开始时先合成一个字丢掉（`prewarm`）。
- 跟不上语速时：积压超过约 8 秒没读的，跳过最旧的，保证读的是刚说过的话。
- 语速可调（默认比正常略快）。

## 5. 音色

- 系统 TTS（`AVSpeechSynthesizer`）：按语言列出这台 Mac 已有的音色，中文、英文各选一个，标注「标准 / 增强 / 高品质」。
  这台 Mac 目前只有标准音色；更自然的「增强 / 高品质」音色在 系统设置 › 辅助功能 › 朗读内容 › 管理声音 里免费下载，
  设置页给入口，下完回来列表自动刷新。
- 以后可选：本地神经网络 TTS 模型（更像真人，要再下载一个模型），不在这一版。

## 6. 防回授（读出来的声音又被识别一遍）

- 音源是麦克风、又从音响外放：麦克风会把读出来的译文再听一遍 → 再翻译 → 再读，循环。
  外放期间暂停识别，读完 0.3 秒恢复。代价是读的那几秒说的话会丢：字幕条上的「朗读」按钮这时变成橙色「朗读中 · 暂停识别」；
  戴耳机（含 AirPods）时打开「戴着耳机：读的时候也继续听」（`livetranslate.voice.keepListening`，默认关）就不暂停。
  不自动判断耳机：蓝牙音箱和蓝牙耳机在系统里分不开，判错了就是回授死循环。
  - **回声消除试过，已撤掉（2026-11-05）**：用户要「朗读的时候也能收音」，试了系统语音处理
    （`AVAudioInputNode.setVoiceProcessingEnabled(true)`，外放挂在麦克风引擎上让系统从收音里减掉）。这台 Mac
    （M3 MacBook Pro 内置麦克风 + 扬声器）上开起来后输入变成 9 声道，CoreAudio 建聚合设备反复失败
    （`AggInpStreamsChanged wait failed`、转换器 `-50`、属性 `-10879`），实时翻译起不来，整个 Baobox 跟着不能用（截图也用不了）。
    要再试必须：放到后台线程开、带超时、失败不弹模态框，先在独立小程序里验证过再进 App。
- 音源是系统声音：系统抓音频时本来就排除 Baobox 自己发出的声音，不会回授。
- 只送会议、不外放：不会回授。

## 7. 实现要点

- `AVSpeechSynthesizer.write(_:toBufferCallback:)` 把语音渲染成 PCM；每个输出设备一个 `AVAudioEngine` + `AVAudioPlayerNode`
  （设备用 `kAudioOutputUnitProperty_CurrentDevice` 指定），同一段 PCM 同时排到各路，保证会议和音响同步。
- 原声混入：麦克风那一路的 PCM 同时送进「会议」引擎的另一个 PlayerNode，读译文时压低它的音量。
- 设置键（前缀 `livetranslate.voice.`）：`enabled`、`meetingDevice`、`speakers`、`voice.<语言>`、`rate`、`mixOriginal`。
- 文件：`LiveTranslateVoiceOutput.swift`（设置键、虚拟声卡枚举、朗读队列 + 多路输出）、`LiveTranslateVoiceSettingsView.swift`
  （设置页「朗读译文」一节 + 每种语言的音色选择 / 试听）；字幕条顶上加「朗读」开关。
- 每个单元只读一次（`Line.spokenUnits`），草稿不读；音色和语速每句现读，改了不用重开。
- 「一句读完」= 合成结束 + 排进去的块都播完。macOS 14 实测 `write` 的音频照常给（22050 Hz 单声道 float32），但结尾的
  空缓冲区不一定发：收到一块就重新计时，0.4 秒没有新块就当合成结束；第一块最多等 2 秒。
- 音色列表滤掉怪声音色（`voiceTraits.isNoveltyVoice`）；没选音色时有增强 / 高品质的用最好的，否则用系统给这种语言的默认音色。
