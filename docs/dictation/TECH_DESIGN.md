# 语音听写 · 技术设计

需求见 `REQUIREMENTS.md`。代码在 `mac/Sources/Modules/Dictation/`，另改 `Core/HotkeyCenter.swift`（松开事件）、`Core/PasteboardBorrow.swift`（粘贴入口），新增 `Core/TextInserter.swift`。

## 0. 约定与踩过的坑

- 模块 id `dictation`，通知来源 `dictation`，本地化前缀 `dictation.*`，UserDefaults 前缀 `dictation.*`，数据目录 `~/Library/Application Support/Baobox/Dictation/`。
- 通知一律经 `NotifyCenter.shared.post`；不碰 `UNUserNotificationCenter`。
- 录音条**绝不能抢焦点**：照 `RecordingHUD`（`Modules/Screenshot/RecordingController.swift` 的 HUD）——borderless + `.nonactivatingPanel`，`canBecomeKey / canBecomeMain = false`，`.statusBar` 级，`[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`，`hidesOnDeactivate = false`，`orderFrontRegardless()`，按钮视图 `acceptsFirstMouse = true`。**不要在 `level` 之后设 `isFloatingPanel`**（会把 level 改回 `.floating`）。
- 长听写的收集面板要编辑文字，可成为 key；插入前先把焦点还给原 App（照 `PasteService` 记 `previousApp` 再激活）。
- 拿注册表用 `AppDelegate.shared?.registry`。
- 并发与容错同项目惯例（Timer 加 `.common`、`MainActor.assumeIsolated`、无 force-unwrap）；新增 key en + zh-Hans 入 `Localizable.xcstrings`。

## 1. 快捷键松开事件（HotkeyCenter）

- Carbon 处理器现在只装 `kEventHotKeyPressed`；加装 `kEventHotKeyReleased`，按事件种类分派。
- `HotkeyDefinition` 加可选 `onRelease: (@MainActor () -> Void)? = nil`（默认 nil，现有定义不受影响）；松开时只调有 `onRelease` 的。
- 「按住说话」= `action` 开始 + `onRelease` 结束。松开时修饰键可能还没抬起 → 插入前等修饰键全部松开（同 `PasteService` 的轮询，≤ 0.5 s）。

## 2. 占用与互斥

开始前 `AudioCaptureCoordinator.shared.claim(owner: "dictation", label: …, microphone: true)`；失败 → 宠物提示占用者（`current.label`）。结束 / 取消 release。

## 3. 识别器 `DictationRecognizer`

- 自己的 `SFSpeechRecognizer` + `AVAudioEngine` 麦克风 tap（不复用实时翻译的分段识别器：那套为长时连续字幕设计，`stop()` 会丢最后一句）。
- 请求：`SFSpeechAudioBufferRecognitionRequest`，`taskHint = .dictation`，`addsPunctuation = true`，`contextualStrings` = 共用术语表（`TranslationGlossary` 的识别提示），`requiresOnDeviceRecognition` = 设置且 `supportsOnDeviceRecognition`。
- **低延迟**：模块 activate 时就建好 `SFSpeechRecognizer`（不录音）；按下时先建请求再启动音频，音频一到就 append（请求在任务就绪前也能收）。目标按下到可说话 < 300 ms。
- **结束**：停音频 → `endAudio()` → 等 `isFinal`（最多 2 s，超时用最后一次 partial）。取消：`task.cancel()`。
- **停顿自动结束**（切换模式）：麦克风 RMS 低于阈值持续 N 秒且已识别出内容。
- **长听写**：每次停顿 ≥ 1.2 s 或满 50 s 就收一段（endAudio → final → 新请求），音频门在换段期间缓冲（同实时翻译 `LiveTranslateAudioGate` 的思路），段落依次追加到收集面板。
- **自动判别中英**：录音期间保留 PCM（只留本次，最长 2 分钟）；定稿后若平均置信度 < 0.45，用另一种语言把录音再认一遍（`SFSpeechAudioBufferRecognitionRequest` 喂缓存），取平均置信度高的那份。
- 权限：语音识别、麦克风首次使用时申请；被拒 → 宠物提示并打开系统设置对应页。

## 4. 文本后处理 `DictationTextProcessor`（纯函数，可单测）

按需求 §4 的顺序：语音指令 → 口头禅过滤 → 标点规整 →（可选）AI 润色。前三步纯字符串处理；语言按识别语言判。AI 润色：`OfflineTranslator.corrector.respond(...)`（Qwen3 本地），提示词「把口语整理成书面语，不增删信息」；开了润色且目标 App 命中时，**开始听写就预热**模型（`beginKeepAlive`），结束时最多等 8 秒。

## 5. 插入 `Core/TextInserter`

`insert(_ text: String) async -> InsertResult`（`.ax` / `.paste` / `.copied(reason)`）：

1. `IsSecureEventInputEnabled()` 为真 → 复制 + 提示（密码框不粘贴）。没有辅助功能权限 → 复制 + 引导授权。
2. 取前台 App 的焦点元素（`kAXFocusedUIElementAttribute`）。走 AX 的条件：角色是文本类、`kAXSelectedTextAttribute` 可写、`kAXValueAttribute` 可读、且 App 不在「只粘贴」名单（Electron：包里有 `Frameworks/Electron Framework.framework`；终端：Terminal / iTerm2 / Ghostty / Otty / Warp / kitty / Alacritty / WezTerm；浏览器内容区）。写入后读回值，**值变了才算成功**；读不回来就不走 AX（防止 AX 其实写进去了、又粘贴一遍变成两份）。
3. 粘贴：`PasteboardBorrow.paste(text)`（新增的公开入口）：快照全部剪贴板条目 → 写入文本 → 等修饰键松开 → `⌘V`（`.combinedSessionState` 源、`.cghidEventTap` 投递，同 `PasteService`）→ 0.35 s 后恢复快照。整个过程置 `PasteboardBorrow.isActive`，剪贴板历史据此跳过两次写入（现有机制）。
4. 都不行 → 普通复制（这次进剪贴板历史，是用户要的复制）+ 提示。

## 6. Esc 取消

听写中临时开一个 `CGEventTap`（keyDown，`.cgSessionEventTap`、`.defaultTap`），只吞 Esc（keyCode 53）并取消听写，其余放行；`tapDisabledByTimeout` 时重新启用；听写结束即关。没有辅助功能权限时不开（只能点 ✕）。

## 7. 界面

- `DictationBar`：见 §0；电平用 RMS 平滑；光标位置用焦点元素的 `kAXSelectedTextRangeAttribute` + `kAXBoundsForRangeParameterizedAttribute`（照 `SelectionText`，坐标翻成 AppKit），取不到放屏幕底部。
- `DictationCollectPanel`（长听写）：可编辑文本区 + [插入][复制][清空][结束]。
- `DictationHistoryWindow`：普通窗口（SwiftUI）。
- 设置 Tab `dictation`。

## 8. 历史 `DictationHistory`

`history.json`：`[{id, date, app (bundle id + 名称), text}]`，最多 N 条，后台串行写；解析容错。

## 9. 验证

- 纯逻辑单测（`swiftc` 直接编译跑）：语音指令、口头禅过滤、标点规整、只粘贴名单判断、历史编解码容错。
- 构建无新增警告；本地化全部入表。
- 插入路径：脱离 App 的小程序验证「AX 写入 + 读回」在 TextEdit 类原生文本框上可行（需要辅助功能权限的部分交主会话在真机做）。
- 不在用户机器上运行 App、不弹会挡屏或拦输入的窗口；安装与真机验证由主会话做。
