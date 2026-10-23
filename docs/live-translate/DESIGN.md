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

非目标（P1 再议）：两路音源同时识别、选择具体麦克风设备、字幕导出成文件、英中以外的语言。

## 2. 技术选型

全部用系统框架，**零第三方依赖、不联网调用任何自建服务**：

| 环节 | 方案 | 备注 |
|---|---|---|
| 麦克风采集 | `AVAudioEngine.inputNode` tap | 默认输入设备；需麦克风授权（entitlement 已有） |
| 系统声音采集 | ScreenCaptureKit `SCStream`，`capturesAudio = true`，只挂 `.audio` 输出 | 复用录屏那套；需**屏幕录制**授权；`excludesCurrentProcessAudio` |
| 语音识别（macOS 26+，首选） | `Speech` 框架 `SpeechAnalyzer` + `SpeechTranscriber`（`.volatileResults`） | 本地模型、为长音频设计，一路流到底不切段 → 上下文完整、**更准**；volatile 结果出字**更快**。首次用 `AssetInventory` 自动下载语言模型；音频经 `AVAudioConverter` 转成 `bestAvailableAudioFormat`。`#if compiler(>=6.2)` 包住（需 Xcode 26 编译） |
| 语音识别（macOS 14–15 / 回退） | `Speech` 框架 `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` | locale `en-US` / `zh-CN`；设置开「优先本地识别」且 `supportsOnDeviceRecognition` 时 `requiresOnDeviceRecognition = true`（不上传音频）；需**语音识别**授权 → `NSSpeechRecognitionUsageDescription` |
| 翻译 | `Translation` 框架（macOS 15+），SwiftUI `.translationTask` 拿 `TranslationSession` | 系统本地翻译；语言包首次使用时系统弹下载。**macOS 14 降级为只显示原文**，字幕条上提示一次 |

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

**专有名词**：用户在设置里填的词（逗号 / 换行分隔，最多 100 个）—— 新引擎走 `AnalysisContext.contextualStrings`，旧引擎走 `request.contextualStrings`，提高人名、产品名、术语的识别率。

### 3.1 旧引擎分段（segment）

`SFSpeechRecognizer` 单个请求有时长上限（服务端约 1 分钟），且一句话说完前文字会一直被改写。
因此按「段」识别：每段一个 request + task，段 id 单调递增，字幕条只保留**最近 2 段**（上一句淡出 + 当前句）。

切段时机（主线程 0.5s 看门狗）：

- 当前段文字 **1.2s 没变化**（停顿 = 一句话说完）；
- 当前段已持续 **45s**（防触到时长上限）；
- 系统主动给出 `isFinal` / 出错。

切段 = 对旧 request `endAudio()`（旧 task 继续把 final 结果回调给**旧 id**）+ 立刻新建下一段 request，
音频路由原子切到新 request —— 不丢音频、不打断显示。

连续 3 段都在 1 秒内出错且没有任何文字（如系统听写被关、识别服务不可用），判定为不可恢复：停止并弹窗说明，避免死循环重启。

### 3.2 翻译节流

识别 partial 每秒可达十几次。翻译器维护两个槽：

- `finals`：已定稿的段，**全部**要翻（按顺序）；
- `latest`：最新的 partial，**只保留最后一个**（新的覆盖旧的）。

`serve(session)` 循环：被唤醒（`AsyncStream<Void>`，`bufferingNewest(1)`）后先清 `finals` 再翻 `latest`，
同一时刻只有一个翻译在飞 —— 天然节流到「翻完一条再翻最新那条」。
`TranslationSession` 只在 `.translationTask` 闭包生命周期内使用，不外泄；字幕条关闭即任务取消、循环结束。

翻译失败（语言包未装、用户取消下载）只在字幕条提示一次，并引导到「系统设置 › 通用 › 语言与地区 › 翻译语言」。

## 3.3 构建

`build-macos.yml` 用 Xcode 26（macos-15）与 Xcode 16.2（macos-14）各编一次：前者编进新引擎，后者保证旧工具链也编得过。
`release.yml` 用 Xcode 26 —— 否则发出去的包里没有新引擎。本地用 Xcode 16 编也能用，只是只有旧引擎。

## 4. 字幕条

- `NSPanel`：`.borderless + .nonactivatingPanel`，`level = .statusBar`，
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`，不抢焦点（`canBecomeKey = false`）；
  `isMovableByWindowBackground` 可拖动，`didMove` 时把原点存 UserDefaults，下次显示若仍在某屏内就沿用，否则放主屏底部居中。
- 宽度 = 屏幕可见宽度 70%（上限 1200pt）；高度由字号与显示样式算出、固定，文字**底部对齐**、长句 `truncationMode(.head)`（总是看到最新的字）。
- 右上角一个小 ✕ = 停止。

## 5. 权限与降级

| 条件 | 处理 |
|---|---|
| 语音识别未授权 | 首次弹系统授权；被拒 → 弹窗引导去「隐私与安全性 › 语音识别」 |
| 麦克风音源、麦克风被拒 | 弹窗引导去「隐私与安全性 › 麦克风」 |
| 系统声音音源、无屏幕录制权限 | 触发系统登记 + 弹窗引导（授权后需重启，沿用 `Permissions` 的既有逻辑） |
| 该语言识别器不可用 | 弹窗说明（多为系统「听写」被关闭或网络不可用且无本地模型） |
| macOS 14 | 只显示原文，提示「翻译需要 macOS 15」 |

## 6. 设置（UserDefaults 键）

| 键 | 取值 | 默认 | 改动生效 |
|---|---|---|---|
| `livetranslate.source` | `mic` / `system` | `system` | 运行中自动重启 |
| `livetranslate.language` | `en-US` / `zh-CN`（说话的语言；译文自动取另一种） | `en-US` | 运行中自动重启 |
| `livetranslate.translate` | Bool | `true` | 运行中自动重启 |
| `livetranslate.display` | `both` / `translation` / `original` | `both` | 即时 |
| `livetranslate.fontSize` | 16–40 | 24 | 即时 |
| `livetranslate.opacity` | 0.3–1.0 | 0.75 | 即时 |
| `livetranslate.onDevice` | Bool | `true` | 运行中自动重启 |
| `livetranslate.vocabulary` | 专有名词原文 | 空 | 下次开始 |
| `livetranslate.barOrigin` | `NSStringFromPoint` | — | 拖动时写 |

## 7. 文件

| 文件 | 内容 |
|---|---|
| `LiveTranslateTool.swift` | `ToolModule` 壳：菜单、快捷键、设置 Tab |
| `LiveTranslateController.swift` | 设置键、状态机、权限、引擎选择与回退、字幕行 |
| `LiveTranslateRecognition.swift` | 识别引擎协议 + SpeechAnalyzer 引擎 + SFSpeechRecognizer 分段引擎 + 专有名词解析 |
| `LiveTranslateAudio.swift` | `AudioRouter`（sink）、PCM 格式转换、麦克风源、系统声音源（SCK） |
| `LiveTranslateTranslator.swift` | 翻译节流队列 + `translationTask` 桥接 |
| `LiveTranslateBar.swift` | 字幕条 `NSPanel` 与 SwiftUI 视图 |
| `LiveTranslateSettingsView.swift` | 设置页 |
