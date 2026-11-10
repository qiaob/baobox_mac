# AI

[简体中文](../ai.md) · English

Settings → **AI** (in the sidebar below General / Shortcuts). Every Baobox feature that uses an AI model gets its model here:

- **Models on this Mac**: run locally, free, nothing leaves the Mac, but they use memory and disk.
- **Cloud models**: better results and no local memory used, but they need an API key, cost per use, and the text is sent
  to the provider.

Everything ships using local models ("Automatic" for translation); cloud models are only used when you pick them.

The page has three panes at the top: **Features / On This Mac / Cloud**.

## Features

Features that use a model are grouped by tool, one row each: the feature name, a model menu, and one line of status.

| Tool | Feature | Used for | Default | Sent when set to a cloud model |
|---|---|---|---|---|
| Meeting | Caption Translation | Translation in Subtitles & Interpreting, and in meetings once Subtitles are on | Automatic | every recognized sentence |
| | AI Correction | Fixing recognition mistakes in Chinese | Qwen3-1.7B on this Mac | each recognized Chinese sentence with the preceding context |
| | Meeting Minutes | Minutes after a meeting, and Regenerate Minutes in the library | Qwen3-1.7B on this Mac | the meeting's full transcript and notes |
| | Weekly Overview | The overview in this week's report | Qwen3-1.7B on this Mac | the week's meeting summaries |
| Selection Assistant | Selection Translation | The selection assistant's "Translate" | Automatic | the selected text |
| | Selection AI Actions | Polish, Rewrite, Natural English, Explain, Summarize, custom actions | Qwen3-1.7B on this Mac | the selected text you run an action on |
| Dictation | AI Polish | Tidying dictation into written text | Qwen3-1.7B on this Mac | the dictated text |

Each tool's own settings page has the same row (plus "AI Settings…" to jump back here); changing either one changes both.

### What's in the model menu

- Translation features list "Automatic" and "System Translation" first. "Automatic" says what it means on this Mac: from
  macOS 15 it's "Automatic (System Translation)", switching to the local offline translation model for languages the system
  can't translate or when it fails; on older systems it's "Automatic (Hy-MT2-1.8B on this Mac)".
- The "On This Mac" group: every local model, with "(not downloaded)" next to the ones you don't have yet. The
  translation-only Hy-MT2 appears for translation features only.
- One group per cloud provider, listing the models you added under Cloud; incomplete ones say "(not set up)".

### The status line

Each row says one thing:

- **The chosen model can't be used right now** (orange): "Not downloaded" with "Download…"; "no API key", "invalid Base URL"
  or "no model ID" with "Set Up…"; "Needs macOS 15"; while downloading, "Downloading 42%".
- **It's the suggested model**: "Suggested model".
- **It isn't**: "Suggested: Qwen3-8B (writes best on this Mac)" with "Switch" on the right, which switches to it.

Suggestions follow the feature and are picked from the local Qwen3 models only:

| Feature | Suggested | Why |
|---|---|---|
| Caption Translation, Selection Translation | Automatic | built in, free (on a Mac without System Translation it's the local Hy-MT2: free and fast) |
| AI Correction, AI Polish, Selection AI Actions | Qwen3-1.7B | the fastest: about a second per sentence, and these can't wait |
| Meeting Minutes, Weekly Overview | The largest Qwen3 this Mac runs comfortably (Qwen3-8B with 16 GB of memory) | writes best on this Mac; a few extra seconds don't matter after a meeting. On a Mac with little memory it's 1.7B (the most this Mac can run) |

Hover a suggestion to read the full reason.

### Usage Limits and Privacy

At the bottom of the Features pane, collapsed by default; even collapsed, its title shows today's usage, such as
"Today: 123 requests · 4.5k tokens" (orange once the cap is reached):

- **Max requests per day**: 500 by default (100–10000). Past it, cloud requests use the local model and the pet asks whether to
  "Allow 500 More"; the same button appears in this section. Services on this Mac (like Ollama) cost nothing and don't count.
- **Max requests per minute**: 120 by default (10–600).
- **Max reply length**: 4096 tokens by default (128–8192). Longer replies are cut off; a cut-off reply falls back to the local
  model.

All of them cover all cloud models combined, to avoid surprise bills; requests over the limit use the local model instead (if
downloaded). Below them is a list of what's being sent to whom right now, such as "Caption Translation: sends every recognized
sentence to “Anthropic Claude”." With no feature on a cloud model it reads
"No feature uses a cloud model right now, so nothing is sent."

## On This Mac

This pane only manages models:

- **This Mac**: chip and memory; memory and disk available now.
- **Installed Models**: one row each with its status (Not running / Starting… / Running · using X GB), "Start / Stop", a
  "Start at launch" switch, and delete. Downloads in progress show here too, with pause and resume.
- **Add a Model**: the "Install a model" menu groups models by this Mac's memory: **Runs Well on This Mac / Runs, but Uses a
  Lot of Memory / Not Enough Memory**. Pick one to see what kind of model it is, its file size and roughly how much memory it
  uses while running, then click "Download".

The models on offer:

| Model | Notes |
|---|---|
| Hy-MT2-1.8B | Tencent Hunyuan, translation only; the default local model for translation features |
| Qwen3-0.6B / 1.7B / 4B / 8B / 14B / 32B | Alibaba Qwen, general, good at Chinese and English; 1.7B is the default local model for general features, 0.6B is the smallest with so-so quality |
| Qwen3-30B-A3B | Alibaba Qwen, mixture of experts: large but fast |
| Gemma 3 4B / 12B / 27B | Google, good at English and other languages |
| Llama 3.1 8B | Meta, good at English, average at Chinese |
| GLM-4-9B | Zhipu, good at Chinese |
| Phi-4-mini | Microsoft, small and capable, good at English |
| DeepSeek-R1 7B / 14B | Reasoning: thinks before answering, so it's slow |

The last item in the menu, "Custom (paste a Hugging Face link)…", takes the link of a `.gguf` file on Hugging Face (its file
page or download link) and "Add and Download" fetches it. Quality and speed aren't guaranteed.

Safeguards:

- Downloading a "Not Enough Memory" model asks first ("This Mac can't run it well"); when disk space is short you're told to
  free some up.
- Before starting a model Baobox checks the available memory and asks first if it may run short ("Memory may run short").
- Every download is checked for size and checksum.

**When a model is running**: models with "Start at launch" are started when Baobox launches and stay loaded until you click
"Stop". Others load when a feature needs them and quit after 10 idle minutes. To start Baobox itself at login, turn that on
under Settings → General.

## Cloud

"Providers": one row per account. Collapsed, it shows the name, which service, the key status (Key saved / No API key /
Local, no key needed) and the number of models. Expanded:

- **Name**: what the model menus show.
- **Base URL**: leave it empty for the provider's default; change it for an international endpoint, a proxy or a self-hosted
  gateway. It must be `https://`; only services on this Mac (like Ollama) may use `http://`, since anything else would send your
  key and text unencrypted.
- **API key**: paste it and click "Save". It's kept in your Keychain and never shown again — the field just reads
  "Saved (type a new one to replace it)" — and can be deleted. Services with an official sign-up page get a "Get an API key" link.
- **Models**: one row each, with "Display name (optional)" and "Model ID (pick or type)", "Test", and delete. Once the key is
  saved, the list switches to every model the provider returns (for Ollama, the models installed on this Mac); before that it
  lists common ones. Below: "Add Model" and "Refresh List".
- At the very bottom, "Delete Provider…": its models and saved key go too, and features using those models go back to their
  defaults.

One provider can hold several models (a fast one for captions, a strong one for minutes, say), and you can add several
accounts for the same service (a work key and a personal key).

The "Add Provider" menu has three groups:

1. Anthropic Claude;
2. services with the address and a default model filled in: OpenAI, Google Gemini, DeepSeek, Qwen (Alibaba Cloud Model
   Studio), Moonshot Kimi, Zhipu GLM, OpenRouter, SiliconFlow, Groq;
3. Ollama (on this Mac), Custom (OpenAI-compatible).

Ollama sits in this pane but runs on your own Mac: no key needed, and nothing leaves the Mac. Start Ollama and pull a model
first. Very large models are flagged, and testing one asks first (loading it could fill up memory).

Apart from the API key, fields in this pane save as you type.

## When a cloud model fails

When there's no network, a timeout, a rejected key, rate limiting, a server error, this Mac's own limit is reached, or the reply
is cut off, that request uses the local model of the same kind instead (if downloaded) and you see "Cloud service unavailable,
using the local model instead." After a service-level error, requests to that provider go to the local model for the next 30
seconds, so you don't wait for a timeout on every sentence. If the local model isn't downloaded either, the feature shows an
error (the subtitle bar says translation failed, for example).

## Data and privacy

- Only features set to a cloud model send anything, and only the text they need; everything else stays on this Mac.
- API keys are kept in the Keychain, never in preferences or logs.
- Local model files live in `~/Library/Application Support/Baobox/Translation/models/` and download from Hugging Face (Qwen3
  and Hy-MT2 fall back to ModelScope).
- Accounts, model IDs and each feature's choice are stored in UserDefaults.

## Troubleshooting

- **The menu says "(not downloaded)"**: click "Download…" on that row; it jumps to On This Mac with the model already picked.
- **The Mac got slow after picking a large model**: pick one from "Runs Well on This Mac"; click "Stop" on models you aren't
  using, or turn off "Start at launch".
- **"Test" fails**: check the API key, Base URL and model ID as the message says. If Ollama reports "Couldn't reach the service
  on this Mac. Is Ollama running?", start it; a large model takes a while to load the first time.
- **"The reply hit the length limit and was cut off"**: raise "Max reply length" under Usage Limits and Privacy.
- **"Reached this Mac's per-minute request limit"**: raise "Max requests per minute" under Usage Limits and Privacy.
- **"Reached today's cloud request limit"**: click "Allow 500 More" in the pet's bubble or under Usage Limits and Privacy, or raise
  the daily cap.

Technical details: [docs/ai-service/DESIGN.md](../../ai-service/DESIGN.md) and
[docs/local-models/DESIGN.md](../../local-models/DESIGN.md).
