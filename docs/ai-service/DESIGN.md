# AI 服务层设计

> issue #86。第一版（PR #88）是同一时间只有一个云端服务，各模块只能选「本地 / 云端」。2026-11-09 用户试用后改了需求：
> 可以接多个服务商，每个服务商下面挂多个有名字的模型；每个功能单独指定用哪个模型，在「AI」页像快捷键页那样集中配置，
> 模块自己的设置页也能改。本文按改后的需求写，PR #88 的 HTTP 客户端、钥匙串、退回本地、服务预设原样沿用。
> #85（划词助手 AI 动作）、#55（宠物 AI 对话）都建在这一层上，到时各声明一个功能即可。

## 1. 需求

- **服务商账号**：可以接任意多个，同一家也能接多个（比如公司和个人两个 Key）。每个账号存一份 Key 和地址，可以起名。
- **模型**：挂在账号下面，一个账号可以挂多个（比如 Haiku 给字幕、Sonnet 给纪要）。每个模型可以起名，下拉框里显示的就是这个名字。
- **功能**：用到模型的地方各算一个功能，由模块声明。每个功能单独选模型：
  - 翻译类（划词翻译、字幕翻译）：自动 / 系统翻译 / 离线模型 / 任一云端模型；
  - 通用类（AI 纠错、会议纪要、周报概述、听写润色）：本地模型 / 任一云端模型。
- **「AI」页**：上半部分管理服务商和模型；下半部分按模块列出所有功能，每个功能一个下拉框（同快捷键页）。模块设置页里嵌同一行，改哪边都一样。
- **默认行为不变**：翻译类默认「自动」（升级时读旧键 `translation.engine`），通用类默认本地。云端只能手动选。
- **出错退回**：云端出错（断网、超时、401/403、429、5xx、本机限额、回复被截断）时，改用同类的本地模型（已下载的话），并提示「云端不可用，已改用本地」。
- **会议纪要、周报、听写润色也能选云端**（2026-11-09 用户定）。默认仍是本地，选了云端才发，行下面写明发出去的是什么。
  这推翻了 PR #88 的「P0 只走本地」；「会议只转录、不翻译时纠错强制本地」的特例一并去掉，统一按功能表里选的走。

## 2. 分层

```
调用方（划词、字幕与同传、纠错、纪要、周报、润色）
        │  translate / generate / correctAndTranslate（参数 route: .local / .cloud(模型 id)）
        ▼
AIService（Core/AI/AIService.swift，@MainActor 单例）
  ├─ .local         → OfflineTranslator.shared（Hy-MT2，翻译）/ .corrector（Qwen3-1.7B，通用生成）
  │                    进程、下载、keep-alive 仍由 OfflineTranslator 负责
  └─ .cloud(模型 id) → AIModelStore 取「账号地址 + Key + 模型名」→ AICloudClient（URLSession async）
                       失败 → 本地（有的话），Reply.usedFallback = true

AIModelStore（Core/AI/AIModelStore.swift）：账号、模型（UserDefaults 里的 JSON）+ Key（钥匙串）
AIFeatureSettings（Core/AI/AIFeature.swift）：功能 → 选择（UserDefaults `ai.feature.<功能 id>`）
功能定义：ToolModule.aiFeatures() → [AIFeatureDefinition]（同 hotkeys()；框架不认识具体工具）

系统翻译（TranslationSession）不进服务层：框架只认挂在视图上的 `.translationTask`，会话继续挂在划词浮层和字幕条上；
`TranslationSettings.resolve(功能)` 只判断这次该用哪个引擎。
```

| 文件 | 内容 |
|---|---|
| `Core/AI/AIFeature.swift` | `AIFeature`（id、类型、旧键）、`AIEngineChoice`、`AIFeatureDefinition`（界面文案）、`AIFeatureSettings`（读写选择） |
| `Core/AI/AIModelStore.swift` | `AICloudAccount`、`AICloudModel`、增删改、配置是否完整、Key 的内存缓存 |
| `Core/AI/AIModelCatalog.swift` | 模型名下拉列表：内置常用名单 + 从服务商拉取的全部模型（§3.4） |
| `Core/AI/AICloudSettings.swift` | 服务预设 `AICloudProvider`、用量上限、`AIKeychain` |
| `Core/AI/AIService.swift` | 路由、云端公共流程（配置 → 本机限额 → 冷却 → 请求 → 退回）、`AIPrompts` |
| `Core/AI/AICloudClient.swift` | 两家的 HTTP 请求与错误归类 |
| `Settings/AISettingsView.swift` | 「AI」页：三栏（功能 / 本机模型 / 云端模型），云端栏的服务商表单 |
| `Settings/AISettingsNavigation.swift` | 三栏切换，以及「去下载」「去填写」的定位 |
| `Settings/LocalModelsPane.swift` | 本机模型栏 |
| `Settings/AIFeatureRow.swift` | 一个功能的模型下拉框（「AI」页和模块页共用，同 `HotkeyRow`） |
| `Settings/ModelComboBox.swift` | 模型名组合框（NSComboBox：下拉选，也能直接输入） |
| `Core/Translation/TranslationSettings.swift` | `resolve(功能)`、`TranslationEngineKind`（`.cloud(模型 id)`） |
| `Core/Translation/TranslationEngineSection.swift` | 模块设置页的翻译区块：功能行 + 说明 + 离线模型下载 |

## 3. 数据

### 3.1 服务商账号与模型

| 键 | 内容 |
|---|---|
| `ai.accounts` | JSON 数组：`{id, name, provider, baseURL}`。`provider` = `AICloudProvider` 的 rawValue；`baseURL` 空 = 该服务的默认地址 |
| `ai.models` | JSON 数组：`{id, accountID, name, model}`。`name` 空 = 显示模型名 |

- id 用 UUID 字符串。JSON 解不开或字段不对时当空列表，决不 crash。
- **Key**：钥匙串 generic password，service `com.baobox.app`、account `ai.account.<账号 id>.apiKey`，
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`（同 `ClipboardCrypto`）。不进 UserDefaults、不写日志；设置页从不回显已存的 Key，
  只显示「已保存」，可以替换、删除。启动时读进内存，请求时不再碰钥匙串。
- **新建账号**：名字默认 = 服务名，同一家第二个账号叫「服务名 2」，以此类推。新账号自动带一个模型：有默认模型的用默认模型，
  Ollama 和自定义带一个空的，让用户填。
- **配置完整**（这个模型能用）= 账号还在 + 地址像样（http/https、有 host）+ 模型名不空 + 有 Key（或 OpenAI 兼容地址指向本机，如 Ollama）。
- **删除**：删模型时，选了它的功能改回默认；删账号时连带删掉它的模型和 Key，功能同样改回默认。

### 3.2 功能与选择

| 键 | 取值 | 默认 |
|---|---|---|
| `ai.feature.<功能 id>` | `auto` / `system` / `local` / `model:<模型 id>` | 翻译类 `auto`、通用类 `local` |

- `auto`、`system` 只对翻译类有意义；`local` = 翻译类的离线模型 Hy-MT2、通用类的 Qwen3-1.7B。
- **升级兼容**：翻译类功能的新键没值时读旧键 `translation.engine`（`auto` / `system` / `offline`，`offline` 当 `local`），只读、不删、不写。
  用户什么都不改，升级后和以前一样；降级回旧版本也不坏。
- 选的模型已被删掉：按默认处理（删的时候已经清掉，这里是兜底）。选的模型配置不完整：翻译类改用离线模型（有的话），通用类改用本地；行下面标橙色提示。
- 改了选择发通知 `AIFeatureSettings.didChange`（userInfo `id`）。字幕与同传运行中收到自己的功能就重启，会话按新设置跑。

### 3.3 功能清单

| 功能 id | 模块（「AI」页分组） | 类型 | 用在 | 选云端时发出去的 |
|---|---|---|---|---|
| `selectiontranslate.translate` | 划词助手 | 翻译 | `SelectionTranslatePanel` | 选中的文字 |
| `livetranslate.translate` | 会议 | 翻译 | `LiveTranslateTranslator`（字幕与同传、会议） | 识别出来的每一句话 |
| `livetranslate.correct` | 会议 | 通用 | `LiveTranslateCorrector` | 识别出来的中文句子连同上文 |
| `meeting.minutes` | 会议 | 通用 | `LiveTranslateMinutes`（会后纪要、重新生成） | 整场会议的转写和速记 |
| `meeting.weekly` | 会议 | 通用 | `MeetingWeeklyReporter` | 一周各场会议的纪要摘要 |
| `dictation.polish` | 听写 | 通用 | `DictationPolisher` | 听写出来的文字 |

字幕与同传的两个功能由会议模块声明：字幕与同传的设置区块嵌在会议页里，且下个版本这个入口就并进会议，不用再挪。
功能 id 沿用 `livetranslate.*`，跟着引擎走，与哪个模块声明无关。

### 3.4 模型列表（模型名的下拉框）

2026-11-09 用户要求：各家支持的模型直接列在下拉框里，也能自己输入。

- 模型名输入框是组合框（`ModelComboBox`，NSComboBox）：可以从下拉列表里选，也能直接输入列表里没有的；打字时按列表自动补全。
- 列表来源：
  1. **服务商返回的全部模型**：账号的 Key 存好（或地址指向本机）后自动拉取。Claude 用 `GET /v1/models?limit=1000`，
     OpenAI 兼容用 `GET {base}/models`。**Ollama 返回的就是本机已安装的模型**。Gemini 的 OpenAI 兼容接口返回的 id 带 `models/` 前缀，去掉再用。
  2. **内置的常用名单**（`AICloudProvider.suggestedModels`）：没填 Key、拉取失败或服务商返回空时用。它只是起步建议，可能过时，以服务商返回的为准。
- 去掉明显不是对话模型的（名字里带 embed、tts、whisper、dall-e、moderation、audio、realtime、transcribe、image、rerank、speech 等），去重；
  内置名单里有的排前面，其余按字母排。
- 什么时候拉：展开账号时、存了 Key 后、改了地址（停手 0.5 秒后）。Key 和地址都没变、上次也拉成功了，就不重拉；「刷新列表」强制重拉。
  结果只放内存（`AIModelCatalog`），按账号存。
- 模型列表下面一行说明下拉列表的来源：服务商返回的 N 个模型 / 常用模型（保存 Key 后换成全部）/ 拉取失败的原因
  （本机服务连不上时提示「Ollama 启动了吗？」）。

## 4. 接口与云端请求

### 4.1 AIService

```swift
enum AIRoute: Hashable { case local; case cloud(String) }   // 模型 id
AIService.shared.translate(text, to:, from:, glossary:, route:, timeout:) async throws -> Reply
AIService.shared.generate(prompt, maxTokens:, sampling:, route:, timeout:) async throws -> Reply
AIService.shared.correctAndTranslate(text, context:, to:, glossary:, modelID:, timeout:) async throws -> (corrected, translation)
AIService.shared.route(for: 通用类功能) -> AIRoute          // 配置不完整的云端模型 → .local
AIService.shared.isReady(route, local: .translation / .generation) -> Bool
AIService.shared.testConnection(modelID:) async -> String?  // nil = 通了
struct Reply { text; route; usedFallback }
```

- `sampling`（温度等）只对本地生效：Claude 新版 API（`anthropic-version: 2026-10-21`）一律不收采样参数，发了会 400。
- 云端的 `maxTokens` = `min(用户上限, max(256, 调用方要的))`：调用方给本地的量很紧（纠错只给字数 ×2），云端模型可能先想再答，
  所以给点余量，但永远不超过用户在「AI」页设的上限。

### 4.2 Claude

`POST {base}/v1/messages`，请求头 `x-api-key`、`anthropic-version: 2026-10-21`。body 里放 `model`、`max_tokens`、`system`、
`messages:[{role:user}]`，再加 `output_config.effort = "low"` 和 `thinking.type = "disabled"`（翻译、纠错要快；Haiku 5.5 在 high 档及以下可以关思考）。

- 模型不认关思考时会回 400，错误信息里提到 thinking（Opus 5.5、Sonnet 5.5 不允许关）：去掉 `thinking`、**保留** `effort: low` 再发一次。
  错误信息提到 effort / output_config 时两项都去掉再发。PR #88 两项一起去掉，换成 Opus / Sonnet 时会按默认档位带思考跑，字幕明显变慢。
- 回复只取 `type == "text"` 的块。`stop_reason == "refusal"` 当拒答；`stop_reason == "max_tokens"` 当截断（§4.5），
  不把半截译文当完整结果显示。

### 4.3 OpenAI 兼容

`POST {base}/chat/completions`，有 Key 才带 `Authorization: Bearer`（地址指向 localhost / 127.0.0.1 时可以不填 Key，Ollama 即 `http://localhost:11434/v1`）。
新一些的 OpenAI 模型只认 `max_completion_tokens`：400 里提到 `max_tokens` 就换这个字段重发。`finish_reason == "length"` 当截断。

### 4.4 服务预设

添加服务商的菜单分三组：Claude / 预填了地址和默认模型的 OpenAI 兼容服务 / 本机 Ollama 和自定义地址。预设都走 OpenAI 兼容协议
（`AICloudProvider.api`），差别只在默认值；地址和模型都能改（国际站、代理、自建网关），留空就用默认。

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

- 通义千问、Kimi 默认用国内站；海外账号改成各自的国际站地址。
- 默认模型选的是各家响应快、便宜的那档。哪天下线了，「测试连接」会报出来，换一个新的即可。
- 有官方申请页的服务，Key 输入框下给「获取 API Key」链接。

### 4.5 错误与退回

| 错误 | 来源 | 冷却 30 秒 |
|---|---|---|
| `timeout` | `URLError.timedOut` | ✓ |
| `offline` | 其他 `URLError`（断网、DNS、连不上） | ✓ |
| `unauthorized` | 401 / 403 | ✓ |
| `throttled` | 429 | ✓ |
| `http(5xx)` | 服务端错误 | ✓ |
| `http(4xx)` / `badResponse` / `refused` / `truncated` | 只是这一句的问题 | ✗ |
| `rateLimited` | 本机每分钟上限到了（没发出去） | ✗ |
| `notConfigured` | 模型被删了或配置不完整 | ✗ |

- 任何错误：同类本地模型已下载 → 改用本地，`usedFallback = true`；没下载 → 抛给调用方（字幕条提示「翻译出错」，划词浮层显示原因）。
- **冷却按账号算**：一个账号出了服务级错误，30 秒内用它的请求直接走本地，不让每句字幕都先等一次超时；别的账号不受影响。
  改了这个账号的地址、Key 或它下面的模型，冷却就清掉。
- 「测试连接」：发一句「Reply with the single word: OK」，不计入每分钟次数，也不触发退回；回复被截断也算通了（连接、Key、模型名都没问题）。
- 日志只记错误描述，不记 Key、不记内容。

### 4.6 用量上限（全局，所有云端模型合计）

| 键 | 取值 | 默认 |
|---|---|---|
| `ai.cloud.maxTokens` | 128…8192 | 4096 |
| `ai.cloud.perMinute` | 10…600 | 120（实时字幕每分钟几十次：定稿逐句，加上降频后的草稿） |

单次上限默认从 PR #88 的 1024 提到 4096：纪要一次要 900、听写润色最多 2048。1024 会把它们截断，现在截断就退回本地。
每分钟次数是主要的防误刷手段。

## 5. 各调用方

### 5.1 翻译引擎解析（`TranslationSettings.resolve(功能)`）

| 选择 | 结果 |
|---|---|
| `auto` | macOS 15+ 用系统翻译，否则离线模型（已下载的话）；系统翻译不支持这对语言或失败时也改用离线模型（同以前） |
| `system` | 系统翻译（macOS 15+），否则没有可用引擎 |
| `local` | 离线模型（已下载的话） |
| `model:<id>` | 配置完整 → `.cloud(id)`；不完整 → 离线模型（已下载的话） |

都不可用时按「没有可用引擎」处理（给下载入口），同以前。系统翻译失败退回离线模型只在 `auto` 下发生；云端失败的退回在 `AIService` 里做。

### 5.2 实时字幕走云端的节奏（沿用 PR #88）

- **定稿**照常逐句翻，超时 4 秒；超时的那一句由 `AIService` 改用本地译文，不卡住后面的句子。
- **草稿降频**：两次云端草稿之间至少隔 2 秒，超时 3 秒。等待期间来了定稿先翻定稿，草稿被更新的替换掉也正好。
- 云端时不让本地翻译模型常驻（不白占 1 GB 内存），真要退回本地时再加载，之后照常空闲 10 分钟才退出。
  所以第一次退回本地会停顿几秒（加载模型），这是取舍，不是故障。
- 字幕条状态行显示「云端：<模型名>」；第一次退回本地时提示「云端不可用，已改用本地」（每次会话提示一次）。翻译和纠错退回本地都会触发这个提示。

### 5.3 AI 纠错与「纠错 + 翻译」合一

- 纠错用 `livetranslate.correct` 选的模型，会议只转录时也一样（特例已去掉，§1）。
- 纠错和字幕翻译**选的是同一个云端模型**时，纠错请求带上目标语言，一条提示词「先改识别错字再翻译」，回一行 JSON
  `{"corrected", "translation"}`，少一次往返；译文直接落到这一单元，不再进翻译队列。两边选的不是同一个模型就各走各的。
- 合一请求失败或 JSON 解析不了 → 照旧只纠错（会退回本地），译文交给翻译队列。纠正结果被 `accept` 判成「在改写」没采用时，
  译文是照改写后的句子翻的，也丢掉，交给翻译队列按原文翻。
- 走本地时纠错模型照旧常驻；云端时不常驻。「纠错模型还在加载就先不纠、直接翻」只对本地生效。

### 5.4 纪要、周报、润色

- 纪要（会后自动生成、会议库里重新生成）用 `meeting.minutes`，周报概述用 `meeting.weekly`，听写润色用 `dictation.polish`。
- 「能不能生成」按选的那条路判断：云端模型配置完整就能，不要求下载本地模型；本地则要求已下载（同以前）。
- 云端超时：纪要每段 120 秒、周报 60 秒；听写润色仍是总共最多等 8 秒，到点就上原文（同以前）。
- 会议文档的「数据不出本机」改成「默认不出本机，在「AI」页给会议纪要选了云端模型才会发」。

### 5.5 本地模型常驻（keep-alive）

`beginLocalKeepAlive` 会顺带把本地模型加载起来，所以**只在走本地时**调用（字幕翻译、纠错、纪要、周报、听写预热都一样）；
走云端时不加载，出错退回时才现加载。成对调用：开始时记下有没有 begin，结束时只 end 自己 begin 过的。

## 6. 设置页

### 6.1 「AI」页：三栏（2026-11-09 用户要求「设置本身就是功能引导」）

位置在侧边栏「通用 / 快捷键」之后（id `ai`）。顶部一个分段切换（`AISettingsNavigation.pane`），新手进来先看到第一栏：

1. **功能**（默认）：一句说明（本机免费、内容不出这台 Mac；云端效果更好但按量付费）。然后按工具分组（同快捷键页），每个功能一行
   `AIFeatureRow`（§6.2）。最下面「用量上限与隐私」默认收起：单次回复上限、每分钟次数上限（所有云端模型合计）、会发出去什么。
2. **本机模型**（docs/local-models/DESIGN.md）：这台 Mac 的内存和磁盘、「怎么选」推荐说明、已装的模型（启动 / 停止、开机自启、删除）、
   添加模型（下拉框按「推荐 / 可以用 / 内存不够」分组，最后一项「自定义（粘贴 Hugging Face 链接）…」）。
3. **云端模型**：一句说明（效果更好、不占本机内存，但要 Key、按量付费、内容会发给服务商），然后「服务商」：
   每个账号一行可展开（`TappableDisclosure`，双击只算一下），收起时显示名字、服务名、Key 状态和模型数。
   展开后每行左边是固定宽度的标签（名字 / 地址 / API Key / 模型）、右边占满剩余宽度，说明文字都在右边左对齐：
   - 名字、地址（留空用默认）、API Key（加上保存和删除按钮，「获取 API Key」链接）；
   - 模型：列标题「显示名称 / 模型名」，每个模型一行：显示名称（留空显示模型名）、模型名（组合框，下拉选或直接输入）、「测试」、删除；
     行下面小字显示 Ollama 模型大小（太大标橙色、测试前先确认）、测试结果和「用在：划词翻译、字幕翻译」；
     下面是「添加模型」「刷新列表」和下拉列表的来源说明（§3.4）；
   - 最下面靠右是「删除这个服务商…」（删之前确认，提示用到它的功能会改回默认）。

   最下面是「添加服务商」菜单（三组，§4.4），新加的账号自动展开。文本框随输入保存，不用另外点保存（Key 除外）。

**跳转**：功能行上的「去下载」→ 切到本机模型栏，把那个模型选进「添加模型」并滚过去；「去填写」→ 切到云端模型栏，展开那个服务商。
工具设置页里的同一行也一样（先切到「AI」页）。

### 6.2 `AIFeatureRow`（「AI」页和工具设置页共用）

一行：**功能名**（固定宽度）| **下拉框**（固定宽度、靠左，显示「模型 · 来源」）| **状态** | 有问题时右边一个**去处理**按钮。

- 下拉框选项：翻译类先列「自动（系统翻译）」或「自动（本机 Hy-MT2-1.8B）」（写清这台 Mac 上实际用什么）和「系统翻译」；
  然后「本机」一组（「Qwen3-8B · 本机」，没下载的标「未下载」，docs/local-models/DESIGN.md §5）；后面每个账号一组（「Haiku · Anthropic Claude」，
  配置不完整的标「未配置」）。
- 状态：✓「可以用」（灰）；⚠ 橙色「还没下载」「下载中 42%」「缺 API Key」「地址不对」「没填模型名」「需要 macOS 15」。
  能处理的带按钮：本地模型没下载 →「去下载」，云端模型配置不完整 →「去填写」。
- 选了云端模型、能用时，下面多一行小字「会把<发出去的内容>发给<账号名>」；其余情况没有这一行，保持干净。
- 工具设置页的行多一个「AI 设置…」，跳到「AI」页的功能栏。
- 嵌进工具设置页的位置：划词助手、字幕与同传的翻译区块（`TranslationEngineSection`，离线模型下载行仍留在工具页）；
  字幕与同传的纠错区块；会议的记录区块（纪要、周报）；听写的润色区块。

## 7. 升级与兼容

- 已发布版本只有一个旧键 `translation.engine`，作为两个翻译功能的默认值读取（§3.2）。
- PR #88 的设置没发布过，**不迁移**：`ai.cloud.provider`、`ai.cloud.<前缀>.model` / `.baseURL`、`selectiontranslate.engine`、
  `livetranslate.engine`、`livetranslate.correctionEngine`，以及钥匙串里的 `ai.cloud.<服务>.apiKey`。装过 PR #88 构建的人要在新的「AI」页重填一次 Key。

## 8. 不做 / P1

- ~~一键部署本地大模型~~：2026-11-09 用户提前要做，已做，见 docs/local-models/DESIGN.md（没有做成服务商，直接作为「本机」一组进功能下拉框）。
- 云端流式输出（#55 的对话、#85 的长回答要用）。
- 用量统计：按功能记请求数和 token，在「AI」页里看。
- 按功能或按模型单独设上限。
- 字幕草稿和定稿分别选模型（两边译文风格不一样，草稿换成定稿时整句会闪一下，见 PR #88 的取舍）。
- 从服务商自动拉取模型列表（现在手填模型名，「测试连接」验证）。
