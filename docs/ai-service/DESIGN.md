# AI 服务层（迁移）设计

> issue #86。2026-11-09 用户确认按「迁移」做：现有的模型调用都收到 Core 的一个接口后面，同时加上云端服务；
> 翻译模块可以指定用云端服务还是本地模型。#85（划词助手 AI 动作）和 #55（宠物 AI 对话）都建在这一层上。

## 1. 需求回顾

- 用到模型的地方（6 处）都从 `AIService` 进，按「本地 / 云端」路由；**默认行为不变**。
- 云端两家：Anthropic Claude（Messages API）、OpenAI 兼容（Chat Completions，自填 Base URL，本机 Ollama 也走这条）。
- Key 存钥匙串；单次回复长度上限、每分钟次数上限；「测试连接」。
- 翻译引擎从两个模块共用一个键，改成每个模块各一个；多一个「云端服务」选项，只能手动选。
- 云端出错（断网、超时、401、429）自动退回本地（有的话），标一句「云端不可用，已改用本地」；字幕不能因为断网就停。
- 设置新增「AI」页：云端配置 + 本地模型一览。各模块页只放自己的引擎选择；没配云端时该项置灰、给「去配置」。

## 2. 分层

```
调用方（划词、字幕与同传、纠错、纪要、周报、润色）
        │  translate(...) / generate(...) / correctAndTranslate(...)
        ▼
AIService（mac/Sources/Core/AI/AIService.swift，@MainActor 单例）
  ├─ route == .local → OfflineTranslator.shared（Hy-MT2，翻译）/ .corrector（Qwen3-1.7B，通用生成）
  │                     进程、下载、keep-alive 仍由 OfflineTranslator 负责，不重写
  └─ route == .cloud → AICloudClient（URLSession async）→ Claude / OpenAI 兼容
                        失败 → 本地（有的话），Reply.usedFallback = true

系统翻译（TranslationSession）不进服务层：框架只认挂在视图上的 `.translationTask`，
会话继续挂在划词浮层和字幕条上；`TranslationSettings.resolve(scope)` 只负责判断这次该用哪个引擎。
```

| 文件 | 内容 |
|---|---|
| `Core/AI/AIService.swift` | 路由、云端公共流程（配置 → 本机限额 → 冷却 → 请求 → 退回）、`AIPrompts`（云端提示词） |
| `Core/AI/AICloudClient.swift` | 两家的 HTTP 请求与错误归类（`AICloudError`） |
| `Core/AI/AICloudSettings.swift` | 服务商、地址、模型、上限的设置键；`AIKeychain` |
| `Settings/AISettingsView.swift` | 设置页「AI」 |
| `Core/Translation/TranslationSettings.swift` | `TranslationScope`（每模块一个引擎键）、`resolve(scope)` |
| `Core/Translation/TranslationEngineSection.swift` | 模块设置页的引擎选择区块（带 scope） |

## 3. 接口

```swift
AIService.shared.translate(text, to:, from:, glossary:, route:, timeout:) async throws -> Reply
AIService.shared.generate(prompt, maxTokens:, sampling:, route:, timeout:) async throws -> Reply
AIService.shared.correctAndTranslate(text, context:, to:, glossary:, timeout:) async throws -> (corrected, translation)
struct Reply { text; route; usedFallback }
```

- `sampling`（温度等）只对本地生效：Claude 新版 API（`anthropic-version: 2026-10-21`）一律不收采样参数，发了会 400。
- 云端的 `maxTokens` = `min(用户上限, max(256, 调用方要的))`：调用方给本地的量很紧（纠错只给字数 ×2），
  云端模型可能先想再答，给点余量，但永远不超过用户在「AI」页设的上限。
- 本地的辅助接口：`isLocalReady(.translation / .generation)`、`isLocalStarting`、`begin/endLocalKeepAlive`、
  `isReady(route, model:)`（云端 = 配置完整）。

### 3.1 Claude

`POST {base}/v1/messages`，头 `x-api-key`、`anthropic-version: 2026-10-21`。body：`model`、`max_tokens`、`system`、
`messages:[{role:user}]`，外加 `output_config.effort = "low"` + `thinking.type = "disabled"`（翻译、纠错要快；
Haiku 5.5 在 high 档以下可以关思考）。模型不认这两项回 400（错误信息里提到 effort / thinking）→ 不带再发一次。
回复只取 `type == "text"` 的块；`stop_reason == "refusal"` 当拒答。默认模型 `claude-haiku-5-5`（快、便宜），可自填。

### 3.2 OpenAI 兼容

`POST {base}/chat/completions`，有 Key 才带 `Authorization: Bearer`（Base URL 指向 localhost / 127.0.0.1 时可不填 Key，
Ollama 即 `http://localhost:11434/v1`）。新一些的 OpenAI 模型只认 `max_completion_tokens`：400 里提到 `max_tokens` 就换字段重发。

### 3.3 服务预设（2026-11-09 用户追加：地址除了自定义，也给常用服务的默认值）

服务菜单分三组：Claude ／ 预填了地址和默认模型的 OpenAI 兼容服务 ／ 本机 Ollama 与自定义地址。预设都走 OpenAI 兼容这条协议
（`AICloudProvider.api`），差别只是默认值；地址和模型都能改（国际站、代理、自建网关），留空用默认。

| 服务 | 默认 Base URL | 默认模型 |
|---|---|---|
| Anthropic Claude | `https://api.anthropic.com` | `claude-haiku-5-5` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | `gemini-2.5-flash` |
| DeepSeek | `https://api.deepseek.com/v1` | `deepseek-chat` |
| 通义千问（阿里云百炼） | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `qwen-plus` |
| Kimi（月之暗面） | `https://api.moonshot.cn/v1` | `moonshot-v1-8k` |
| 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4` | `glm-4-flash` |
| OpenRouter | `https://openrouter.ai/api/v1` | `openai/gpt-4o-mini` |
| 硅基流动 SiliconFlow | `https://api.siliconflow.cn/v1` | `Qwen/Qwen2.5-7B-Instruct` |
| Groq | `https://api.groq.com/openai/v1` | `llama-3.1-8b-instant` |
| Ollama（本机） | `http://localhost:11434/v1` | 必填（如 `qwen2.5:7b`），不用 Key |
| 自定义（OpenAI 兼容） | 必填 | 必填 |

- 通义千问、Kimi 默认国内站；海外账号改成各自的国际站地址。
- 默认模型选各家响应快、便宜的那档；哪天下线了，「测试连接」会报出来，填个新的即可。
- 有官方申请页的服务，Key 输入框下给「获取 API Key」链接。

### 3.4 错误与退回

| 错误 | 来源 | 冷却 30 秒 |
|---|---|---|
| `timeout` | `URLError.timedOut` | ✓ |
| `offline` | 其他 `URLError`（断网、DNS、连不上） | ✓ |
| `unauthorized` | 401 / 403 | ✓ |
| `throttled` | 429 | ✓ |
| `http(5xx)` | 服务端错误 | ✓ |
| `http(4xx)` / `badResponse` / `refused` | 单句问题 | ✗ |
| `rateLimited` | 本机每分钟上限到了（没发出去） | ✗ |
| `notConfigured` | 配置不完整 | ✗ |

任何错误：本地模型已下载 → 改走本地，`usedFallback = true`；没有 → 抛给调用方（字幕条提示「翻译出错」，划词浮层显示原因）。
**冷却**：服务级错误后 30 秒内直接走本地，不让每句字幕都先等一次超时；改了设置（`refreshCloudConfiguration`）清掉冷却。
日志只记错误描述，不记 Key、不记内容。

## 4. 云端配置与安全

| 键 | 取值 | 默认 |
|---|---|---|
| `ai.cloud.provider` | `AICloudProvider` 的 rawValue（`anthropic` / `openai` / `gemini` / … / `ollama` / `openAICompatible`） | `anthropic` |
| `ai.cloud.<前缀>.model` | 模型名 | 空 = 该服务的默认模型（§3.3） |
| `ai.cloud.<前缀>.baseURL` | http(s) 地址 | 空 = 该服务的默认地址（§3.3） |

前缀 = rawValue，例外两个沿用最初版本：自定义用 `ai.cloud.openai`，所以 OpenAI 官方这一项另起 `ai.cloud.openaiOfficial`。
| `ai.cloud.maxTokens` | 128…8192 | 1024 |
| `ai.cloud.perMinute` | 10…600 | 120（实时字幕每分钟几十次：定稿逐句 + 降频后的草稿） |

- Key：钥匙串 generic password，service `com.baobox.app`、account `ai.cloud.<provider>.apiKey`，
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`（同 `ClipboardCrypto`）。不进 UserDefaults、不写日志；设置页从不回显已存的 Key，
  只显示「已保存」，可替换 / 删除。每个服务各存各的 Key、地址和模型，切换不丢。
- 「配置完整」= 地址像样 + 有模型 + 有 Key（或 OpenAI 兼容地址指向本机，如 Ollama）。`AIService.cloudConfigured` 发布出去，设置页和引擎选择据此置灰。
- 「测试连接」：发一句「Reply with the single word: OK」，不计入每分钟次数、不触发退回。

## 5. 各调用方

| 位置 | 用途 | 本地模型 | 能选云端 | 设置键 |
|---|---|---|---|---|
| `SelectionTranslatePanel` | 划词翻译 | Hy-MT2 | ✓ | `selectiontranslate.engine` |
| `LiveTranslateTranslator` | 字幕与同传、会议的翻译 | Hy-MT2 | ✓ | `livetranslate.engine` |
| `LiveTranslateCorrector` | 中文识别纠错 | Qwen3 | ✓ | `livetranslate.correctionEngine`（`local` / `cloud`，默认 `local`） |
| `LiveTranslateTranscript` | 纪要（自由听译、会议） | Qwen3 | P0 不开放 | — |
| `MeetingReports` | 周报概述 | Qwen3 | P0 不开放 | — |
| `DictationPolisher` | 听写润色 | Qwen3 | P0 不开放 | — |

### 5.1 翻译引擎选项（每模块一个）

`auto`（= 以前的行为：macOS 15+ 系统翻译，不支持 / 失败再离线模型）/ `system` / `offline` / `cloud`。

- **云端只能手动选**，「自动」不会自己切到云端（要花钱，内容也会离开本机）。
- 选了云端但云端没配置好：有离线模型就用离线模型，都没有按「没有可用引擎」处理（给下载入口）。
- **升级兼容**：新键没值时读旧键 `translation.engine`（只读、不删、不写），用户什么都不改就和以前一样；降级回旧版本也不坏。
  设置页的 `@AppStorage` 默认值同样取旧键的值。
- 系统翻译失败时退回离线模型只在 `auto` 下发生（同以前）；云端失败的退回在 `AIService` 里做。

### 5.2 选云端时告诉用户会发出去什么

引擎区块选中「云端服务」时下方显示：划词助手 = 选中的文字；字幕与同传和会议 = 识别出来的每一句话（AI 纠错也选云端时连同上文）。
「AI」页另有一段「会发出去什么」总说明。

### 5.3 实时字幕走云端的节奏

现在是「定稿全翻 + 每个方向只留最新一句草稿」。云端时：

- **定稿**照常逐句翻，超时 4 秒；超时的那一句由 `AIService` 改用本地译文，不卡住后面的句子。
- **草稿降频**：两次云端草稿之间至少隔 2 秒（`cloudPartialInterval`），超时 3 秒。等待期间来了定稿先翻定稿，草稿被更新的替换掉也正好。
- 取舍：没选「草稿用本地、定稿用云端」—— 两边译文风格不一样，草稿换成定稿时字幕会整句闪一下；降频后草稿慢一点，但一句话里风格一致。
- 云端时不让本地翻译模型常驻（不白占 1 GB 内存）；真要退回本地时再加载，之后照常空闲 10 分钟才退。
- 字幕条状态行的翻译引擎显示「云端服务」；第一次退回本地时提示「云端不可用，已改用本地」（每次会话提示一次）。

### 5.4 AI 纠错与「纠错 + 翻译」合一

- 纠错走哪边按 `livetranslate.correctionEngine`。例外：会议只转录、不翻译（纠错模式 `.always`）时一律本地 —— 会议文档定过「数据不出本机」，翻译之外不往外发。
- 纠错与翻译**都**走云端时，纠错请求带上目标语言，一条提示词「先改识别错字再翻译」，回一行 JSON `{"corrected", "translation"}`，少一次往返。
  译文直接落到这一单元，不再进翻译队列。
- 合一请求失败 / JSON 解析不了 → 照旧只纠错（会退回本地），译文交给翻译队列。纠正结果被 `accept` 判成「在改写」没采用时，
  译文是照改写后的句子翻的，也丢掉，交给翻译队列按原文翻。
- 走本地时纠错模型照旧常驻；云端时不常驻。纠错模型还在加载时先不纠、直接翻的规则只对本地生效。

### 5.5 纪要、周报、润色（待定 1 的结论）

P0 保持只走本地：入口换成 `AIService.generate(..., route: .local)`，行为不变。会议文档定过「数据不出本机」；
要开放云端是 P1，届时各自加一个「本地 / 云端」选择，并在会议文档里改口径。

## 6. 设置页「AI」

位置：侧边栏「通用 / 快捷键」之后（id `ai`）。

1. 说明：默认走本地；只有在某个工具里手动选了云端才用。
2. 云端服务：服务商、Base URL（留空用默认）、模型（留空用默认）、API Key（SecureField + 保存 / 删除）、测试连接、就绪状态。
   模型和地址在回车 / 离开页面 / 测试前保存，不在每次敲键时写（免得半截地址触发配置变化）。
3. 用量上限：单次回复上限、每分钟次数上限。
4. 会发出去什么。
5. 本地模型：Hy-MT2（翻译）、Qwen3-1.7B（通用）的下载 / 暂停 / 删除。

模块设置页：引擎选择区块（云端未配置时该项写「云端服务（未配置）」，下面一行「云端服务未配置」+「去配置…」跳到「AI」页）。

**待定 3 的结论**：模块页现有的模型下载行**两边都留**。选「离线模型」的人在模块页就能下，不用跳页；「AI」页是一览。

## 7. 待定 2 的结论

P0 两家都做。Claude 是默认（响应快、便宜的 Haiku），OpenAI 兼容一条接口覆盖 OpenAI、各家兼容服务和本机 Ollama。
两家的差别全在 `AICloudClient` 里，调用方不感知。

## 8. 不做 / P1

- 云端流式输出（#55 的对话、#85 的长回答要用）。
- 用量统计：按模块记请求数和 token，在「AI」页里看。
- 纪要、周报、听写润色的云端选项。
