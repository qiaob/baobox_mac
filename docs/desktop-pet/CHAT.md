# 桌面宠物：AI 对话

对应 issue #55（关联 #44）。宠物会聊天：按角色的性格回复，API Key 由用户自己配，每个角色有自己的声音。

**已定（2026-11-06）**：P0 只做 Anthropic Claude + OpenAI 兼容接口；声音只用系统语音；**不做语音输入**
（用户定：「不需要语音交互驱动」）—— 只打字，回复照样朗读。

## 1. 入口

- 宠物右键环形菜单内圈第一格「聊天」；快捷键「和宠物聊天」（出厂不绑定，`pet.chat`，再按一次关闭）。
- 聊天框（`PetChatPanel`，300 × 320）出在宠物头顶，放不下就放旁边；是宠物窗的子窗口，拖宠物时跟着走。
  不激活 Baobox（`nonactivatingPanel`，能打字、原来的 App 还是前台）；Esc 或 × 关闭，万一 Baobox 被激活了就把前台还给原来的 App。
- 聊天框开着时宠物站住、面向用户（和气泡、环形菜单一样算 `held`）。出场 / 退场、换形象、关掉宠物、借给休息画面时自动关掉。
- 外圈「清空对话」：清掉当前角色的上下文和本机记录。

## 2. 一次对话

1. 回车发送。每分钟次数超过上限（默认 6）就不发，用角色口吻提示一句。
2. 上下文 = 这个角色最近 10 轮（一问一答成对存）+ 这一问；系统提示词 = 人设 + 桌宠的说话规矩（简短、口语、跟着用户的语言、
   不能看屏幕 / 剪贴板 / 不能操作电脑、开头一个情绪标签）。默认不带任何屏幕、剪贴板内容。
3. 回复流式逐字出现在聊天框里；开头的 `[happy]` 之类情绪标签藏掉，映射到 VRM 表情（happy / sad / surprised / angry / relaxed，
   `neutral` 不变），读完复原。
4. 说完整一句（。！？.!?…~ 换行）就排进朗读，不等整段。
5. 成功才把这一问一答写进上下文和 `~/Library/Application Support/Baobox/Pets/<角色>/chat.json`（后台写，最多 20 条）；
   出错那一问不进上下文。没聊过时显示开场白（只显示 + 朗读，不进上下文）。

错误都用角色的口吻说：没填 Key、401/403（Key 不对）、429（被限流）、5xx/529（服务忙）、超时、断网、模型拒答（refusal）、
其他 HTTP 错误（附状态码与服务给的说明）、读不懂的返回（多半是模型名或 Base URL 填错）。

## 3. AI 服务（设置 › 桌面宠物 › AI 对话）

| 项 | 说明 |
|---|---|
| 服务商 | Anthropic Claude（默认）/ OpenAI 兼容接口 |
| Base URL | 只有 OpenAI 兼容有，填到 `/v1`；默认 `https://api.openai.com/v1`，本机 Ollama 填 `http://localhost:11434/v1` |
| 模型 | Claude 默认 `claude-haiku-5-5`（响应快、便宜）；OpenAI 兼容默认 `gpt-4o-mini`，可改 |
| API Key | 钥匙串（`com.baobox.app.pet.ai`，每家一条，`WhenUnlockedThisDeviceOnly`），不进 UserDefaults、不写日志；输入框不回显已存的 Key。OpenAI 兼容可留空（本机模型） |
| 测试连接 | 发一句最短的话，通了显示回复开头，不通显示和聊天里一样的原因 |
| 单次回复上限 | `max_tokens`，默认 600（100–4000） |
| 每分钟次数 | 默认 6（1–60） |
| 朗读回复 | 默认开 |
| 开会、录屏、勿扰时也出声 | 默认关：这些时候（以及「安静一下」、Baobox 正在录音时）只出文字 |

页面底部写明「对话内容会发给你配置的 AI 服务」。

**请求**（`PetAIClient`，`URLSession.bytes` 逐行读 SSE，无第三方依赖，在主线程上 await、不阻塞）：

- Claude：`POST https://api.anthropic.com/v1/messages`，头 `x-api-key`、`anthropic-version: 2026-10-21`；
  体 `model / max_tokens / system / messages / stream: true / output_config.effort: "low"`（闲聊不需要深想，回得快也便宜；
  不发 temperature 等采样参数）。读 `content_block_delta` 里的 `text_delta`，`message_delta` 的 `stop_reason: refusal`、
  `error` 事件按错误处理，其他事件（思考块、用量）跳过。
- OpenAI 兼容：`POST {Base URL}/chat/completions`，有 Key 才带 `Authorization: Bearer`；`system` 作为第一条消息；
  读 `choices[0].delta.content`，`data: [DONE]` 结束。

## 4. 角色人设与声音

`pet.json` 新增三个可选字段（写错类型的 `voice` 当没写，不影响形象加载）：

```json
{
  "model": "model.vrm",
  "persona": "你是……（性格与说话方式）",
  "voice": { "pitch": 1.2, "rate": 0.5, "zh": "<系统声音 identifier>", "en": "<系统声音 identifier>" },
  "greeting": "开场白"
}
```

优先级：设置里改过的 > pet.json > 内置默认。内置默认按角色大类给（猫：傲娇黏人带「喵」、狗：热情带「汪」、兔：轻声细语、
凍香：开朗的二次元少女、炼金术师少女：沉着书卷气、机器人：一板一眼冷幽默、其他：通用桌宠），人设文案随界面语言。
设置页「形象」下面有当前角色的「性格与声音」：人设可改、可恢复默认；中文 / 英文声音各选一个系统声音（默认 = 该语言的系统默认）、
音调、语速、试听。

## 5. 声音与嘴型（`PetVoice`）

- 自己一个 `AVSpeechSynthesizer`，从系统默认输出出声：不碰同传「朗读译文送进会议」那套输出。
- 回复含汉字用中文声音，否则英文声音；音调、语速按角色。
- 嘴型：系统每读到一个词回调一次（`willSpeakRangeOfSpeechString`），按字数估这个词读多久，期间嘴一张一合，词间合上。
  VRM 直接设 `aa` 表情的形变权重；毛绒 / 动物模型轻轻一鼓一鼓；2D 形象轻轻弹。没有拿音频算音量（那要另开一路播放）。

## 6. 没做的（issue #55 的 P1）

云端语音合成、主动搭话、工具调用（查会议 / 开专注）、角色记忆。
