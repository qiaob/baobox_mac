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
- **两种模式**：整句（`Mode.utterance`，只给按住说话）满 50 s 才换段，结束时一次交出整段；分段（`Mode.segmented`，长听写与连续听写共用）每次停顿 ≥ 1.2 s 或满 50 s 就收一段（endAudio → final → 新请求），每段定稿经 `onSegment` 交出。音频门在换段期间缓冲（同实时翻译 `LiveTranslateAudioGate` 的思路），一个字也不丢。
- **停顿 = 1.2 s 没有新字、也没有人声**。「人声」= 这块缓冲区的 RMS 高过门槛（`DictationVoiceFloor`）：固定 -40 dBFS（0.01），
  环境底噪更高时取底噪的 2.5 倍（约 8 dB）。底噪 = 最近约 2 秒里最安静的那块缓冲区（每 0.5 s 一格取最小、留 4 格）。
  2026-11-10 起：以前只有固定门槛，环境稍吵（空调、风扇、键盘、外放）底噪就一直过线，连续听写等不到停顿，一整段说完按键结束才一起上屏。
  兜底：字 3 s 没变也收一段（底噪起伏大、人声判断一直为真时）。每次收段记一条日志（原因、两种「安静」各多久、底噪），不含文字。
- **安静自动结束**（连续听写）：没有人声、也没有新字持续 N 秒（默认 30，可设 关 / 10 / 30 / 60）且已识别出内容。旧版本存的 2 / 3 / 5 秒不在新选项里，模块启用时清掉、回到默认。
- **自动判别中英**：录音期间保留 PCM（只留本段，最长 2 分钟）；一段定稿后若平均置信度 < 0.45（或有人声却没认出字），用另一种语言把录音再认一遍（`SFSpeechAudioBufferRecognitionRequest` 喂缓存），按实时翻译的打分取高的那份，并换成它接着听。分段模式下就是逐句判。
- **识别语言默认「自动」**（2026-11-08 起）：主语言随系统（英文系统先英文，否则先中文）。
- 权限：语音识别、麦克风首次使用时申请；被拒 → 宠物提示并打开系统设置对应页。

## 3.1 连续听写（点按切换：一句定稿就上屏）

2026-11-08 用户定（需求 §1）。识别器用分段模式，控制器每次听写建一个 `DictationStream`（这次听写的状态，取消后新开的听写不会和它串）。

- **每段**（`onSegment`）：`prepare`（语音指令 → 口头禅 → 标点；整段只有口头禅的丢掉 —— 多半是停下来想的时候「嗯」了一声，`keepLoneFiller: false`）→ 按需润色（含「删除上一句」的段不润色）→ 排进这次听写的 `pipeline`（Task 链，保证按顺序）→ `place`。
- **算编辑**：`DictationTextProcessor.streamEdit(piece, after: typed)` = `render(piece, into: typed)` 与 `typed` 求公共前缀（按 Character），先退格删掉 `typed` 多出的那截、再输入新串剩下的部分。接缝的英文空格、「删除上一句」都由 `render` 决定，这里只做差分。
  `typed` 只记这次听写在**当前前台 App** 里输入成功的字：前台 App（pid）变了就清空 —— 接缝、删除都不跨 App，绝不删到不是这次听写打的字。
- **退格** `TextInserter.deleteBackward(n)`：等修饰键松开（≤ 0.5 s）→ 合成 n 次 Delete（0x33）→ 再等 0.12 s。合成按键走事件队列，AX 写入是同步 IPC：不等的话后面的 AX 写入可能先于退格生效。密码框（安全输入）、没有辅助功能权限时不发。
- **插入** `TextInserter.insert(..., copyOnFailure: false)`：插不进去只返回原因、不动剪贴板；这句攒进 `unplaced`，结束时一次复制（不每句覆盖剪贴板、不刷剪贴板历史）。插入成功后按 `TextInserter.caretRect` 把录音条挪到新的光标旁。
- **收尾**（再按一次 / 菜单 / 安静自动结束）：识别器冲刷最后一段（它的 `onSegment` 先于结束回调）→ 让出麦克风 → 等 `pipeline` 走完 → 有 `unplaced` 就复制并显示「已复制」，否则「已插入」→ 历史记全文一条（`transcript`，同样经 `render`，「删除上一句」也作用在它上面）。
- **Esc / ✕**：识别器取消（还没定稿的那句、正在重认语种的那句都丢掉）；已经定稿、还在排队的句子照常上完（界面先收起，插不进去的不复制，历史里有），然后记历史。
- **识别失败**：已上屏的不动，等 `pipeline` 走完照常收尾，再提示失败。
- **状态栏菜单开着时不上屏**：用户多半正要点「结束听写」，菜单 tracking 时合成的 ⌘V / 退格会被菜单吃掉，那句就丢了。
  `StatusItemController.isMenuOpen`（`menuWillOpen` / `menuDidClose` 维护）为真时 `place` 先等（最多 30 s），菜单关了再输入。
- **历史只记一次**：收尾、Esc 之后排队句子上完、退出 App 三条路都走 `recordStream`（`recorded` 标记）。
- **录音条**：第二行占位改为「说完一句停一下就上屏」（每上屏一句预览清空，提示就又出来）；提示行同点按切换（再按一次结束 / 安静 N 秒结束 · Esc 取消）。

## 4. 文本后处理 `DictationTextProcessor`（纯函数，可单测）

按需求 §4 的顺序：语音指令 → 口头禅过滤 → 标点规整 →（可选）AI 润色。前三步纯字符串处理；语言按识别语言判。AI 润色：`OfflineTranslator.corrector.respond(...)`（Qwen3 本地），提示词「把口语整理成书面语，不增删信息」；开了润色且目标 App 命中时，**开始听写就预热**模型（`beginKeepAlive`），结束时最多等 8 秒。

## 5. 插入 `Core/TextInserter`

`insert(_ text: String) async -> InsertResult`（`.ax` / `.paste` / `.copied(reason)`）：

1. `IsSecureEventInputEnabled()` 为真 → 复制 + 提示（密码框不粘贴）。没有辅助功能权限 → 复制 + 引导授权。
2. 取前台 App 的焦点元素（`kAXFocusedUIElementAttribute`）。走 AX 的条件：角色是文本类、`kAXSelectedTextAttribute` 可写、`kAXValueAttribute` 可读、且 App 不在「只粘贴」名单（Electron：包里有 `Frameworks/Electron Framework.framework`；终端：Terminal / iTerm2 / Ghostty / Otty / Warp / kitty / Alacritty / WezTerm；浏览器内容区）。写入后读回值，**值变了才算成功**；读不回来就不走 AX（防止 AX 其实写进去了、又粘贴一遍变成两份）。
3. 粘贴：`PasteboardBorrow.paste(text)`（新增的公开入口）：快照全部剪贴板条目 → 写入文本 → 等修饰键松开 → `⌘V`（`.combinedSessionState` 源、`.cghidEventTap` 投递，同 `PasteService`）→ 0.35 s 后恢复快照。整个过程置 `PasteboardBorrow.isActive`，剪贴板历史据此跳过两次写入（现有机制）。
4. 都不行 → 普通复制（这次进剪贴板历史，是用户要的复制）+ 提示。连续听写传 `copyOnFailure: false`：只返回原因，结束时由控制器一次复制（§3.1）。
5. `deleteBackward(_:)`：连续听写的「删除上一句」用（§3.1）。

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

- 纯逻辑单测（`swiftc` 直接编译跑）：语音指令、口头禅过滤、标点规整、只粘贴名单判断、历史编解码容错、连续听写的 `streamEdit`（接缝空格、删除上一句、换行指令）。
- 构建无新增警告；本地化全部入表。
- 插入路径：脱离 App 的小程序验证「AX 写入 + 读回」在 TextEdit 类原生文本框上可行（需要辅助功能权限的部分交主会话在真机做）。
- 不在用户机器上运行 App、不弹会挡屏或拦输入的窗口；安装与真机验证由主会话做。
